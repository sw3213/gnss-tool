import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData, HapticFeedback, MethodChannel;
import 'package:maplibre_gl/maplibre_gl.dart' show CameraPosition;
import 'package:path_provider/path_provider.dart';

import 'address.dart' show AddressSearcher, SearchHit;
import 'advice.dart';
import 'analysis.dart';
import 'fire.dart';
import 'main.dart';
import 'nav.dart';
import 'offline_map.dart';
import 'routing.dart' show CarClass, RouteException, RouteMode, findRouteInBackground;
import 'search_page.dart';
import 'shelters.dart';
import 'updater.dart';
import 'voice.dart';
import 'water.dart' show WaterSource, waterChipLabel;
import 'weather.dart';

// ============================================================
// 메인 화면: 전체 화면 지도 + 상태·나침반 + 아래 정보 패널 + 아래 버튼 4개
// (목표로 삼은 "Black GPS" 앱 화면 구성)
// ============================================================

class MainScreen extends StatefulWidget {
  final ValueListenable<GnssSnapshot> snap;
  final ValueListenable<List<SensorSample>> sensors;
  final ValueListenable<StormStatus> weather;
  final ValueListenable<List<(DateTime, double)>> qnhHistory;
  final ValueListenable<List<String>> log;
  final ValueListenable<String?> notice, alert;
  final ValueListenable<double?> heading;
  final String sourceLabel;
  final MapControl map;
  final TrackRecorder track;
  final WaypointStore waypoints;
  final DataSource source;
  final void Function(DataSource) onSource;
  final VoidCallback onRetrySource, onDismissAlert;
  final TerrainAnalysis analysis;
  final Guide guide;
  final RouteFollow route;
  final ValueListenable<List<Advice>> advice;

  const MainScreen({
    required this.advice,
    required this.analysis,
    required this.guide,
    required this.route,
    super.key,
    required this.snap,
    required this.sensors,
    required this.weather,
    required this.qnhHistory,
    required this.log,
    required this.notice,
    required this.alert,
    required this.heading,
    required this.sourceLabel,
    required this.map,
    required this.track,
    required this.waypoints,
    required this.source,
    required this.onSource,
    required this.onRetrySource,
    required this.onDismissAlert,
  });

  @override
  State<MainScreen> createState() => _MainScreenState();
}

/// 좌표를 "37.86123, 127.74123" 모양으로 복사 (소수 5자리 ≈ 1 m)
void copyCoordinates(BuildContext context, double lat, double lon) {
  final text = '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}';
  Clipboard.setData(ClipboardData(text: text));
  HapticFeedback.lightImpact();
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('좌표를 복사했습니다: $text')));
}

const _waterColor = Color(0xFF1C7ED6), _emergencyColor = Color(0xFFE8590C); // 수원지 번호: 기본 파랑, 긴급 주황
const _panelMin = 0.13, _panelInit = 0.24, _panelMax = 0.62;

class _MainScreenState extends State<MainScreen> {
  final _sheet = ValueNotifier<double>(_panelInit); // 아래 패널이 화면에서 차지하는 비율
  final _viewshedOn = ValueNotifier<bool>(false);
  NavTarget? _arrivedAt; // 도착 알림을 이미 띄운 목표 (한 번만)

  @override
  void initState() {
    super.initState();
    widget.map.onLongPress = _onLongPress;
    widget.map.onTapPlace = (lat, lon, name, kind) => _onLongPress(lat, lon, name: name, kind: kind);
    MapStore.instance.installed.addListener(_loadShelters);
    widget.snap.addListener(_updateShelters);
    _loadShelters();
    if (isAndroid) {
      _pip.setMethodCallHandler((c) async {
        if (c.method == 'changed') _inPip.value = c.arguments == true;
      });
      widget.route.route.addListener(_syncPip);
      _syncPip();
    }
    widget.guide.info.addListener(_checkArrival);
    widget.route.info.addListener(_checkRoute);
  }

  @override
  void dispose() {
    widget.map.onLongPress = null;
    widget.map.onTapPlace = null;
    MapStore.instance.installed.removeListener(_loadShelters);
    widget.snap.removeListener(_updateShelters);
    widget.map.camera.removeListener(_onCameraForFire);
    widget.route.route.removeListener(_syncPip);
    widget.guide.info.removeListener(_checkArrival);
    widget.route.info.removeListener(_checkRoute);
    super.dispose();
  }

