import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'main.dart' show GnssSnapshot, SensorSample;
import 'nav.dart';
import 'terrain.dart' show TerrainSun;
import 'weather.dart';

// ============================================================
// 규칙 기반 조언: 지금 상황(날씨·기온·습도·해·남은 거리·배터리)에서 위험한 것을 짧게 알려 줌.
// 온도·습도 규칙은 외부 장치(AHT20)가 연결됐을 때만 동작 (폰에는 온·습도 센서가 없음)
// ============================================================

enum AdviceLevel { info, warn, danger }

class Advice {
  final AdviceLevel level;
  final String title, detail;
  const Advice(this.level, this.title, this.detail);
}

class Battery {
  final double? percent, tempC;
  final bool charging;
  const Battery(this.percent, this.tempC, this.charging);
}

class AdviceInput {
  final DateTime now;
  final double? temp, humidity; // 최신 기온 (°C), 습도 (%)
  final double? humidity10m; // 10분 전 습도 (급상승 판단)
  final StormStatus? weather;
  final TerrainSun? sun; // 오늘 해 (산 능선 기준)
  final Duration? walkLeft; // 목표·경로 끝까지 걷는 시간
  final Battery? battery;
  final double? hAcc;
  const AdviceInput({
    required this.now,
    this.temp,
    this.humidity,
    this.humidity10m,
    this.weather,
    this.sun,
    this.walkLeft,
    this.battery,
    this.hAcc,
  });
}

/// 체감 더위 (열지수, °C). 미국 기상청(NWS) Rothfusz 식, 27°C·습도 40% 미만이면 기온 그대로
double heatIndex(double tC, double rh) {
  if (tC < 27 || rh < 40) return tC;
  final t = tC * 9 / 5 + 32;
  final hi = -42.379 +
      2.04901523 * t +
      10.14333127 * rh -
      0.22475541 * t * rh -
      6.83783e-3 * t * t -
      5.481717e-2 * rh * rh +
      1.22874e-3 * t * t * rh +
      8.5282e-4 * t * rh * rh -
      1.99e-6 * t * t * rh * rh;
  return (hi - 32) * 5 / 9;
}

