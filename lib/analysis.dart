import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'main.dart' show GnssSnapshot;
import 'nav.dart';
import 'offline_map.dart';
import 'terrain.dart';
import 'water.dart';

// ============================================================
// 현재 위치·방향으로 지형 분석을 계속 갱신: 전방 경사, 지형 일출·일몰, 가장 가까운 수원지, 가시권
// 고도 격자(kind=dem)와 기본 지도(kind=basemap)를 내려받아 있어야 동작
// ============================================================

/// 별도 스레드에서 실행 (최상위 함수라 넘기는 값이 문자열·숫자뿐)
List<WaterSource> _findWater((String, double, double, bool) a) {
  final pm = PmTiles.open(a.$1);
  try {
    return nearestWaters(pm, a.$2, a.$3, emergency: a.$4);
  } finally {
    pm.close();
  }
}

class TerrainAnalysis {
  final ValueListenable<GnssSnapshot> snap;
  final ValueListenable<double?> heading;
  TerrainAnalysis({required this.snap, required this.heading});

  final slope = ValueNotifier<String?>(null); // "전방 내리막 -5m · -4%"
  final sunToday = ValueNotifier<TerrainSun?>(null);
  TerrainSun? _sunTomorrow;
  final water = ValueNotifier<List<WaterSource>>([]); // 가까운 수원지 최대 5곳
  /// 긴급 수원지 포함: 켜면 소류지·저수지·연못 같은 고인 물도 거리 계산에 넣음 (설정은 water_mode.json에 저장)
  final emergencyWater = ValueNotifier<bool>(false);
  final hasDem = ValueNotifier<bool>(false);

  DemFile? _dem;
  String? _demPath, _mapPath;
  Timer? _timer;
  DateTime _slopeAt = DateTime(0);
  (double, double, DateTime)? _sunFor, _waterFor;
  bool _waterBusy = false;
  bool _waterAgain = false; // 계산 중에 긴급 설정이 바뀌면 끝나고 한 번 더

