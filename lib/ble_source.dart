import 'dart:async';
import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// ============================================================
// 외부 장치 (ESP32-S3 + LC29H + AHT20/BMP280, firmware/black_gps)와 블루투스(BLE) 연결.
// 장치는 Nordic UART 서비스(NUS)로 줄 단위 글을 보냄:
//   - LC29H의 NMEA 문장 그대로 ($GNGGA, $GPGSV …)
//   - 1초마다 센서 문장  $PSENS,<기압 hPa>,<기온 °C>,<습도 %>,<배터리 %>*체크섬  (없는 값은 빈칸)
// 끊기면 5초마다 다시 찾아 연결. 폰 GPS로 바꾸는 판단은 main.dart가 함 (위치가 들어오는지로)
// ============================================================

final nusService = Guid('6e400001-b5a3-f393-e0a9-e50e24dcca9e');
final nusTx = Guid('6e400003-b5a3-f393-e0a9-e50e24dcca9e'); // 장치 -> 폰 (notify)
const deviceName = 'BlackGPS';

enum BleState { off, searching, connecting, connected }

/// 센서 문장 한 줄 ($PSENS,...) -> (기압, 기온, 습도, 배터리). 형식이 다르면 null
(double?, double?, double?, double?)? parseSensorSentence(String line) {
  if (!line.startsWith(r'$PSENS,')) return null;
  final star = line.indexOf('*');
  final body = line.substring(1, star < 0 ? line.length : star);
  if (star >= 0) {
    var cs = 0;
    for (final c in body.codeUnits) {
      cs ^= c;
    }
    if (int.tryParse(line.substring(star + 1).trim(), radix: 16) != cs) return null;
  }
  final f = body.split(',');
  double? v(int i) => i < f.length ? double.tryParse(f[i]) : null;
  return (v(1), v(2), v(3), v(4));
}

/// 블루투스 조각을 줄로 이어 붙임 (한 번에 오는 양이 MTU에 따라 잘림)
class LineJoiner {
  final void Function(String) onLine;
  final _buf = StringBuffer();
  LineJoiner(this.onLine);

  void add(List<int> bytes) {
    _buf.write(utf8.decode(bytes, allowMalformed: true));
    final s = _buf.toString();
    final parts = s.split('\n');
    _buf
      ..clear()
      ..write(parts.removeLast()); // 마지막 조각은 아직 줄이 안 끝남
    if (_buf.length > 4096) _buf.clear(); // 줄바꿈 없이 쓰레기만 오면 버림
    for (final p in parts) {
      final line = p.trim();
      if (line.isNotEmpty) onLine(line);
    }
  }
}

class BleGnss {
  final void Function(String line) onLine; // NMEA
  final void Function(double? pressure, double? temp, double? humidity, double? battery) onSensor;
  final void Function(BleState state, String? name) onState;
  BleGnss({required this.onLine, required this.onSensor, required this.onState});

  bool _running = false;
  BluetoothDevice? _dev;
  final _subs = <StreamSubscription<dynamic>>[];
  Timer? _retry;

  void start() {
    _running = true;
    _search();
  }

  Future<void> stop() async {
    _running = false;
    _retry?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    try {
      await _dev?.disconnect();
    } catch (_) {}
    _dev = null;
  }

  void _later() {
    _retry?.cancel();
    if (_running) _retry = Timer(const Duration(seconds: 5), _search);
  }

  Future<void> _search() async {
    if (!_running) return;
    try {
      if (await FlutterBluePlus.isSupported == false) {
        onState(BleState.off, '이 폰은 블루투스 LE를 지원하지 않습니다');
        return;
      }
      final adapter = await FlutterBluePlus.adapterState.firstWhere((s) => s != BluetoothAdapterState.unknown);
      if (adapter != BluetoothAdapterState.on) {
        onState(BleState.off, null);
        try {
          await FlutterBluePlus.turnOn(); // 안드로이드: "블루투스를 켤까요?" 창
        } catch (_) {}
        _later();
        return;
      }
      onState(BleState.searching, null);
      final found = Completer<BluetoothDevice?>();
      final sub = FlutterBluePlus.onScanResults.listen((rs) {
        for (final r in rs) {
          final name = r.advertisementData.advName.isNotEmpty ? r.advertisementData.advName : r.device.platformName;
          if (name.startsWith(deviceName) || r.advertisementData.serviceUuids.contains(nusService)) {
            if (!found.isCompleted) found.complete(r.device);
          }
        }
      });
      await FlutterBluePlus.startScan(withServices: [nusService], withKeywords: [deviceName], timeout: const Duration(seconds: 8));
      final dev = await found.future.timeout(const Duration(seconds: 9), onTimeout: () => null);
      await sub.cancel();
      await FlutterBluePlus.stopScan();
      if (dev == null) return _later();
      await _connect(dev);
    } catch (_) {
      _later();
    }
  }

  Future<void> _connect(BluetoothDevice dev) async {
    onState(BleState.connecting, dev.platformName);
    _dev = dev;
    await dev.connect(timeout: const Duration(seconds: 15), mtu: 247);
    final services = await dev.discoverServices();
    final tx = services
        .where((s) => s.uuid == nusService)
        .expand((s) => s.characteristics)
        .where((c) => c.uuid == nusTx)
        .firstOrNull;
    if (tx == null) {
      await dev.disconnect();
      onState(BleState.searching, '장치에서 UART 서비스를 찾지 못했습니다');
      return _later();
    }
    final joiner = LineJoiner((line) {
      final s = parseSensorSentence(line);
      if (s != null) {
        onSensor(s.$1, s.$2, s.$3, s.$4);
      } else if (line.startsWith(r'$')) {
        onLine(line);
      }
    });
    _subs.add(tx.onValueReceived.listen(joiner.add));
    _subs.add(dev.connectionState.listen((st) {
      if (st == BluetoothConnectionState.disconnected && _running) {
        onState(BleState.searching, '연결 끊김 — 다시 찾는 중');
        for (final s in _subs) {
          s.cancel();
        }
        _subs.clear();
        _later();
      }
    }));
    await tx.setNotifyValue(true);
    onState(BleState.connected, dev.platformName.isEmpty ? deviceName : dev.platformName);
  }
}
