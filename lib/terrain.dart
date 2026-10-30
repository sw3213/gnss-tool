import 'dart:math';
import 'dart:typed_data';

import 'dem.dart';
import 'nav.dart';

export 'dem.dart';

// ============================================================
// 지형 분석: 고도 격자(.gdem) 읽기, 전방 경사, 태양 위치, 산 능선(지평선), 지형 일출·일몰, 가시권
// 고도 격자 형식은 maps/build_dem.py 참고 (한국 3초 ≈ 90 m 간격)
// ============================================================

/// [lat],[lon]에서 [bearing] 방향으로 [d] m 간 지점
(double, double) destination(double lat, double lon, double bearing, double d) {
  const r = 6371008.8;
  final p1 = lat * pi / 180, l1 = lon * pi / 180, b = bearing * pi / 180, a = d / r;
  final p2 = asin(sin(p1) * cos(a) + cos(p1) * sin(a) * cos(b));
  final l2 = l1 + atan2(sin(b) * sin(a) * cos(p1), cos(a) - sin(p1) * sin(p2));
  return (p2 * 180 / pi, l2 * 180 / pi);
}

// ---------------- 전방 경사 ----------------

/// 바라보는 방향 [ahead] m 앞과의 높이 차 (m)와 경사 (%)
(double, double)? forwardSlope(DemFile dem, double lat, double lon, double heading, {double ahead = 100}) {
  final h0 = dem.elevation(lat, lon);
  final (la, lo) = destination(lat, lon, heading, ahead);
  final h1 = dem.elevation(la, lo);
  if (h0 == null || h1 == null) return null;
  final dh = h1 - h0;
  return (dh, dh / ahead * 100);
}

String slopeLabel((double, double) s) {
  final (dh, pct) = s;
  if (pct.abs() < 2) return '전방 평지 ${dh >= 0 ? '+' : ''}${dh.round()}m';
  return '전방 ${dh > 0 ? '오르막' : '내리막'} ${dh > 0 ? '+' : ''}${dh.round()}m · ${pct > 0 ? '+' : ''}${pct.round()}%';
}

// ---------------- 태양 위치 (NOAA 근사식) ----------------

/// 시각 [t]에 태양의 방위각(도, 진북 기준)과 고도각(도, 대기 굴절 포함)
(double, double) sunPosition(DateTime t, double lat, double lon) {
  final u = t.toUtc();
  final n = u.difference(DateTime.utc(u.year, 1, 1)).inDays + 1;
  final hour = u.hour + u.minute / 60 + u.second / 3600;
  final g = 2 * pi / 365 * (n - 1 + (hour - 12) / 24);
  final eqTime = 229.18 *
      (0.000075 + 0.001868 * cos(g) - 0.032077 * sin(g) - 0.014615 * cos(2 * g) - 0.040849 * sin(2 * g));
  final decl = 0.006918 -
      0.399912 * cos(g) +
      0.070257 * sin(g) -
      0.006758 * cos(2 * g) +
      0.000907 * sin(2 * g) -
      0.002697 * cos(3 * g) +
      0.00148 * sin(3 * g);
  // 진태양시 (분). 한국 아침은 UTC로 전날 저녁이라 24시간을 넘어가므로 하루로 감음
  final tst = (hour * 60 + eqTime + 4 * lon) % 1440;
  final ha = (tst / 4 - 180) * pi / 180; // 시간각
  final phi = lat * pi / 180;
  final cosZen = (sin(phi) * sin(decl) + cos(phi) * cos(decl) * cos(ha)).clamp(-1.0, 1.0);
  final zen = acos(cosZen);
  final elev = 90 - zen * 180 / pi;
  var az = acos(((sin(phi) * cosZen - sin(decl)) / (cos(phi) * sin(zen))).clamp(-1.0, 1.0)) * 180 / pi;
  az = ha > 0 ? (az + 180) % 360 : (540 - az) % 360;
  // 대기 굴절 (지평선 근처에서 약 0.5°)
  final r = elev > -2 ? 1.02 / tan((elev + 10.3 / (elev + 5.11)) * pi / 180) / 60 : 0.0;
  return (az, elev + r);
}

// ---------------- 산 능선 (지평선 각도) ----------------

