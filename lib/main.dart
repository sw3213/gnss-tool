import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'analysis.dart';
import 'dop.dart';
import 'main_screen.dart';
import 'nav.dart';
import 'offline_map.dart';
import 'phone_gnss.dart';
import 'updater.dart';
import 'weather.dart';

void main() => runApp(const GnssApp());

class GnssApp extends StatelessWidget {
  const GnssApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'GNSS Tool',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: const HomePage(),
      );
}

// ============================================================
// 데이터 모델
// ============================================================

class Sat {
  final String sys; // GPS / GLO / GAL / BDS / QZS
  final int prn;
  final int? elev;
  final int? az;
  final int? snr; // C/N0 (dB-Hz), null = 추적 안 함
  final bool used;
  final bool l5; // L5/E5a/B2a 신호도 수신 중 (듀얼밴드)
  const Sat(this.sys, this.prn, this.elev, this.az, this.snr, {this.used = false, this.l5 = false});
}

class GnssSnapshot {
  final List<Sat> sats;
  final double? pdop, hdop, vdop, lat, lon, alt;
  final double? hAcc, vAcc; // 수신기가 추정한 오차 (m, 폰 GPS만 제공)
  final Dop? geoDop; // 사용 위성 배치로 직접 계산한 DOP (수신기 보고값 검증용)
  final int fixQ, ggaSats, dropped, badChecksum;
  const GnssSnapshot({
    this.sats = const [],
    this.geoDop,
    this.pdop,
    this.hdop,
    this.vdop,
    this.lat,
    this.lon,
    this.alt,
    this.hAcc,
    this.vAcc,
    this.fixQ = 0,
    this.ggaSats = 0,
    this.dropped = 0,
    this.badChecksum = 0,
  });
}

class SensorSample {
  final DateTime t;
  // null = 해당 센서 없음 (예: 폰에는 온·습도 센서가 없음)
  final double? pressure; // hPa (BMP280 / 폰 기압계)
  final double? temp; // °C (AHT20)
  final double? humidity; // %RH (AHT20)
  final double? gnssAlt; // m, 같은 시각 GGA 고도 (측위 중일 때만)
  final double? qnh; // 해면기압 (BaroAltFilter)
  final double? baroAlt; // 기압 + GNSS 보정 고도 (BaroAltFilter)
  const SensorSample(this.t, this.pressure, this.temp, this.humidity, this.gnssAlt,
      {this.qnh, this.baroAlt});
}

const sensorWindow = 300; // 최근 5분 (1초 간격)

const sysList = ['GPS', 'GLO', 'GAL', 'BDS', 'QZS'];

bool get isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

Color sysColor(String sys) {
  switch (sys) {
    case 'GPS':
      return Colors.lightBlueAccent;
    case 'GLO':
      return Colors.redAccent;
    case 'GAL':
      return Colors.amberAccent;
    case 'BDS':
      return Colors.purpleAccent;
    case 'QZS':
      return Colors.lightGreenAccent;
    default:
      return Colors.white54;
  }
}

String sysOf(String talker) {
  switch (talker) {
    case 'GP':
      return 'GPS';
    case 'GL':
      return 'GLO';
    case 'GA':
      return 'GAL';
    case 'GB':
    case 'BD':
      return 'BDS';
    case 'GQ':
    case 'QZ':
      return 'QZS';
    default:
      return talker;
  }
}

String fmt(double? v, [int d = 1]) => v == null ? '--' : v.toStringAsFixed(d);

String hdopGrade(double? h) {
  if (h == null) return '알 수 없음';
  if (h < 1) return '이상적';
  if (h < 2) return '우수';
  if (h < 5) return '양호';
  if (h < 10) return '보통';
  return '불량';
}

// ============================================================
// NMEA 유틸 + 파서 (GSV 병합 상태 머신 포함)
// ============================================================

String nmea(String body) {
  int cs = 0;
  for (final c in body.codeUnits) {
    cs ^= c;
  }
  return '\$$body*${cs.toRadixString(16).toUpperCase().padLeft(2, '0')}';
}

bool nmeaVerify(String line) {
  final i = line.indexOf('*');
  if (!line.startsWith('\$') || i < 0 || i + 3 > line.length) return false;
  int cs = 0;
  for (final c in line.substring(1, i).codeUnits) {
    cs ^= c;
  }
  final given = int.tryParse(line.substring(i + 1, i + 3), radix: 16);
  return given != null && given == cs;
}

class _Cycle {
  final int total;
  int next = 2; // 다음에 기대하는 문장 번호 (1번은 이미 받음)
  final List<Sat> sats = [];
  _Cycle(this.total);
}

class NmeaParser {
  final Map<String, List<Sat>> _committed = {}; // talker+신호ID -> 완성된 위성 목록
  final Map<String, _Cycle> _cur = {}; // talker+신호ID -> 수집 중인 사이클
  final Map<String, Set<int>> _usedBySys = {};
  double? pdop, hdop, vdop, alt, lat, lon, hAcc, vAcc;
  int fixQ = 0, ggaSats = 0, dropped = 0, badChecksum = 0;

