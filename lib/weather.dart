import 'dart:math';

// ============================================================
// 기압 고도 보정 + 해면기압 + 폭풍 경보
// ============================================================

// 표준대기 근사. p: 현지기압, qnh: 해면기압 (hPa), h: 해발고도 (m)
double qnhFrom(double p, double h) => p / pow(1 - h / 44330, 5.255).toDouble();
double altFrom(double p, double qnh) => 44330 * (1 - pow(p / qnh, 1 / 5.255).toDouble());

/// 기압계(짧은 시간의 상대 고도 변화는 정밀) + GNSS(절대 고도는 맞지만 ±10 m 잡음)를 섞는 상보 필터.
///
/// 매 초: 기압 변화만큼 고도를 옮기고(해면기압 일정 가정) GNSS 고도 쪽으로 조금씩 당긴다.
/// - 등산/하산: 기압이 바로 따라가므로 해면기압은 거의 안 변함
/// - 날씨 변화: 처음엔 고도 변화로 오인되지만 GNSS가 [tau]초에 걸쳐 되돌려 해면기압 변화로 드러남
///   (3 hPa/3h 하강이면 지연 오차는 0.03 hPa 수준)
class BaroAltFilter {
  static const tau = 120; // 초

  double? _alt, _lastP;
  double? qnh; // 추정 해면기압 (hPa)
  int _n = 0;

  double? get alt => _alt; // 보정된 고도 (m)

  void reset() {
    _alt = _lastP = qnh = null;
    _n = 0;
  }

  /// 1초마다 호출. [gnssAlt]는 측위 중일 때만 (해발고도, m)
  void update(double p, double? gnssAlt) {
    final a = _alt, lp = _lastP, q = qnh;
    _lastP = p;
    if (a == null || lp == null || q == null) {
      if (gnssAlt == null) return; // 첫 GNSS 고도가 올 때까지 대기
      _alt = gnssAlt;
      _n = 1;
      qnh = qnhFrom(p, gnssAlt);
      return;
    }
    var h = a + altFrom(p, q) - altFrom(lp, q);
    if (gnssAlt != null) {
      _n++;
      // 처음엔 GNSS 평균(1/n), 수렴 후엔 시간 상수 tau
      h += max(1 / _n, 1 / tau) * (gnssAlt - h);
    }
    _alt = h;
    qnh = qnhFrom(p, h);
  }
}

enum StormLevel { none, warning, storm }

class StormStatus {
  final double? qnh;
  final double? rate3h; // 해면기압 변화율 (hPa / 3시간), null = 데이터 부족
  final double spanMin; // 추세 계산에 쓴 데이터 기간 (분)
  final double? drop5m; // 최근 5분 하강폭 (hPa)
  final StormLevel level;
  final String text;
  final List<(DateTime, double)> history; // 1분 평균 해면기압, 최근 3시간
  const StormStatus({
    this.qnh,
    this.rate3h,
    this.spanMin = 0,
    this.drop5m,
    this.level = StormLevel.none,
    this.text = '해면기압 계산 대기 중 (기압 센서 + GPS 측위 필요)',
    this.history = const [],
  });
}

/// 해면기압 추세로 날씨 악화 판단.
/// - 3시간 변화율: 영국 기상청 기압 경향 구분 (빠르게 하강 3.6 hPa 이상 -> 경고, 6 이상 -> 폭풍)
/// - 급하강: 5분 안에 3.0 hPa 이상 하강 (스콜·돌풍 전선 등)
class StormWatch {
  static const minSpanMin = 30; // 이보다 짧은 데이터로는 3시간 추세를 말하지 않음
  static const rapidDrop = 3.0; // hPa / 5분
  static const warnRate = -3.6; // hPa / 3h
  static const stormRate = -6.0;

  final List<(DateTime, double)> _minutes = []; // 1분 평균
  final List<(DateTime, double)> _seconds = []; // 최근 5분 원본
  DateTime? _bucket;
  double _sum = 0;
  int _cnt = 0;

