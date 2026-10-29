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

  test('water classification excludes sea, pools and fountains', () {
    // 실제 한국 지도에서 본 종류들
    expect(waterLabel('water', {'kind': 'stream'}), '계곡·개울');
    expect(waterLabel('water', {'kind': 'river'}), '하천');
    expect(waterLabel('water', {'kind': 'water', 'kind_detail': 'lake'}), '호수');
    expect(waterLabel('water', {'kind': 'water', 'kind_detail': 'river'}), '하천');
    expect(waterLabel('water', {'kind': 'water'}), '연못·물');
    expect(waterLabel('water', {'kind': 'ocean'}), isNull);
    expect(waterLabel('water', {'kind': 'swimming_pool'}), isNull);
    expect(waterLabel('water', {'kind': 'fountain'}), isNull);
    expect(waterLabel('pois', {'kind': 'drinking_water'}), '식수대');
    expect(waterLabel('pois', {'kind': 'cafe'}), isNull);
  });
}
