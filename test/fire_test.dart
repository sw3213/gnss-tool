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

  test('fire status wording and the 100 m rule', () {
    expect(const FireStatus(forestM: 0).banned, isTrue);
    expect(const FireStatus(forestM: 0).summary, '숲 안: 불 피우기 금지 (산림보호법)');
    expect(const FireStatus(forestM: 40).banned, isTrue);
    expect(const FireStatus(forestM: 40).summary, contains('100 m 안'));
    expect(const FireStatus(forestM: 150).banned, isFalse);
    expect(const FireStatus(forestM: 150).chip, '불 가능');
    expect(const FireStatus().banned, isFalse); // 주변에 숲 없음
    expect(const FireStatus(forestM: 500, inPark: true, parkName: '북한산국립공원').summary, startsWith('북한산국립공원 안'));
    expect(const FireStatus(forestM: 500, inPark: true).chip, '불 금지');
    expect(isForest({'kind': 'wood'}), isTrue);
    expect(isForest({'kind': 'park'}), isFalse);
  });
}
