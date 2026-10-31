import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gnss_tool/dop.dart';
import 'package:gnss_tool/main.dart';
import 'package:gnss_tool/weather.dart';

// 해발 h, 해면기압 qnh일 때 기압계가 읽을 현지기압
double station(double qnh, double h) => qnh * pow(1 - h / 44330, 5.255).toDouble();

void main() {
  final t0 = DateTime(2026, 10, 29, 11);
  final rnd = Random(1);
  double noisy(double h) => h + (rnd.nextDouble() - 0.5) * 20; // 폰 GNSS 고도 ±10 m

  test('qnh / altitude round trip (원주 단구동 예: 997.5 hPa, 예보 1019 hPa)', () {
    final h = altFrom(997.5, 1019);
    expect(h, closeTo(180, 10));
    expect(qnhFrom(997.5, h), closeTo(1019, 1e-6));
  });

  test('filter: noisy GNSS at fixed altitude converges to true sea-level pressure', () {
    final f = BaroAltFilter();
    for (int i = 0; i < 600; i++) {
      f.update(station(1019, 180), noisy(180));
    }
    expect(f.qnh, closeTo(1019, 0.3));
    expect(f.alt, closeTo(180, 3));
  });

  test('filter: climbing 150 m is altitude, not weather', () {
    final f = BaroAltFilter();
    for (int i = 0; i < 600; i++) {
      f.update(station(1019, 180), noisy(180));
    }
    double worst = 0;
    for (int i = 0; i < 600; i++) {
      final h = 180 + 0.25 * i; // 10분 동안 150 m 상승
      f.update(station(1019, h), noisy(h));
      worst = max(worst, (f.qnh! - 1019).abs());
    }
    expect(worst, lessThan(0.5));
    expect(f.alt, closeTo(330, 5));
  });

  test('weather: 6 hPa/3h fall at fixed altitude triggers storm level', () {
    final f = BaroAltFilter();
    final w = StormWatch();
    late StormStatus st;
    for (int i = 0; i < 90 * 60; i++) {
      final qnh = 1019 - 6.5 / (3 * 3600) * i;
      f.update(station(qnh, 180), noisy(180));
      if (f.qnh != null) st = w.add(t0.add(Duration(seconds: i)), f.qnh!);
    }
    expect(st.rate3h, closeTo(-6.5, 1.0));
    expect(st.level, StormLevel.storm);
    expect(st.text, contains('하강'));
  });

  test('weather: steady pressure stays calm, short data says collecting', () {
    final w = StormWatch();
    late StormStatus st;
    for (int i = 0; i < 10 * 60; i++) {
      st = w.add(t0.add(Duration(seconds: i)), 1015 + (rnd.nextDouble() - 0.5) * 0.1);
    }
    expect(st.rate3h, isNull);
    expect(st.text, contains('수집 중'));
    expect(st.level, StormLevel.none);
  });

  test('weather: 3.5 hPa drop within 5 minutes is a rapid-drop storm', () {
    final w = StormWatch();
    late StormStatus st;
    for (int i = 0; i < 300; i++) {
      final q = i < 120 ? 1015.0 : 1015 - 3.5 * min(1, (i - 120) / 120);
      st = w.add(t0.add(Duration(seconds: i)), q);
    }
    expect(st.drop5m, greaterThan(3.0));
    expect(st.level, StormLevel.storm);
    expect(st.text, contains('급하강'));
  });

  test('DOP from geometry: many well-spread satellites give HDOP well below 1', () {
    final sats = [
      for (final el in [20, 50])
        for (int az = 0; az < 360; az += 30) Sat(el == 20 ? 'GPS' : 'GAL', az + el, el, az, 40, used: true),
      const Sat('GPS', 99, 90, 0, 45, used: true),
    ];
    final d = dopFromSats(sats)!;
    expect(d.hdop, inInclusiveRange(0.3, 1.0));
    expect(d.pdop, greaterThan(d.hdop));
  });

  test('DOP from geometry: too few satellites returns null', () {
    expect(dopFromSats([const Sat('GPS', 1, 40, 0, 40, used: true)]), isNull);
  });

  test('weather: saved history survives a restart and the trend continues', () {
    final w = StormWatch();
    var saved = 0;
    w.onMinute = () => saved++;
    // 1시간 동안 5 hPa/3h로 하강
    for (int i = 0; i < 60 * 60; i++) {
      w.add(t0.add(Duration(seconds: i)), 1019 - 5 / (3 * 3600) * i);
    }
    expect(saved, 59);
    final text = w.encode();

    // 20분 꺼져 있다가 다시 켬: 기록을 되살리고 계속 하강
    final w2 = StormWatch();
    final back = t0.add(const Duration(minutes: 80));
    w2.restore(StormWatch.decode(text), back);
    expect(w2.minutes.length, 59);
    late StormStatus st;
    for (int i = 0; i < 120; i++) {
      final s = 80 * 60 + i;
      st = w2.add(t0.add(Duration(seconds: s)), 1019 - 5 / (3 * 3600) * s);
    }
    expect(st.spanMin, greaterThan(80));
    expect(st.rate3h, closeTo(-5, 0.3));
    expect(st.level, StormLevel.warning);
  });

  test('weather: restore drops values older than 3 hours or in the future', () {
    final w = StormWatch();
    final now = t0.add(const Duration(hours: 4));
    w.restore([
      (t0, 1010.0), // 4시간 전
      (now.subtract(const Duration(minutes: 30)), 1012.0),
      (now.subtract(const Duration(minutes: 90)), 1011.0),
      (now.add(const Duration(minutes: 5)), 1013.0), // 시계가 바뀜
    ], now);
    expect(w.minutes.map((e) => e.$2), [1011.0, 1012.0]);
  });

  test('filter: settles only after enough GNSS heights', () {
    final f = BaroAltFilter();
    for (int i = 0; i < 29; i++) {
      f.update(station(1019, 180), noisy(180));
    }
    expect(f.settled, isFalse);
    f.update(station(1019, 180), noisy(180));
    expect(f.settled, isTrue);
  });
}
