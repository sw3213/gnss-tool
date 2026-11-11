import 'dart:math';
import 'dart:typed_data';

import 'water.dart' show PmTiles, areasIn, nearestArea;

// ============================================================
// 불 사용(화기) 참고: 지도 자료의 숲·국립공원 경계로 "여기서 불을 피워도 되는지" 어림
//   - 산림보호법: 산림과 산림에서 100 m 안(산림인접지역)에서는 불을 피우면 안 됨 (과태료)
//   - 자연공원법: 국립공원 안에서는 지정된 곳 밖에서 불을 쓰면 안 됨
// 지도에 그려진 숲만 알 수 있고, 지자체가 따로 정한 금지·건조특보·사유지는 모름 -> 참고용으로만 보여 줌
// ============================================================

const forestLawM = 100.0; // 산림인접지역 (산림보호법)
const forestBufferM = 150.0; // 앱이 금지로 보는 거리: 법 기준 100 m에 여유 50 m

class FireStatus {
  final double? forestM; // 가장 가까운 숲까지 (m, 숲 안이면 0). 주변 약 2 km 안에 없으면 null
  final bool inPark; // 국립공원 안
  final String? parkName;
  const FireStatus({this.forestM, this.inPark = false, this.parkName});

  /// 금지로 봄 (국립공원 안, 숲 안이나 숲 150 m 안: 법은 100 m지만 안전하게 여유를 둠)
  bool get banned => inPark || (forestM != null && forestM! < forestBufferM);

  /// 지도 칩 글씨: "불 금지" / "불 가능"
  String get chip => banned ? '불 금지' : '불 가능';

  /// 한 줄 설명
  String get summary {
    final f = forestM;
    if (inPark) return '${parkName ?? '국립공원'} 안: 지정된 곳 밖에서 불 사용 금지 (자연공원법)';
    if (f == null) return '주변 2 km 안에 지도에 그려진 숲 없음: 산림인접지역 밖으로 보임';
    if (f == 0) return '숲 안: 불 피우기 금지 (산림보호법)';
    if (f < forestLawM) return '숲까지 ${f.round()} m: 100 m 안이라 불 피우기 금지 (산림보호법)';
    if (f < forestBufferM) return '숲까지 ${f.round()} m: 법 기준(100 m)은 넘지만 안전하게 150 m 안은 피하세요';
    return '숲까지 ${f.round()} m: 숲에서 150 m 밖 (법 기준 100 m보다 여유)';
  }

  /// 주의 사항 (판단은 사용자가)
  static const caution = '지도에 그려진 숲만 봅니다. 지자체 금지, 산불조심기간·건조특보, 사유지는 따로 확인하세요. '
      '긴급할 때도 바람을 피하고 주변을 정리한 뒤 작게, 반드시 완전히 끄세요';
}

/// 숲: landuse의 forest(조림지)·wood(자연림)
bool isForest(Map<String, Object?> p) => p['kind'] == 'forest' || p['kind'] == 'wood';

/// 국립공원
bool isNationalPark(Map<String, Object?> p) => p['kind'] == 'national_park';

/// 기본 지도(z14 타일)로 불 사용 참고 정보 계산
FireStatus fireStatus(PmTiles pm, double lat, double lon) {
  final forest = nearestArea(pm, lat, lon, 'landuse', isForest);
  final park = nearestArea(pm, lat, lon, 'landuse', isNationalPark, maxRing: 0);
  final inPark = park != null && park.$1 == 0;
  return FireStatus(
    forestM: forest?.$1,
    inPark: inPark,
    parkName: inPark ? (park.$2['name:ko'] ?? park.$2['name']) as String? : null,
  );
}

// ---------------- 불 사용 지도 (주변을 한 번에 칠하기) ----------------

/// 가운데 [lat]/[lon]에서 [halfM] 안을 [cellM] 칸으로 나눠 칸마다 0 가능 / 1 금지(숲 150 m 안) / 2 금지(국립공원).
/// 숲을 칸에 칠한 뒤 칸 거리(대각선 √2)로 150 m 안을 넓힘 -> 칸 수만큼만 계산해서 빠름
class FireGrid {
  final int n; // 한 변 칸 수
  final double north, south, west, east;
  final Uint8List cells; // 위쪽 줄부터
  const FireGrid(this.n, this.north, this.south, this.west, this.east, this.cells);