  void _checkArrival() {
    final i = widget.guide.info.value, t = widget.guide.target.value;
    if (i == null || t == null || !i.arrived || identical(_arrivedAt, t)) return;
    _arrivedAt = t;
    HapticFeedback.heavyImpact();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('"${t.name}"에 도착했습니다'),
      duration: const Duration(seconds: 10),
      action: SnackBarAction(label: '안내 종료', onPressed: widget.guide.stop),
    ));
  }

  bool _wasOff = false, _routeDone = false;

  /// 경로에서 벗어나는 순간 / 경로 끝에 닿는 순간 진동과 알림 (한 번씩)
  void _checkRoute() {
    final i = widget.route.info.value;
    if (i == null) {
      _wasOff = _routeDone = false;
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    if (i.offRoute && !_wasOff) {
      HapticFeedback.heavyImpact();
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade800,
        content: Text('경로 이탈 ${distanceLabel(i.off)} — 경로는 ${directionLabel(i.toRoute)} 쪽'),
        action: widget.route.target == null
            ? null
            : SnackBarAction(
                label: '다시 찾기', onPressed: () => _findRoute(widget.route.target!, mode: widget.route.mode)),
      ));
    }
    _wasOff = i.offRoute;
    if (i.finished && !_routeDone) {
      _routeDone = true;
      HapticFeedback.heavyImpact();
      messenger.showSnackBar(SnackBar(
        content: const Text('경로 끝에 도착했습니다'),
        duration: const Duration(seconds: 10),
        action: SnackBarAction(label: '따라가기 종료', onPressed: widget.route.stop),
      ));
    }
  }

  void _guideTo(NavTarget t) {
    widget.guide.start(t);
    final s = widget.snap.value;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(s.lat == null
          ? '"${t.name}" 안내를 시작합니다'
          : '"${t.name}" 안내 시작: ${distanceLabel(distanceM(s.lat!, s.lon!, t.lat, t.lon))}'),
    ));
  }

  bool _routing = false;

  /// 현재 위치에서 [t]까지 길 따라 경로를 찾아 "경로 따라가기"로 안내 (직선 안내는 끝냄).
  /// [mode]: 걷기 / 자동차(고속도로 이용) / 자동차(고속도로 없이)
  Future<void> _findRoute(NavTarget t, {RouteMode mode = RouteMode.walk}) async {
    final messenger = ScaffoldMessenger.of(context);
    final s = widget.snap.value;
    if (s.lat == null || s.lon == null || s.fixQ == 0) {
      messenger.showSnackBar(const SnackBar(content: Text('현재 위치를 아직 모릅니다. 위치를 잡은 뒤 다시 눌러 주세요')));
      return;
    }
    final store = MapStore.instance;
    String? pathOf(String kind) {
      final p = store.installed.value.where((p) => p.kind == kind).firstOrNull;
      return p == null ? null : store.fileOf(p.id);
    }

    final graph = pathOf(mode.isCar ? 'drive' : 'routes');
    if (graph == null) {
      messenger.showSnackBar(SnackBar(
        content: Text(mode.isCar ? '자동차 길찾기에는 "대한민국 자동차 길찾기" 자료가 필요합니다' : '길찾기에는 "대한민국 길찾기" 자료가 필요합니다'),
        action: SnackBarAction(
          label: '받기',
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MapDownloadPage())),
        ),
      ));
      return;
    }
    if (_routing) return;
    _routing = true;
    messenger.showSnackBar(const SnackBar(content: Text('길 찾는 중…'), duration: Duration(minutes: 1)));
    try {
      final r = await findRouteInBackground(graph, pathOf('dem'), s.lat!, s.lon!, t.lat, t.lon, mode: mode);
      if (!mounted) return;
      await widget.route.start(
        GpxRoute('${mode.isCar ? '자동차' : '길찾기'}: ${t.name}',
            [for (final (la, lo, h) in r.pts) TrackPoint(la, lo, h, DateTime(0))]),
        target: t,
        mode: mode,
        carSpeed: r.seconds > 0 ? r.length / r.seconds : null,
      );
      widget.guide.stop();
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 8),
        content: Text([
          if (mode.isCar) ...[
            '${distanceLabel(r.length)}  ·  차로 약 ${durationLabel(Duration(seconds: r.seconds.round()))}',
            if (r.byClass[CarClass.motorway] + r.byClass[CarClass.motorwayLink] >= 100)
              '고속도로 ${distanceLabel(r.byClass[CarClass.motorway] + r.byClass[CarClass.motorwayLink])} 포함'
            else
              '고속도로 없이',
            '실시간 교통은 반영되지 않습니다',
          ] else ...[
            '${distanceLabel(r.length)}  ·  걸어서 약 ${durationLabel(walkTime(r.length, r.up))}',
            '오르막 ${r.up.round()} m · 내리막 ${r.down.round()} m',
          ],
          if (r.warnings.isNotEmpty) '피할 수 없는 구간: ${r.warnings.join(', ')}',
          if (r.startGap > 50) '가장 가까운 길까지 ${distanceLabel(r.startGap)} 먼저 이동',
        ].join('\n')),
      ));
    } on RouteException catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('길찾기 실패: $e')));
    } finally {
      _routing = false;
    }
  }

  final _menuOpen = ValueNotifier<bool>(false); // 오른쪽 아래 메뉴 펼침

  // ---- 화면 속 화면(작은 창): 경로를 따라가는 중에 홈 버튼을 누르면 길 안내 띠만 작게 (MainActivity.kt) ----
  static const _pip = MethodChannel('gnss_tool/pip');
  final _inPip = ValueNotifier<bool>(false);

  /// 경로가 있을 때만 홈으로 나가면 작은 창이 되게
  void _syncPip() =>
      _pip.invokeMethod<bool>('setAuto', widget.route.route.value != null).catchError((Object _) => false);

  // ---- 대피·안전 시설 (오프라인에서 받은 kr-shelters.json, kr-fac-<종류>.json) ----
  ShelterIndex? _shelters; // 민방위 대피소 (지도 칩의 🛡)
  var _facilities = <String, ShelterIndex>{}; // 종류마다 (민방위 대피소 포함)
  String? _shelterFiles; // 지금 읽어 둔 파일들 (바뀌었을 때만 다시 읽음)
  (double, double)? _shelterAt; // 가까운 대피소를 마지막으로 찾은 위치
  final _nearShelters = ValueNotifier<List<(Shelter, double)>>(const []);

  /// 시설 자료를 받았거나 업데이트했으면 읽어서 지도에 그림
  Future<void> _loadShelters() async {
    final store = MapStore.instance;
    final paths = [
      for (final p in store.installed.value)
        if (p.kind == 'shelters' || p.kind == 'facility')
          if (store.fileOf(p.id) case final f?) f
    ]..sort();
    final key = paths.join('|');
    if (key == _shelterFiles) return;
    _shelterFiles = key;
    if (paths.isEmpty) {
      _shelters = null;
      _facilities = {};
      _nearShelters.value = const [];
      widget.map.setShelters(const []);
      return;
    }
    try {
      final list = await Isolate.run(() => [
            for (final path in paths)
              if (File(path).existsSync()) ...parseShelters(File(path).readAsStringSync())
          ]);
      if (!mounted || key != _shelterFiles) return;
      final byCat = <String, List<Shelter>>{};
      for (final s in list) {
        byCat.putIfAbsent(s.cat, () => []).add(s);
      }
      _facilities = {for (final e in byCat.entries) e.key: ShelterIndex(e.value)};
      _shelters = _facilities['shelter'];
      _nearShelters.value = const [];
      widget.map.setShelters([for (final s in list) (lat: s.lat, lon: s.lon, name: s.name, cat: s.cat)]);
      _shelterAt = null;
      _updateShelters();
    } catch (_) {}
  }

  /// 30 m 넘게 움직였을 때만 가까운 대피소를 다시 찾음 (5 km 안 5곳)
  void _updateShelters() {
    final idx = _shelters, s = widget.snap.value;
    if (idx == null || s.lat == null || s.lon == null || s.fixQ == 0) return;
    final at = _shelterAt;
    if (at != null && distanceM(at.$1, at.$2, s.lat!, s.lon!) < 30) return;
    _shelterAt = (s.lat!, s.lon!);
    _nearShelters.value = idx.nearest(s.lat!, s.lon!);
  }

  /// 주변 정보: 가장 가까운 대피소·수원지와 해 정보를 한 화면에. 줄을 누르면 자세히
  void _showNearby() {
    final a = widget.analysis;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('주변 정보', style: TextStyle(fontWeight: FontWeight.bold))),
          ValueListenableBuilder<List<(Shelter, double)>>(
            valueListenable: _nearShelters,
            builder: (_, near, __) => ListTile(
              leading: const Icon(Icons.shield_outlined, color: Color(0xFF7048E8)),
              title: const Text('민방위 대피소'),
              subtitle: Text(near.isEmpty
                  ? (_facilities.isEmpty
                      ? '오프라인에서 "민방위 대피소" 자료를 받으면 보입니다'
                      : _shelters == null
                          ? '받은 시설: ${_facilities.keys.map(facilityLabel).join(', ')}'
                          : '5 km 안에 없음')
                  : '${near.first.$1.name} · ${shelterChipLabel(near).replaceFirst('대피소 ', '')}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.pop(ctx);
                if (_facilities.isEmpty) {
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MapDownloadPage()));
                } else {
                  _showShelters();
                }
              },
            ),
          ),
          ValueListenableBuilder<List<WaterSource>>(
            valueListenable: a.water,
            builder: (_, ws, __) => ListTile(
              leading: Icon(ws.any((w) => w.emergency) ? Icons.warning_amber_rounded : Icons.water_drop_outlined,
                  color: _waterColor),
              title: const Text('수원지'),
              subtitle: Text(ws.isEmpty ? '주변 10 km 안에 찾은 수원지 없음' : waterChipLabel(ws).replaceFirst('수원지 ', '')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.pop(ctx);
                _showWater();
              },
            ),
          ),
          // 불 사용 (참고): 숲 100 m·국립공원 기준
          ValueListenableBuilder<FireStatus?>(
            valueListenable: a.fire,
            builder: (_, f, __) => ListTile(
              leading: Icon(f?.banned == true ? Icons.local_fire_department : Icons.local_fire_department_outlined,
                  color: f == null ? null : (f.banned ? Colors.redAccent : Colors.lightGreenAccent)),
              title: Text(f == null ? '불 사용' : '불 사용 · ${f.banned ? '금지 구역' : '가능 (참고)'}'),
              subtitle: Text(f == null ? '대한민국 지도를 받고 위치를 잡으면 숲까지 거리로 알려 줍니다' : f.summary),
              trailing: const Icon(Icons.info_outline),
              onTap: () => showDialog<void>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('불 사용 (참고)'),
                  content: Text('${f?.summary ?? '아직 계산 전입니다'}\n\n'
                      '• 산림보호법: 숲과 숲에서 100 m 안(산림인접지역)에서는 불을 피우면 안 됩니다 (과태료).\n'
                      '• 자연공원법: 국립공원 안에서는 지정된 곳 밖에서 불을 쓰면 안 됩니다.\n\n'
                      '${FireStatus.caution}'),
                  actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('닫기'))],
                ),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.wb_twilight, color: Colors.orangeAccent),
            title: const Text('해'),
            subtitle: Text(a.sunChip(DateTime.now()) ?? '고도 데이터가 있어야 지형을 고려한 일출·일몰을 계산합니다'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.pop(ctx);
              final d = a.sunDetail();
              if (d == null) return _needDem();
              showDialog<void>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('오늘 해'),
                  content: Text(d),
                  actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('닫기'))],
                ),
              );
            },
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  /// 가까운 대피·안전 시설 목록: 위쪽에서 종류를 고르고, 누르면 그 시설 카드 (길 안내), 깃발은 바로 직선 안내
  void _showShelters() {
    final cats = [
      for (final c in facilityCats)
        if (_facilities.containsKey(c.id)) c
    ];
    if (cats.isEmpty) return;
    var cat = cats.first.id;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: StatefulBuilder(
          builder: (ctx, setSheet) => SingleChildScrollView(
            child: ValueListenableBuilder<List<(Shelter, double)>>(
              valueListenable: _nearShelters, // 움직이면 다시 그림
              builder: (_, __, ___) {
                final s = widget.snap.value;
                final c = cats.firstWhere((c) => c.id == cat);
                final near = s.lat == null || s.lon == null
                    ? const <(Shelter, double)>[]
                    : _facilities[cat]!.nearest(s.lat!, s.lon!, n: 8);
                final color = Color(c.color);
                return Column(mainAxisSize: MainAxisSize.min, children: [
                  ListTile(
                    title: Text('가까운 ${c.label}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(cat == 'shelter'
                        ? '행정안전부 자료 (매달 갱신). 공습·재난 때 가장 가까운 곳으로, 지하 시설이 더 안전합니다'
                        : '공공데이터 자료 (매달 갱신). 운영 시간·이용 가능 여부는 전화로 확인하세요'),
                  ),
                  // 종류 고르기 (받은 것만)
                  if (cats.length > 1)
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(children: [
                        for (final k in cats)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              avatar: Icon(facilityIcon(k.id), size: 18, color: Color(k.color)),
                              label: Text(k.label),
                              selected: k.id == cat,
                              onSelected: (_) => setSheet(() => cat = k.id),
                            ),
                          ),
                      ]),
                    ),
                  if (s.lat == null) const ListTile(title: Text('위치를 잡으면 가까운 곳을 보여 줍니다')),
                  if (s.lat != null && near.isEmpty) ListTile(title: Text('5 km 안에 ${c.label}이(가) 없습니다')),
                  for (final (sh, d) in near)
                    ListTile(
                      leading: Icon(
                          cat == 'shelter'
                              ? (sh.underground ? Icons.shield : Icons.shield_outlined)
                              : facilityIcon(cat),
                          color: color),
                      title: Text(sh.name),
                      subtitle: Text([
                        '${distanceLabel(d)}  ·  ${directionLabel(bearingDeg(s.lat!, s.lon!, sh.lat, sh.lon))}',
                        if (sh.summary.isNotEmpty) sh.summary,
                        if (sh.info.isNotEmpty) sh.info,
                        if (sh.address.isNotEmpty) sh.address,
                      ].join('\n')),
                      isThreeLine: true,
                      trailing: IconButton(
                        icon: const Icon(Icons.flag_outlined),
                        tooltip: '여기로 안내',
                        onPressed: () {
                          Navigator.pop(ctx);
                          _guideTo(NavTarget(sh.name, sh.lat, sh.lon));
                        },
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        widget.map.showPlace(sh.lat, sh.lon);
                        _onLongPress(sh.lat, sh.lon,
                            name: sh.name, kind: [c.label, if (sh.summary.isNotEmpty) sh.summary].join(' · '));
                      },
                    ),
                ]);
              },
            ),
          ),
        ),
      ),
    );
  }

  /// 메뉴 버튼 위로 펼쳐지는 버튼들 (위에서 아래 순서). 옆에 이름표를 붙여 무슨 버튼인지 보이게
  List<Widget> _menuButtons() {
    Widget labeled(String label, Widget button) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(10)),
            child: Text(label, style: const TextStyle(fontSize: 12, color: Colors.white)),
          ),
          const SizedBox(width: 8),
          button,
        ]);
    return [
      labeled(
        '지도 레이어',
        _RoundButton(
          tooltip: '지도 레이어',
          onTap: _showLayers,
          child: const Icon(Icons.layers_outlined, size: 22),
        ),
      ),
      ValueListenableBuilder<bool>(
        valueListenable: _viewshedOn,
        builder: (_, on, __) => labeled(
          '가시권',
          _RoundButton(
            tooltip: '가시권 (지형에 가려 안 보이는 곳)',
            active: on,
            onTap: _toggleViewshed,
            child: const Icon(Icons.visibility_outlined, size: 22),
          ),
        ),
      ),
      ValueListenableBuilder<bool>(
        valueListenable: _fireOn,
        builder: (_, on, __) => labeled(
          '불 사용 지역',
          _RoundButton(
            tooltip: '불 사용 지역 (초록 가능 · 빨강 금지)',
            active: on,
            onTap: _toggleFireMap,
            child: const Icon(Icons.local_fire_department_outlined, size: 22),
          ),
        ),
      ),
      ValueListenableBuilder<bool>(
        valueListenable: widget.map.tilted,
        builder: (_, on, __) => labeled(
          '3D',
          _RoundButton(
            tooltip: '3D (기울여 보기, 3D 건물)',
            active: on,
            onTap: widget.map.toggleTilt,
            child: const Text('3D', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          ),
        ),
      ),
      ValueListenableBuilder<bool>(
        valueListenable: widget.track.recording,
        builder: (_, rec, __) => labeled(
          rec ? '이동 중지' : '이동 시작',
          _RoundButton(
            tooltip: rec ? '이동 기록 중지' : '이동 기록 시작',
            onTap: _toggleTrack,
            child: Icon(rec ? Icons.stop_circle_outlined : Icons.navigation_outlined,
                size: 24, color: rec ? Colors.redAccent : Colors.orangeAccent),
          ),
        ),
      ),
      // 메뉴 버튼 바로 위 (펼치면 가장 먼저 나타남)
      ValueListenableBuilder<bool>(
        valueListenable: widget.map.follow,
        builder: (_, on, __) => labeled(
          '내 위치',
          _RoundButton(
            tooltip: '내 위치',
            active: on,
            onTap: () {
              final s = widget.snap.value;
              if (s.lat != null && s.lon != null) widget.map.recenter(s.lat!, s.lon!);
            },
            child: const Icon(Icons.my_location, size: 22),
          ),
        ),
      ),
    ];
  }

  /// 주소·장소 검색 -> 고른 곳으로 지도를 옮기고 길게 누른 것과 같은 메뉴
  Future<void> _search() async {
    final s = widget.snap.value;
    final ok = s.fixQ > 0;
    final h = await Navigator.of(context).push<SearchHit>(MaterialPageRoute(
        builder: (_) => SearchPage(
              lat: ok ? s.lat : null,
              lon: ok ? s.lon : null,
              mapLat: widget.map.camera.value?.target.latitude,
              mapLon: widget.map.camera.value?.target.longitude,
            )));
    if (h == null || !mounted) return;
    widget.map.showPlace(h.lat, h.lon);
    _onLongPress(h.lat, h.lon, name: h.title);
  }

  /// 그 자리 도로 이름 ("구곡길"): 60 m 안 가장 가까운 도로명주소에서 번호를 뺀 것. 길 안내 띠에 씀
  Future<String?> _roadNameAt(double lat, double lon) async {
    final a = await _askAddressData((a) => a.nearest(lat, lon));
    if (a == null || distanceM(lat, lon, a.lat, a.lon) > 60) return null;
    return a.title.replaceFirst(RegExp(r'\s+[\d-]+$'), '');
  }

  /// 주소 검색 자료로 묻기 (자료가 없거나 실패하면 null)
  Future<SearchHit?> _askAddressData(Future<SearchHit?> Function(AddressSearcher a) ask) async {
    final store = MapStore.instance;
    final p = store.installed.value.where((p) => p.kind == 'address').firstOrNull;
    final path = p == null ? null : store.fileOf(p.id);
    if (path == null) return null;
    try {
      return await ask(await AddressSearcher.open(path));
    } catch (_) {
      return null;
    }
  }

  /// 지도를 길게 누른 곳·이름을 누른 곳·검색한 곳: 이름·종류·도로명주소·고도·거리를 보여 주고
  /// "길 따라 안내" / "직선으로 안내" / "지점으로 저장"
  void _onLongPress(double lat, double lon, {String? name, String? kind}) {
    final s = widget.snap.value;
    final elev = widget.analysis.elevationAt(lat, lon);
    final address = _askAddressData((a) => a.nearest(lat, lon)); // 가장 가까운 도로명주소 (120 m 안)
    final place = _askAddressData((a) => a.nearestPlaceAt(lat, lon)); // 그 자리 건물·가게 이름 (40 m 안)
    final fire = widget.analysis.fireAt(lat, lon); // 그 자리에서 불을 써도 되는지 (숲 100 m·국립공원)
    widget.map.setPick(lat, lon); // 메뉴가 열려 있는 동안 고른 곳에 빨간 점
    const sub = TextStyle(fontSize: 13, color: Colors.white70);
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.push_pin_outlined, color: Colors.redAccent),
            // 이름을 모르면(길게 누른 곳) 그 자리 건물 이름을 제목으로
            title: FutureBuilder<SearchHit?>(
              future: place,
              builder: (_, p) {
                final pl = name == null ? p.data : null;
                final k = kind ?? pl?.detail;
                return Text.rich(TextSpan(children: [
                  TextSpan(text: name ?? pl?.title ?? '선택한 곳'),
                  if (k != null) TextSpan(text: '  $k', style: const TextStyle(fontSize: 13, color: Colors.white60)),
                ]));
              },
            ),
            subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // 주소로 찾은 곳: 그 자리 건물 이름도 (예: 입춘로 45 -> ○○빌딩)
              if (name != null)
                FutureBuilder<SearchHit?>(
                  future: place,
                  builder: (_, p) => p.data == null || p.data!.title == name
                      ? const SizedBox.shrink()
                      : Text('${p.data!.title} · ${p.data!.detail}',
                          style: const TextStyle(fontSize: 14, color: Colors.white)),
                ),
              FutureBuilder<SearchHit?>(
                future: address,
                builder: (_, a) => a.data == null
                    ? const SizedBox.shrink()
                    : Text([a.data!.detail, a.data!.title].where((t) => t.isNotEmpty).join(' '), style: sub),
              ),
              Text(
                  [
                    if (elev != null) '고도 ${elev.round()} m',
                    if (s.lat != null)
                      '${distanceLabel(distanceM(s.lat!, s.lon!, lat, lon))} '
                          '${directionLabel(bearingDeg(s.lat!, s.lon!, lat, lon))}',
                  ].join('  ·  '),
                  style: sub),
              // 불 사용 (참고): "🔥 불 가능 · 숲까지 150 m" / "불 금지 · 숲까지 40 m"
              FutureBuilder<FireStatus?>(
                future: fire,
                builder: (_, f) {
                  final st = f.data;
                  if (st == null) return const SizedBox.shrink();
                  final color = st.banned ? Colors.redAccent : Colors.lightGreenAccent;
                  return Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(Icons.local_fire_department_outlined, size: 16, color: color),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text('${st.chip} · ${st.summary}', style: TextStyle(fontSize: 13, color: color)),
                      ),
                    ]),
                  );
                },
              ),
              // 좌표: 누르면 복사 (검색창에 그대로 붙여 넣어 찾을 수 있는 모양)
              InkWell(
                onTap: () => copyCoordinates(context, lat, lon),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}',
                        style: const TextStyle(fontSize: 13, color: Colors.white70)),
                    const SizedBox(width: 6),
                    const Icon(Icons.copy, size: 16, color: Colors.white70),
                  ]),
                ),
              ),
            ]),
          ),
          ListTile(
            leading: const Icon(Icons.directions_walk),
            title: const Text('걸어서 길 안내'),
            subtitle: const Text('도로·등산로를 따라, 오르막과 큰 차도는 피해서'),
            onTap: () {
              Navigator.pop(ctx);
              _findRoute(NavTarget(name ?? '선택한 곳', lat, lon));
            },
          ),
          ListTile(
            leading: const Icon(Icons.directions_car),
            title: const Text('차로 안내 (고속도로 이용)'),
            subtitle: const Text('빠른 길, 일방통행 지킴'),
            onTap: () {
              Navigator.pop(ctx);
              _findRoute(NavTarget(name ?? '선택한 곳', lat, lon), mode: RouteMode.car);
            },
          ),
          ListTile(
            leading: const Icon(Icons.directions_car_outlined),
            title: const Text('차로 안내 (고속도로 없이)'),
            subtitle: const Text('국도·일반도로로'),
            onTap: () {
              Navigator.pop(ctx);
              _findRoute(NavTarget(name ?? '선택한 곳', lat, lon), mode: RouteMode.carNoHighway);
            },
          ),
          ListTile(
            leading: const Icon(Icons.flag_outlined),
            title: const Text('직선으로 안내'),
            onTap: () {
              Navigator.pop(ctx);
              _guideTo(NavTarget(name ?? '선택한 곳', lat, lon));
            },
          ),
          ListTile(
            leading: const Icon(Icons.add_location_alt_outlined),
            title: const Text('지점으로 저장'),
            onTap: () {
              Navigator.pop(ctx);
              _saveWaypoint(at: (lat, lon, elev));
            },
          ),
        ]),
      ),
    ).whenComplete(() => widget.map.setPick(null, null));
  }

  void _needDem() => ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('지형 분석에는 "대한민국 고도 데이터 (분석용)"이 필요합니다'),
        action: SnackBarAction(
          label: '받기',
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MapDownloadPage())),
        ),
      ));

  void _showWater() {
    final a = widget.analysis;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true, // 5곳이면 화면 절반을 넘을 수 있음
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: ValueListenableBuilder<bool>(
            valueListenable: a.emergencyWater,
            builder: (_, emergency, __) => ValueListenableBuilder<List<WaterSource>>(
              valueListenable: a.water,
              builder: (_, ws, __) {
                final s = widget.snap.value;
                return Column(mainAxisSize: MainAxisSize.min, children: [
                  ListTile(
                    title: const Text('가까운 수원지', style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(emergency
                        ? '기본 수원지 + 긴급 수원지(소류지·저수지·연못 등 고인 물). 마시기 전 반드시 끓이거나 정수하세요'
                        : '기본 수원지: 흐르는 물·샘·식수대만. 마시기 전 반드시 끓이거나 정수하세요'),
                  ),
                  // 물이 정말 급할 때만 켬: 고인 물까지 거리 계산에 넣음 (설정은 저장됨)
                  SwitchListTile(
                    secondary: Icon(Icons.warning_amber_rounded, color: emergency ? Colors.orange : null),
                    title: const Text('긴급 수원지 포함'),
                    subtitle: const Text('소류지·저수지·연못·호수도 찾기 (오염 위험, 최후의 수단)'),
                    value: emergency,
                    activeThumbColor: Colors.orange,
                    onChanged: a.setEmergencyWater,
                  ),
                  if (ws.isEmpty) const ListTile(title: Text('주변 10 km 안에 찾은 수원지가 없습니다')),
                  for (var i = 0; i < ws.length; i++)
                    ListTile(
                      leading: CircleAvatar(
                        radius: 14,
                        backgroundColor: ws[i].emergency ? _emergencyColor : _waterColor,
                        child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 13)),
                      ),
                      title: Text.rich(TextSpan(children: [
                        if (ws[i].emergency)
                          const TextSpan(
                              text: '긴급  ', style: TextStyle(color: _emergencyColor, fontWeight: FontWeight.bold)),
                        TextSpan(text: '${ws[i].label}${ws[i].name == null ? '' : ' · ${ws[i].name}'}'),
                      ])),
                      subtitle: Text(s.lat == null
                          ? distanceLabel(ws[i].distanceM)
                          : '${distanceLabel(ws[i].distanceM)}  ·  '
                              '${directionLabel(bearingDeg(s.lat!, s.lon!, ws[i].lat, ws[i].lon))}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.flag_outlined),
                        tooltip: '여기로 안내',
                        onPressed: () {
                          Navigator.pop(ctx);
                          _guideTo(NavTarget(
                              '${ws[i].emergency ? '긴급 ' : ''}${ws[i].name ?? ws[i].label}', ws[i].lat, ws[i].lon));
                        },
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        widget.map.recenter(ws[i].lat, ws[i].lon);
                        widget.map.follow.value = false;
                      },
                    ),
                ]);
              },
            ),
          ),
        ),
      ),
    );
  }

  /// 레이어 켜고 끄기 (등고선, 고도 색칠, 등산로…). 선택은 저장되어 다음에도 유지
  /// 레이어 메뉴 아이콘 색: 대피·안전 시설은 지도 아이콘과 같은 색
  Color? _groupColor(String id) {
    final cat = id == 'shelters' ? 'shelter' : (id.startsWith('fac-') ? id.substring(4) : null);
    final c = facilityCats.where((c) => c.id == cat).firstOrNull;
    return c == null ? null : Color(c.color);
  }

  /// 지도 레이어: 위에 분류 이름, 가운데 체크 목록, 아래 분류 탭 (안전디딤돌 안전지도처럼).
  /// 켜고 끈 것은 저장되어 앱을 다시 켜도 그대로
  void _showLayers() {
    var cat = MapControl.layerCategories.first;
    const blue = Color(0xFF4C8DFF);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: StatefulBuilder(
          builder: (ctx, setSheet) => ValueListenableBuilder<Set<String>>(
            valueListenable: widget.map.hidden,
            builder: (_, hidden, __) {
              final loaded = widget.map.facilityCatsLoaded.value;
              final groups = MapControl.layerGroups.where((g) => g.cat == cat).toList();
              return Column(mainAxisSize: MainAxisSize.min, children: [
                // 위: 분류 이름 + 닫기
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
                  child: Row(children: [
                    Text(cat, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: blue)),
                    const Spacer(),
                    IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                  ]),
                ),
                const Divider(height: 1),
                // 가운데: 체크 목록 (길면 스크롤)
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.45),
                  child: ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(vertical: 6), children: [
                    for (final g in groups)
                      () {
                        final fac = g.id == 'shelters' || g.id.startsWith('fac-');
                        final facCat = g.id == 'shelters' ? 'shelter' : g.id.substring(4);
                        final have = !fac || loaded.contains(facCat);
                        return ListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.only(left: 8, right: 16),
                          leading: Checkbox(
                            value: have && !hidden.contains(g.id),
                            onChanged: have ? (on) => widget.map.setLayerShown(g.id, on ?? false) : null,
                          ),
                          title: Text(g.label, style: TextStyle(fontSize: 16, color: have ? null : Colors.white38)),
                          subtitle: have ? null : const Text('지도 다운로드에서 받으면 켤 수 있어요', style: TextStyle(fontSize: 11)),
                          trailing: Icon(g.icon, size: 22, color: have ? _groupColor(g.id) : Colors.white24),
                          onTap: have
                              ? () => widget.map.setLayerShown(g.id, hidden.contains(g.id))
                              : () {
                                  Navigator.pop(ctx);
                                  Navigator.of(context)
                                      .push(MaterialPageRoute<void>(builder: (_) => const MapDownloadPage()));
                                },
                        );
                      }(),
                  ]),
                ),
                const Divider(height: 1),
                // 아래: 분류 탭
                Row(children: [
                  for (final c in MapControl.layerCategories)
                    Expanded(
                      child: InkWell(
                        onTap: () => setSheet(() => cat = c),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Column(children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: c == cat ? blue.withValues(alpha: 0.25) : Colors.transparent,
                              ),
                              child: Icon(MapControl.layerCategoryIcons[c], color: c == cat ? blue : Colors.white70),
                            ),
                            const SizedBox(height: 4),
                            Text(c,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: c == cat ? FontWeight.bold : FontWeight.normal,
                                  color: c == cat ? blue : Colors.white70,
                                  decoration: c == cat ? TextDecoration.underline : null,
                                  decorationColor: blue,
                                )),
                          ]),
                        ),
                      ),
                    ),
                ]),
              ]);
            },
          ),
        ),
      ),
    );
  }

  // ---- 🔥 불 사용 지역: 지도 가운데 둘레 2 km를 초록(가능)·빨강(금지)으로 ----
  final _fireOn = ValueNotifier<bool>(false);
  (double, double)? _fireCenter; // 마지막으로 칠한 곳의 가운데
  bool _fireBusy = false;

  Future<void> _toggleFireMap() async {
    if (_fireOn.value) {
      _fireOn.value = false;
      widget.map.camera.removeListener(_onCameraForFire);
      await widget.map.hideOverlay('fire');
      return;
    }
    final ok = await _drawFireMap();
    if (!ok || !mounted) return;
    _fireOn.value = true;
    widget.map.camera.addListener(_onCameraForFire);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      duration: Duration(seconds: 6),
      content: Text('초록 = 불 사용 가능해 보이는 곳 (숲에서 100 m 밖), 빨강 = 금지 (숲·숲 100 m 안·국립공원)\n'
          '지도 가운데 둘레 2 km, 지도에 그려진 숲 기준이라 참고용입니다'),
    ));
  }

  /// 지도 가운데 둘레를 다시 칠함. 대한민국 지도가 없으면 false
  Future<bool> _drawFireMap() async {
    final c = widget.map.camera.value?.target;
    if (c == null || _fireBusy) return false;
    _fireBusy = true;
    try {
      final img = await widget.analysis.fireMapImage(c.latitude, c.longitude);
      if (img == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('불 사용 지역은 "대한민국" 지도를 받아야 볼 수 있습니다')));
        }
        return false;
      }
      final (png, n, s, w, e) = img;
      await widget.map.showOverlay('fire', png, n, s, w, e);
      _fireCenter = (c.latitude, c.longitude);
      return true;
    } catch (_) {
      return false;
    } finally {
      _fireBusy = false;
    }
  }

  /// 지도를 1.2 km 넘게 옮기면 새 가운데 둘레를 다시 칠함
  void _onCameraForFire() {
    final c = widget.map.camera.value?.target, f = _fireCenter;
    if (!_fireOn.value || c == null || f == null) return;
    if (distanceM(f.$1, f.$2, c.latitude, c.longitude) > 1200) _drawFireMap();
  }

  /// 👁 가시권: 현재 위치에서 5 km 안 지형에 가려 안 보이는 곳을 어둡게
  Future<void> _toggleViewshed() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_viewshedOn.value) {
      _viewshedOn.value = false;
      await widget.map.hideViewshed();
      return;
    }
    if (!widget.analysis.hasDem.value) return _needDem();
    final img = await widget.analysis.viewshedImage();
    if (img == null) {
      messenger.showSnackBar(const SnackBar(content: Text('현재 위치가 있어야 가시권을 계산할 수 있습니다')));
      return;
    }
    final (png, n, s, w, e) = img;
    await widget.map.showViewshed(png, n, s, w, e);
    _viewshedOn.value = true;
    messenger.showSnackBar(const SnackBar(content: Text('어두운 곳 = 지형에 가려 보이지 않는 곳 (반경 5 km, 나무·건물 제외)')));
  }

  void _push(Widget page, String title) => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(appBar: AppBar(title: Text(title)), body: page),
      ));

  Future<void> _toggleTrack() async {
    final t = widget.track;
    final messenger = ScaffoldMessenger.of(context);
    if (!t.recording.value) {
      t.start();
      messenger.showSnackBar(const SnackBar(content: Text('이동 기록을 시작합니다')));
      return;
    }
    final dist = t.distance.value;
    final path = await t.stop();
    messenger.showSnackBar(SnackBar(
      content:
          Text(path == null ? '기록할 이동이 없어 저장하지 않았습니다' : '이동 기록 저장: ${distanceLabel(dist)} (${path.split('/').last})'),
    ));
  }

  /// 현재 위치(또는 지도에서 길게 누른 곳 [at]: 위도, 경도, 고도)를 이름 붙여 저장
  Future<void> _saveWaypoint({(double, double, double?)? at}) async {
    final s = widget.snap.value;
    final messenger = ScaffoldMessenger.of(context);
    if (at == null && (s.lat == null || s.lon == null)) {
      messenger.showSnackBar(const SnackBar(content: Text('현재 위치가 없어 저장할 수 없습니다 (GPS 측위 대기)')));
      return;
    }
    final ctl = TextEditingController(text: widget.waypoints.nextName());
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('지점 저장'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '예: 화장실, 대피소, 샘터'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('저장')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await widget.waypoints
        .add(Waypoint(name.trim(), at?.$1 ?? s.lat!, at?.$2 ?? s.lon!, at == null ? s.alt : at.$3, DateTime.now()));
    messenger.showSnackBar(SnackBar(content: Text('"${name.trim()}" 저장했습니다')));
  }

  void _openTools() => _push(
        ToolsPage(
          snap: widget.snap,
          sensors: widget.sensors,
          weather: widget.weather,
          qnhHistory: widget.qnhHistory,
          log: widget.log,
          waypoints: widget.waypoints,
          onGuide: _guideTo,
          route: widget.route,
          map: widget.map,
          source: widget.source,
          onSource: widget.onSource,
        ),
        '도구',
      );

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: _inPip,
        builder: (context, pip, _) => pip ? _pipView() : _fullView(context),
      );

  /// 작은 창: 길 안내 띠만 창 크기에 맞춰
  Widget _pipView() => Material(
        color: const Color(0xFF1C4FD6),
        child: Center(
          child: FittedBox(
            child: SizedBox(width: 340, child: _TurnBanner(route: widget.route, roadNameAt: _roadNameAt)),
          ),
        ),
      );

  Widget _fullView(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return Scaffold(
      backgroundColor: const Color(0xFF16181C),
      body: LayoutBuilder(builder: (context, box) {
        return Stack(children: [
          Positioned.fill(
            child: isAndroid
                ? MapPage(snap: widget.snap, control: widget.map, topInset: pad.top)
                : SafeArea(child: SkyPage(snap: widget.snap)), // 웹 미리보기: 네이티브 지도 없음
          ),
          // 맨 위: 길 안내 띠(다음에 꺾는 곳) -> 경보·안내 띠 -> 오른쪽에 GPS 상태·나침반·방위 (위에서부터 차례로, 겹치지 않게)
          Positioned(
            top: pad.top,
            left: 0,
            right: 0,
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              SizedBox(width: double.infinity, child: _TurnBanner(route: widget.route, roadNameAt: _roadNameAt)),
              _banner(widget.alert, Colors.red.shade900, Icons.thunderstorm, '확인', widget.onDismissAlert),
              _banner(widget.notice, Colors.blueGrey.shade800, Icons.info_outline, '다시 시도', widget.onRetrySource),
              Padding(
                padding: const EdgeInsets.only(top: 8, right: 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  _GpsStatusChip(snap: widget.snap, sourceLabel: widget.sourceLabel),
                  const SizedBox(height: 10),
                  // 메뉴를 펼치면 방위·전방 경사 글씨는 숨김 (메뉴 이름표와 겹치지 않게)
                  ValueListenableBuilder<bool>(
                    valueListenable: _menuOpen,
                    builder: (_, open, __) => Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      _CompassButton(map: widget.map, heading: widget.heading, showLabel: !open),
                      const SizedBox(height: 6),
                      // "전방 내리막 -5m · -4%" (바라보는 방향 100 m 앞)
                      ValueListenableBuilder<String?>(
                        valueListenable: widget.analysis.slope,
                        builder: (_, s, __) => s == null || open
                            ? const SizedBox.shrink()
                            : _MapChip(
                                icon: s.contains('오르막')
                                    ? Icons.north_east
                                    : s.contains('내리막')
                                        ? Icons.south_east
                                        : Icons.east,
                                text: s,
                              ),
                      ),
                    ]),
                  ),
                ]),
              ),
            ]),
          ),
          // 오른쪽 아래(패널 위): 메뉴 버튼 (누르면 레이어·가시권·3D·이동 시작·내 위치가 위로 펼쳐짐)
          ValueListenableBuilder<double>(
            valueListenable: _sheet,
            builder: (_, ext, __) => Positioned(
              right: 10,
              bottom: ext * box.maxHeight + 10,
              child: ValueListenableBuilder<bool>(
                valueListenable: _menuOpen,
                builder: (_, open, __) {
                  final buttons = open ? _menuButtons() : const <Widget>[];
                  return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    AnimatedSize(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOut,
                      alignment: Alignment.bottomCenter,
                      child: !open
                          ? const SizedBox(width: 50)
                          : Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                              for (final (i, b) in buttons.indexed)
                                // 아래 것부터 차례로 올라오며 나타남
                                TweenAnimationBuilder<double>(
                                  tween: Tween(begin: 0, end: 1),
                                  duration: Duration(milliseconds: 160 + 50 * (buttons.length - 1 - i)),
                                  curve: Curves.easeOutBack,
                                  builder: (_, t, child) => Opacity(
                                    opacity: t.clamp(0.0, 1.0).toDouble(),
                                    child: Transform.translate(offset: Offset(0, 30 * (1 - t)), child: child),
                                  ),
                                  child: Padding(padding: const EdgeInsets.only(bottom: 10), child: b),
                                ),
                            ]),
                    ),
                    _RoundButton(
                      tooltip: open ? '메뉴 접기' : '메뉴 펼치기',
                      active: open,
                      onTap: () => _menuOpen.value = !open,
                      child: AnimatedRotation(
                        turns: open ? 0.125 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: Icon(open ? Icons.add : Icons.menu, size: 24),
                      ),
                    ),
                  ]);
                },
              ),
            ),
          ),
          // 왼쪽 아래(패널 위): "주변 정보" 한 줄 (대피소 · 수원지 · 해). 누르면 한 화면에 모아 보기
          ValueListenableBuilder<double>(
            valueListenable: _sheet,
            builder: (_, ext, __) => Positioned(
              left: 10,
              bottom: ext * box.maxHeight + 10,
              child: GestureDetector(
                onTap: _showNearby,
                child: _NearbyChip(shelters: _nearShelters, analysis: widget.analysis),
              ),
            ),
          ),
          // 아래 정보 패널 (끌어올리면 더 보임)
          NotificationListener<DraggableScrollableNotification>(
            onNotification: (n) {
              _sheet.value = n.extent;
              return false;
            },
            child: DraggableScrollableSheet(
              initialChildSize: _panelInit,
              minChildSize: _panelMin,
              maxChildSize: _panelMax,
              builder: (_, scroll) => _InfoPanel(
                scroll: scroll,
                guide: widget.guide,
                analysis: widget.analysis,
                route: widget.route,
                advice: widget.advice,
                snap: widget.snap,
                sensors: widget.sensors,
                weather: widget.weather,
                track: widget.track,
                onRoute: _findRoute,
              ),
            ),
          ),
        ]);
      }),
      bottomNavigationBar: _BottomBar(
        onSearch: _search,
        onWaypoint: _saveWaypoint,
        onOffline: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MapDownloadPage())),
        onTools: _openTools,
      ),
    );
  }

  Widget _banner(ValueListenable<String?> msg, Color color, IconData icon, String action, VoidCallback onAction) =>
      ValueListenableBuilder<String?>(
        valueListenable: msg,
        builder: (_, m, __) => m == null
            ? const SizedBox.shrink()
            : Material(
                color: color,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                  child: Row(children: [
                    Icon(icon, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(m, style: const TextStyle(fontSize: 13))),
                    TextButton(onPressed: onAction, child: Text(action)),
                  ]),
                ),
              ),
      );
}

