import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gnss_tool/ble_source.dart';

String withChecksum(String body) {
  var cs = 0;
  for (final c in body.codeUnits) {
    cs ^= c;
  }
  return '\$$body*${cs.toRadixString(16).toUpperCase().padLeft(2, '0')}';
}

void main() {
  test('sensor sentence from the device', () {
    final s = parseSensorSentence(withChecksum('PSENS,1001.25,23.4,61.0,87'))!;
    expect(s.$1, 1001.25);
    expect(s.$2, 23.4);
    expect(s.$3, 61.0);
    expect(s.$4, 87);
    // 센서가 없으면 빈칸
    final missing = parseSensorSentence(withChecksum('PSENS,1001.25,,,'))!;
    expect(missing.$2, isNull);
    // 체크섬이 틀리면 버림, NMEA는 센서 문장이 아님
    expect(parseSensorSentence(r'$PSENS,1001.25,23.4,61.0,87*00'), isNull);
    expect(parseSensorSentence(r'$GNGGA,1,2,3*00'), isNull);
  });

  test('BLE chunks are joined into whole lines', () {
    final lines = <String>[];
    final j = LineJoiner(lines.add);
    // MTU 때문에 한 줄이 여러 조각으로, 여러 줄이 한 조각으로 올 수 있음
    j.add(utf8.encode(r'$GNGGA,0123,37.3'));
    j.add(utf8.encode('2,N*5A\r\n\$GNRMC,'));
    expect(lines, [r'$GNGGA,0123,37.32,N*5A']);
    j.add(utf8.encode('A*00\n\n'));
    expect(lines.last, r'$GNRMC,A*00');
    expect(lines.length, 2);
  });
}