  /// 지도에 겹칠 그림 (RGBA): 가능 = 옅은 초록, 금지 = 옅은 빨강
  Uint8List rgba() {
    final out = Uint8List(n * n * 4);
    for (var i = 0; i < n * n; i++) {
      final ban = cells[i] != 0;
      out[i * 4] = ban ? 224 : 47;
      out[i * 4 + 1] = ban ? 49 : 158;
      out[i * 4 + 2] = ban ? 49 : 68;
      out[i * 4 + 3] = ban ? 95 : 80;
    }
    return out;
  }
}

FireGrid fireGrid(PmTiles pm, double lat, double lon, {double halfM = 2000, double cellM = 16}) {
  final dLat = halfM / 111320, dLon = halfM / (111320 * cos(lat * pi / 180));
  final (n, s, w, e) = (lat + dLat, lat - dLat, lon - dLon, lon + dLon);
  return fireGridFrom([for (final (r, _) in areasIn(pm, s, w, n, e, 'landuse', isForest)) r],
      [for (final (r, _) in areasIn(pm, s, w, n, e, 'landuse', isNationalPark)) r], lat, lon,
      halfM: halfM, cellM: cellM);
}

/// [forests]·[parks] 테두리(위도·경도, 면마다 첫 번째가 바깥)로 칸 칠하기
FireGrid fireGridFrom(List<List<List<(double, double)>>> forests, List<List<List<(double, double)>>> parks, double lat,
    double lon,
    {double halfM = 2000, double cellM = 16}) {
  final n = (2 * halfM / cellM).round();
  final dLat = halfM / 111320, dLon = halfM / (111320 * cos(lat * pi / 180));
  final north = lat + dLat, south = lat - dLat, west = lon - dLon, east = lon + dLon;
  final forest = Uint8List(n * n), park = Uint8List(n * n);

  // 면을 칸에 칠하기 (줄마다 테두리와 만나는 곳을 구해 짝수-홀수 규칙으로)
  void fill(List<List<(double, double)>> rings, Uint8List grid) {
    var minLat = 90.0, maxLat = -90.0;
    for (final (la, _) in rings.first) {
      minLat = min(minLat, la);
      maxLat = max(maxLat, la);
    }
    final r0 = max(0, ((north - maxLat) / (north - south) * n).floor());
    final r1 = min(n - 1, ((north - minLat) / (north - south) * n).ceil());
    for (var r = r0; r <= r1; r++) {
      final y = north - (r + 0.5) / n * (north - south);
      final xs = <double>[];
      for (final ring in rings) {
        for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
          final (yi, xi) = ring[i];
          final (yj, xj) = ring[j];
          if ((yi > y) != (yj > y)) xs.add(xi + (y - yi) / (yj - yi) * (xj - xi));
        }
      }
      xs.sort();
      for (var k = 0; k + 1 < xs.length; k += 2) {
        final c0 = max(0, ((xs[k] - west) / (east - west) * n - 0.5).ceil());
        final c1 = min(n - 1, ((xs[k + 1] - west) / (east - west) * n - 0.5).floor());
        for (var c = c0; c <= c1; c++) {
          grid[r * n + c] = 1;
        }
      }
    }
  }

  for (final rings in forests) {
    fill(rings, forest);
  }
  for (final rings in parks) {
    fill(rings, park);
  }

  // 숲에서 칸 거리 (두 번 훑기, 가로세로 1·대각선 √2)
  const inf = 1e9;
  final d = Float64List(n * n);
  for (var i = 0; i < n * n; i++) {
    d[i] = forest[i] == 1 ? 0 : inf;
  }
  const s2 = 1.4142135623730951;
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      var v = d[r * n + c];
      if (c > 0) v = min(v, d[r * n + c - 1] + 1);
      if (r > 0) {
        v = min(v, d[(r - 1) * n + c] + 1);
        if (c > 0) v = min(v, d[(r - 1) * n + c - 1] + s2);
        if (c < n - 1) v = min(v, d[(r - 1) * n + c + 1] + s2);
      }
      d[r * n + c] = v;
    }
  }
  for (var r = n - 1; r >= 0; r--) {
    for (var c = n - 1; c >= 0; c--) {
      var v = d[r * n + c];
      if (c < n - 1) v = min(v, d[r * n + c + 1] + 1);
      if (r < n - 1) {
        v = min(v, d[(r + 1) * n + c] + 1);
        if (c < n - 1) v = min(v, d[(r + 1) * n + c + 1] + s2);
        if (c > 0) v = min(v, d[(r + 1) * n + c - 1] + s2);
      }
      d[r * n + c] = v;
    }
  }
  final cells = Uint8List(n * n);
  for (var i = 0; i < n * n; i++) {
    cells[i] = park[i] == 1 ? 2 : (d[i] * cellM < forestBufferM ? 1 : 0);
  }
  return FireGrid(n, north, south, west, east, cells);
}