// ---------------- 지도 위 작은 위젯들 ----------------

/// 오차에 따라 초록(5 m 미만) / 노랑(15 m 미만) / 빨강
Color accuracyColor(double? hAcc) => hAcc == null
    ? Colors.grey
    : hAcc < 5
        ? Colors.greenAccent.shade400
        : hAcc < 15
            ? Colors.amberAccent
            : Colors.redAccent;

class _GpsStatusChip extends StatelessWidget {
  final ValueListenable<GnssSnapshot> snap;
  final String sourceLabel;
  const _GpsStatusChip({required this.snap, required this.sourceLabel});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<GnssSnapshot>(
        valueListenable: snap,
        builder: (_, s, __) {
          final used = s.sats.where((x) => x.used).length;
          final fix = s.lat != null && used > 0;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(16)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.circle, size: 10, color: fix ? accuracyColor(s.hAcc) : Colors.grey),
              const SizedBox(width: 6),
              Text(
                fix ? '$sourceLabel · 위성 $used' : '$sourceLabel · 위성 탐색 중',
                style: const TextStyle(fontSize: 12, color: Colors.white),
              ),
            ]),
          );
        },
      );
}

class _CompassButton extends StatelessWidget {
  final MapControl map;
  final ValueListenable<double?> heading;
  final bool showLabel; // 아래 방위 글씨 (메뉴가 펼쳐져 있으면 숨김)
  const _CompassButton({required this.map, required this.heading, this.showLabel = true});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
      // 지도 회전에 맞춰 N 표시가 실제 북쪽을 가리킴. 누르면 진행 방향 위 <-> 북쪽 위
      ValueListenableBuilder<CameraPosition?>(
        valueListenable: map.camera,
        builder: (_, cam, __) => ValueListenableBuilder<bool>(
          valueListenable: map.headingUp,
          builder: (_, up, __) => _RoundButton(
            tooltip: up ? '북쪽을 위로' : '진행 방향을 위로',
            active: up,
            onTap: () => map.toggleHeadingUp(heading.value),
            child: Transform.rotate(
              angle: -(cam?.bearing ?? 0) * math.pi / 180,
              child: const Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.navigation, size: 16, color: Colors.redAccent),
                Text('N', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, height: 1)),
              ]),
            ),
          ),
        ),
      ),
      const SizedBox(height: 6),
      ValueListenableBuilder<double?>(
        valueListenable: heading,
        builder: (_, h, __) => h == null || !showLabel
            ? const SizedBox.shrink()
            : Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(10)),
                child: Text(directionLabel(h), style: const TextStyle(fontSize: 12, color: Colors.white)),
              ),
      ),
    ]);
  }
}

