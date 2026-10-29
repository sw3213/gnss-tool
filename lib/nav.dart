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
      ..writeln('<trk><name>$name</name><trkseg>');
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
