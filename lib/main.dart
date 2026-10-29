import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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
  final String sys; // GPS / GLO / GAL / BDS
  final int prn;
  final int? elev;
  final int? az;
  final int? snr; // C/N0 (dB-Hz), null = 추적 안 함
  final bool used;
  const Sat(this.sys, this.prn, this.elev, this.az, this.snr, {this.used = false});
}

class GnssSnapshot {
  final List<Sat> sats;
  final double? pdop, hdop, vdop, lat, lon, alt;
  final int fixQ, ggaSats, dropped, badChecksum;
  const GnssSnapshot({
    this.sats = const [],
    this.pdop,
    this.hdop,
    this.vdop,
    this.lat,
    this.lon,
    this.alt,
    this.fixQ = 0,
    this.ggaSats = 0,
    this.dropped = 0,
    this.badChecksum = 0,
  });
}

const sysList = ['GPS', 'GLO', 'GAL', 'BDS'];

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
  final Map<String, List<Sat>> _committed = {}; // talker -> 완성된 위성 목록
  final Map<String, _Cycle> _cur = {}; // talker -> 수집 중인 사이클
  final Map<String, Set<int>> _usedBySys = {};
  double? pdop, hdop, vdop, alt, lat, lon;
  int fixQ = 0, ggaSats = 0, dropped = 0, badChecksum = 0;

  final notifier = ValueNotifier<GnssSnapshot>(const GnssSnapshot());

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
        _publish(); // GGA를 에포크(1초 묶음)의 끝으로 간주
        break;
    }
  }

  // GSV 병합: 1번 문장에서 시작, 번호가 연속일 때만 이어 붙이고,
  // 마지막 문장이 오면 해당 talker의 위성 목록을 통째로 교체(commit)한다.
  void _gsv(String talker, List<String> f) {
    if (f.length < 4) return;
    final total = int.tryParse(f[1]);
    final seq = int.tryParse(f[2]);
    if (total == null || seq == null) return;

    _Cycle? c = _cur[talker];
    if (seq == 1) {
      if (c != null) dropped++; // 이전 사이클이 미완성인 채로 새로 시작됨
      c = _Cycle(total);
      _cur[talker] = c;
    } else if (c == null || seq != c.next || total != c.total) {
      _cur.remove(talker); // 불연속 -> 사이클 폐기
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
      _committed[talker] = c.sats;
      _cur.remove(talker);
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

  void _publish() {
    final all = <Sat>[];
    for (final list in _committed.values) {
      for (final s in list) {
        all.add(Sat(s.sys, s.prn, s.elev, s.az, s.snr,
            used: _usedBySys[s.sys]?.contains(s.prn) ?? false));
      }
    }
    notifier.value = GnssSnapshot(
      sats: all,
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
  GnssSimulator(this.onLine);

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

class _HomePageState extends State<HomePage> {
  final parser = NmeaParser();
  final log = ValueNotifier<List<String>>([]);
  final _buf = <String>[];
  late final GnssSimulator sim;
  int tab = 0;

  @override
  void initState() {
    super.initState();
    sim = GnssSimulator((line) {
      parser.feed(line);
      _buf.add(line);
      if (_buf.length > 60) _buf.removeRange(0, _buf.length - 60);
      if (line.contains('GGA')) log.value = List.of(_buf);
    });
    sim.start();
  }

  @override
  void dispose() {
    sim.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      SkyPage(snap: parser.notifier),
      QualityPage(snap: parser.notifier),
      LogPage(log: log),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('GNSS Tool  (시뮬레이션)')),
      body: pages[tab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.public), label: '스카이플롯'),
          NavigationDestination(icon: Icon(Icons.speed), label: '품질'),
          NavigationDestination(icon: Icon(Icons.terminal), label: 'NMEA'),
        ],
      ),
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
              '관측 ${s.sats.length}개  /  사용 $used개   |   HDOP ${fmt(s.hdop)} (${hdopGrade(s.hdop)})',
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
                  Text('오차 등급: ${hdopGrade(s.hdop)}',
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Text('HDOP ${fmt(s.hdop)}   VDOP ${fmt(s.vdop)}   PDOP ${fmt(s.pdop)}'),
                  Text('위치 ${fmt(s.lat, 5)}, ${fmt(s.lon, 5)}   고도 ${fmt(s.alt)} m'),
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
