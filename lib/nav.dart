import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

// ============================================================
// 길 찾기 기본: 거리·방위, 이동 기록(트랙), 저장한 지점(웨이포인트), 일출·일몰
// ============================================================

const _earthR = 6371008.8; // m

/// 두 지점 사이 거리 (m, 하버사인)
double distanceM(double lat1, double lon1, double lat2, double lon2) {
  final p1 = lat1 * pi / 180, p2 = lat2 * pi / 180;
  final dp = p2 - p1, dl = (lon2 - lon1) * pi / 180;
  final a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2);
  return 2 * _earthR * asin(min(1, sqrt(a)));
}

/// 1에서 2로 가는 방위각 (도, 진북 기준 0~360)
double bearingDeg(double lat1, double lon1, double lat2, double lon2) {
  final p1 = lat1 * pi / 180, p2 = lat2 * pi / 180, dl = (lon2 - lon1) * pi / 180;
  final y = sin(dl) * cos(p2);
  final x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl);
  return (atan2(y, x) * 180 / pi + 360) % 360;
}

const _dirs = ['북', '북동', '동', '남동', '남', '남서', '서', '북서'];

/// 방위각 -> "동 89°"
String directionLabel(double deg) => '${_dirs[((deg + 22.5) % 360 ~/ 45)]} ${deg.round() % 360}°';

String distanceLabel(double m) => m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(m < 10000 ? 2 : 1)} km';

String durationLabel(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60;
  return h > 0 ? '$h시간 $m분' : '$m분';
}

Future<Directory> _dataDir(String name) async {
  final d = Directory('${(await getApplicationDocumentsDirectory()).path}/$name');
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}

// ---------------- 이동 기록 ----------------

class TrackPoint {
  final double lat, lon;
  final double? alt;
  final DateTime t;
  const TrackPoint(this.lat, this.lon, this.alt, this.t);
}

/// "이동 시작"을 누르면 위치를 기록. 3 m 이상 움직였고 오차가 30 m 이하일 때만 점을 추가해
/// 제자리 GPS 흔들림이 거리로 쌓이지 않게 함. 정지하면 GPX 파일로 저장(다른 앱에서도 열림)
class TrackRecorder {
  static const minStepM = 3.0;
  static const maxAccM = 30.0;

  final recording = ValueNotifier<bool>(false);
  final points = ValueNotifier<List<TrackPoint>>([]);
  final distance = ValueNotifier<double>(0);
  DateTime? startedAt;

  void start() {
    points.value = [];
    distance.value = 0;
    startedAt = DateTime.now();
    recording.value = true;
  }

  /// 기록 중이면 위치 하나를 반영
  void add(double lat, double lon, double? alt, double? hAcc) {
    if (!recording.value) return;
    if (hAcc != null && hAcc > maxAccM) return;
    final list = points.value;
    if (list.isNotEmpty) {
      final d = distanceM(list.last.lat, list.last.lon, lat, lon);
      if (d < minStepM) return;
      distance.value += d;
    }
    points.value = [...list, TrackPoint(lat, lon, alt, DateTime.now())];
  }

  /// 기록을 끝내고 GPX로 저장. 저장한 파일 경로 (점이 2개 미만이면 null)
  Future<String?> stop() async {
    recording.value = false;
    final list = points.value;
    if (list.length < 2) return null;
    final s = startedAt ?? list.first.t;
    String two(int v) => v.toString().padLeft(2, '0');
    final name = '${s.year}${two(s.month)}${two(s.day)}-${two(s.hour)}${two(s.minute)}';
    final f = File('${(await _dataDir('tracks')).path}/$name.gpx');
    await f.writeAsString(toGpx(name, list));
    return f.path;
  }

  static String toGpx(String name, List<TrackPoint> pts) {
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<gpx version="1.1" creator="GNSS Tool" xmlns="http://www.topografix.com/GPX/1/1">')
      ..writeln('<trk><name>${_xmlEscape(name)}</name><trkseg>');
    for (final p in pts) {
      b.write('<trkpt lat="${p.lat.toStringAsFixed(7)}" lon="${p.lon.toStringAsFixed(7)}">');
      if (p.alt != null) b.write('<ele>${p.alt!.toStringAsFixed(1)}</ele>');
      b.writeln('<time>${p.t.toUtc().toIso8601String()}</time></trkpt>');
    }
    b.writeln('</trkseg></trk></gpx>');
    return b.toString();
  }
}

// ---------------- 저장한 지점 ----------------