class _RoundButton extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  final bool active;
  final String tooltip;
  const _RoundButton({required this.child, required this.onTap, required this.tooltip, this.active = false});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: active ? const Color(0xFF2F6BFF) : const Color(0xE61E2026),
          shape: const CircleBorder(),
          elevation: 3,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(width: 50, height: 50, child: Center(child: child)),
          ),
        ),
      );
}

/// "일출까지 7시간 31분" — 고도 데이터가 있으면 산 능선 위로 해가 보이는 시각 기준
/// 왼쪽 아래 한 줄: "🛡 350 m  💧 440 m  🌅 1시간 21분" (있는 것만). 30초마다 해 시간 갱신
class _NearbyChip extends StatefulWidget {
  final ValueListenable<List<(Shelter, double)>> shelters;
  final TerrainAnalysis analysis;
  const _NearbyChip({required this.shelters, required this.analysis});

  @override
  State<_NearbyChip> createState() => _NearbyChipState();
}

class _NearbyChipState extends State<_NearbyChip> {
  late final Stream<int> _tick = Stream.periodic(const Duration(seconds: 30), (i) => i);

  @override
  Widget build(BuildContext context) => StreamBuilder<int>(
        stream: _tick,
        builder: (_, __) => AnimatedBuilder(
          animation: Listenable.merge(
              [widget.shelters, widget.analysis.water, widget.analysis.sunToday, widget.analysis.fire]),
          builder: (_, __) {
            final near = widget.shelters.value, ws = widget.analysis.water.value;
            final sun = widget.analysis.sunChip(DateTime.now());
            final fire = widget.analysis.fire.value;
            final parts = <(IconData, Color, String)>[
              if (near.isNotEmpty) (Icons.shield_outlined, const Color(0xFFB197FC), distanceLabel(near.first.$2)),
              if (ws.isNotEmpty)
                (
                  ws.any((w) => w.emergency) ? Icons.warning_amber_rounded : Icons.water_drop_outlined,
                  const Color(0xFF74C0FC),
                  distanceLabel(ws.first.distanceM)
                ),
              if (fire != null)
                (
                  Icons.local_fire_department_outlined,
                  fire.banned ? Colors.redAccent : Colors.lightGreenAccent,
                  fire.chip
                ),
              if (sun != null)
                (
                  sun.startsWith('일출') ? Icons.wb_twilight : Icons.wb_sunny_outlined,
                  Colors.orangeAccent,
                  sun.replaceFirst(RegExp(r'^(일출|일몰)까지 '), '')
                ),
            ];
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(color: const Color(0xE61E2026), borderRadius: BorderRadius.circular(16)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (parts.isEmpty) ...[
                  const Icon(Icons.explore_outlined, size: 16, color: Colors.white70),
                  const SizedBox(width: 6),
                  const Text('주변 정보', style: TextStyle(fontSize: 12, color: Colors.white)),
                ],
                for (final (i, (icon, color, text)) in parts.indexed) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Icon(icon, size: 15, color: color),
                  const SizedBox(width: 4),
                  Text(text, style: const TextStyle(fontSize: 12, color: Colors.white)),
                ],
              ]),
            );
          },
        ),
      );
}

