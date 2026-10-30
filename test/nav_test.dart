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
}