class Waypoint {
  final String name;
  final double lat, lon;
  final double? alt;
  final DateTime t;
  const Waypoint(this.name, this.lat, this.lon, this.alt, this.t);

  Map<String, dynamic> toJson() => {'name': name, 'lat': lat, 'lon': lon, 'alt': alt, 't': t.toIso8601String()};
  factory Waypoint.fromJson(Map<String, dynamic> j) => Waypoint(
        j['name'] as String,
        (j['lat'] as num).toDouble(),
        (j['lon'] as num).toDouble(),
        (j['alt'] as num?)?.toDouble(),
        DateTime.parse(j['t'] as String),
      );
}

class WaypointStore {
  final items = ValueNotifier<List<Waypoint>>([]);

  Future<File> _file() async => File('${(await _dataDir('waypoints')).path}/waypoints.json');

  Future<void> load() async {
    try {
      final f = await _file();
      if (f.existsSync()) {
        items.value = [
          for (final j in jsonDecode(await f.readAsString()) as List) Waypoint.fromJson(j as Map<String, dynamic>)
        ];
      }
    } catch (_) {}
  }

  Future<void> _save() async => (await _file()).writeAsString(jsonEncode([for (final w in items.value) w.toJson()]));

  Future<void> add(Waypoint w) async {
    items.value = [...items.value, w];
    await _save();
  }

  Future<void> remove(Waypoint w) async {
    items.value = [...items.value]..remove(w);
    await _save();
  }

  String nextName() => '지점 ${items.value.length + 1}';
}

// ---------------- 일출·일몰 (NOAA 근사식, 지형 미반영) ----------------

class SunTimes {
  final DateTime? rise, set; // 현지 시각, 극지방 백야/극야면 null
  const SunTimes(this.rise, this.set);
}

/// [day] 날짜의 일출·일몰. 대기 굴절 포함 태양 고도 -0.833° 기준 (±1~2분)
SunTimes sunTimes(DateTime day, double lat, double lon) {
  final utcMidnight = DateTime.utc(day.year, day.month, day.day);
  final n = utcMidnight.difference(DateTime.utc(day.year, 1, 1)).inDays + 1;
  final g = 2 * pi / 365 * (n - 1 + 0.5);
  final eqTime = 229.18 *
      (0.000075 + 0.001868 * cos(g) - 0.032077 * sin(g) - 0.014615 * cos(2 * g) - 0.040849 * sin(2 * g));
  final decl = 0.006918 -
      0.399912 * cos(g) +
      0.070257 * sin(g) -
      0.006758 * cos(2 * g) +
      0.000907 * sin(2 * g) -
      0.002697 * cos(3 * g) +
      0.00148 * sin(3 * g);
  final phi = lat * pi / 180;
  final cosH = (cos(90.833 * pi / 180) - sin(phi) * sin(decl)) / (cos(phi) * cos(decl));
  if (cosH.abs() > 1) return const SunTimes(null, null);
  final h = acos(cosH) * 180 / pi;
  DateTime at(double minutes) => utcMidnight.add(Duration(seconds: (minutes * 60).round())).toLocal();
  return SunTimes(at(720 - 4 * (lon + h) - eqTime), at(720 - 4 * (lon - h) - eqTime));
}

/// "일출까지 7시간 31분" / "일몰까지 …"
String? sunCountdown(DateTime now, double lat, double lon) {
  final today = sunTimes(now, lat, lon);
  if (today.rise == null || today.set == null) return null;
  if (now.isBefore(today.rise!)) return '일출까지 ${durationLabel(today.rise!.difference(now))}';
  if (now.isBefore(today.set!)) return '일몰까지 ${durationLabel(today.set!.difference(now))}';
  final tomorrow = sunTimes(now.add(const Duration(days: 1)), lat, lon).rise;
  return tomorrow == null ? null : '일출까지 ${durationLabel(tomorrow.difference(now))}';
}

// ---------------- 목표 지점 안내 ----------------
// 저장한 지점·수원지·지도에서 길게 누른 곳을 목표로 정하면 거리·방향·걷는 시간을 계속 알려 줌 (직선 기준)

class NavTarget {
  final String name;
  final double lat, lon;
  const NavTarget(this.name, this.lat, this.lon);

  Map<String, dynamic> toJson() => {'name': name, 'lat': lat, 'lon': lon};
  factory NavTarget.fromJson(Map<String, dynamic> j) =>
      NavTarget(j['name'] as String, (j['lat'] as num).toDouble(), (j['lon'] as num).toDouble());
}