class _MapChip extends StatelessWidget {
  final IconData icon;
  final String text;
  const _MapChip({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: const Color(0xE61E2026), borderRadius: BorderRadius.circular(16)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: Colors.white70),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(fontSize: 12, color: Colors.white)),
        ]),
      );
}

// ---------------- 아래 정보 패널 ----------------

class _InfoPanel extends StatelessWidget {
  final ScrollController scroll;
  final ValueListenable<List<Advice>> advice;
  final Guide guide;
  final RouteFollow route;
  final TerrainAnalysis analysis;
  final ValueListenable<GnssSnapshot> snap;
  final ValueListenable<List<SensorSample>> sensors;
  final ValueListenable<StormStatus> weather;
  final void Function(NavTarget) onRoute;
  final TrackRecorder track;
  const _InfoPanel({
    required this.onRoute,
    required this.scroll,
    required this.advice,
    required this.guide,
    required this.route,
    required this.analysis,
    required this.snap,
    required this.sensors,
    required this.weather,
    required this.track,
  });

  @override
  Widget build(BuildContext context) {
    const label = TextStyle(fontSize: 12, color: Colors.white60);
    return Material(
      color: const Color(0xFF16181C),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(16, 6, 16, 16), children: [
        Center(
          child: Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
          ),
        ),
        _RouteCard(route: route),
        _GuideCard(guide: guide, analysis: analysis, onRoute: onRoute),
        _AdviceList(advice: advice),
        Row(children: [
          Expanded(
            child: ValueListenableBuilder<GnssSnapshot>(
              valueListenable: snap,
              // 누르면 내 위치 좌표 복사
              builder: (_, s, __) => InkWell(
                onTap: s.lat == null || s.lon == null ? null : () => copyCoordinates(context, s.lat!, s.lon!),
                child: _PanelItem(
                  icon: Icons.navigation,
                  iconColor: const Color(0xFF4D7CFE),
                  title: 'GPS 현재 위치',
                  value: s.hAcc != null
                      ? '오차범위 ±${s.hAcc!.toStringAsFixed(1)} m'
                      : s.lat != null
                          ? '측위 중'
                          : '측위 대기',
                  valueColor: s.hAcc == null ? null : accuracyColor(s.hAcc),
                ),
              ),
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<double>(
              valueListenable: track.distance,
              builder: (_, d, __) => ValueListenableBuilder<bool>(
                valueListenable: track.recording,
                builder: (_, rec, __) => _PanelItem(
                  icon: Icons.timeline,
                  iconColor: Colors.orangeAccent,
                  title: rec ? '이동 기록 중' : '이동 기록',
                  value: distanceLabel(d),
                ),
              ),
            ),
          ),
        ]),
        const Divider(height: 24, color: Colors.white12),
        ValueListenableBuilder<List<SensorSample>>(
          valueListenable: sensors,
          builder: (_, list, __) {
            final last = list.isEmpty ? null : list.last;
            return Row(children: [
              _mini('기압', last?.pressure, 'hPa', 1, 2, Colors.lightBlueAccent, (s) => s.pressure),
              _mini('온도', last?.temp, '°C', 1, 2, Colors.orangeAccent, (s) => s.temp),
              _mini('습도', last?.humidity, '%', 0, 5, Colors.tealAccent, (s) => s.humidity),
            ]);
          },
        ),
        const SizedBox(height: 14),
        ValueListenableBuilder<List<SensorSample>>(
          valueListenable: sensors,
          builder: (_, list, __) {
            final last = list.isEmpty ? null : list.last;
            final alt = last?.baroAlt ?? last?.gnssAlt;
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('고도', style: label),
              Text(alt == null ? '--' : '${alt.round()} m',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
            ]);
          },
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 56,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: LineChartPainter<SensorSample>(
                  sensors, (s) => s.baroAlt ?? s.gnssAlt, Colors.lightGreenAccent, 0, 5,
                  second: (s) => s.gnssAlt),
              size: Size.infinite,
            ),
          ),
        ),
        const SizedBox(height: 12),
        ValueListenableBuilder<StormStatus>(
          valueListenable: weather,
          builder: (_, w, __) => Text(
            w.qnh == null ? w.text : '해면기압 ${w.qnh!.toStringAsFixed(1)} hPa · ${w.text}',
            style: TextStyle(
              fontSize: 12,
              color: switch (w.level) {
                StormLevel.storm => Colors.redAccent,
                StormLevel.warning => Colors.orangeAccent,
                StormLevel.none => Colors.white60,
              },
            ),
          ),
        ),
        const SizedBox(height: 6),
        ValueListenableBuilder<GnssSnapshot>(
          valueListenable: snap,
          builder: (_, s, __) => Text(
            s.lat == null ? '' : '위치 ${s.lat!.toStringAsFixed(5)}, ${s.lon!.toStringAsFixed(5)}',
            style: label,
          ),
        ),
      ]),
    );
  }

  Widget _mini(String title, double? v, String unit, int digits, double minSpan, Color color,
          double? Function(SensorSample) f) =>
      Expanded(
        child: Padding(
          padding: const EdgeInsets.only(right: 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 12, color: Colors.white60)),
            Text(v == null ? '—' : '${v.toStringAsFixed(digits)} $unit',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            SizedBox(
              height: 30,
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: LineChartPainter<SensorSample>(sensors, f, color, digits, minSpan, labels: false),
                  size: Size.infinite,
                ),
              ),
            ),
          ]),
        ),
      );
}

