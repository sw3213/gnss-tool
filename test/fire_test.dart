import 'package:flutter_test/flutter_test.dart';
import 'package:gnss_tool/fire.dart';
import 'package:gnss_tool/water.dart' show areaDistanceM;

void main() {
  // 위도 37도에서 0.001도 ≈ 위도 111 m, 경도 89 m
  final square = [
    [(37.0, 127.0), (37.0, 127.01), (37.01, 127.01), (37.01, 127.0), (37.0, 127.0)]
  ];

  test('distance to an area: 0 inside, to the edge outside', () {
    expect(areaDistanceM(square, 37.005, 127.005), 0);
    expect(areaDistanceM(square, 36.999, 127.005), closeTo(111, 2)); // 남쪽으로 0.001도
    expect(areaDistanceM(square, 37.005, 127.011), closeTo(89, 2)); // 동쪽으로 0.001도
    // 구멍 안은 밖
    final holed = [
      ...square,
      [(37.004, 127.004), (37.004, 127.006), (37.006, 127.006), (37.006, 127.004), (37.004, 127.004)]
    ];
    expect(areaDistanceM(holed, 37.005, 127.005), greaterThan(80));
  });

  test('fire status wording: law 100 m, app keeps 150 m', () {
    expect(const FireStatus(forestM: 0).banned, isTrue);
    expect(const FireStatus(forestM: 0).summary, '숲 안: 불 피우기 금지 (산림보호법)');
    expect(const FireStatus(forestM: 40).banned, isTrue);
    expect(const FireStatus(forestM: 40).summary, contains('100 m 안'));
    expect(const FireStatus(forestM: 120).banned, isTrue); // 법 기준은 넘지만 여유 안
    expect(const FireStatus(forestM: 120).summary, contains('150 m 안은 피하세요'));
    expect(const FireStatus(forestM: 160).banned, isFalse);
    expect(const FireStatus(forestM: 160).chip, '불 가능');
    expect(const FireStatus().banned, isFalse); // 주변에 숲 없음
    expect(const FireStatus(forestM: 500, inPark: true, parkName: '북한산국립공원').summary, startsWith('북한산국립공원 안'));
    expect(const FireStatus(forestM: 500, inPark: true).chip, '불 금지');
    expect(isForest({'kind': 'wood'}), isTrue);
    expect(isForest({'kind': 'park'}), isFalse);
  });

  test('fire grid: forest, the 150 m band around it, and national parks', () {
    // 가운데(37.0, 127.0)에서 동쪽 0.005도(약 444 m)부터 숲, 남쪽 끝에 국립공원
    final forest = [
      [(36.99, 127.005), (36.99, 127.03), (37.01, 127.03), (37.01, 127.005), (36.99, 127.005)]
    ];
    final park = [
      [(36.98, 126.97), (36.98, 127.03), (36.985, 127.03), (36.985, 126.97), (36.98, 126.97)]
    ];
    final g = fireGridFrom([forest], [park], 37.0, 127.0, halfM: 2000, cellM: 10);
    expect(g.n, 400);
    int at(double lat, double lon) {
      final r = ((g.north - lat) / (g.north - g.south) * g.n).floor();
      final c = ((lon - g.west) / (g.east - g.west) * g.n).floor();
      return g.cells[r * g.n + c];
    }

    expect(at(37.0, 127.0), 0); // 숲에서 약 444 m: 가능
    expect(at(37.0, 127.006), 1); // 숲 안
    expect(at(37.0, 127.0045), 1); // 숲에서 약 44 m
    expect(at(37.0, 127.0035), 1); // 숲에서 약 133 m: 여유(150 m) 안
    expect(at(37.0, 127.003), 0); // 숲에서 약 178 m
    expect(at(36.9835, 126.995), 2); // 국립공원
    expect(g.rgba().length, 400 * 400 * 4);
  });
}
