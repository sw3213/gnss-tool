import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gnss_tool/routing.dart';

/// [경도, 위도] 목록 (GeoJSON 순서)
List<List<num>> line(List<(double, double)> latLon) => [for (final (la, lo) in latLon) [lo, la]];

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('routes'));
  tearDown(() => tmp.deleteSync(recursive: true));

  RouteGraph build(void Function(RouteGraphBuilder b) add, {double? Function(double, double)? elevation}) {
    final b = RouteGraphBuilder(126.9, 36.9, 127.1, 37.1, elevation: elevation);
    add(b);
    final path = '${tmp.path}/g${tmp.listSync().length}.grt';
    b.write(path);
    return RouteGraph.open(path);
  }

  test('way classes from OpenStreetMap tags', () {
    expect(wayClass({'highway': 'path'}), WayClass.path);
    expect(wayClass({'highway': 'path', 'sac_scale': 'alpine_hiking'}), WayClass.alpineTrail);
    expect(wayClass({'highway': 'primary'}), WayClass.primary);
    expect(wayClass({'highway': 'primary', 'sidewalk': 'both'}), WayClass.tertiary);
    expect(wayClass({'highway': 'motorway'}), isNull);
    expect(wayClass({'highway': 'trunk', 'motorroad': 'yes'}), isNull);
    expect(wayClass({'highway': 'service', 'access': 'private'}), isNull);
    expect(wayClass({'highway': 'service', 'access': 'private', 'foot': 'yes'}), WayClass.minor);
    expect(wayClass({'highway': 'footway', 'foot': 'no'}), isNull);
    expect(wayClass({'highway': 'construction'}), isNull);
    expect(wayClass({'building': 'yes'}), isNull);
  });

  test('avoids a big road even if the detour is longer', () {
    final g = build((b) {
      b.addWay(WayClass.primary, line([(37.0, 127.0), (37.0, 127.01)]));
      b.addWay(WayClass.minor, line([(37.0, 127.0), (37.002, 127.005), (37.0, 127.01)]));
    });
    final r = findRoute(g, 37.0, 127.0, 37.0, 127.01);
    expect(r.byClass[WayClass.primary], 0);
    expect(r.byClass[WayClass.minor], closeTo(r.length, 1));
    expect(r.pts.any((p) => (p.$1 - 37.002).abs() < 1e-6), isTrue); // 돌아가는 길의 가운데 점을 지남
    expect(r.length, greaterThan(950));
    g.close();
  });

  test('prefers the flat way around a hill', () {
    // 37.0, 127.005 에 높이 200 m 언덕
    double hill(double lat, double lon) {
      final d = sqrt(pow((lat - 37.0) * 111320, 2) + pow((lon - 127.005) * 88900, 2));
      return 200 * exp(-d * d / (2 * 150 * 150));
    }

    final g = build((b) {
      b.addWay(WayClass.path, line([(37.0, 127.0), (37.0, 127.005), (37.0, 127.01)])); // 언덕 넘기
      b.addWay(WayClass.path, line([(37.0, 127.0), (37.006, 127.005), (37.0, 127.01)])); // 언덕 돌기
    }, elevation: hill);
    final r = findRoute(g, 37.0, 127.0, 37.0, 127.01);
    expect(r.up, lessThan(20));
    expect(r.pts.any((p) => (p.$1 - 37.006).abs() < 1e-6), isTrue);
    // 반대로 짧은 길만 있으면 넘어가고, 오르막이 계산됨
    final g2 = build((b) => b.addWay(WayClass.path, line([(37.0, 127.0), (37.0, 127.005), (37.0, 127.01)])),
        elevation: hill);
    final r2 = findRoute(g2, 37.0, 127.0, 37.0, 127.01);
    expect(r2.up, closeTo(200, 15));
    expect(r2.down, closeTo(200, 15));
    g.close();
    g2.close();
  });

  test('starts and ends on the nearest point of a road, in the middle of it', () {
    final g = build((b) {
      b.addWay(WayClass.minor, line([(37.0, 127.0), (37.0, 127.004), (37.0, 127.008), (37.0, 127.012)]));
      b.addWay(WayClass.minor, line([(37.0, 127.012), (37.004, 127.012)]));
    });
    // 길에서 북쪽으로 약 33 m 떨어진 곳 -> 길 가운데로 붙음
    final r = findRoute(g, 37.0003, 127.003, 37.002, 127.0123);
    expect(r.startGap, closeTo(33, 2));
    expect(r.endGap, closeTo(27, 2));
    expect(r.pts.first.$1, closeTo(37.0, 1e-6));
    expect(r.pts.first.$2, closeTo(127.003, 1e-6));
    expect(r.pts.last.$1, closeTo(37.002, 1e-6));
    // 127.003 -> 127.012 (약 800 m) + 북쪽 222 m
    expect(r.length, closeTo(800 + 222, 10));

    // 같은 길 위 두 점 (거꾸로 가기)
    final same = findRoute(g, 37.0, 127.010, 37.0, 127.002);
    expect(same.length, closeTo(711, 5));
    expect(same.pts.first.$2, closeTo(127.010, 1e-6));
    expect(same.pts.last.$2, closeTo(127.002, 1e-6));
    g.close();
  });

  test('reports when there is no road nearby or no connection', () {
    final g = build((b) {
      b.addWay(WayClass.minor, line([(37.0, 127.0), (37.0, 127.01)]));
      b.addWay(WayClass.minor, line([(37.05, 127.05), (37.05, 127.06)])); // 섬
    });
    expect(() => findRoute(g, 37.02, 127.0, 37.0, 127.01), throwsA(isA<RouteException>()));
    expect(
        () => findRoute(g, 37.0, 127.0, 37.05, 127.055),
        throwsA(predicate((e) => e is RouteException && e.message.contains('이어져'))));
    g.close();
  });

  test('road pieces that only join each other are merged into one connection', () {
    final g = build((b) {
      // 같은 길이 세 조각으로 나뉨 + 가운데에서 다른 종류 길이 이어짐
      b.addWay(WayClass.minor, line([(37.0, 127.0), (37.0, 127.002)]));
      b.addWay(WayClass.minor, line([(37.0, 127.002), (37.0005, 127.004), (37.0, 127.006)]));
      b.addWay(WayClass.path, line([(37.0, 127.006), (37.0, 127.01)]));
      b.addWay(WayClass.path, line([(37.0, 127.01), (37.003, 127.01)]));
    });
    expect(g.nodes, 3); // 127.0 / 127.006 (종류가 바뀜) / 37.003 끝
    final r = findRoute(g, 37.0, 127.0, 37.003, 127.01);
    expect(r.pts.any((p) => (p.$1 - 37.0005).abs() < 1e-6), isTrue);
    expect(r.pts.any((p) => (p.$2 - 127.002).abs() < 1e-6 && p.$1 == 37.0), isTrue); // 합친 이음매 점도 모양에 남음
    expect(r.byClass[WayClass.minor], closeTo(550, 3)); // 178 m + 굽은 곳 186 m × 2
    g.close();
  });

  test('a loop road is split so both halves can be used', () {
    final g = build((b) {
      b.addWay(WayClass.minor, line([(37.0, 127.0), (37.0, 127.01)]));
      b.addWay(WayClass.path,
          line([(37.0, 127.01), (37.003, 127.01), (37.003, 127.013), (37.0, 127.013), (37.0, 127.01)]));
    });
    final r = findRoute(g, 37.0, 127.0, 37.003, 127.0115);
    expect(r.length, closeTo(890 + 333 + 133, 15));
    g.close();
  });
}