/// 위험한 것부터 정렬한 조언 목록 (없으면 빈 목록)
List<Advice> advise(AdviceInput a) {
  final out = <Advice>[];
  final t = a.temp, rh = a.humidity;

  // 더위: 열지수 41°C 이상 열사병 위험, 32°C 이상 주의
  if (t != null && rh != null) {
    final hi = heatIndex(t, rh);
    if (hi >= 41) {
      out.add(Advice(AdviceLevel.danger, '열사병 위험 (체감 ${hi.round()}°C)',
          '그늘에서 쉬고 물·염분을 보충하세요. 어지럽거나 땀이 멈추면 즉시 휴식·하산'));
    } else if (hi >= 32) {
      out.add(Advice(AdviceLevel.warn, '더위 주의 (체감 ${hi.round()}°C)', '30분마다 쉬면서 물을 조금씩 자주 마시세요'));
    }
  }
  // 추위: 영하 결빙, 5°C 이하 + 습함 = 젖으면 저체온
  if (t != null) {
    if (t <= 0) {
      out.add(Advice(AdviceLevel.danger, '영하 ${t.toStringAsFixed(0)}°C — 결빙·저체온 주의',
          '바위·나무 계단이 얼 수 있습니다. 젖은 옷은 바로 갈아입고 보온하세요'));
    } else if (t <= 5 && (rh ?? 0) >= 85) {
      out.add(const Advice(AdviceLevel.warn, '춥고 습함 — 저체온 주의', '몸이 젖으면 체온이 빨리 떨어집니다. 방수·보온 겉옷을 입으세요'));
    }
  }
  // 습도 급상승 + 기압 하강 = 소나기 직전 -> 계곡 물이 갑자기 불어날 수 있음
  final w = a.weather;
  final falling = w != null && ((w.rate3h ?? 0) <= -1 || (w.drop5m ?? 0) >= 0.5);
  if (rh != null && a.humidity10m != null && rh - a.humidity10m! >= 15) {
    out.add(Advice(falling ? AdviceLevel.danger : AdviceLevel.warn, '습도 급상승 (+${(rh - a.humidity10m!).round()}%, 10분)',
        falling ? '기압도 떨어지는 중: 소나기·계곡 물 불어남 위험. 계곡·하천 바닥에서 벗어나세요' : '비가 올 수 있습니다. 계곡 근처라면 높은 곳을 확인해 두세요'));
  }
  // 기압 경보 (weather.dart가 판단)
  if (w != null && w.level != StormLevel.none) {
    out.add(Advice(w.level == StormLevel.storm ? AdviceLevel.danger : AdviceLevel.warn,
        w.level == StormLevel.storm ? '폭풍 경보' : '날씨 악화 조짐', '${w.text}. 능선·정상 같은 높은 곳과 계곡 바닥을 피하세요'));
  }
  // 해: 남은 걷는 시간이 일몰까지보다 길면 위험
  final sun = a.sun;
  if (sun?.set != null && sun?.rise != null) {
    final toSet = sun!.set!.difference(a.now);
    final night = a.now.isAfter(sun.set!) || a.now.isBefore(sun.rise!);
    if (night) {
      out.add(const Advice(AdviceLevel.info, '야간', '헤드랜턴을 켜고 이동을 줄이세요. 길을 잃기 쉬우니 경로를 자주 확인하세요'));
    } else if (a.walkLeft != null && a.walkLeft! > toSet) {
      out.add(Advice(AdviceLevel.danger, '일몰 전에 도착 못 함',
          '남은 걸음 약 ${durationLabel(a.walkLeft!)}, 해 지기까지 ${durationLabel(toSet)}. 헤드랜턴 준비, 가까운 하산로를 고려하세요'));
    } else if (toSet.inMinutes <= 60) {
      out.add(Advice(AdviceLevel.warn, '일몰 ${toSet.inMinutes}분 전', '산그늘은 더 빨리 어두워집니다. 하산을 서두르세요'));
    }
  }
  // 폰 배터리·과열
  final b = a.battery;
  if (b != null && !b.charging && b.percent != null) {
    if (b.percent! <= 10) {
      out.add(Advice(AdviceLevel.danger, '배터리 ${b.percent!.round()}%',
          '곧 꺼집니다. 지금 위치를 지점으로 저장하고, 화면을 끄고 비행기 모드로 아끼세요'));
    } else if (b.percent! <= 20) {
      out.add(Advice(AdviceLevel.warn, '배터리 ${b.percent!.round()}%', '화면 밝기를 낮추고 필요할 때만 지도를 보세요'));
    }
  }
  if (b?.tempC != null && b!.tempC! >= 45) {
    out.add(Advice(AdviceLevel.warn, '폰 과열 (${b.tempC!.round()}°C)', '직사광선을 피해 그늘이나 가방 속에 두세요. 과열되면 GPS가 꺼질 수 있습니다'));
  }
  // GPS 오차
  if ((a.hAcc ?? 0) > 30) {
    out.add(Advice(AdviceLevel.info, 'GPS 오차 ±${a.hAcc!.round()} m', '하늘이 트인 곳으로 나가면 정확해집니다 (골짜기·숲속은 오차가 큼)'));
  }
  out.sort((x, y) => y.level.index.compareTo(x.level.index));
  return out;
}

/// 15초마다 조언을 다시 계산. 배터리는 1분마다 폰에 물어봄
class AdviceWatch {
  final ValueListenable<List<SensorSample>> sensors;
  final ValueListenable<StormStatus> weather;
  final ValueListenable<GnssSnapshot> snap;
  final ValueListenable<TerrainSun?> sun;
  final Duration? Function() walkLeft;
  AdviceWatch({required this.sensors, required this.weather, required this.snap, required this.sun, required this.walkLeft});

  final advice = ValueNotifier<List<Advice>>([]);
  final _hist = <(DateTime, double)>[]; // 습도 기록 (최근 15분, 1분 간격)
  Battery? _battery;
  Timer? _timer;
  int _ticks = 0;

  void start() {
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _tick());
    _tick();
  }

  void dispose() => _timer?.cancel();

  Future<void> _tick() async {
    if (_ticks++ % 4 == 0) {
      try {
        final m = await const MethodChannel('gnss_tool/diag').invokeMapMethod<String, dynamic>('battery');
        if (m != null) {
          _battery = Battery((m['percent'] as num?)?.toDouble(), (m['tempC'] as num?)?.toDouble(), m['charging'] == true);
        }
      } catch (_) {}
    }
    final now = DateTime.now();
    final last = sensors.value.isEmpty ? null : sensors.value.last;
    final rh = last?.humidity;
    if (rh != null && (_hist.isEmpty || now.difference(_hist.last.$1).inSeconds >= 60)) _hist.add((now, rh));
    _hist.removeWhere((h) => now.difference(h.$1).inMinutes > 15);
    final ago = _hist.where((h) => now.difference(h.$1).inMinutes >= 9).toList();
    advice.value = advise(AdviceInput(
      now: now,
      temp: last?.temp,
      humidity: rh,
      humidity10m: ago.isEmpty ? null : ago.map((h) => h.$2).reduce(min),
      weather: weather.value,
      sun: sun.value,
      walkLeft: walkLeft(),
      battery: _battery,
      hAcc: snap.value.hAcc,
    ));
  }
}
