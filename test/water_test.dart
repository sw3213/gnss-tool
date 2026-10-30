import 'package:flutter_test/flutter_test.dart';
import 'package:gnss_tool/water.dart';

void main() {
  test('PMTiles tile ids follow the spec (hilbert order per zoom)', () {
    expect(zxyToTileId(0, 0, 0), 0);
    expect(zxyToTileId(1, 0, 0), 1);
    expect(zxyToTileId(1, 0, 1), 2);
    expect(zxyToTileId(1, 1, 1), 3);
    expect(zxyToTileId(1, 1, 0), 4);
    expect(zxyToTileId(2, 0, 0), 5);
  });

  test('survival water: flowing water and springs only', () {
    // 실제 한국 지도에서 본 종류들
    expect(waterLabel('water', {'kind': 'stream'}), '계곡·개울');
    expect(waterLabel('water', {'kind': 'river'}), '하천');
    expect(waterLabel('water', {'kind': 'water', 'kind_detail': 'lake'}), isNull); // 이름 없는 소류지가 이렇게 들어옴
    expect(waterLabel('water', {'kind': 'water', 'kind_detail': 'river'}), '하천');
    expect(waterLabel('pois', {'kind': 'drinking_water'}), '식수대');
    expect(waterLabel('pois', {'kind': 'spring'}), '샘');

    // 바다·수영장·분수
    expect(waterLabel('water', {'kind': 'ocean'}), isNull);
    expect(waterLabel('water', {'kind': 'swimming_pool'}), isNull);
    expect(waterLabel('water', {'kind': 'fountain'}), isNull);
    expect(waterLabel('pois', {'kind': 'cafe'}), isNull);

    // 고인 물·인공 수로: 소류지·저수지·연못, 농수로·배수로
    expect(waterLabel('water', {'kind': 'water'}), isNull);
    expect(waterLabel('water', {'kind': 'water', 'kind_detail': 'reservoir'}), isNull);
    expect(waterLabel('water', {'kind': 'ditch'}), isNull);
    expect(waterLabel('water', {'kind': 'drain'}), isNull);
    expect(waterLabel('water', {'kind': 'canal'}), isNull);
    expect(waterLabel('water', {'kind': 'water', 'kind_detail': 'lake', 'name': '내동소류지'}), isNull);
    expect(waterLabel('water', {'kind': 'water', 'kind_detail': 'lake', 'name': '장성저수지'}), isNull);
    expect(waterLabel('water', {'kind': 'stream', 'name': '남송천'}), '계곡·개울');
  });
}
