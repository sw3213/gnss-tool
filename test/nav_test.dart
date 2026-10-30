import 'package:flutter_test/flutter_test.dart';
import 'package:gnss_tool/nav.dart';

void main() {
  test('distance and bearing', () {
    // 서울시청 -> 원주시청 직선 약 86 km, 동남동
    final d = distanceM(37.5665, 126.9780, 37.3422, 127.9202);
    expect(d, closeTo(86300, 1500));
    expect(bearingDeg(37.5665, 126.9780, 37.3422, 127.9202), closeTo(106, 3));
    expect(directionLabel(89), '동 89°');
    expect(directionLabel(359.6), '북 0°');
    expect(distanceLabel(1500), '1.50 km');
    expect(distanceLabel(820), '820 m');
  });

  test('track ignores GPS jitter and poor fixes', () {
    final r = TrackRecorder()..start();
    r.add(37.0, 127.0, 100, 5);
    r.add(37.00001, 127.0, 100, 5); // 약 1 m: 흔들림으로 무시
    r.add(37.001, 127.0, 100, 50); // 오차 50 m: 무시
    r.add(37.001, 127.0, 100, 5); // 약 111 m
    expect(r.points.value.length, 2);
    expect(r.distance.value, closeTo(111, 2));
  });

  test('sunrise/sunset in Wonju is plausible', () {
    // 원주 10월 말 일출 6시 50분대, 일몰 17시 30분대 (천문연구원 표 기준 대략값)
    final s = sunTimes(DateTime(2026, 10, 30), 37.34, 127.92);
    final rise = s.rise!.toUtc().add(const Duration(hours: 9));
    final set = s.set!.toUtc().add(const Duration(hours: 9));
    expect(rise.hour * 60 + rise.minute, closeTo(6 * 60 + 52, 5));
    expect(set.hour * 60 + set.minute, closeTo(17 * 60 + 35, 5));
  });

  test('GPX export', () {
    final gpx = TrackRecorder.toGpx('t', [TrackPoint(37, 127, 100, DateTime.utc(2026))]);
    expect(gpx, contains('<trkpt lat="37.0000000" lon="127.0000000"><ele>100.0</ele>'));
  });

  test('target guidance: distance, turn, walking time, arrival', () {
    // 원주 단구동에서 북동쪽 약 1.4 km 지점
    const t = NavTarget('목표', 37.33, 127.945);
    final i = guideInfo(37.32, 127.935, 5, t, 0, hereElev: 180, targetElev: 300);
    expect(i.distance, closeTo(1417, 20));
    expect(i.bearing, closeTo(39, 2));
    expect(i.turn, closeTo(38.4, 1)); // 북쪽을 보고 있으면 오른쪽 38°
    expect(turnLabel(i.turn!), '오른쪽 38°');
    expect(i.climb, 120);
    // 1.42 km / 4 km/h ≈ 21분 + 120 m 오르막 / 600 m/h = 12분
    expect(i.walk.inMinutes, closeTo(33, 1));
    expect(i.arrived, isFalse);

    // 반대 방향을 보고 있으면 뒤쪽, 나침반 없으면 turn 없음
    expect(turnLabel(guideInfo(37.32, 127.935, 5, t, 220).turn!), '뒤쪽');
    expect(turnLabel(-90), '왼쪽 90°');
    expect(turnLabel(8), '정면');
    expect(guideInfo(37.32, 127.935, 5, t, null).turn, isNull);

    // 15 m 앞이면 도착, GPS 오차가 40 m면 35 m 앞도 도착으로 침
    expect(guideInfo(37.32, 127.935, 5, const NavTarget('a', 37.32013, 127.935), null).arrived, isTrue);
    expect(guideInfo(37.32, 127.935, 5, const NavTarget('a', 37.32032, 127.935), null).arrived, isFalse);
    expect(guideInfo(37.32, 127.935, 40, const NavTarget('a', 37.32032, 127.935), null).arrived, isTrue);
  });

  test('GPX route: parse, progress along route, off-route, reverse', () {
    // 북쪽으로 곧게 1 km (0.009°마다 약 1 km), 고도 100 -> 300 m
    const xml = '''<?xml version="1.0"?><gpx><trk><name>치악산 A&amp;B</name><trkseg>
      <trkpt lat="37.300" lon="128.000"><ele>100</ele></trkpt>
      <trkpt lat="37.3045" lon="128.000"><ele>200</ele></trkpt>
      <trkpt lat="37.309" lon="128.000"><ele>300</ele></trkpt>
    </trkseg></trk></gpx>''';
    final r = parseGpx(xml, 'x')!;
    expect(r.name, '치악산 A&B');
    expect(r.pts.length, 3);
    expect(r.total, closeTo(1000, 10));

    // 중간쯤, 경로 위
    final mid = routeInfo(r, 37.3045, 128.0, 5);
    expect(mid.off, lessThan(1));
    expect(mid.done, closeTo(500, 10));
    expect(mid.left, closeTo(500, 10));
    expect(mid.ahead, closeTo(0, 1)); // 북쪽으로 진행
    expect(mid.climbLeft, 100);
    expect(mid.offRoute, isFalse);

    // 동쪽으로 100 m 벗어남 -> 이탈, 경로는 서쪽
    final off = routeInfo(r, 37.3045, 128.00113, 5);
    expect(off.off, closeTo(100, 5));
    expect(off.offRoute, isTrue);
    expect(off.toRoute, closeTo(270, 2));

    // 끝 근처 -> 도착
    expect(routeInfo(r, 37.30899, 128.0, 5).finished, isTrue);

    // 거꾸로 = 왔던 길로 돌아가기: 남쪽으로 진행, 오르막 없음
    final back = routeInfo(r.reversed(), 37.3045, 128.0, 5);
    expect(back.ahead, closeTo(180, 1));
    expect(back.climbLeft, 0);

    // 이름이 쓴 그대로 다시 읽히는지 (저장할 때 &를 이스케이프)
    expect(parseGpx(TrackRecorder.toGpx(r.name, r.pts), 'x')!.name, '치악산 A&B');
    expect(parseGpx('<gpx></gpx>', 'x'), isNull);
  });
}
