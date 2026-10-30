import 'package:flutter_test/flutter_test.dart';
import 'package:gnss_tool/advice.dart';
import 'package:gnss_tool/terrain.dart';
import 'package:gnss_tool/weather.dart';

void main() {
  final noon = DateTime(2026, 7, 30, 15, 0);
  final sun = TerrainSun(DateTime(2026, 7, 30, 6, 0), DateTime(2026, 7, 30, 18, 30), null, null);

  List<String> titles(AdviceInput a) => [for (final x in advise(a)) x.title];

  test('heat index matches NWS table (32°C, 70% -> about 41°C)', () {
    expect(heatIndex(32, 70), closeTo(40.5, 1.5));
    expect(heatIndex(20, 90), 20); // 덥지 않으면 기온 그대로
  });

  test('hot and humid: heat stroke danger first', () {
    final a = advise(AdviceInput(now: noon, temp: 34, humidity: 75, sun: sun));
    expect(a.first.level, AdviceLevel.danger);
    expect(a.first.title, startsWith('열사병 위험'));
    expect(titles(AdviceInput(now: noon, temp: 30, humidity: 60, sun: sun)).first, startsWith('더위 주의'));
  });

  test('humidity surge with falling pressure -> flood danger', () {
    const falling = StormStatus(rate3h: -2, level: StormLevel.none);
    final a = advise(AdviceInput(now: noon, temp: 24, humidity: 90, humidity10m: 70, weather: falling, sun: sun));
    expect(a.first.level, AdviceLevel.danger);
    expect(a.first.detail, contains('계곡'));
    // 기압이 그대로면 주의만
    expect(advise(AdviceInput(now: noon, temp: 24, humidity: 90, humidity10m: 70, sun: sun)).first.level, AdviceLevel.warn);
  });

  test('not enough daylight to reach the target', () {
    final late = DateTime(2026, 7, 30, 17, 30); // 일몰 1시간 전
    expect(titles(AdviceInput(now: late, sun: sun, walkLeft: const Duration(minutes: 90))), contains('일몰 전에 도착 못 함'));
    expect(titles(AdviceInput(now: late, sun: sun, walkLeft: const Duration(minutes: 20))), contains('일몰 60분 전'));
    expect(titles(AdviceInput(now: DateTime(2026, 7, 30, 21), sun: sun)), contains('야간'));
  });

  test('phone battery and calm conditions', () {
    expect(titles(AdviceInput(now: noon, sun: sun, battery: const Battery(8, 30, false))).first, '배터리 8%');
    expect(advise(AdviceInput(now: noon, sun: sun, battery: const Battery(8, 30, true))), isEmpty); // 충전 중
    expect(titles(AdviceInput(now: noon, sun: sun, battery: const Battery(80, 47, false))), contains('폰 과열 (47°C)'));
    // 폰만 있을 때(온·습도 없음) 평온하면 조언 없음
    expect(advise(AdviceInput(now: noon, sun: sun, hAcc: 4, battery: const Battery(80, 30, false))), isEmpty);
  });
}
