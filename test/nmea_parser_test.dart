import 'package:flutter_test/flutter_test.dart';
import 'package:gnss_tool/main.dart';

void main() {
  test('dual-band GSV: L5 cycle does not overwrite L1 satellites', () {
    final p = NmeaParser();
    // NMEA 4.10+: 끝 필드가 신호 ID (1 = L1 C/A, 8 = L5)
    p.feed(nmea('GPGSV,1,1,02,01,40,100,35,03,50,200,30,1'));
    p.feed(nmea('GPGSV,1,1,01,01,40,100,42,8'));
    p.feed(nmea('GNGGA,000000.00,3733.9900,N,12658.6800,E,1,02,1.0,45.0,M,0.0,M,,'));

    final sats = p.notifier.value.sats;
    expect(sats.map((s) => s.prn).toSet(), {1, 3});
    expect(sats.firstWhere((s) => s.prn == 1).snr, 42); // 두 신호 중 센 쪽
    expect(p.notifier.value.dropped, 0);
  });

  test('legacy GSV without signal ID and missing sentence detection', () {
    final p = NmeaParser();
    p.feed(nmea('GPGSV,2,1,05,01,40,100,35,03,50,200,30,06,10,10,20,09,20,20,25'));
    p.feed(nmea('GPGSV,2,2,05,11,30,300,28'));
    p.feed(nmea('GLGSV,2,2,05,65,30,300,28')); // 1번 없이 2번부터 -> 폐기
    p.feed(nmea('GNGGA,000000.00,3733.9900,N,12658.6800,E,1,05,1.0,45.0,M,0.0,M,,'));

    expect(p.notifier.value.sats.length, 5);
    expect(p.notifier.value.dropped, 1);
  });

  test('external satellite list (phone GnssStatus) replaces GSV', () {
    final p = NmeaParser();
    p.feed(nmea('GPGSV,1,1,01,01,40,100,35'));
    p.externalSats = [const Sat('GAL', 11, 60, 90, 40, used: true, l5: true)];
    p.publish();
    expect(p.notifier.value.sats.single.sys, 'GAL');
  });
}