  // 폰 GPS처럼 위성 목록을 따로(GnssStatus) 받는 경우 GSV 대신 이것을 씀
  List<Sat>? externalSats;

  final notifier = ValueNotifier<GnssSnapshot>(const GnssSnapshot());

  void reset() {
    _committed.clear();
    _cur.clear();
    _usedBySys.clear();
    pdop = hdop = vdop = alt = lat = lon = hAcc = vAcc = null;
    fixQ = ggaSats = dropped = badChecksum = 0;
    externalSats = null;
    publish();
  }

  void feed(String raw) {
    final line = raw.trim();
    if (!nmeaVerify(line)) {
      badChecksum++;
      return;
    }
    final body = line.substring(1, line.indexOf('*'));
    final f = body.split(',');
    final id = f[0];
    if (id.length < 5) return;
    final talker = id.substring(0, 2);
    final type = id.substring(2);
    switch (type) {
      case 'GSV':
        _gsv(talker, f);
        break;
      case 'GSA':
        _gsa(talker, f);
        break;
      case 'GGA':
        _gga(f);
        publish(); // GGA를 에포크(1초 묶음)의 끝으로 간주
        break;
    }
  }

  // GSV 병합: 1번 문장에서 시작, 번호가 연속일 때만 이어 붙이고,
  // 마지막 문장이 오면 해당 talker(+신호)의 위성 목록을 통째로 교체(commit)한다.
  // NMEA 4.10+ 듀얼밴드 수신기는 L1, L5를 별도 사이클로 보내며 끝에 신호 ID가 붙음
  // -> 사이클을 talker+신호ID로 구분해야 L5 사이클이 L1 목록을 덮어쓰지 않음
  void _gsv(String talker, List<String> f) {
    if (f.length < 4) return;
    final total = int.tryParse(f[1]);
    final seq = int.tryParse(f[2]);
    if (total == null || seq == null) return;
    final key = (f.length - 4) % 4 == 1 ? '$talker/${f.last}' : talker;

    _Cycle? c = _cur[key];
    if (seq == 1) {
      if (c != null) dropped++; // 이전 사이클이 미완성인 채로 새로 시작됨
      c = _Cycle(total);
      _cur[key] = c;
    } else if (c == null || seq != c.next || total != c.total) {
      _cur.remove(key); // 불연속 -> 사이클 폐기
      dropped++;
      return;
    } else {
      c.next++;
    }

    final sys = sysOf(talker);
    for (int i = 4; i + 3 < f.length; i += 4) {
      final prn = int.tryParse(f[i]);
      if (prn == null) continue;
      c.sats.add(Sat(sys, prn, int.tryParse(f[i + 1]), int.tryParse(f[i + 2]),
          int.tryParse(f[i + 3])));
    }
    if (seq == total) {
      _committed[key] = c.sats;
      _cur.remove(key);
    }
  }

  // GSA: 측위에 실제 사용한 위성 PRN 목록 + PDOP/HDOP/VDOP
  // (주의: 실제 장치에서는 GLONASS 등의 PRN 번호 체계가 GSV와 다를 수 있음 -> 연결 단계에서 보정)
  void _gsa(String talker, List<String> f) {
    if (f.length < 18) return;
    final used = <int>{};
    for (int i = 3; i <= 14; i++) {
      final p = int.tryParse(f[i]);
      if (p != null) used.add(p);
    }
    pdop = double.tryParse(f[15]) ?? pdop;
    hdop = double.tryParse(f[16]) ?? hdop;
    vdop = double.tryParse(f[17]) ?? vdop;
    final sysId = f.length > 18 ? int.tryParse(f[18]) : null;
    const ids = {1: 'GPS', 2: 'GLO', 3: 'GAL', 4: 'BDS'};
    final sys = ids[sysId] ?? sysOf(talker);
    _usedBySys[sys] = used;
  }

  void _gga(List<String> f) {
    if (f.length < 10) return;
    lat = _coord(f[2], f[3]) ?? lat;
    lon = _coord(f[4], f[5]) ?? lon;
    fixQ = int.tryParse(f[6]) ?? 0;
    ggaSats = int.tryParse(f[7]) ?? 0;
    alt = double.tryParse(f[9]) ?? alt;
  }

  double? _coord(String v, String hemi) {
    final x = double.tryParse(v);
    if (x == null) return null;
    final d = (x / 100).floor();
    final deg = d + (x - d * 100) / 60;
    return (hemi == 'S' || hemi == 'W') ? -deg : deg;
  }

