import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gnss_tool/nav.dart';
import 'package:gnss_tool/voice.dart';

const _lat0 = 37.0, _lon0 = 127.0;
final _mLon = 111320.0 * cos(_lat0 * pi / 180);

/// 시작점에서 동쪽 x m, 북쪽 y m 지점
TrackPoint _p(double x, double y) => TrackPoint(_lat0 + y / 111320, _lon0 + x / _mLon, null, DateTime(0));

/// 북쪽으로 300 m 간 뒤 서쪽(왼쪽)으로 200 m. 점은 10 m마다, 꺾는 곳 앞은 살짝 둥글게
GpxRoute _lRoute() => GpxRoute('L', [
      for (var y = 0.0; y < 300; y += 10) _p(0, y),
      _p(-3, 303),
      for (var x = -10.0; x >= -200; x -= 10) _p(x, 305),
    ]);

void main() {
  test('finds one left turn on an L-shaped route, none on a gentle curve', () {
    final r = _lRoute();
    expect(r.turns.length, 1);
    expect(r.turns.first.at, closeTo(300, 15));
    expect(r.turns.first.angle, closeTo(-90, 15));
    expect(turnWord(r.turns.first.angle), '왼쪽');
    expect(turnWord(30 + 20), '약간 오른쪽');
    expect(turnWord(-170), '뒤로 돌아');

    // 반지름 300 m 원호 (90°): 꺾는 곳 없음
    final arc = GpxRoute('arc', [
      for (var a = 0.0; a <= 90; a += 2) _p(300 - 300 * cos(a * pi / 180), 300 * sin(a * pi / 180)),
    ]);
    expect(arc.turns, isEmpty);
  });

  test('pointAt interpolates along the route', () {
    final r = _lRoute();
    final (lat, lon) = r.pointAt(155);
    expect(distanceM(lat, lon, _p(0, 155).lat, _p(0, 155).lon), lessThan(1));
  });

  test('announces start, turn ahead, turn now, off route, arrival once each', () {
    final r = _lRoute(), a = VoiceAnnouncer();
    List<String> at(double x, double y, {DateTime? now}) {
      final p = _p(x, y);
      return a.update(r, routeInfo(r, p.lat, p.lon, 5), hasTarget: true, now: now);
    }

    final s = at(0, 0);
    expect(s.single, startsWith('경로 안내를 시작합니다. 목적지까지 500미터'));
    expect(at(0, 100), isEmpty);
    expect(at(0, 190), ['110미터 앞에서 왼쪽으로 가세요.']);
    expect(at(0, 200), isEmpty); // 같은 꺾는 곳은 한 번만
    expect(at(0, 280), ['왼쪽으로 가세요.']);
    expect(at(0, 285), isEmpty);

    final t0 = DateTime(2026);
    final off = at(-100, 400, now: t0);
    expect(off.single, startsWith('경로를 벗어났습니다. 경로는 남쪽'));
    expect(off.single, contains('다시 찾기'));
    expect(at(-100, 400, now: t0.add(const Duration(seconds: 30))), isEmpty);
    expect(at(-100, 400, now: t0.add(const Duration(seconds: 100))).single, startsWith('경로를 벗어났습니다'));
    expect(at(-100, 305), ['경로로 돌아왔습니다.']);
    expect(at(-200, 305), ['목적지에 도착했습니다. 안내를 마칩니다.']);
    expect(at(-200, 305), isEmpty);
    expect(speechDistance(1234), '1.2킬로미터');
  });
}