  void start() {
    MapStore.instance.installed.addListener(_files);
    snap.addListener(_onMove);
    heading.addListener(_onMove);
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _periodic());
    _modeFile().then((f) {
      if (f.existsSync() && f.readAsStringSync().trim() == 'emergency') setEmergencyWater(true); // 첫 검색이 먼저 돌았어도 다시 찾음
    }).catchError((Object _) {});
    _files();
  }

  void dispose() {
    MapStore.instance.installed.removeListener(_files);
    snap.removeListener(_onMove);
    heading.removeListener(_onMove);
    _timer?.cancel();
    _dem?.close();
  }

  static Future<File> _modeFile() async => File('${(await getApplicationSupportDirectory()).path}/water_mode.json');

  Future<void> setEmergencyWater(bool on) async {
    emergencyWater.value = on;
    water.value = on ? water.value : [for (final w in water.value) if (!w.emergency) w]; // 끌 때는 바로 빼 줌
    _waterFor = null;
    if (_waterBusy) {
      _waterAgain = true;
    } else {
      _periodic();
    }
    (await _modeFile()).writeAsStringSync(on ? 'emergency' : 'basic');
  }

  (double, double)? get _pos {
    final s = snap.value;
    return s.lat == null || s.lon == null || s.fixQ == 0 ? null : (s.lat!, s.lon!);
  }

  void _files() {
    final store = MapStore.instance;
    final dem = store.installed.value.where((p) => p.kind == 'dem').firstOrNull;
    final map = store.installed.value.where((p) => p.kind == 'basemap').firstOrNull;
    final demPath = dem == null ? null : store.fileOf(dem.id);
    if (demPath != _demPath) {
      _dem?.close();
      _dem = null;
      _demPath = demPath;
      try {
        if (demPath != null) _dem = DemFile.open(demPath);
      } catch (_) {}
      hasDem.value = _dem != null;
      _sunFor = null;
    }
    final mapPath = map == null ? null : store.fileOf(map.id);
    if (mapPath != _mapPath) {
      _mapPath = mapPath;
      _waterFor = null;
    }
    _periodic();
  }

  void _onMove() {
    // 전방 경사는 나침반이 움직일 때마다 (초당 최대 2번)
    final now = DateTime.now();
    if (now.difference(_slopeAt).inMilliseconds < 500) return;
    _slopeAt = now;
    final dem = _dem, p = _pos, h = heading.value;
    if (dem == null || p == null || h == null) {
      slope.value = null;
      return;
    }
    final s = forwardSlope(dem, p.$1, p.$2, h);
    slope.value = s == null ? null : slopeLabel(s);
  }

  bool _stale((double, double, DateTime)? last, double lat, double lon, double meters, Duration age) =>
      last == null ||
      distanceM(last.$1, last.$2, lat, lon) > meters ||
      DateTime.now().difference(last.$3) > age;

  void _periodic() {
    final p = _pos;
    if (p == null) return;
    final (lat, lon) = p;
    final now = DateTime.now();

    // 지형 일출·일몰: 1 km 이상 이동했거나 날짜가 바뀌면 다시 계산 (수 ms)
    final dem = _dem;
    if (dem != null &&
        (_stale(_sunFor, lat, lon, 1000, const Duration(hours: 6)) || _sunFor!.$3.day != now.day)) {
      _sunFor = (lat, lon, now);
      sunToday.value = terrainSun(dem, now, lat, lon);
      _sunTomorrow = terrainSun(dem, now.add(const Duration(days: 1)), lat, lon);
    }

    // 수원지: 100 m 이상 이동했거나 3분마다. 지도 타일을 여러 장 풀어야 해서 별도 스레드에서
    final mapPath = _mapPath;
    if (mapPath != null && !_waterBusy && _stale(_waterFor, lat, lon, 100, const Duration(minutes: 3))) {
      _waterBusy = true;
      _waterFor = (lat, lon, now);
      compute(_findWater, (mapPath, lat, lon, emergencyWater.value))
          .then((w) => water.value = w, onError: (Object _) {})
          .whenComplete(() {
        _waterBusy = false;
        if (_waterAgain) {
          _waterAgain = false;
          _waterFor = null;
          _periodic();
        }
      });
    }
  }

  /// 고도 데이터의 지면 고도 (m). 고도 데이터가 없으면 null
  double? elevationAt(double lat, double lon) => _dem?.elevation(lat, lon);

  /// 목표 방향으로 100 m 앞 경사 ("오르막 +8m · 8%"). 고도 데이터·위치가 없으면 null
  String? slopeToward(double bearing) {
    final dem = _dem, p = _pos;
    if (dem == null || p == null) return null;
    final s = forwardSlope(dem, p.$1, p.$2, bearing);
    return s == null ? null : slopeLabel(s).replaceFirst('전방 ', '');
  }

  /// "일출까지 7시간 31분" — 고도 데이터가 있으면 산 능선을 반영한 시각
  String? sunChip(DateTime now) {
    final p = _pos;
    final t = sunToday.value;
    if (t == null || t.rise == null || t.set == null) {
      return p == null ? null : sunCountdown(now, p.$1, p.$2);
    }
    if (now.isBefore(t.rise!)) return '일출까지 ${durationLabel(t.rise!.difference(now))}';
    if (now.isBefore(t.set!)) return '일몰까지 ${durationLabel(t.set!.difference(now))}';
    final next = _sunTomorrow?.rise;
    return next == null ? null : '일출까지 ${durationLabel(next.difference(now))}';
  }

  String? sunDetail() {
    final t = sunToday.value;
    if (t == null) return null;
    String hm(DateTime? d) => d == null ? '--:--' : '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    return '산 능선 기준  일출 ${hm(t.rise)} · 일몰 ${hm(t.set)}\n'
        '평지 기준      일출 ${hm(t.astroRise)} · 일몰 ${hm(t.astroSet)}\n'
        '해가 보이는 시간 ${t.daylight == null ? '--' : durationLabel(t.daylight!)}';
  }

  /// 현재 위치의 가시권을 반투명 그림(PNG)으로: 가려진 곳 = 어둡게. (그림, 북·남·서·동 경계)
  Future<(Uint8List, double, double, double, double)?> viewshedImage() async {
    final dem = _dem, p = _pos;
    if (dem == null || p == null) return null;
    final v = viewshed(dem, p.$1, p.$2);
    final n = v.size;
    final rgba = Uint8List(n * n * 4);
    for (var i = 0; i < n * n; i++) {
      if (v.visible[i] == 0) {
        rgba[i * 4 + 0] = 20;
        rgba[i * 4 + 1] = 24;
        rgba[i * 4 + 2] = 40;
        rgba[i * 4 + 3] = 150;
      }
    }
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, n, n, ui.PixelFormat.rgba8888, done.complete);
    final img = await done.future;
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    if (png == null) return null;
    final halfM = (n / 2) * v.cellM;
    final dLat = halfM / 111320, dLon = halfM / (111320 * cos(v.lat * pi / 180));
    return (png.buffer.asUint8List(), v.lat + dLat, v.lat - dLat, v.lon - dLon, v.lon + dLon);
  }
}