class _PanelItem extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title, value;
  final Color? valueColor;
  const _PanelItem({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icon, color: iconColor, size: 26),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            Text(value, style: TextStyle(fontSize: 12, color: valueColor ?? Colors.white60)),
          ]),
        ),
      ]);
}

class _BottomBar extends StatelessWidget {
  final VoidCallback onSearch, onWaypoint, onOffline, onTools;
  const _BottomBar({
    required this.onSearch,
    required this.onWaypoint,
    required this.onOffline,
    required this.onTools,
  });

  @override
  Widget build(BuildContext context) => Material(
        color: const Color(0xFF0F1013),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 64,
            child: Row(children: [
              _item(Icons.search, '검색', Colors.orangeAccent, onSearch),
              _item(Icons.add_location_alt_outlined, '지점 저장', Colors.amber, onWaypoint),
              _item(Icons.download_for_offline_outlined, '오프라인', const Color(0xFF4D7CFE), onOffline),
              _item(Icons.more_horiz, '도구', Colors.white70, onTools),
            ]),
          ),
        ),
      );

  Widget _item(IconData icon, String label, Color color, VoidCallback onTap) => Expanded(
        child: InkWell(
          onTap: onTap,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, color: color),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 12)),
          ]),
        ),
      );
}

// ---------------- 도구 ----------------

class ToolsPage extends StatelessWidget {
  final RouteFollow route;
  final ValueListenable<GnssSnapshot> snap;
  final ValueListenable<List<SensorSample>> sensors;
  final ValueListenable<StormStatus> weather;
  final ValueListenable<List<(DateTime, double)>> qnhHistory;
  final ValueListenable<List<String>> log;
  final void Function(NavTarget) onGuide;
  final WaypointStore waypoints;
  final MapControl map;
  final DataSource source;
  final void Function(DataSource) onSource;
  const ToolsPage({
    required this.route,
    required this.onGuide,
    super.key,
    required this.snap,
    required this.sensors,
    required this.weather,
    required this.qnhHistory,
    required this.log,
    required this.waypoints,
    required this.map,
    required this.source,
    required this.onSource,
  });

  @override
  Widget build(BuildContext context) {
    void open(Widget page, String title) => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => Scaffold(appBar: AppBar(title: Text(title)), body: page),
        ));
    Widget tile(IconData icon, String title, String sub, VoidCallback onTap) =>
        ListTile(leading: Icon(icon), title: Text(title), subtitle: Text(sub), onTap: onTap);
    return ListView(children: [
      tile(Icons.public, '스카이플롯', '하늘의 위성 위치와 신호 세기', () => open(SkyPage(snap: snap), '스카이플롯')),
      tile(Icons.speed, '위성 품질', 'DOP, 오차, 위성별 신호', () => open(QualityPage(snap: snap), '위성 품질')),
      tile(Icons.show_chart, '센서 그래프', '해면기압 추세, 기압·온도·습도·고도',
          () => open(SensorPage(data: sensors, weather: weather, qnhHistory: qnhHistory), '센서 그래프')),
      tile(Icons.place_outlined, '저장한 지점', '거리·방위 보기, 지도에서 찾기',
          () => open(WaypointsPage(waypoints: waypoints, snap: snap, map: map, onGuide: onGuide), '저장한 지점')),
      tile(Icons.route, '경로 따라가기', 'GPX 불러오기, 내 이동 기록, 왔던 길로 돌아가기', () => open(RoutesPage(route: route), '경로 따라가기')),
      tile(Icons.terminal, 'NMEA 로그', '수신기 원시 문장', () => open(LogPage(log: log), 'NMEA 로그')),
      const Divider(),
      tile(Icons.settings, '설정', '위치 출처 (폰 GPS / 외부 장치)',
          () => open(SettingsPage(source: source, onSource: onSource), '설정')),
      if (updateSupported)
        tile(Icons.system_update, '앱 업데이트 확인', '새 버전이 있으면 설치', () => checkForUpdate(context, manual: true)),
    ]);
  }
}