class GuideInfo {
  final double distance, bearing;
  final double? turn; // 폰이 향한 방향 기준 상대 각도 (-180 왼쪽 ~ +180 오른쪽), 나침반 없으면 null
  final double? climb; // 목표 고도 - 현재 고도 (m), 고도 데이터 없으면 null
  final Duration walk;
  final bool arrived;
  const GuideInfo(this.distance, this.bearing, this.turn, this.climb, this.walk, this.arrived);
}

/// 상대 각도 -> "정면", "오른쪽 40°", "왼쪽 90°", "뒤쪽"
String turnLabel(double rel) {
  final a = rel.abs().round();
  if (a < 15) return '정면';
  if (a > 150) return '뒤쪽';
  return rel < 0 ? '왼쪽 $a°' : '오른쪽 $a°';
}

/// 걷는 시간 어림 (등산 지도 계산법): 평지 시속 4 km + 오르막 600 m마다 1시간 더
Duration walkTime(double distM, double? climbM) {
  final h = distM / 4000 + max(0.0, climbM ?? 0) / 600;
  return Duration(minutes: (h * 60).round());
}

/// 도착 판정 거리: 20 m, GPS 오차가 크면 그만큼 넓힘 (최대 50 m)
double arriveRadius(double? hAcc) => min(50.0, max(20.0, hAcc ?? 0));

GuideInfo guideInfo(double lat, double lon, double? hAcc, NavTarget t, double? heading,
    {double? hereElev, double? targetElev}) {
  final d = distanceM(lat, lon, t.lat, t.lon);
  final b = bearingDeg(lat, lon, t.lat, t.lon);
  final turn = heading == null ? null : (b - heading + 540) % 360 - 180;
  final climb = hereElev == null || targetElev == null ? null : targetElev - hereElev;
  return GuideInfo(d, b, turn, climb, walkTime(d, climb), d <= arriveRadius(hAcc));
}

/// 지금 안내 중인 목표 (앱을 다시 켜도 이어서 안내: documents/guide/target.json)
class Guide {
  final target = ValueNotifier<NavTarget?>(null);
  final info = ValueNotifier<GuideInfo?>(null);

  Future<File> _file() async => File('${(await _dataDir('guide')).path}/target.json');

  Future<void> load() async {
    try {
      final f = await _file();
      if (f.existsSync()) target.value = NavTarget.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {}
  }

  Future<void> start(NavTarget t) async {
    target.value = t;
    info.value = null;
    await (await _file()).writeAsString(jsonEncode(t.toJson()));
  }

  Future<void> stop() async {
    target.value = null;
    info.value = null;
    final f = await _file();
    if (f.existsSync()) f.deleteSync();
  }

  /// 위치나 방위가 바뀔 때마다 호출. [elevation]은 고도 데이터로 고도를 구하는 함수 (없으면 null)
  void update(double? lat, double? lon, double? hAcc, double? heading, double? Function(double, double)? elevation) {
    final t = target.value;
    if (t == null || lat == null || lon == null) {
      info.value = null;
      return;
    }
    info.value = guideInfo(lat, lon, hAcc, t, heading,
        hereElev: elevation?.call(lat, lon), targetElev: elevation?.call(t.lat, t.lon));
  }
}

// ---------------- GPX 경로 따라가기 ----------------
// 남이 만든 등산로 GPX나 내 이동 기록을 불러와 지도에 그리고, 남은 거리·이탈 여부를 계속 알려 줌.
// "왔던 길로 돌아가기"는 내 이동 기록을 거꾸로 따라가는 것

class GpxRoute {
  final String name;
  final List<TrackPoint> pts;
  final List<double> cum; // 시작점부터 각 점까지 누적 거리 (m)
  GpxRoute(this.name, this.pts) : cum = _cumulative(pts);

  double get total => cum.isEmpty ? 0 : cum.last;

  /// 갈림길에서 꺾는 곳 (음성 안내용, 처음 쓸 때 한 번 계산)
  late final List<RouteTurn> turns = findTurns(this);

  /// 시작점부터 [d] m 지점의 위치
  (double, double) pointAt(double d) {
    if (d <= 0) return (pts.first.lat, pts.first.lon);
    if (d >= total) return (pts.last.lat, pts.last.lon);
    var lo = 0, hi = cum.length - 1;
    while (hi - lo > 1) {
      final m = (lo + hi) ~/ 2;
      if (cum[m] <= d) {
        lo = m;
      } else {
        hi = m;
      }
    }
    final seg = cum[hi] - cum[lo], t = seg == 0 ? 0.0 : (d - cum[lo]) / seg;
    final a = pts[lo], b = pts[hi];
    return (a.lat + (b.lat - a.lat) * t, a.lon + (b.lon - a.lon) * t);
  }