/// [az] 방향으로 [maxDist] m까지 지형이 가리는 가장 높은 각도 (도). 지구 곡률·대기 굴절 보정
double horizonAngle(DemFile dem, double lat, double lon, double eyeH, double az, {double maxDist = 25000}) {
  const r = 6371008.8, k = 0.13; // 굴절 계수
  var best = -90.0;
  final step = dem.cellMeters;
  for (var d = step; d <= maxDist; d += d < 3000 ? step : step * 2) {
    final (la, lo) = destination(lat, lon, az, d);
    final h = dem.elevation(la, lo);
    if (h == null) break;
    final drop = d * d / (2 * r) * (1 - k);
    final ang = atan2(h - drop - eyeH, d) * 180 / pi;
    if (ang > best) best = ang;
  }
  return best;
}

class TerrainSun {
  final DateTime? rise, set; // 산 위로 해가 보이기 시작 / 산 뒤로 넘어감
  final DateTime? astroRise, astroSet; // 평지 기준
  const TerrainSun(this.rise, this.set, this.astroRise, this.astroSet);

  Duration? get daylight => rise != null && set != null ? set!.difference(rise!) : null;
}

/// 지형을 반영한 일출·일몰: 태양 고도각이 그 방향 산 능선보다 높아지는 첫 순간 / 낮아지는 마지막 순간
TerrainSun terrainSun(DemFile dem, DateTime day, double lat, double lon) {
  final astro = sunTimes(day, lat, lon);
  if (astro.rise == null || astro.set == null) return TerrainSun(null, null, astro.rise, astro.set);
  final eye = (dem.elevation(lat, lon) ?? 0) + 1.7;
  final horizon = <int, double>{}; // 0.5° 단위 방위각 -> 능선 각도
  double hz(double az) => horizon.putIfAbsent((az * 2).round(), () => horizonAngle(dem, lat, lon, eye, az));
  bool visible(DateTime t) {
    final (az, el) = sunPosition(t, lat, lon);
    return el > hz(az) + 0.27; // 해의 윗가장자리 기준 (반지름 0.27°)
  }

  DateTime? rise, set;
  for (var m = -20; m <= 240; m++) {
    final t = astro.rise!.add(Duration(minutes: m));
    if (visible(t)) {
      rise = t;
      break;
    }
  }
  for (var m = 20; m >= -240; m--) {
    final t = astro.set!.add(Duration(minutes: m));
    if (visible(t)) {
      set = t;
      break;
    }
  }
  return TerrainSun(rise, set, astro.rise, astro.set);
}

// ---------------- 가시권 ----------------

class Viewshed {
  final int size; // size x size 칸, 가운데가 관측 지점
  final double cellM;
  final double lat, lon;
  final Uint8List visible; // 1 = 보임, 0 = 가려짐, 255 = 반경 밖
  const Viewshed(this.size, this.cellM, this.lat, this.lon, this.visible);

  int get hiddenCount => visible.where((v) => v == 0).length;
}

/// 관측 지점에서 반경 [radius] m 안 각 칸이 보이는지 (지형만, 나무·건물 제외).
/// 사방으로 광선을 쏘며 지금까지의 최대 올려본각보다 높은 칸만 "보임"
Viewshed viewshed(DemFile dem, double lat, double lon, {double radius = 5000, double eye = 1.7}) {
  final cell = dem.cellMeters;
  final half = (radius / cell).ceil();
  final size = half * 2 + 1;
  final out = Uint8List(size * size)..fillRange(0, size * size, 255);
  final h0 = (dem.elevation(lat, lon) ?? 0) + eye;
  const r = 6371008.8, k = 0.13;
  final mLat = 111320.0, mLon = 111320.0 * cos(lat * pi / 180);
  final rays = (2 * pi * half * 1.5).ceil(); // 가장자리 칸까지 빠짐없이 닿도록
  for (var i = 0; i < rays; i++) {
    final a = 2 * pi * i / rays;
    final dx = sin(a), dy = cos(a);
    var maxSlope = double.negativeInfinity;
    for (var d = cell / 2; d <= radius; d += cell / 2) {
      final ex = dx * d, ny = dy * d;
      final cx = half + (ex / cell).round(), cy = half - (ny / cell).round();
      if (cx < 0 || cy < 0 || cx >= size || cy >= size) break;
      final h = dem.elevation(lat + ny / mLat, lon + ex / mLon);
      if (h == null) break;
      final slope = (h - d * d / (2 * r) * (1 - k) - h0) / d;
      final idx = cy * size + cx;
      final vis = slope >= maxSlope;
      if (vis) maxSlope = slope;
      // 같은 칸을 여러 광선이 지나면 한 번이라도 보이면 보임
      if (out[idx] != 1) out[idx] = vis ? 1 : 0;
    }
  }
  out[half * size + half] = 1;
  return Viewshed(size, cell, lat, lon, out);
}
