import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gnss_tool/wind.dart';

void main() {
  // 동쪽 경도 127.01에 남북으로 긴 능선(높이 200 m, 폭 약 900 m), 나머지는 평지 100 m
  double ridge(double lat, double lon) {
    final x = (lon - 127.01) * 111320 * cos(37 * pi / 180); // 능선에서 동서 거리 (m)
    return 100 + 200 * exp(-(x * x) / (2 * 300 * 300));
  }

  test('lee of a ridge is sheltered, its crest is exposed', () {
    // 동풍(90°): 능선 서쪽 400 m는 바람 그늘, 능선 꼭대기는 바람 셈
    final west = 127.01 - 400 / (111320 * cos(37 * pi / 180));
    expect(shelterAngle(ridge, 37.0, west, 90), greaterThan(8));
    expect(shelterAngle(ridge, 37.0, 127.01, 90), lessThan(-3));
    // 서풍(270°)이면 같은 자리는 바람을 그대로 맞음
    expect(shelterAngle(ridge, 37.0, west, 270), lessThan(3));
    expect(windFromLabel(315), '북서풍');
    expect(windFromLabel(-10), '북풍');
  });

  test('wind grid colours lee, crest and valley floor', () {
    final g = windGridFrom(ridge, 37.0, 127.01, 90, halfM: 1500, cellM: 50);
    int at(double lat, double lon) {
      final r = ((g.north - lat) / (g.north - g.south) * g.n).floor();
      final c = ((lon - g.west) / (g.east - g.west) * g.n).floor();
      return g.cells[r * g.n + c];
    }

    final m = 111320 * cos(37 * pi / 180);
    expect(at(37.0, 127.01 - 400 / m), windShelter);
    expect(at(37.0, 127.01), windExposed);
    // 좁은 골짜기: 둘레보다 깊으면 계곡 바닥
    double valley(double lat, double lon) {
      final x = (lon - 127.0) * m;
      return 200 - 60 * exp(-(x * x) / (2 * 80 * 80));
    }

    final v = windGridFrom(valley, 37.0, 127.0, 0, halfM: 500, cellM: 50);
    expect(v.cells[(v.n ~/ 2) * v.n + v.n ~/ 2], windValley);
    expect(g.rgba().length, g.n * g.n * 4);
  });
}