class WaypointsPage extends StatelessWidget {
  final WaypointStore waypoints;
  final ValueListenable<GnssSnapshot> snap;
  final MapControl map;
  final void Function(NavTarget) onGuide;
  const WaypointsPage(
      {super.key, required this.waypoints, required this.snap, required this.map, required this.onGuide});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<Waypoint>>(
        valueListenable: waypoints.items,
        builder: (_, list, __) => list.isEmpty
            ? const Center(child: Text('아래 [지점 저장]으로 현재 위치를 저장할 수 있습니다'))
            : ValueListenableBuilder<GnssSnapshot>(
                valueListenable: snap,
                builder: (_, s, __) => ListView(children: [
                  for (final w in list.reversed)
                    ListTile(
                      leading: const Icon(Icons.place, color: Colors.deepOrangeAccent),
                      title: Text(w.name),
                      subtitle: Text(s.lat == null
                          ? '${w.lat.toStringAsFixed(5)}, ${w.lon.toStringAsFixed(5)}'
                          : '${distanceLabel(distanceM(s.lat!, s.lon!, w.lat, w.lon))}  ·  '
                              '${directionLabel(bearingDeg(s.lat!, s.lon!, w.lat, w.lon))}'),
                      onTap: () {
                        map.follow.value = false;
                        map.recenter(w.lat, w.lon);
                        map.follow.value = false;
                        Navigator.of(context).popUntil((r) => r.isFirst);
                      },
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          icon: const Icon(Icons.flag_outlined),
                          tooltip: '여기로 안내',
                          onPressed: () {
                            onGuide(NavTarget(w.name, w.lat, w.lon));
                            Navigator.of(context).popUntil((r) => r.isFirst);
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: '삭제',
                          onPressed: () => waypoints.remove(w),
                        ),
                      ]),
                    ),
                ]),
              ),
      );
}

/// 경로 따라가기: 불러온 GPX 경로와 내 이동 기록 목록. 따라가기 / 거꾸로(왔던 길로 돌아가기)
class RoutesPage extends StatefulWidget {
  final RouteFollow route;
  const RoutesPage({super.key, required this.route});

  @override
  State<RoutesPage> createState() => _RoutesPageState();
}

class _RoutesPageState extends State<RoutesPage> {
  List<File>? _routes, _tracks;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    List<File> gpx(Directory d) => d.existsSync()
        ? (d.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.gpx')).toList()
          ..sort((a, b) => b.path.compareTo(a.path)))
        : <File>[];
    final routes = gpx(await routesDir());
    final tracks = gpx(Directory('${(await getApplicationDocumentsDirectory()).path}/tracks'));
    if (mounted) {
      setState(() {
        _routes = routes;
        _tracks = tracks;
      });
    }
  }

  static String _baseName(File f) =>
      f.path.split('/').last.split(Platform.pathSeparator).last.replaceAll(RegExp(r'\.gpx$', caseSensitive: false), '');

  /// 휴대폰에서 GPX 파일을 골라 앱 폴더로 복사 (저장소 권한 없이 시스템 파일 선택기 사용)
  Future<void> _import() async {
    final messenger = ScaffoldMessenger.of(context);
    final files = await FilePicker.pickFiles(type: FileType.any);
    if (files.isEmpty) return;
    final f = files.first;
    final text = utf8.decode(await f.readAsBytes(), allowMalformed: true);
    final name = f.name.replaceAll(RegExp(r'\.gpx$', caseSensitive: false), '');
    final r = parseGpx(text, name);
    if (r == null) {
      messenger.showSnackBar(const SnackBar(content: Text('GPX 경로를 찾지 못했습니다 (trkpt/rtept 점이 없음)')));
      return;
    }
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    await File('${(await routesDir()).path}/$safe.gpx').writeAsString(text);
    messenger.showSnackBar(SnackBar(content: Text('"${r.name}" 불러옴: ${distanceLabel(r.total)}, 점 ${r.pts.length}개')));
    _load();
  }

  Future<void> _follow(File f, {bool reverse = false}) async {
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    final r = parseGpx(await f.readAsString(), _baseName(f));
    if (r == null) {
      messenger.showSnackBar(const SnackBar(content: Text('경로 점이 2개 미만입니다')));
      return;
    }
    final use = reverse ? r.reversed() : r;
    await widget.route.start(use);
    messenger.showSnackBar(SnackBar(content: Text('"${use.name}" 따라가기 시작 (${distanceLabel(use.total)})')));
    nav.popUntil((p) => p.isFirst);
  }

  Widget _tile(File f, {required bool imported}) => ListTile(
        leading: Icon(imported ? Icons.route : Icons.timeline),
        title: Text(_baseName(f)),
        subtitle: Text('${(f.lengthSync() / 1024).toStringAsFixed(1)} KB'),
        onTap: () => _follow(f),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(icon: const Icon(Icons.play_arrow), tooltip: '따라가기', onPressed: () => _follow(f)),
          IconButton(
            icon: const Icon(Icons.u_turn_left),
            tooltip: '거꾸로 (왔던 길로 돌아가기)',
            onPressed: () => _follow(f, reverse: true),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '삭제',
            onPressed: () {
              f.deleteSync();
              _load();
            },
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final routes = _routes, tracks = _tracks;
    const head = TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white70);
    return Stack(children: [
      if (routes == null || tracks == null)
        const Center(child: CircularProgressIndicator())
      else
        ListView(padding: const EdgeInsets.only(bottom: 90), children: [
          ValueListenableBuilder<GpxRoute?>(
            valueListenable: widget.route.route,
            builder: (_, r, __) => r == null
                ? const SizedBox.shrink()
                : Card(
                    margin: const EdgeInsets.all(12),
                    child: ListTile(
                      leading: const Icon(Icons.directions_walk, color: Color(0xFF9775FA)),
                      title: Text('따라가는 중: ${r.name}'),
                      subtitle: Text(distanceLabel(r.total)),
                      trailing: TextButton(onPressed: widget.route.stop, child: const Text('종료')),
                    ),
                  ),
          ),
          const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('불러온 경로', style: head)),
          if (routes.isEmpty)
            const ListTile(
              title: Text('아래 [GPX 불러오기]로 등산로 파일을 넣을 수 있습니다'),
              subtitle: Text('등산 앱·산림청 등에서 받은 .gpx 파일'),
            ),
          for (final f in routes) _tile(f, imported: true),
          const Padding(padding: EdgeInsets.fromLTRB(16, 16, 16, 4), child: Text('내 이동 기록', style: head)),
          if (tracks.isEmpty) const ListTile(title: Text('지도 오른쪽 아래 메뉴의 [이동 시작]으로 기록하면 여기에 저장됩니다')),
          for (final f in tracks) _tile(f, imported: false),
        ]),
      Positioned(
        right: 16,
        bottom: 16,
        child: FloatingActionButton.extended(
          onPressed: _import,
          icon: const Icon(Icons.file_open_outlined),
          label: const Text('GPX 불러오기'),
        ),
      ),
    ]);
  }
}

class SettingsPage extends StatefulWidget {
  final DataSource source;
  final void Function(DataSource) onSource;
  const SettingsPage({super.key, required this.source, required this.onSource});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late DataSource _source = widget.source;

  @override
  Widget build(BuildContext context) {
    void pick(DataSource? s) {
      if (s == null) return;
      setState(() => _source = s);
      widget.onSource(s);
    }

    return ListView(children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text('위치 출처', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      RadioGroup<DataSource>(
        groupValue: _source,
        onChanged: pick,
        child: const Column(children: [
          RadioListTile<DataSource>(
            value: DataSource.phone,
            title: Text('폰 내장 GPS'),
            subtitle: Text('폰의 GPS와 기압계 사용'),
          ),
          RadioListTile<DataSource>(
            value: DataSource.ble,
            title: Text('외부 GPS 장치 (ESP32 · LC29H)'),
            subtitle: Text('블루투스로 "BlackGPS" 장치에 연결 — 듀얼밴드 GPS, 기압·온도·습도.\n'
                '장치가 꺼지거나 끊기면 자동으로 폰 GPS 사용'),
          ),
          RadioListTile<DataSource>(
            value: DataSource.sim,
            title: Text('시뮬레이션'),
            subtitle: Text('가짜 위성·센서 데이터 (테스트용)'),
          ),
        ]),
      ),
    ]);
  }
}

// ---------------- 목표 지점 안내 카드 (아래 패널 맨 위) ----------------

/// 목표까지 직선 거리·방향 화살표·걷는 시간·고도 차이·목표 방향 경사. 안내 중이 아니면 아무것도 안 그림
class _GuideCard extends StatelessWidget {
  final Guide guide;
  final TerrainAnalysis analysis;
  final void Function(NavTarget) onRoute;
  const _GuideCard({required this.guide, required this.analysis, required this.onRoute});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<NavTarget?>(
        valueListenable: guide.target,
        builder: (_, t, __) => t == null
            ? const SizedBox.shrink()
            : ValueListenableBuilder<GuideInfo?>(
                valueListenable: guide.info,
                builder: (_, i, __) {
                  const sub = TextStyle(fontSize: 12, color: Colors.white70);
                  final slope = i == null ? null : analysis.slopeToward(i.bearing);
                  final climb = i?.climb;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                    decoration: BoxDecoration(
                      color: i?.arrived == true ? const Color(0xFF1F3B2A) : const Color(0xFF2A1E1E),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: i?.arrived == true ? Colors.greenAccent : Colors.redAccent, width: 1),
                    ),
                    child: Row(children: [
                      // 화살표: 나침반이 있으면 폰이 향한 방향 기준(위 = 정면), 없으면 북쪽 기준
                      Transform.rotate(
                        angle: ((i?.turn ?? i?.bearing ?? 0) * math.pi / 180),
                        child: Icon(i?.arrived == true ? Icons.flag : Icons.navigation,
                            size: 40, color: i?.arrived == true ? Colors.greenAccent : Colors.redAccent),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(t.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13, color: Colors.white70)),
                          Text(
                            i == null
                                ? '현재 위치를 기다리는 중'
                                : i.arrived
                                    ? '도착 (${distanceLabel(i.distance)})'
                                    : '${distanceLabel(i.distance)}  ·  '
                                        '${i.turn == null ? directionLabel(i.bearing) : turnLabel(i.turn!)}',
                            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
                          ),
                          if (i != null && !i.arrived)
                            Text(
                              [
                                if (i.turn != null) '방위 ${directionLabel(i.bearing)}',
                                '걸어서 약 ${durationLabel(i.walk)}',
                                if (climb != null && climb.abs() >= 10)
                                  '목표가 ${climb.abs().round()} m ${climb > 0 ? '높음' : '낮음'}',
                              ].join('  ·  '),
                              style: sub,
                            ),
                          if (slope != null && i != null && !i.arrived) Text('목표 방향 $slope', style: sub),
                        ]),
                      ),
                      IconButton(
                        icon: const Icon(Icons.alt_route),
                        tooltip: '길 따라 안내',
                        onPressed: () => onRoute(t),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: '안내 종료',
                        onPressed: guide.stop,
                      ),
                    ]),
                  );
                },
              ),
      );
}