  void publish() {
    var sats = externalSats;
    if (sats == null) {
      // 여러 신호(L1/L5) 사이클에 같은 위성이 있으면 하나로 합치고 더 센 신호를 씀
      final bySat = <String, Sat>{};
      for (final list in _committed.values) {
        for (final s in list) {
          final prev = bySat['${s.sys}${s.prn}'];
          if (prev != null && (prev.snr ?? 0) >= (s.snr ?? 0)) continue;
          bySat['${s.sys}${s.prn}'] = Sat(s.sys, s.prn, s.elev, s.az, s.snr,
              used: _usedBySys[s.sys]?.contains(s.prn) ?? false);
        }
      }
      sats = bySat.values.toList();
    }
    notifier.value = GnssSnapshot(
      sats: sats,
      geoDop: dopFromSats(sats),
      hAcc: hAcc,
      vAcc: vAcc,
      pdop: pdop,
      hdop: hdop,
      vdop: vdop,
      lat: lat,
      lon: lon,
      alt: alt,
      fixQ: fixQ,
      ggaSats: ggaSats,
      dropped: dropped,
      badChecksum: badChecksum,
    );
  }
}

// ============================================================
// 가짜 GNSS 장치 (나중에 BLE 수신으로 교체할 부분)
// ============================================================

class _SatSim {
  final String talker;
  final int prn;
  final double az0, azRate, elPhase, elRate;
  _SatSim(this.talker, this.prn, this.az0, this.azRate, this.elPhase, this.elRate);
}

class GnssSimulator {
  final void Function(String line) onLine;
  final void Function(double pressure, double temp, double humidity)? onSensor;
  GnssSimulator(this.onLine, {this.onSensor});

  static const _talkers = ['GP', 'GL', 'GA', 'GB'];
  final _rnd = Random(7);
  late final List<_SatSim> _sats = _build();
  Timer? _timer;
  int _n = 0;

  List<_SatSim> _build() {
    final out = <_SatSim>[];
    void add(String t, List<int> prns) {
      for (final p in prns) {
        final sign = _rnd.nextBool() ? 1 : -1;
        out.add(_SatSim(
          t,
          p,
          _rnd.nextDouble() * 360,
          sign * (0.1 + _rnd.nextDouble() * 0.3), // 데모용으로 빠르게 움직임 (도/초)
          _rnd.nextDouble() * 2 * pi,
          0.01 + _rnd.nextDouble() * 0.02,
        ));
      }
    }

    add('GP', [1, 3, 6, 9, 11, 14, 17, 19, 22, 24, 28, 31]);
    add('GL', [65, 66, 71, 72, 75, 81, 82, 88]);
    add('GA', [2, 4, 7, 11, 13, 19, 24, 31]);
    add('GB', [1, 3, 6, 9, 16, 22, 27, 34]);
    return out;
  }

  void start() {
    _epoch();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _epoch());
  }

  void stop() => _timer?.cancel();

  String _two(int v) => v.toString().padLeft(2, '0');

  String _coordStr(double v, int degDigits) {
    final a = v.abs();
    final d = a.floor();
    final m = (a - d) * 60;
    return d.toString().padLeft(degDigits, '0') + m.toStringAsFixed(4).padLeft(7, '0');
  }

  void _epoch() {
    final t = _n.toDouble();
    _n++;
    final gsv = <String>[];
    final gsa = <String>[];
    int usedTotal = 0;

    for (int k = 0; k < _talkers.length; k++) {
      final tk = _talkers[k];
      final vis = <String>[];
      final used = <int>[];
      for (final s in _sats.where((x) => x.talker == tk)) {
        final el = 40 + 50 * sin(s.elPhase + t * s.elRate);
        if (el < 5) continue;
        final az = ((s.az0 + t * s.azRate) % 360 + 360) % 360;
        final snr = (18 + el * 0.3 + _rnd.nextInt(5)).round().clamp(0, 55).toInt();
        vis.add('${s.prn},${el.round()},${az.round() % 360},$snr');
        if (el >= 15 && used.length < 12) used.add(s.prn);
      }
      if (vis.isNotEmpty) {
        final total = (vis.length / 4).ceil();
        for (int i = 0; i < total; i++) {
          final slice = vis.sublist(i * 4, min(i * 4 + 4, vis.length)).join(',');
          gsv.add(nmea('${tk}GSV,$total,${i + 1},${vis.length},$slice'));
        }
      }
      usedTotal += used.length;
      gsa.add(used.join(',')); // 임시 저장, DOP 계산 후 문장 완성
      _usedTmp[k] = used;
    }

    final hdop = 0.7 + 7.0 / max(usedTotal, 1) + _rnd.nextDouble() * 0.2;
    final pdop = hdop * 1.6;
    final vdop = sqrt(max(pdop * pdop - hdop * hdop, 0));

    final gsaLines = <String>[];
    for (int k = 0; k < _talkers.length; k++) {
      final slots = List<String>.filled(12, '');
      final u = _usedTmp[k] ?? <int>[];
      for (int i = 0; i < u.length && i < 12; i++) {
        slots[i] = u[i].toString();
      }
      gsaLines.add(nmea(
          'GNGSA,A,3,${slots.join(',')},${fmt(pdop)},${fmt(hdop)},${fmt(vdop)},${k + 1}'));
    }

    // 가끔 GSV 문장 하나를 일부러 누락시켜 병합기 동작 확인
    if (_rnd.nextDouble() < 0.05 && gsv.length > 1) {
      gsv.removeAt(_rnd.nextInt(gsv.length));
    }

    final now = DateTime.now().toUtc();
    final time = '${_two(now.hour)}${_two(now.minute)}${_two(now.second)}.00';
    final lat = _coordStr(37.5665, 2);
    final lon = _coordStr(126.9780, 3);
    final alt = (45.0 + _rnd.nextDouble() * 0.6).toStringAsFixed(1);
    final gga = nmea('GNGGA,$time,$lat,N,$lon,E,1,$usedTotal,${fmt(hdop)},$alt,M,0.0,M,,');

    for (final l in gsv) {
      onLine(l);
    }
    for (final l in gsaLines) {
      onLine(l);
    }
    onLine(gga);

    // 가짜 BMP280/AHT20 값: 고도 45 m 부근 기압에 느린 변화 + 잡음
    onSensor?.call(
      1007.9 + 0.6 * sin(t / 300) + (_rnd.nextDouble() - 0.5) * 0.1,
      18.0 + 1.5 * sin(t / 600) + (_rnd.nextDouble() - 0.5) * 0.2,
      55.0 - 4.0 * sin(t / 600) + (_rnd.nextDouble() - 0.5) * 1.0,
    );
  }

  final Map<int, List<int>> _usedTmp = {};
}

