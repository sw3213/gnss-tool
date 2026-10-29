import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';

import 'main.dart' show Sat;

// ============================================================
// 데이터 출처 "폰 GPS": 폰 내장 GNSS + 기압계 (MainActivity.kt의 EventChannel)
// ============================================================

class PhoneGnss {
  final void Function(String line) onLine; // 원시 NMEA -> NmeaParser (위치, DOP, 로그)
  final void Function(List<Sat> sats) onSats; // 위성 목록은 GnssStatus가 더 정확 (사용 여부 포함)
  final void Function(double? hAcc, double? vAcc) onAccuracy; // 폰이 추정한 오차 (m)
  final void Function(double hPa) onPressure;
  final void Function(String code) onGnssError; // PERMISSION_DENIED, GPS_OFF
  final void Function() onNoBarometer;

  PhoneGnss({
    required this.onLine,
    required this.onSats,
    required this.onAccuracy,
    required this.onPressure,
    required this.onGnssError,
    required this.onNoBarometer,
  });

  static const _gnss = EventChannel('gnss_tool/gnss');
  static const _pressure = EventChannel('gnss_tool/pressure');
  StreamSubscription<dynamic>? _g, _p;

  // android.location.GnssStatus.CONSTELLATION_* (SBAS, IRNSS는 표시하지 않음)
  static const _sys = {1: 'GPS', 3: 'GLO', 4: 'QZS', 5: 'BDS', 6: 'GAL'};

  void start() {
    _g = _gnss.receiveBroadcastStream().listen(
          _onGnss,
          onError: (Object e) => onGnssError(e is PlatformException ? e.code : '$e'),
        );
    _p = _pressure.receiveBroadcastStream().listen(
          (v) => onPressure((v as num).toDouble()),
          onError: (Object _) => onNoBarometer(),
        );
  }

  void stop() {
    _g?.cancel();
    _p?.cancel();
  }

  void _onGnss(dynamic event) {
    final m = event as Map;
    switch (m['type']) {
      case 'nmea':
        onLine(m['line'] as String);
      case 'loc':
        onAccuracy((m['hAcc'] as num?)?.toDouble(), (m['vAcc'] as num?)?.toDouble());
      case 'sats':
        onSats(_merge((m['sats'] as List).cast<List<dynamic>>()));
    }
  }

  // 듀얼밴드 폰은 같은 위성이 L1, L5 신호로 두 번 옴 -> 한 위성으로 합치고 L5 수신 여부 표시
  List<Sat> _merge(List<List<dynamic>> rows) {
    final out = <String, Sat>{};
    for (final r in rows) {
      final sys = _sys[r[0]];
      if (sys == null) continue;
      final prn = r[1] as int;
      final cn0 = (r[4] as num).round();
      final hz = (r[6] as num).toDouble();
      final isL5 = hz > 1.16e9 && hz < 1.19e9; // L5 / E5a / B2a ≈ 1176.45 MHz
      final prev = out['$sys$prn'];
      final snr = cn0 > 0 ? max(cn0, prev?.snr ?? 0) : prev?.snr; // 0 = 추적 안 함
      out['$sys$prn'] = Sat(
        sys,
        prn,
        (r[3] as num).round(),
        (r[2] as num).round(),
        snr,
        used: (r[5] as bool) || (prev?.used ?? false),
        l5: (isL5 && cn0 > 0) || (prev?.l5 ?? false),
      );
    }
    return out.values.toList();
  }
}
