import 'dart:math';
import 'dart:typed_data';

import 'dem.dart';

// ============================================================
// 바람 피할 곳 (참고): 고도 격자로 칸마다 "바람이 불어오는 쪽 지형이 얼마나 높이 막고 있는지" 계산
//   - 바람 오는 쪽으로 1.5 km까지 훑어 올려다보는 각도의 최대값 (Winstral의 바람 가림 지수 Sx)
//     바람 방향 ±15°도 함께 보고 평균 -> 방향이 조금 흔들려도 비슷하게
//   - 각도가 크면 산·언덕 뒤라 바람이 약함, 음수면 앞이 다 낮은 능선·꼭대기라 바람이 셈
//   - 계곡 바닥(둘레보다 15 m 넘게 낮음)은 바람은 적어도 밤에 찬 공기가 고이고 비 오면 물이 불어 따로 표시
// 나무·건물이 막는 바람, 산 뒤 소용돌이는 모름 -> 참고용
// ============================================================

/// 칸 종류
const windNeutral = 0, windShelter = 1, windPartial = 2, windExposed = 3, windValley = 4;

class WindGrid {
  final int n; // 한 변 칸 수
  final double north, south, west, east;
  final Uint8List cells; // 위쪽 줄부터, [windShelter] 등
  const WindGrid(this.n, this.north, this.south, this.west, this.east, this.cells);

  /// 지도에 겹칠 그림 (RGBA): 초록 = 바람 적음, 노랑 = 조금 막힘, 빨강 = 바람 셈, 파랑 = 계곡 바닥
  Uint8List rgba() {
    final out = Uint8List(n * n * 4);
    for (var i = 0; i < n * n; i++) {
      final (r, g, b, a) = switch (cells[i]) {
        windShelter => (47, 158, 68, 105),
        windPartial => (250, 200, 40, 70),
        windExposed => (224, 49, 49, 95),
        windValley => (77, 140, 247, 95),
        _ => (0, 0, 0, 0),
      };
      out[i * 4] = r;
      out[i * 4 + 1] = g;
      out[i * 4 + 2] = b;
      out[i * 4 + 3] = a;
    }
    return out;
  }
}

/// 바람 가림 각도 (도): [fromDeg]에서 불어오는 바람에 대해 [lat]/[lon] 앞쪽 지형이 막는 정도.
/// 앞이 막혀 있으면 +, 앞이 다 낮으면(능선) −
double shelterAngle(double Function(double lat, double lon) elev, double lat, double lon, double fromDeg,
    {double maxM = 1500, double stepM = 45}) {
  final z0 = elev(lat, lon);
  final mLat = 111320.0, mLon = 111320.0 * cos(lat * pi / 180);
  var sum = 0.0;
  for (final spread in const [-15.0, 0.0, 15.0]) {
    final a = (fromDeg + spread) * pi / 180;
    final dx = sin(a), dy = cos(a);
    var best = -90.0;
    for (var d = stepM * 1.5; d <= maxM; d += stepM) {
      final z = elev(lat + dy * d / mLat, lon + dx * d / mLon);
      final ang = atan2(z - z0, d) * 180 / pi;
      if (ang > best) best = ang;
    }
    sum += best;
  }
  return sum / 3;
}

/// 가운데 [lat]/[lon]에서 [halfM] 안을 [cellM] 칸으로 나눠 칸마다 바람 종류
WindGrid windGrid(DemFile dem, double lat, double lon, double fromDeg, {double halfM = 2500, double cellM = 40}) =>
    windGridFrom((la, lo) => dem.elevation(la, lo) ?? 0, lat, lon, fromDeg, halfM: halfM, cellM: cellM);

WindGrid windGridFrom(double Function(double lat, double lon) elev, double lat, double lon, double fromDeg,
    {double halfM = 2500, double cellM = 40}) {
  final n = (2 * halfM / cellM).round();
  final dLat = halfM / 111320, dLon = halfM / (111320 * cos(lat * pi / 180));
  final north = lat + dLat, south = lat - dLat, west = lon - dLon, east = lon + dLon;
  final cells = Uint8List(n * n);
  final mLat = 111320.0, mLon = 111320.0 * cos(lat * pi / 180);
  for (var r = 0; r < n; r++) {
    final la = north - (r + 0.5) / n * (north - south);
    for (var c = 0; c < n; c++) {
      final lo = west + (c + 0.5) / n * (east - west);
      final z0 = elev(la, lo);
      // 계곡 바닥: 둘레 300 m(8방향) 평균보다 15 m 넘게 낮음
      var ring = 0.0;
      for (var k = 0; k < 8; k++) {
        final a = k * pi / 4;
        ring += elev(la + cos(a) * 300 / mLat, lo + sin(a) * 300 / mLon);
      }
      if (z0 < ring / 8 - 15) {
        cells[r * n + c] = windValley;
        continue;
      }
      final s = shelterAngle(elev, la, lo, fromDeg);
      cells[r * n + c] = s >= 8
          ? windShelter
          : s >= 3
              ? windPartial
              : s <= -3
                  ? windExposed
                  : windNeutral;
    }
  }
  return WindGrid(n, north, south, west, east, cells);
}

/// 바람이 불어오는 방향 이름 ("북서풍")
String windFromLabel(double deg) {
  const names = ['북', '북동', '동', '남동', '남', '남서', '서', '북서'];
  return '${names[((deg % 360) / 45).round() % 8]}풍';
}