// ============================================================
// 화면
// ============================================================

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

enum DataSource { sim, phone } // 다음: ESP32(BLE) — 설정에서 고름

const sourceLabels = {DataSource.sim: '시뮬레이션', DataSource.phone: '폰 GPS'};

class _HomePageState extends State<HomePage> {
  final parser = NmeaParser();
  final log = ValueNotifier<List<String>>([]);
  final sensors = ValueNotifier<List<SensorSample>>([]);
  final notice = ValueNotifier<String?>(null); // 권한 거부, GPS 꺼짐 등 안내
  final alert = ValueNotifier<String?>(null); // 폭풍 경보
  final weather = ValueNotifier<StormStatus>(const StormStatus());
  final qnhHistory = ValueNotifier<List<(DateTime, double)>>([]);
  final baro = BaroAltFilter();
  final storm = StormWatch();
  StormLevel _alerted = StormLevel.none;
  final _buf = <String>[];
  DataSource source = isAndroid ? DataSource.phone : DataSource.sim;
  GnssSimulator? _sim;
  PhoneGnss? _phone;
  Timer? _sampler;
  double? _pressure, _temp, _humidity; // 출처가 보낸 최신 센서 값

  final track = TrackRecorder();
  final waypoints = WaypointStore();
  final mapControl = MapControl();
  final guide = Guide(); // 목표 지점 안내
  final route = RouteFollow(); // GPX 경로 따라가기
  final heading = ValueNotifier<double?>(null); // 폰이 향한 방위 (진북 기준)
  StreamSubscription<dynamic>? _headingSub;
  late final analysis = TerrainAnalysis(snap: parser.notifier, heading: heading);

