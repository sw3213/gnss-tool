import 'dart:math';

import 'main.dart' show Sat;

// ============================================================
// 위성 배치로 DOP 직접 계산 (수신기가 보고한 값 검증용)
// ============================================================

typedef Dop = ({double hdop, double vdop, double pdop});

/// 측위에 사용된 위성의 방위·고도각으로 DOP 계산.
/// 다중 GNSS는 시스템마다 시계 오차가 따로 있으므로 시스템 수만큼 시계 열을 둔다.
Dop? dopFromSats(List<Sat> sats) {
  final used = sats.where((s) => s.used && s.elev != null && s.az != null).toList();
  final systems = {for (final s in used) s.sys}.toList();
  final n = 3 + systems.length;
  if (used.length < n + 1) return null;

  // 정규 행렬 GᵀG, 행 = [-e, -n, -u, (해당 시스템 열에 1)]
  final m = List.generate(n, (_) => List<double>.filled(n, 0));
  for (final s in used) {
    final el = s.elev! * pi / 180, az = s.az! * pi / 180;
    final row = List<double>.filled(n, 0)
      ..[0] = -cos(el) * sin(az)
      ..[1] = -cos(el) * cos(az)
      ..[2] = -sin(el)
      ..[3 + systems.indexOf(s.sys)] = 1;
    for (int i = 0; i < n; i++) {
      for (int j = 0; j < n; j++) {
        m[i][j] += row[i] * row[j];
      }
    }
  }
  final q = _invert(m);
  if (q == null) return null;
  return (
    hdop: sqrt(q[0][0] + q[1][1]),
    vdop: sqrt(q[2][2]),
    pdop: sqrt(q[0][0] + q[1][1] + q[2][2]),
  );
}

// 가우스-조던 역행렬 (n ≤ 9라 단순 구현으로 충분)
List<List<double>>? _invert(List<List<double>> a) {
  final n = a.length;
  final m = [
    for (int i = 0; i < n; i++) [...a[i], for (int j = 0; j < n; j++) i == j ? 1.0 : 0.0]
  ];
  for (int c = 0; c < n; c++) {
    var p = c;
    for (int r = c + 1; r < n; r++) {
      if (m[r][c].abs() > m[p][c].abs()) p = r;
    }
    if (m[p][c].abs() < 1e-12) return null; // 배치가 나빠 계산 불가
    final tmp = m[c];
    m[c] = m[p];
    m[p] = tmp;
    final d = m[c][c];
    for (int j = 0; j < 2 * n; j++) {
      m[c][j] /= d;
    }
    for (int r = 0; r < n; r++) {
      if (r == c) continue;
      final f = m[r][c];
      if (f == 0) continue;
      for (int j = 0; j < 2 * n; j++) {
        m[r][j] -= f * m[c][j];
      }
    }
  }
  return [for (final row in m) row.sublist(n)];
}