  GpxRoute reversed() => GpxRoute('$name (되돌아가기)', pts.reversed.toList());

  static List<double> _cumulative(List<TrackPoint> pts) {
    final out = <double>[];
    var d = 0.0;
    for (var i = 0; i < pts.length; i++) {
      if (i > 0) d += distanceM(pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon);
      out.add(d);
    }
    return out;
  }
}

/// GPX 글에서 경로 점(trkpt, 없으면 rtept)과 이름을 읽음. 점이 2개 미만이면 null
GpxRoute? parseGpx(String xml, String fallbackName) {
  final pt = RegExp(r'<(trkpt|rtept)\b([^>]*?)(/>|>([\s\S]*?)</\1>)');
  final attr = RegExp(r'''(lat|lon)\s*=\s*["']([-0-9.eE+]+)["']''');
  final ele = RegExp(r'<ele>\s*([-0-9.eE+]+)\s*</ele>');
  List<TrackPoint> read(String tag) => [
        for (final m in pt.allMatches(xml))
          if (m.group(1) == tag)
            () {
              final a = {for (final x in attr.allMatches(m.group(2)!)) x.group(1)!: double.parse(x.group(2)!)};
              final e = m.group(4) == null ? null : ele.firstMatch(m.group(4)!);
              return a.length == 2 ? TrackPoint(a['lat']!, a['lon']!, e == null ? null : double.parse(e.group(1)!), DateTime(0)) : null;
            }()
      ].whereType<TrackPoint>().toList();
  var pts = read('trkpt');
  if (pts.length < 2) pts = read('rtept');
  if (pts.length < 2) return null;
  final name = RegExp(r'<name>\s*(?:<!\[CDATA\[)?([\s\S]*?)(?:\]\]>)?\s*</name>').firstMatch(xml)?.group(1)?.trim();
  return GpxRoute(name == null || name.isEmpty ? fallbackName : _xmlUnescape(name), pts);
}

/// 경로에서 꺾는 곳: [at] 시작점부터 거리 (m), [angle] 꺾는 각도 (-180 왼쪽 ~ +180 오른쪽)
class RouteTurn {
  final double at, angle;
  const RouteTurn(this.at, this.angle);
}

/// 꺾는 곳 찾기: 각 점에서 20 m 앞뒤 방향을 비교해 40° 넘게 바뀌면 꺾는 곳.
/// 굽은 길은 점이 여러 개라 20 m 안의 후보는 하나로 묶고 가장 크게 꺾는 점을 씀 (완만한 커브는 안 잡힘)
List<RouteTurn> findTurns(GpxRoute r, {double window = 20, double minAngle = 40}) {
  final out = <RouteTurn>[];
  for (var k = 1; k + 1 < r.pts.length; k++) {
    final c = r.cum[k];
    if (c < 5 || r.total - c < 5) continue;
    final p = r.pts[k];
    final (bLat, bLon) = r.pointAt(c - window);
    final (aLat, aLon) = r.pointAt(c + window);
    if (distanceM(bLat, bLon, p.lat, p.lon) < 3 || distanceM(p.lat, p.lon, aLat, aLon) < 3) continue;
    final inB = bearingDeg(bLat, bLon, p.lat, p.lon), outB = bearingDeg(p.lat, p.lon, aLat, aLon);
    final a = (outB - inB + 540) % 360 - 180;
    if (a.abs() < minAngle) continue;
    if (out.isNotEmpty && c - out.last.at < window) {
      if (a.abs() > out.last.angle.abs()) out[out.length - 1] = RouteTurn(c, a);
    } else {
      out.add(RouteTurn(c, a));
    }
  }
  return out;
}

/// 꺾는 각도 -> "약간 왼쪽", "왼쪽", "크게 오른쪽", "뒤로 돌아"
String turnWord(double angle) {
  final a = angle.abs(), side = angle < 0 ? '왼쪽' : '오른쪽';
  if (a >= 160) return '뒤로 돌아';
  if (a >= 120) return '크게 $side';
  if (a >= 60) return side;
  return '약간 $side';
}

class RouteInfo {
  final double off; // 경로에서 떨어진 거리 (m)
  final double done, left; // 경로를 따라 지나온 / 남은 거리 (m)
  final double ahead; // 경로 진행 방향 (도): 가장 가까운 곳에서 30 m 앞을 향함
  final double toRoute; // 경로로 돌아가는 방향 (도)
  final double climbLeft; // 남은 오르막 합 (m, 고도가 없는 GPX는 0)
  final bool offRoute, finished;
  final RouteTurn? next; // 다음에 꺾는 곳 (없으면 목적지까지 쭉)
  const RouteInfo(this.off, this.done, this.left, this.ahead, this.toRoute, this.climbLeft, this.offRoute, this.finished,
      [this.next]);