  @override
  void initState() {
    super.initState();
    // 앱을 내려도 GPS·센서를 계속 켜 둠 (사용자 선택: 내렸다 돌아올 때 다시 잡는 게 불편).
    // 배터리를 더 쓰며, 안드로이드가 백그라운드 위치·센서 전달을 줄일 수는 있음
    _resume();
    _loadSource();
    parser.notifier.addListener(_onPosition);
    track.points.addListener(() => mapControl.setTrack(track.points.value));
    waypoints.items.addListener(() => mapControl.setWaypoints(waypoints.items.value));
    analysis.water.addListener(() =>
        mapControl.setWater([for (final w in analysis.water.value) (lat: w.lat, lon: w.lon, emergency: w.emergency)]));
    waypoints.load();
    guide.target.addListener(() {
      mapControl.setTarget(guide.target.value);
      _updateGuide();
    });
    guide.load();
    route.route.addListener(() {
      mapControl.setRoute(route.route.value?.pts);
      _updateGuide();
    });
    route.load();
    if (isAndroid) analysis.start(); // 고도 데이터·지도 파일은 안드로이드에서만 받음
    if (isAndroid) {
      _headingSub = const EventChannel('gnss_tool/heading').receiveBroadcastStream().listen((d) {
        heading.value = (d as num).toDouble();
        mapControl.onHeading(heading.value!);
        _updateGuide();
      }, onError: (Object _) {}); // 방향 센서 없는 폰: 방위 표시만 안 함
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _showLastCrash();
      if (mounted) checkForUpdate(context);
    });
  }

  /// 새 위치가 오면 이동 기록에 반영
  void _onPosition() {
    final s = parser.notifier.value;
    if (s.lat != null && s.lon != null && s.fixQ > 0) track.add(s.lat!, s.lon!, s.alt, s.hAcc);
    _updateGuide();
  }

  void _updateGuide() {
    final s = parser.notifier.value;
    final ok = s.fixQ > 0;
    if (route.route.value != null) route.update(ok ? s.lat : null, ok ? s.lon : null, s.hAcc);
    if (guide.target.value == null) return;
    guide.update(ok ? s.lat : null, ok ? s.lon : null, s.hAcc, heading.value, analysis.elevationAt);
  }

  // 위치 출처 선택은 앱을 다시 켜도 유지
  Future<File> _settingsFile() async => File('${(await getApplicationDocumentsDirectory()).path}/settings.json');

  Future<void> _loadSource() async {
    if (!isAndroid) return;
    try {
      final f = await _settingsFile();
      if (!f.existsSync()) return;
      final name = (jsonDecode(await f.readAsString()) as Map)['source'] as String?;
      final s = DataSource.values.where((v) => v.name == name).firstOrNull;
      if (s != null && s != source && mounted) _switchTo(s);
    } catch (_) {}
  }

  Future<void> _saveSource(DataSource s) async {
    try {
      await (await _settingsFile()).writeAsString(jsonEncode({'source': s.name}));
    } catch (_) {}
  }

  /// 지난 실행이 비정상 종료였으면 원인을 보여 줌 (캡처해서 보내면 원인 파악 가능)
  Future<void> _showLastCrash() async {
    if (!isAndroid) return;
    String? text;
    try {
      text = await const MethodChannel('gnss_tool/diag').invokeMethod<String>('lastCrash');
    } catch (_) {}
    if (text == null || !mounted) return;
    final report = text;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('지난번에 앱이 비정상 종료됐습니다'),
        content: SizedBox(
          width: double.maxFinite,
          height: 320,
          child: SingleChildScrollView(
            child: SelectableText(report,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 10.5)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: report)),
            child: const Text('복사'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기')),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _pause();
    _headingSub?.cancel();
    parser.notifier.removeListener(_onPosition);
    if (isAndroid) analysis.dispose();
    super.dispose();
  }

  void _resume() {
    if (_sampler != null) return;
    _start();
    // 센서 차트는 출처와 무관하게 1초마다 최신 값을 한 점씩 기록
    _sampler = Timer.periodic(const Duration(seconds: 1), (_) => _sample());
  }

  void _pause() {
    _stop();
    _sampler?.cancel();
    _sampler = null;
    baro.reset();
  }

  void _onLine(String line) {
    parser.feed(line);
    _buf.add(line);
    if (_buf.length > 60) _buf.removeRange(0, _buf.length - 60);
    if (line.contains('GGA')) log.value = List.of(_buf);
  }

  void _sample() {
    final now = DateTime.now();
    final snap = parser.notifier.value;
    final gnssAlt = snap.fixQ > 0 ? snap.alt : null;
    final p = _pressure;
    if (p != null) {
      baro.update(p, gnssAlt);
      final q = baro.qnh;
      if (q != null) _onWeather(storm.add(now, q));
    }
    final next = [
      ...sensors.value,
      SensorSample(now, p, _temp, _humidity, gnssAlt,
          qnh: p == null ? null : baro.qnh, baroAlt: p == null ? null : baro.alt),
    ];
    if (next.length > sensorWindow) next.removeRange(0, next.length - sensorWindow);
    sensors.value = next;
  }

  void _onWeather(StormStatus st) {
    weather.value = st;
    qnhHistory.value = st.history;
    // 경보 단계가 올라갈 때만 한 번 알림. 정상으로 돌아오면 다음 악화 때 다시 알림
    if (st.level.index > _alerted.index) {
      alert.value = st.level == StormLevel.storm ? '폭풍 경보 — ${st.text}' : '날씨 악화 주의 — ${st.text}';
      for (int i = 0; i < 3; i++) {
        Future.delayed(Duration(milliseconds: 400 * i), HapticFeedback.heavyImpact);
      }
    }
    if (st.level == StormLevel.none) alert.value = null;
    _alerted = st.level;
  }

  void _start() {
    notice.value = null;
    switch (source) {
      case DataSource.sim:
        _sim = GnssSimulator(_onLine, onSensor: (p, t, h) {
          _pressure = p;
          _temp = t;
          _humidity = h;
        })
          ..start();
      case DataSource.phone:
        notice.value = '위성 신호를 찾는 중... 실외나 창가에서 더 빨리 잡힙니다.';
        _phone = PhoneGnss(
          onLine: _onLine,
          onSats: (sats) {
            if (sats.any((s) => s.snr != null) && notice.value != null) notice.value = null;
            parser.externalSats = sats;
            parser.publish();
          },
          onAccuracy: (h, v) {
            parser.hAcc = h;
            parser.vAcc = v;
          },
          onPressure: (p) => _pressure = p,
          onGnssError: (code) => notice.value = switch (code) {
            'PERMISSION_DENIED' => '정확한 위치 권한이 필요합니다. [다시 시도]를 누르거나 설정 > 애플리케이션에서 허용해 주세요.',
            'GPS_OFF' => '폰의 위치(GPS)가 꺼져 있습니다. 켠 뒤 [다시 시도]를 눌러 주세요.',
            _ => 'GPS 오류: $code',
          },
          onNoBarometer: () {}, // 기압 null로 남음 -> 센서 탭에 "센서 없음" 표시
        )..start();
    }
  }

  void _stop() {
    _sim?.stop();
    _phone?.stop();
    _sim = null;
    _phone = null;
    _pressure = _temp = _humidity = null;
  }

  void _switchTo(DataSource s) {
    _stop();
    parser.reset();
    _buf.clear();
    log.value = [];
    sensors.value = [];
    baro.reset();
    storm.clear(); // 시뮬레이션과 실제 기압이 섞이지 않게
    weather.value = const StormStatus();
    qnhHistory.value = [];
    alert.value = null;
    _alerted = StormLevel.none;
    setState(() => source = s);
    _start();
  }

  @override
  Widget build(BuildContext context) {
    return MainScreen(
      analysis: analysis,
      snap: parser.notifier,
      sensors: sensors,
      weather: weather,
      qnhHistory: qnhHistory,
      log: log,
      notice: notice,
      alert: alert,
      heading: heading,
      sourceLabel: sourceLabels[source]!,
      map: mapControl,
      guide: guide,
      route: route,
      track: track,
      waypoints: waypoints,
      source: source,
      onSource: (s) {
        if (s != source) _switchTo(s);
        _saveSource(s);
      },
      onRetrySource: () => _switchTo(source),
      onDismissAlert: () => alert.value = null,
    );
  }
}

