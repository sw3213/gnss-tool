import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'nav.dart';

// ============================================================
// 음성 안내 (네비처럼): 경로 따라가기 중 꺾는 곳·이탈·도착을 말로 알려 줌.
// 폰에 깔린 음성 엔진(MainActivity.kt의 gnss_tool/voice)을 써서 인터넷 없이 동작
// ============================================================

class Voice {
  static final instance = Voice._();
  Voice._();

  static const _ch = MethodChannel('gnss_tool/voice');
  final enabled = ValueNotifier<bool>(true);

  /// 말하기. [flush]면 하던 말을 끊고 바로. 결과: null 정상, 'NO_ENGINE' / 'NO_KOREAN' 음성 엔진 문제
  Future<String?> speak(String text, {bool flush = false}) async {
    if (!enabled.value || kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      return await _ch.invokeMethod<String>('speak', {'text': text, 'flush': flush});
    } catch (_) {
      return 'NO_ENGINE';
    }
  }

  Future<void> stop() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _ch.invokeMethod<void>('stop');
    } catch (_) {}
  }
}

/// 거리를 읽기 좋게: 10 m 단위 "120미터", 1 km 넘으면 "1.2킬로미터"
String speechDistance(double m) =>
    m < 1000 ? '${(m / 10).round() * 10}미터' : '${(m / 1000).toStringAsFixed(1)}킬로미터';

/// 경로 정보가 바뀔 때마다 할 말을 정함 (말하기와 분리해 테스트 가능)
class VoiceAnnouncer {
  static const farM = 120.0, nearM = 30.0; // 미리 알림 / 지금 꺾으라는 알림 거리
  static const offRepeat = Duration(seconds: 90); // 이탈 중이면 이만큼마다 다시 알림

  GpxRoute? _route;
  bool _started = false, _off = false, _done = false;
  final _far = <double>{}, _near = <double>{}; // 이미 알린 꺾는 곳 (RouteTurn.at)
  DateTime _offAt = DateTime(0);

  /// [hasTarget]: 길찾기로 만든 경로라 "다시 찾기"가 가능한지
  List<String> update(GpxRoute? r, RouteInfo? i, {bool hasTarget = false, DateTime? now}) {
    now ??= DateTime.now();
    if (!identical(r, _route)) {
      _route = r;
      _started = _off = _done = false;
      _far.clear();
      _near.clear();
    }
    if (r == null || i == null || _done) return const [];
    final out = <String>[];
    if (!_started) {
      _started = true;
      out.add('경로 안내를 시작합니다. 목적지까지 ${speechDistance(i.left)}, 걸어서 약 ${durationLabel(i.walk)}입니다.');
    }
    if (i.finished) {
      _done = true;
      return [...out, '목적지에 도착했습니다. 안내를 마칩니다.'];
    }
    if (i.offRoute) {
      if (!_off || now.difference(_offAt) >= offRepeat) {
        _offAt = now;
        final dir = directionLabel(i.toRoute).split(' ').first;
        out.add('경로를 벗어났습니다. 경로는 $dir쪽 ${speechDistance(i.off)}입니다.'
            '${!_off && hasTarget ? ' 다시 찾기를 누르면 새 경로를 찾습니다.' : ''}');
      }
      _off = true;
      return out;
    }
    if (_off) {
      _off = false;
      out.add('경로로 돌아왔습니다.');
    }
    final t = i.next, d = i.toNext;
    if (t == null || d == null) return out;
    if (d <= nearM) {
      if (_near.add(t.at)) {
        _far.add(t.at);
        final after = r.turns.where((x) => x.at > t.at).firstOrNull;
        final gap = (after?.at ?? r.total) - t.at;
        out.add(after != null && gap <= 40
            ? '${_go(t.angle)} 간 뒤, 바로 ${_go(after.angle)} 가세요.'
            : '${_go(t.angle)} 가세요.${gap >= 300 ? ' 그다음 ${speechDistance(gap)} 쭉 가세요.' : ''}');
      }
    } else if (d <= farM && _far.add(t.at)) {
      out.add('${speechDistance(d)} 앞에서 ${_go(t.angle)} 가세요.');
    }
    return out;
  }
}

/// "왼쪽으로", "약간 오른쪽으로", "뒤로 돌아"
String _go(double angle) {
  final w = turnWord(angle);
  return angle.abs() >= 160 ? w : '$w으로';
}

/// [RouteFollow]에 붙어 할 말을 음성으로 내보냄
class VoiceGuide {
  final RouteFollow route;
  final _a = VoiceAnnouncer();
  VoiceGuide(this.route) {
    route.info.addListener(_tick);
    route.route.addListener(() {
      if (route.route.value == null) Voice.instance.stop();
      _tick();
    });
  }

  void _tick() {
    for (final s in _a.update(route.route.value, route.info.value, hasTarget: route.target != null)) {
      Voice.instance.speak(s);
    }
  }
}