// ---------------- GPX 경로 따라가기 카드 (아래 패널 맨 위) ----------------

class _RouteCard extends StatelessWidget {
  final RouteFollow route;
  const _RouteCard({required this.route});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<GpxRoute?>(
        valueListenable: route.route,
        builder: (_, r, __) => r == null
            ? const SizedBox.shrink()
            : ValueListenableBuilder<RouteInfo?>(
                valueListenable: route.info,
                builder: (_, i, __) {
                  const sub = TextStyle(fontSize: 12, color: Colors.white70);
                  final off = i?.offRoute == true;
                  final pct = i == null || r.total == 0 ? 0 : (i.done / r.total * 100).round();
                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                    decoration: BoxDecoration(
                      color: off ? const Color(0xFF3B1E1E) : const Color(0xFF241E36),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: off ? Colors.redAccent : const Color(0xFF9775FA)),
                    ),
                    child: Row(children: [
                      Icon(off ? Icons.wrong_location_outlined : Icons.directions_walk,
                          size: 34, color: off ? Colors.redAccent : const Color(0xFF9775FA)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(r.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13, color: Colors.white70)),
                          Text(
                            i == null
                                ? '현재 위치를 기다리는 중'
                                : i.finished
                                    ? '경로 끝 도착'
                                    : off
                                        ? '경로 이탈 ${distanceLabel(i.off)}'
                                        : '남은 ${distanceLabel(i.left)}  ·  $pct%',
                            style: TextStyle(
                                fontSize: 19, fontWeight: FontWeight.w700, color: off ? Colors.redAccent : null),
                          ),
                          if (i != null && !i.finished)
                            Text(
                              off
                                  ? '경로로 돌아가기: ${directionLabel(i.toRoute)} 방향'
                                  : [
                                      if (i.toNext != null && i.toNext! <= 500)
                                        '${distanceLabel(i.toNext!)} 앞 ${turnWord(i.next!.angle)}'
                                      else
                                        '진행 방향 ${directionLabel(i.ahead)}',
                                      route.timeLabel(i),
                                      if (i.climbLeft >= 10 && route.carSpeed == null)
                                        '남은 오르막 ${i.climbLeft.round()} m',
                                    ].join('  ·  '),
                              style: sub,
                            ),
                          if (i != null && r.total > 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 6, right: 8),
                              child: LinearProgressIndicator(
                                value: (i.done / r.total).clamp(0.0, 1.0),
                                color: const Color(0xFF9775FA),
                                backgroundColor: Colors.white12,
                              ),
                            ),
                        ]),
                      ),
                      ValueListenableBuilder<bool>(
                        valueListenable: Voice.instance.enabled,
                        builder: (context, on, _) => IconButton(
                          icon: Icon(on ? Icons.volume_up : Icons.volume_off, color: on ? null : Colors.white38),
                          tooltip: on ? '음성 안내 끄기' : '음성 안내 켜기',
                          onPressed: () async {
                            final messenger = ScaffoldMessenger.of(context);
                            Voice.instance.enabled.value = !on;
                            if (on) return Voice.instance.stop();
                            final err = await Voice.instance.speak('음성 안내를 켭니다', flush: true);
                            if (err != null) {
                              messenger.showSnackBar(SnackBar(
                                content: Text(err == 'NO_KOREAN'
                                    ? '음성 엔진에 한국어가 없습니다. 설정 > 일반 > 텍스트 음성 변환에서 한국어를 받아 주세요'
                                    : '폰의 음성 엔진(텍스트 음성 변환)을 쓸 수 없습니다'),
                              ));
                            }
                          },
                        ),
                      ),
                      IconButton(icon: const Icon(Icons.close), tooltip: '따라가기 종료', onPressed: route.stop),
                    ]),
                  );
                },
              ),
      );
}

// ---------------- 조언 (아래 패널, 안내 카드 아래) ----------------

class _AdviceList extends StatelessWidget {
  final ValueListenable<List<Advice>> advice;
  const _AdviceList({required this.advice});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<Advice>>(
        valueListenable: advice,
        builder: (_, list, __) => list.isEmpty
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(children: [
                  for (final a in list)
                    Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                      decoration: BoxDecoration(
                        color: switch (a.level) {
                          AdviceLevel.danger => const Color(0xFF4A1C1C),
                          AdviceLevel.warn => const Color(0xFF45361A),
                          AdviceLevel.info => const Color(0xFF1E2A38),
                        },
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(
                          switch (a.level) {
                            AdviceLevel.danger => Icons.warning_rounded,
                            AdviceLevel.warn => Icons.error_outline,
                            AdviceLevel.info => Icons.info_outline,
                          },
                          size: 20,
                          color: switch (a.level) {
                            AdviceLevel.danger => Colors.redAccent,
                            AdviceLevel.warn => Colors.amberAccent,
                            AdviceLevel.info => Colors.lightBlueAccent,
                          },
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(a.title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                            Text(a.detail, style: const TextStyle(fontSize: 12, color: Colors.white70)),
                          ]),
                        ),
                      ]),
                    ),
                ]),
              ),
      );
}

// ---------------- 길 안내 띠 (경로를 따라갈 때 맨 위, 내비처럼) ----------------

/// 꺾는 각도 -> 화살표 아이콘
IconData turnIcon(double angle) {
  final a = angle.abs(), left = angle < 0;
  if (a >= 160) return left ? Icons.u_turn_left : Icons.u_turn_right;
  if (a >= 120) return left ? Icons.turn_sharp_left : Icons.turn_sharp_right;
  if (a >= 60) return left ? Icons.turn_left : Icons.turn_right;
  if (a >= 35) return left ? Icons.turn_slight_left : Icons.turn_slight_right;
  return Icons.straight;
}

/// "↰ 80 m 구곡길 방면" + 그다음 꺾는 곳. 경로를 벗어나면 빨간 띠, 꺾는 곳이 없으면 목적지까지
class _TurnBanner extends StatefulWidget {
  final RouteFollow route;
  final Future<String?> Function(double lat, double lon) roadNameAt;
  const _TurnBanner({required this.route, required this.roadNameAt});

  @override
  State<_TurnBanner> createState() => _TurnBannerState();
}

class _TurnBannerState extends State<_TurnBanner> {
  GpxRoute? _for;
  final _names = <double, Future<String?>>{}; // 꺾는 곳(RouteTurn.at) -> 꺾은 뒤 길 이름

  /// 꺾고 나서 25 m 간 곳의 도로 이름
  Future<String?> _nameAfter(GpxRoute r, RouteTurn t) {
    if (!identical(r, _for)) {
      _for = r;
      _names.clear();
    }
    return _names.putIfAbsent(t.at, () {
      final (la, lo) = r.pointAt(t.at + 25);
      return widget.roadNameAt(la, lo);
    });
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<GpxRoute?>(
        valueListenable: widget.route.route,
        builder: (_, r, __) => r == null
            ? const SizedBox.shrink()
            : ValueListenableBuilder<RouteInfo?>(
                valueListenable: widget.route.info,
                builder: (_, i, __) {
                  if (i == null) return const SizedBox.shrink();
                  if (i.offRoute) {
                    return _bar(const Color(0xFFC92A2A), Icons.wrong_location_outlined, '경로 이탈',
                        '경로는 ${directionLabel(i.toRoute).split(' ').first}쪽 ${distanceLabel(i.off)}');
                  }
                  if (i.finished) return _bar(const Color(0xFF2B8A3E), Icons.flag, '도착', '목적지에 도착했습니다');
                  final t = i.next, d = i.toNext;
                  if (t == null || d == null) {
                    return _bar(const Color(0xFF1C4FD6), Icons.flag_outlined, distanceLabel(i.left), '목적지까지 쭉');
                  }
                  final after = r.turns.where((x) => x.at > t.at).firstOrNull;
                  return _bar(
                    const Color(0xFF1C4FD6),
                    turnIcon(t.angle),
                    distanceLabel(d),
                    null,
                    name: _nameAfter(r, t),
                    then: after == null ? null : (turnIcon(after.angle), '그다음 ${distanceLabel(after.at - t.at)}'),
                  );
                },
              ),
      );

  Widget _bar(Color color, IconData icon, String big, String? small,
          {Future<String?>? name, (IconData, String)? then}) =>
      Material(
        color: color,
        elevation: 4,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, size: 44, color: Colors.white),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(big, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: Colors.white)),
                  if (small != null) Text(small, style: const TextStyle(fontSize: 15, color: Colors.white)),
                  if (name != null)
                    FutureBuilder<String?>(
                      future: name,
                      builder: (_, n) => n.data == null
                          ? const SizedBox.shrink()
                          : Text('${n.data} 방면', style: const TextStyle(fontSize: 15, color: Colors.white)),
                    ),
                ]),
              ),
            ]),
            if (then != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  Icon(then.$1, size: 20, color: Colors.white70),
                  const SizedBox(width: 6),
                  Text(then.$2, style: const TextStyle(fontSize: 13, color: Colors.white70)),
                ]),
              ),
          ]),
        ),
      );
}