// ---------------- 스카이플롯 ----------------

class SkyPage extends StatelessWidget {
  final ValueListenable<GnssSnapshot> snap;
  const SkyPage({super.key, required this.snap});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: RepaintBoundary(
            child: CustomPaint(painter: SkyPainter(snap), size: Size.infinite),
          ),
        ),
        const SizedBox(height: 8),
        ValueListenableBuilder<GnssSnapshot>(
          valueListenable: snap,
          builder: (_, s, __) {
            final used = s.sats.where((x) => x.used).length;
            return Text(
              '관측 ${s.sats.length}개  /  사용 $used개   |   '
              'HDOP ${fmt(s.geoDop?.hdop ?? s.hdop)} (${hdopGrade(s.geoDop?.hdop ?? s.hdop)})',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15),
            );
          },
        ),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 14,
          children: [
            for (final s in sysList)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.circle, size: 12, color: sysColor(s)),
                const SizedBox(width: 4),
                Text(s),
              ]),
          ],
        ),
        const SizedBox(height: 4),
        const Text('채운 원 = 측위에 사용 / 빈 원 = 관측만 / 크기 = 신호 세기',
            textAlign: TextAlign.center, style: TextStyle(color: Colors.white54, fontSize: 12)),
      ],
    );
  }
}

class SkyPainter extends CustomPainter {
  final ValueListenable<GnssSnapshot> snap;
  SkyPainter(this.snap) : super(repaint: snap); // 데이터가 바뀌면 build 없이 paint만 다시 호출

  void _text(Canvas c, String s, Offset center,
      {double size = 11, Color color = Colors.white70}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = min(size.width, size.height) / 2 - 22;

    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..color = Colors.white24
      ..strokeWidth = 1;

    for (final e in [0, 30, 60]) {
      canvas.drawCircle(c, r * (90 - e) / 90, grid);
    }
    canvas.drawLine(Offset(c.dx - r, c.dy), Offset(c.dx + r, c.dy), grid);
    canvas.drawLine(Offset(c.dx, c.dy - r), Offset(c.dx, c.dy + r), grid);
    _text(canvas, 'N', Offset(c.dx, c.dy - r - 12), size: 13, color: Colors.white);
    _text(canvas, 'S', Offset(c.dx, c.dy + r + 12), size: 13);
    _text(canvas, 'E', Offset(c.dx + r + 12, c.dy), size: 13);
    _text(canvas, 'W', Offset(c.dx - r - 12, c.dy), size: 13);
    _text(canvas, '30°', Offset(c.dx + 14, c.dy - r * 60 / 90 - 7), size: 9, color: Colors.white38);
    _text(canvas, '60°', Offset(c.dx + 14, c.dy - r * 30 / 90 - 7), size: 9, color: Colors.white38);

    for (final s in snap.value.sats) {
      if (s.az == null || s.elev == null) continue;
      final rad = s.az! * pi / 180;
      final rr = r * (90 - s.elev!) / 90;
      final p = c + Offset(sin(rad), -cos(rad)) * rr;
      final snr = (s.snr ?? 0).toDouble();
      final radius = 5 + (snr / 50).clamp(0.0, 1.0).toDouble() * 8;
      final color = sysColor(s.sys);
      final paint = Paint()
        ..color = color
        ..style = s.used ? PaintingStyle.fill : PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawCircle(p, radius, paint);
      _text(canvas, '${s.prn}', p, size: 9, color: s.used ? Colors.black : Colors.white);
    }
  }