  void clear() {
    _minutes.clear();
    _seconds.clear();
    _bucket = null;
    _sum = 0;
    _cnt = 0;
  }

  StormStatus add(DateTime t, double qnh) {
    final minute = DateTime(t.year, t.month, t.day, t.hour, t.minute);
    if (_bucket != null && minute != _bucket) {
      _minutes.add((_bucket!, _sum / _cnt));
      _sum = 0;
      _cnt = 0;
    }
    _bucket = minute;
    _sum += qnh;
    _cnt++;
    _minutes.removeWhere((e) => t.difference(e.$1).inMinutes > 180);

    _seconds.add((t, qnh));
    _seconds.removeWhere((e) => t.difference(e.$1).inSeconds > 300);

    return _status(t, qnh);
  }

  StormStatus _status(DateTime now, double qnh) {
    // 급하강: 5분 전 30초 평균 vs 최근 30초 평균 (1초 잡음 제거)
    double? drop5m;
    if (_seconds.isNotEmpty && now.difference(_seconds.first.$1).inSeconds >= 270) {
      double avg(Iterable<(DateTime, double)> xs) => xs.map((e) => e.$2).reduce((a, b) => a + b) / xs.length;
      final old = _seconds.where((e) => e.$1.difference(_seconds.first.$1).inSeconds < 30);
      final cur = _seconds.where((e) => now.difference(e.$1).inSeconds < 30);
      drop5m = avg(old) - avg(cur);
    }

    final span = _minutes.isEmpty ? 0.0 : now.difference(_minutes.first.$1).inSeconds / 60;
    final rate = span >= minSpanMin && _minutes.length >= 10 ? _slopePerMin() * 180 : null;

    var level = StormLevel.none;
    if ((drop5m ?? 0) >= rapidDrop || (rate != null && rate <= stormRate)) {
      level = StormLevel.storm;
    } else if (rate != null && rate <= warnRate) {
      level = StormLevel.warning;
    }

    final String text;
    if ((drop5m ?? 0) >= rapidDrop) {
      text = '⚠ 기압 급하강: 5분간 -${drop5m!.toStringAsFixed(1)} hPa. 돌풍·뇌우 가능';
    } else if (rate == null) {
      text = '추세 계산용 데이터 수집 중 (${span.floor()}/$minSpanMin분)';
    } else {
      text = '${_tendency(rate)}  ${rate >= 0 ? '+' : ''}${rate.toStringAsFixed(1)} hPa/3h';
    }

    return StormStatus(
      qnh: qnh,
      rate3h: rate,
      spanMin: span,
      drop5m: drop5m,
      level: level,
      text: text,
      history: List.of(_minutes),
    );
  }

  // 최소제곱 기울기 (hPa / 분). 앱이 꺼져 있던 공백도 실제 시각 기준으로 처리됨
  double _slopePerMin() {
    final t0 = _minutes.first.$1;
    final xs = [for (final e in _minutes) e.$1.difference(t0).inSeconds / 60.0];
    final ys = [for (final e in _minutes) e.$2];
    final mx = xs.reduce((a, b) => a + b) / xs.length;
    final my = ys.reduce((a, b) => a + b) / ys.length;
    double sxy = 0, sxx = 0;
    for (int i = 0; i < xs.length; i++) {
      sxy += (xs[i] - mx) * (ys[i] - my);
      sxx += (xs[i] - mx) * (xs[i] - mx);
    }
    return sxx == 0 ? 0 : sxy / sxx;
  }

  static String _tendency(double r) {
    final a = r.abs();
    if (a < 0.1) return '→ 안정';
    final dir = r < 0 ? '하강' : '상승';
    final arrow = r < 0 ? '↓' : '↑';
    if (a <= 1.5) return '$arrow 약간 $dir';
    if (a <= 3.5) return '$arrow $dir';
    if (a <= 6.0) return '$arrow 빠르게 $dir';
    return '$arrow 매우 빠르게 $dir';
  }
}