  /// 다음 꺾는 곳까지 남은 거리 (m)
  double? get toNext => next == null ? null : next!.at - done;

  Duration get walk => walkTime(left, climbLeft);
}

/// 경로 이탈 판정: 40 m, GPS 오차가 크면 오차 + 25 m
double offRouteLimit(double? hAcc) => max(40.0, (hAcc ?? 0) + 25);

RouteInfo routeInfo(GpxRoute r, double lat, double lon, double? hAcc) {
  final mLat = 111320.0, mLon = 111320.0 * cos(lat * pi / 180);
  var best = double.infinity, bestI = 0, bestT = 0.0;
  for (var i = 0; i + 1 < r.pts.length; i++) {
    final a = r.pts[i], b = r.pts[i + 1];
    final ax = (a.lon - lon) * mLon, ay = (a.lat - lat) * mLat;
    final bx = (b.lon - lon) * mLon, by = (b.lat - lat) * mLat;
    final l2 = (bx - ax) * (bx - ax) + (by - ay) * (by - ay);
    final t = l2 == 0 ? 0.0 : (((-ax) * (bx - ax) + (-ay) * (by - ay)) / l2).clamp(0.0, 1.0);
    final px = ax + (bx - ax) * t, py = ay + (by - ay) * t;
    final d = sqrt(px * px + py * py);
    if (d < best) {
      best = d;
      bestI = i;
      bestT = t;
    }
  }
  final a = r.pts[bestI], b = r.pts[bestI + 1];
  final pLat = a.lat + (b.lat - a.lat) * bestT, pLon = a.lon + (b.lon - a.lon) * bestT;
  final done = r.cum[bestI] + (r.cum[bestI + 1] - r.cum[bestI]) * bestT;
  // 30 m 앞 점으로 진행 방향
  var j = bestI + 1;
  while (j < r.pts.length - 1 && r.cum[j] - done < 30) {
    j++;
  }
  final ahead = bearingDeg(pLat, pLon, r.pts[j].lat, r.pts[j].lon);
  var climb = 0.0;
  for (var k = bestI + 1; k + 1 < r.pts.length; k++) {
    final e1 = r.pts[k].alt, e2 = r.pts[k + 1].alt;
    if (e1 != null && e2 != null && e2 > e1) climb += e2 - e1;
  }
  final left = r.total - done;
  return RouteInfo(best, done, left, ahead, bearingDeg(lat, lon, pLat, pLon), climb, best > offRouteLimit(hAcc),
      left <= arriveRadius(hAcc) && best <= offRouteLimit(hAcc), r.turns.where((t) => t.at > done).firstOrNull);
}

/// 지금 따라가는 경로 (앱을 다시 켜도 이어서: documents/guide/route.gpx)
class RouteFollow {
  final route = ValueNotifier<GpxRoute?>(null);
  final info = ValueNotifier<RouteInfo?>(null);
  NavTarget? target; // 길찾기로 만든 경로의 목적지 (벗어나면 다시 찾기)

  Future<File> _file() async => File('${(await _dataDir('guide')).path}/route.gpx');

  Future<void> load() async {
    try {
      final f = await _file();
      if (f.existsSync()) route.value = parseGpx(await f.readAsString(), '경로');
    } catch (_) {}
  }

  Future<void> start(GpxRoute r, {NavTarget? target}) async {
    this.target = target;
    route.value = r;
    info.value = null;
    await (await _file()).writeAsString(TrackRecorder.toGpx(r.name, r.pts));
  }

  Future<void> stop() async {
    target = null;
    route.value = null;
    info.value = null;
    final f = await _file();
    if (f.existsSync()) f.deleteSync();
  }

  void update(double? lat, double? lon, double? hAcc) {
    final r = route.value;
    info.value = r == null || lat == null || lon == null ? null : routeInfo(r, lat, lon, hAcc);
  }
}

/// 불러온 GPX 경로 보관 폴더 (documents/routes)
Future<Directory> routesDir() => _dataDir('routes');

String _xmlEscape(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
String _xmlUnescape(String s) =>
    s.replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&apos;', "'").replaceAll('&amp;', '&');