  @override
  bool shouldRepaint(covariant SkyPainter old) => old.snap != snap;
}

// ---------------- 품질 ----------------

class QualityPage extends StatelessWidget {
  final ValueListenable<GnssSnapshot> snap;
  const QualityPage({super.key, required this.snap});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<GnssSnapshot>(
      valueListenable: snap,
      builder: (_, s, __) {
        final sorted = [...s.sats]..sort((a, b) => (b.snr ?? 0).compareTo(a.snr ?? 0));
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('오차 등급: ${hdopGrade(s.geoDop?.hdop ?? s.hdop)}',
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  if (s.geoDop != null)
                    Text('HDOP ${fmt(s.geoDop!.hdop)}   VDOP ${fmt(s.geoDop!.vdop)}   '
                        'PDOP ${fmt(s.geoDop!.pdop)}  (위성 배치로 계산)'),
                  Text('HDOP ${fmt(s.hdop)}   VDOP ${fmt(s.vdop)}   PDOP ${fmt(s.pdop)}  (수신기 보고)',
                      style: s.geoDop == null ? null : const TextStyle(color: Colors.white54)),
                  Text('위치 ${fmt(s.lat, 5)}, ${fmt(s.lon, 5)}   고도 ${fmt(s.alt)} m'),
                  if (s.hAcc != null)
                    Text('예상 오차 (수신기 추정): 수평 ±${fmt(s.hAcc)} m   수직 ±${fmt(s.vAcc)} m'),
                  if (s.sats.any((x) => x.l5))
                    Text('듀얼밴드: L5 신호 수신 위성 ${s.sats.where((x) => x.l5).length}개'),
                  Text('파서 통계: 병합 폐기 ${s.dropped}회 / 체크섬 오류 ${s.badChecksum}회',
                      style: const TextStyle(color: Colors.white54, fontSize: 12)),
                ]),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(children: [
                  for (final sys in sysList)
                    Row(children: [
                      Icon(Icons.circle, size: 12, color: sysColor(sys)),
                      const SizedBox(width: 8),
                      SizedBox(width: 44, child: Text(sys)),
                      Text('관측 ${s.sats.where((x) => x.sys == sys).length}  /  '
                          '사용 ${s.sats.where((x) => x.sys == sys && x.used).length}'),
                    ]),
                ]),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 8, 4, 4),
              child: Text('신호 세기 (C/N0, dB-Hz)'),
            ),
            for (final x in sorted)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  SizedBox(
                    width: 74,
                    child: Text('${x.sys} ${x.prn.toString().padLeft(2, '0')}',
                        style: TextStyle(color: sysColor(x.sys), fontSize: 13)),
                  ),
                  Expanded(
                    child: LinearProgressIndicator(
                      value: ((x.snr ?? 0) / 50).clamp(0.0, 1.0).toDouble(),
                      color: x.used ? sysColor(x.sys) : Colors.white38,
                      minHeight: 8,
                    ),
                  ),
                  SizedBox(
                    width: 36,
                    child: Text(x.snr?.toString() ?? '--',
                        textAlign: TextAlign.right, style: const TextStyle(fontSize: 13)),
                  ),
                ]),
              ),
          ],
        );
      },
    );
  }
}

// ---------------- 센서 대시보드 ----------------

class SensorPage extends StatelessWidget {
  final ValueListenable<List<SensorSample>> data;
  final ValueListenable<StormStatus> weather;
  final ValueListenable<List<(DateTime, double)>> qnhHistory;
  const SensorPage({super.key, required this.data, required this.weather, required this.qnhHistory});

  Widget _weatherCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ValueListenableBuilder<StormStatus>(
            valueListenable: weather,
            builder: (_, w, __) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('해면기압  ${fmt(w.qnh)} hPa',
                  style: const TextStyle(fontSize: 18, color: Colors.lightBlueAccent)),
              const SizedBox(height: 2),
              Text(w.text,
                  style: TextStyle(
                    fontSize: 15,
                    color: switch (w.level) {
                      StormLevel.storm => Colors.redAccent,
                      StormLevel.warning => Colors.orangeAccent,
                      StormLevel.none => Colors.white70,
                    },
                  )),
            ]),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 110,
            child: RepaintBoundary(
              child: CustomPaint(
                painter: LineChartPainter<(DateTime, double)>(
                    qnhHistory, (e) => e.$2, Colors.lightBlueAccent, 1, 2,
                    window: 180),
                size: Size.infinite,
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
              '최근 3시간, 1분 평균. 현지기압을 보정 고도로 해수면 기준 환산 → 일기예보 기압과 비교 가능\n'
              '경보: 3시간 3.6 hPa↓ 주의, 6 hPa↓ 폭풍 / 5분 3 hPa↓ 급하강',
              style: TextStyle(color: Colors.white54, fontSize: 12)),
        ]),
      ),
    );
  }

  Widget _chart(String title, String unit, int digits, double minSpan, Color color,
      double? Function(SensorSample) value,
      {double? Function(SensorSample)? second, String? legend}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ValueListenableBuilder<List<SensorSample>>(
            valueListenable: data,
            builder: (_, list, __) => Text(
              '$title  ${list.isEmpty ? '--' : fmt(value(list.last), digits)} $unit',
              style: TextStyle(fontSize: 16, color: color),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 110,
            child: RepaintBoundary(
              child: CustomPaint(
                painter: LineChartPainter(data, value, color, digits, minSpan, second: second),
                size: Size.infinite,
              ),
            ),
          ),
          if (legend != null) ...[
            const SizedBox(height: 4),
            Text(legend, style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _weatherCard(),
        _chart('현지기압', 'hPa', 1, 2, Colors.lightBlueAccent, (s) => s.pressure),
        _chart('온도', '°C', 1, 2, Colors.orangeAccent, (s) => s.temp),
        _chart('습도', '%', 0, 5, Colors.tealAccent, (s) => s.humidity),
        _chart('보정 고도', 'm', 1, 5, Colors.amberAccent, (s) => s.baroAlt,
            second: (s) => s.gnssAlt,
            legend: '노란 선 = 기압+GNSS 보정 고도 / 회색 선 = GNSS 고도 (측위 중일 때)'),
        const Text('최근 5분, 1초 간격',
            textAlign: TextAlign.center, style: TextStyle(color: Colors.white54, fontSize: 12)),
        ValueListenableBuilder<List<SensorSample>>(
          valueListenable: data,
          builder: (_, list, __) {
            if (list.isEmpty) return const SizedBox.shrink();
            final last = list.last;
            final missing = [
              if (last.pressure == null) '기압',
              if (last.temp == null) '온도',
              if (last.humidity == null) '습도',
            ];
            if (missing.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('${missing.join('·')}: 이 기기에 센서 없음 (ESP32 장치 연결 후 표시)',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
            );
          },
        ),
      ],
    );
  }
}

class LineChartPainter<T> extends CustomPainter {
  final ValueListenable<List<T>> data;
  final double? Function(T) value;
  final double? Function(T)? second;
  final Color color;
  final int digits;
  final double minSpan; // 잡음이 과장되지 않도록 세로축 최소 범위
  final int window; // 가로축에 들어가는 점 개수
  final bool labels; // 위·아래 끝 값 표시 (작은 그래프에선 끔)
  LineChartPainter(this.data, this.value, this.color, this.digits, this.minSpan,
      {this.second, this.window = sensorWindow, this.labels = true})
      : super(repaint: data);

  void _text(Canvas c, String s, Offset at) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: const TextStyle(color: Colors.white38, fontSize: 10)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, at);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final list = data.value;
    canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = Colors.white24);
    if (list.length < 2) {
      _text(canvas, '데이터 수집 중...', const Offset(6, 6));
      return;
    }

    final all = [
      for (final s in list) ...[value(s), second?.call(s)]
    ].whereType<double>();
    if (all.isEmpty) {
      _text(canvas, '센서 없음', const Offset(6, 6));
      return;
    }
    var lo = all.reduce(min), hi = all.reduce(max);
    if (hi - lo < minSpan) {
      final mid = (hi + lo) / 2;
      lo = mid - minSpan / 2;
      hi = mid + minSpan / 2;
    }

    // 최신 값이 오른쪽 끝, 창을 다 채우기 전에는 오른쪽부터 채워짐
    Path? line(double? Function(T) f) {
      Path? p;
      for (int i = 0; i < list.length; i++) {
        final v = f(list[i]);
        if (v == null) continue;
        final x = size.width * (i + window - list.length) / (window - 1);
        final y = size.height * (hi - v) / (hi - lo);
        p = p == null ? (Path()..moveTo(x, y)) : (p..lineTo(x, y));
      }
      return p;
    }

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    if (second != null) {
      final p2 = line(second!);
      if (p2 != null) canvas.drawPath(p2, stroke..color = Colors.white54);
    }
    final p1 = line(value);
    if (p1 != null) canvas.drawPath(p1, stroke..color = color);

    if (!labels) return;
    _text(canvas, fmt(hi, digits), const Offset(4, 2));
    _text(canvas, fmt(lo, digits), Offset(4, size.height - 14));
  }

  @override
  bool shouldRepaint(covariant LineChartPainter<T> old) => old.data != data;
}

// ---------------- 원시 로그 ----------------

class LogPage extends StatelessWidget {
  final ValueListenable<List<String>> log;
  const LogPage({super.key, required this.log});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<String>>(
      valueListenable: log,
      builder: (_, lines, __) => ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: lines.length,
        itemBuilder: (_, i) {
          final l = lines[lines.length - 1 - i]; // 최신 줄이 위로
          return Text(l,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 10.5, height: 1.3));
        },
      ),
    );
  }
}
