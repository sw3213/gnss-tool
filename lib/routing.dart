import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'dem.dart';

// ============================================================
// 길찾기: 도로·등산로 연결망(.grt)에서 걷기 좋은 길을 찾음 (인터넷 없이 폰 안에서)
//   - 오르막은 크게, 내리막은 조금 비용을 매겨 "오르막 적은 길"을 고름
//   - 큰 차도(국도·간선도로)와 험한 등산로(암릉 등)는 멀어도 피함, 고속도로·자동차 전용도로는 아예 안 씀
// 연결망은 tool/build_routes.dart가 OpenStreetMap에서 만들어 Release "maps"에 올림 (kind = routes)
// Flutter 없이도 쓰도록 dart: 라이브러리만 씀
//
// 파일 형식 (리틀엔디언)
//   헤더 48바이트: b'GRTE', u16 버전(2), u16 0, f64 서쪽 경도, f64 남쪽 위도, f64 칸 크기(도),
//                  u32 가로 칸 수, u32 세로 칸 수, u32 전체 갈림길 수, u32 0
//   u32 칸마다 첫 갈림길 번호 (칸 수 + 1)개: 칸 c의 갈림길 = [first[c], first[c+1])
//   u64 칸마다 자료 위치 (칸 수 + 1)개: 칸 c 자료 = [off[c], off[c+1]), 비어 있으면 길이 0
//   칸 자료 (zlib 압축):
//     u32 갈림길 수 n, 연결 수 m, 모양 수 g, 모양 점 바이트 수 q
//     u16 위도[n], 경도[n] (칸 남서쪽 모서리에서 백만분의 1도 단위 차이). 칸 안에서는 Z 순서
//     u32 연결 시작[n+1]               갈림길 i의 연결 = [start[i], start[i+1])
//     i32 상대 갈림길[m] (내 번호와의 차이), u16 길이[m] (m), u16 오르막[m], u16 내리막[m] (0.1 m),
//     u8 길 종류[m] (4바이트 맞춤), u32 모양 번호[m]
//       모양 번호의 맨 윗비트가 1이면 모양이 상대 갈림길 칸에 있고 거꾸로 읽음
//     u32 모양 시작[g+1] (바이트), u8 중간 점[q]: 모양 주인 갈림길부터 위도·경도 차이를
//       지그재그 가변 길이 정수로 번갈아 (양 끝 갈림길 제외)
// ============================================================

const routeMagic = 'GRTE';
const routeCellDeg = 0.05; // 칸 크기 약 5 km
const _rev = 0x80000000;
const routeVersion = 2;

/// 길 종류 (파일에 번호로 저장, 비용 배수는 앱에서 정해 자료를 다시 만들지 않고 바꿀 수 있음)
abstract final class WayClass {
  static const path = 0, track = 1, steps = 2, minor = 3, tertiary = 4, secondary = 5, primary = 6, trunk = 7;
  static const hardTrail = 8, alpineTrail = 9;
  static const count = 10;
}

/// 걷기 비용 배수 (1 = 평지 오솔길·골목). 큰 차도는 인도가 없고 위험해서 멀어도 피함
const classFactor = [1.0, 1.0, 1.4, 1.05, 1.25, 1.5, 1.9, 2.6, 1.8, 3.5];

/// 요약에 쓰는 이름
const classLabel = ['오솔길·등산로', '임도', '계단', '골목·마을길', '작은 도로', '지방 도로', '큰 도로', '국도', '험한 등산로', '암릉·위험 구간'];

/// OpenStreetMap 태그로 걷기용 길 종류를 정함. 걸을 수 없거나 걸으면 안 되는 길은 null
int? wayClass(Map<String, dynamic> tags) {
  String? t(String k) => tags[k]?.toString();
  final hw = t('highway');
  if (hw == null || t('area') == 'yes') return null;
  final foot = t('foot'), access = t('access');
  final footOk = foot == 'yes' || foot == 'designated' || foot == 'permissive';
  if (foot == 'no' || foot == 'use_sidepath') return null;
  if ((access == 'no' || access == 'private') && !footOk) return null;
  if (t('motorroad') == 'yes' && !footOk) return null;
  final sidewalk = t('sidewalk');
  final hasSidewalk = sidewalk == 'both' || sidewalk == 'left' || sidewalk == 'right' || sidewalk == 'yes';
  int trail(int base) => switch (t('sac_scale')) {
        'demanding_mountain_hiking' => WayClass.hardTrail,
        'alpine_hiking' || 'demanding_alpine_hiking' || 'difficult_alpine_hiking' => WayClass.alpineTrail,
        _ => base,
      };
  switch (hw) {
    case 'trunk' || 'trunk_link':
      return hasSidewalk ? WayClass.secondary : WayClass.trunk;
    case 'primary' || 'primary_link':
      return hasSidewalk ? WayClass.tertiary : WayClass.primary;
    case 'secondary' || 'secondary_link':
      return hasSidewalk ? WayClass.tertiary : WayClass.secondary;
    case 'tertiary' || 'tertiary_link':
      return WayClass.tertiary;
    case 'service' when t('service') == 'parking_aisle' || t('service') == 'drive-through':
      return null; // 주차장 통로 (도시에 아주 많고 걷는 길로는 쓸모없음)
    case 'unclassified' || 'residential' || 'service' || 'living_street' || 'road':
      return WayClass.minor;
    case 'track':
      return trail(WayClass.track);
    case 'steps':
      return WayClass.steps;
    case 'footway' || 'path' || 'pedestrian' || 'bridleway' || 'cycleway':
      return trail(WayClass.path);
  }
  return null; // motorway, construction, proposed, platform, corridor, elevator, via_ferrata ...
}

double _distM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371008.8;
  final p1 = lat1 * pi / 180, p2 = lat2 * pi / 180;
  final dp = p2 - p1, dl = (lon2 - lon1) * pi / 180;
  final a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2);
  return 2 * r * asin(sqrt(min(1.0, a)));
}

const _speed = 4000 / 3600; // 평지 걷는 속도 4 km/h (m/s)
const _upCost = 6.0; // 오르막 1 m = 6초 (1시간에 600 m)
const _downCost = 1.5; // 내리막 1 m = 1.5초 (무릎·미끄럼)

/// 연결 하나를 걷는 비용 (초 단위 어림)
double edgeCost(double len, double up, double down, int cls) =>
    len / _speed * classFactor[cls] + up * _upCost + down * _downCost;

// ---------------- 파일 만들기 (tool/build_routes.dart, 시험) ----------------

class RouteGraphBuilder {
  final double west, south, east, north;
  final double? Function(double lat, double lon)? elevation;
  RouteGraphBuilder(this.west, this.south, this.east, this.north, {this.elevation});

  final _cls = <int>[];
  final _ways = <Int32List>[]; // 위도, 경도 번갈아 (백만분의 1도)
  final _uses = HashMap<int, int>(); // 점 -> 쓰인 횟수 (2 이상이면 갈림길)

  static int _key(int lat, int lon) => lat * (1 << 28) + lon;

  int get ways => _ways.length;

  /// 길 하나 추가: [coords] = [[경도, 위도], ...] (GeoJSON 순서)
  void addWay(int cls, List<List<num>> coords) {
    final pts = <int>[];
    for (final c in coords) {
      final lat = (c[1] * 1e6).round(), lon = (c[0] * 1e6).round();
      if (pts.isNotEmpty && pts[pts.length - 2] == lat && pts[pts.length - 1] == lon) continue;
      pts..add(lat)..add(lon);
    }
    if (pts.length < 4) return;
    final w = Int32List.fromList(pts);
    _ways.add(w);
    _cls.add(cls);
    final n = w.length ~/ 2;
    for (var i = 0; i < n; i++) {
      final k = _key(w[2 * i], w[2 * i + 1]);
      // 양 끝은 늘 갈림길. 고리 모양 길은 가운데도 갈림길로 (같은 갈림길로 돌아오는 연결은 못 쓰므로)
      final extra = i == 0 || i == n - 1 ? 2 : 1;
      _uses[k] = (_uses[k] ?? 0) + extra;
    }
    if (_key(w[0], w[1]) == _key(w[2 * n - 2], w[2 * n - 1]) && n > 2) {
      final m = _key(w[n ~/ 2 * 2], w[n ~/ 2 * 2 + 1]);
      _uses[m] = (_uses[m] ?? 0) + 2;
    }
  }

  (double, double) _climb(List<int> pts) {
    final elev = elevation;
    if (elev == null) return (0, 0);
    // 고도 격자(Copernicus DSM)는 도시에서 건물·다리 높이가 섞여 들쭉날쭉함 -> 4 m 넘게 바뀔 때만 셈.
    // 마지막에 남은 차이는 더해서 연결 양 끝 높이 차(순 오르막)는 그대로 맞춤
    var up = 0.0, down = 0.0;
    double? anchor, last;
    void see(double? h) {
      if (h == null) return;
      last = h;
      final a = anchor;
      if (a == null) {
        anchor = h;
      } else if (h - a >= 4) {
        up += h - a;
        anchor = h;
      } else if (a - h >= 4) {
        down += a - h;
        anchor = h;
      }
    }

    for (var i = 0; i < pts.length ~/ 2; i++) {
      final lat = pts[2 * i] / 1e6, lon = pts[2 * i + 1] / 1e6;
      if (i > 0) {
        // 고도 격자가 약 90 m라 30 m마다 잼
        final plat = pts[2 * i - 2] / 1e6, plon = pts[2 * i - 1] / 1e6;
        final steps = max(1, (_distM(plat, plon, lat, lon) / 30).ceil());
        for (var s = 1; s <= steps; s++) {
          see(elev(plat + (lat - plat) * s / steps, plon + (lon - plon) * s / steps));
        }
      } else {
        see(elev(lat, lon));
      }
    }
    final a = anchor, l = last;
    if (a != null && l != null) {
      if (l > a) up += l - a; else down += a - l;
    }
    return (up, down);
  }

  /// 2 m 안쪽으로 굽은 점은 버림 (Douglas-Peucker), 양 끝은 남김
  static List<int> _simplify(List<int> pts, double tol) {
    final n = pts.length ~/ 2;
    if (n <= 2) return pts;
    final keep = List<bool>.filled(n, false)..[0] = true..[n - 1] = true;
    final mLon = 111320 * cos(pts[0] / 1e6 * pi / 180) / 1e6, mLat = 111320 / 1e6;
    final stack = [(0, n - 1)];
    while (stack.isNotEmpty) {
      final (a, b) = stack.removeLast();
      final ax = pts[2 * a + 1] * mLon, ay = pts[2 * a] * mLat, bx = pts[2 * b + 1] * mLon, by = pts[2 * b] * mLat;
      final dx = bx - ax, dy = by - ay, l2 = dx * dx + dy * dy;
      var worst = -1.0, wi = -1;
      for (var i = a + 1; i < b; i++) {
        final px = pts[2 * i + 1] * mLon - ax, py = pts[2 * i] * mLat - ay;
        final t = l2 == 0 ? 0.0 : ((px * dx + py * dy) / l2).clamp(0.0, 1.0);
        final ex = px - dx * t, ey = py - dy * t, d = ex * ex + ey * ey;
        if (d > worst) {
          worst = d;
          wi = i;
        }
      }
      if (wi >= 0 && worst > tol * tol) {
        keep[wi] = true;
        stack..add((a, wi))..add((wi, b));
      }
    }
    return [for (var i = 0; i < n; i++) if (keep[i]) ...[pts[2 * i], pts[2 * i + 1]]];
  }

  /// 파일로 저장하고 (갈림길 수, 연결 수) 를 돌려줌
  (int, int) write(String path) {
    final w0 = (west * 1e6).round(), s0 = (south * 1e6).round(), step = (routeCellDeg * 1e6).round();
    final nx = ((east - west) / routeCellDeg).ceil(), ny = ((north - south) / routeCellDeg).ceil();
    // 칸 나누기는 정수로 (갈림길 위치를 칸 모서리에서의 차이 u16으로 정확히 저장하려고)
    int cellOf(int lat, int lon) =>
        ((lat - s0) ~/ step).clamp(0, ny - 1) * nx + ((lon - w0) ~/ step).clamp(0, nx - 1);

    // 1. 길을 갈림길마다 잘라 연결로 만듦
    final eA = <int>[], eB = <int>[], eCls = <int>[], eLen = <double>[], eUp = <double>[], eDown = <double>[];
    final eMid = <Int32List>[];
    for (var w = 0; w < _ways.length; w++) {
      final pts = _ways[w];
      final n = pts.length ~/ 2;
      var start = 0;
      for (var i = 1; i < n; i++) {
        final k = _key(pts[2 * i], pts[2 * i + 1]);
        if ((_uses[k] ?? 0) < 2) continue;
        final a = _key(pts[2 * start], pts[2 * start + 1]);
        if (a != k) {
          final seg = pts.sublist(2 * start, 2 * i + 2);
          var len = 0.0;
          for (var j = 1; j < seg.length ~/ 2; j++) {
            len += _distM(seg[2 * j - 2] / 1e6, seg[2 * j - 1] / 1e6, seg[2 * j] / 1e6, seg[2 * j + 1] / 1e6);
          }
          final (up, down) = _climb(seg);
          final simple = _simplify(seg, 2);
          eA.add(a);
          eB.add(k);
          eCls.add(_cls[w]);
          eLen.add(len);
          eUp.add(up);
          eDown.add(down);
          eMid.add(Int32List.fromList(simple.sublist(2, simple.length - 2)));
        }
        start = i;
      }
    }
    _ways.clear();
    _uses.clear();
    int latOf(int k) => k >> 28;
    int lonOf(int k) => k & ((1 << 28) - 1);

    // 2. 길이 둘만 만나는 이음매(OSM에서 길이 이름·포장 등으로 나뉜 곳)는 같은 종류면 한 연결로 합침
    final alive = List<bool>.filled(eA.length, true);
    final inc = HashMap<int, List<int>>();
    for (var e = 0; e < eA.length; e++) {
      (inc[eA[e]] ??= []).add(e);
      (inc[eB[e]] ??= []).add(e);
    }
    for (final k in inc.keys.toList()) {
      final l = inc[k]!;
      if (l.length != 2 || l[0] == l[1]) continue;
      var e1 = l[0], e2 = l[1];
      if (eCls[e1] != eCls[e2]) continue;
      // e1은 k에서 끝나게, e2는 k에서 시작하게 방향을 맞춤
      void flip(int e) {
        final a = eA[e];
        eA[e] = eB[e];
        eB[e] = a;
        final u = eUp[e];
        eUp[e] = eDown[e];
        eDown[e] = u;
        final m = eMid[e], r = Int32List(m.length);
        for (var j = 0; j < m.length ~/ 2; j++) {
          r[2 * j] = m[m.length - 2 - 2 * j];
          r[2 * j + 1] = m[m.length - 1 - 2 * j];
        }
        eMid[e] = r;
      }

      if (eB[e1] != k) flip(e1);
      if (eA[e2] != k) flip(e2);
      if (eA[e1] == eB[e2]) continue; // 합치면 제자리로 돌아오는 고리
      eMid[e1] = Int32List.fromList([...eMid[e1], latOf(k), lonOf(k), ...eMid[e2]]);
      eB[e1] = eB[e2];
      eLen[e1] += eLen[e2];
      eUp[e1] += eUp[e2];
      eDown[e1] += eDown[e2];
      alive[e2] = false;
      final other = inc[eB[e1]]!;
      other[other.indexOf(e2)] = e1;
      inc.remove(k);
    }
    final live = [for (var e = 0; e < eA.length; e++) if (alive[e]) e];

    // 3. 갈림길 번호: 칸 순서, 칸 안에서는 가까운 것끼리 (Z 순서) -> 번호 차이가 작아져 압축이 잘 됨
    final nodeKeys = <int>{for (final e in live) eA[e], for (final e in live) eB[e]}.toList();
    int z(int k) {
      final la = (latOf(k) - s0) % step, lo = (lonOf(k) - w0) % step;
      var r = 0;
      for (var b = 0; b < 16; b++) {
        r |= ((la >> b) & 1) << (2 * b + 1) | ((lo >> b) & 1) << (2 * b);
      }
      return r;
    }

    final nodeCell = HashMap<int, int>();
    final order = HashMap<int, int>();
    for (final k in nodeKeys) {
      nodeCell[k] = cellOf(latOf(k), lonOf(k));
      order[k] = z(k);
    }
    nodeKeys.sort((a, b) {
      final c = nodeCell[a]!.compareTo(nodeCell[b]!);
      return c != 0 ? c : order[a]!.compareTo(order[b]!);
    });
    final index = HashMap<int, int>();
    for (var i = 0; i < nodeKeys.length; i++) {
      index[nodeKeys[i]] = i;
    }
    final cells = nx * ny;
    final first = Uint32List(cells + 1);
    for (final k in nodeKeys) {
      first[nodeCell[k]! + 1]++;
    }
    for (var c = 0; c < cells; c++) {
      first[c + 1] += first[c];
    }

    // 4. 갈림길마다 연결 목록 (모양은 A쪽 칸에 한 번만 저장, B쪽은 거꾸로 가리킴)
    final adj = List<List<int>>.generate(nodeKeys.length, (_) => []); // 연결 번호 * 2 (+1 = 거꾸로)
    final geomIndex = Int32List(eA.length); // 연결 -> A쪽 칸 안 모양 번호
    final geomCount = Int32List(cells);
    for (final e in live) {
      final a = index[eA[e]]!, b = index[eB[e]]!;
      adj[a].add(e * 2);
      adj[b].add(e * 2 + 1);
    }
    // 모양 번호는 갈림길 순서대로 매김
    for (var i = 0; i < nodeKeys.length; i++) {
      for (final x in adj[i]) {
        if (x.isEven) geomIndex[x ~/ 2] = geomCount[nodeCell[nodeKeys[i]]!]++;
      }
    }

    // 5. 칸마다 묶어 압축
    final blocks = <Uint8List>[];
    final codec = ZLibCodec(level: 9);
    for (var c = 0; c < cells; c++) {
      final n = first[c + 1] - first[c];
      if (n == 0) {
        blocks.add(Uint8List(0));
        continue;
      }
      final cLat = s0 + (c ~/ nx) * step, cLon = w0 + (c % nx) * step;
      final nodes = [for (var i = first[c]; i < first[c + 1]; i++) i];
      final flat = [for (final i in nodes) ...adj[i]];
      final m = flat.length;
      // 모양 점: 모양 주인 갈림길에서부터 차이를 지그재그 가변 길이 정수로
      final pts = BytesBuilder(copy: false);
      final gStart = <int>[];
      void varint(int v) {
        var u = v >= 0 ? v * 2 : -v * 2 - 1;
        final out = <int>[];
        while (u >= 0x80) {
          out.add((u & 0x7f) | 0x80);
          u >>= 7;
        }
        out.add(u);
        pts.add(out);
      }

      for (final i in nodes) {
        for (final x in adj[i]) {
          if (x.isOdd) continue;
          final mid = eMid[x ~/ 2];
          gStart.add(pts.length);
          var pl = latOf(nodeKeys[i]), po = lonOf(nodeKeys[i]);
          for (var j = 0; j < mid.length; j += 2) {
            varint(mid[j] - pl);
            varint(mid[j + 1] - po);
            pl = mid[j];
            po = mid[j + 1];
          }
        }
      }
      gStart.add(pts.length);
      final g = gStart.length - 1, q = pts.length;
      int pad4(int x) => (x + 3) & ~3;
      final size = 16 + pad4(4 * n) + 4 * (n + 1) + 4 * m + 2 * m + 2 * m + 2 * m + pad4(m) + pad4(2 * m) + 4 * m +
          4 * (g + 1) + q;
      final bd = ByteData(size);
      var o = 0;
      void u32(int v) {
        bd.setUint32(o, v, Endian.little);
        o += 4;
      }

      void u16(int v) {
        bd.setUint16(o, v, Endian.little);
        o += 2;
      }

      u32(n);
      u32(m);
      u32(g);
      u32(q);
      for (final i in nodes) {
        u16(latOf(nodeKeys[i]) - cLat);
      }
      for (final i in nodes) {
        u16(lonOf(nodeKeys[i]) - cLon);
      }
      o = pad4(o);
      var s = 0;
      for (final i in nodes) {
        u32(s);
        s += adj[i].length;
      }
      u32(s);
      var self = first[c];
      for (final i in nodes) {
        for (final x in adj[i]) {
          final e = x ~/ 2;
          bd.setInt32(o, index[x.isEven ? eB[e] : eA[e]]! - self, Endian.little);
          o += 4;
        }
        self++;
      }
      for (final x in flat) {
        u16(eLen[x ~/ 2].round().clamp(0, 65535));
      }
      int dm(double v) => (v * 10).round().clamp(0, 65535);
      for (final x in flat) {
        final e = x ~/ 2;
        u16(dm(x.isEven ? eUp[e] : eDown[e]));
      }
      for (final x in flat) {
        final e = x ~/ 2;
        u16(dm(x.isEven ? eDown[e] : eUp[e]));
      }
      for (final x in flat) {
        bd.setUint8(o++, eCls[x ~/ 2]);
      }
      o = pad4(o);
      for (final x in flat) {
        u32(geomIndex[x ~/ 2] | (x.isOdd ? _rev : 0));
      }
      for (final v in gStart) {
        u32(v);
      }
      bd.buffer.asUint8List().setRange(o, o + q, pts.takeBytes());
      o += q;
      blocks.add(Uint8List.fromList(codec.encode(bd.buffer.asUint8List(0, o))));
    }

    final head = ByteData(48 + 4 * (cells + 1) + 8 * (cells + 1));
    for (var i = 0; i < 4; i++) {
      head.setUint8(i, routeMagic.codeUnitAt(i));
    }
    head.setUint16(4, routeVersion, Endian.little);
    head.setFloat64(8, w0 / 1e6, Endian.little);
    head.setFloat64(16, s0 / 1e6, Endian.little);
    head.setFloat64(24, step / 1e6, Endian.little);
    head.setUint32(32, nx, Endian.little);
    head.setUint32(36, ny, Endian.little);
    head.setUint32(40, nodeKeys.length, Endian.little);
    for (var c = 0; c <= cells; c++) {
      head.setUint32(48 + 4 * c, first[c], Endian.little);
    }
    var off = head.lengthInBytes;
    final offBase = 48 + 4 * (cells + 1);
    for (var c = 0; c <= cells; c++) {
      head.setUint64(offBase + 8 * c, off, Endian.little);
      if (c < cells) off += blocks[c].length;
    }
    final out = File(path).openSync(mode: FileMode.write);
    out.writeFromSync(head.buffer.asUint8List());
    for (final b in blocks) {
      out.writeFromSync(b);
    }
    out.closeSync();
    return (nodeKeys.length, live.length);
  }
}

// ---------------- 파일 읽기 ----------------

class _Cell {
  final int first; // 이 칸 첫 갈림길의 전체 번호
  final int lat0, lon0; // 칸 남서쪽 모서리 (백만분의 1도)
  final Uint16List dLat, dLon, len, up, down;
  final Uint32List start, geom, gStart;
  final Int32List dTo;
  final Uint8List cls, pts;
  _Cell(this.first, this.lat0, this.lon0, this.dLat, this.dLon, this.start, this.dTo, this.len, this.up, this.down,
      this.cls, this.geom, this.gStart, this.pts);

  int get count => dLat.length;
  int latE6(int i) => lat0 + dLat[i];
  int lonE6(int i) => lon0 + dLon[i];
  int to(int i, int k) => first + i + dTo[k];

  static _Cell parse(int first, int lat0, int lon0, Uint8List raw) {
    final b = raw.buffer;
    final h = ByteData.sublistView(raw, 0, 16);
    final n = h.getUint32(0, Endian.little), m = h.getUint32(4, Endian.little);
    final g = h.getUint32(8, Endian.little), q = h.getUint32(12, Endian.little);
    var o = raw.offsetInBytes + 16;
    int pad4(int x) => (x + 3) & ~3;
    T take<T>(T Function(int off) f, int bytes) {
      final r = f(o);
      o += bytes;
      return r;
    }

    final dLat = take((x) => b.asUint16List(x, n), 2 * n);
    final dLon = take((x) => b.asUint16List(x, n), pad4(4 * n) - 2 * n);
    final start = take((x) => b.asUint32List(x, n + 1), 4 * (n + 1));
    final dTo = take((x) => b.asInt32List(x, m), 4 * m);
    final len = take((x) => b.asUint16List(x, m), 2 * m);
    final up = take((x) => b.asUint16List(x, m), 2 * m);
    final down = take((x) => b.asUint16List(x, m), 2 * m);
    final cls = take((x) => b.asUint8List(x, m), 0);
    o = pad4(o + m);
    final geom = take((x) => b.asUint32List(x, m), 4 * m);
    final gStart = take((x) => b.asUint32List(x, g + 1), 4 * (g + 1));
    final pts = take((x) => b.asUint8List(x, q), q);
    return _Cell(first, lat0, lon0, dLat, dLon, start, dTo, len, up, down, cls, geom, gStart, pts);
  }
}

class RouteGraph {
  final RandomAccessFile _f;
  final double west, south, cell;
  final int nx, ny, nodes;
  final Uint32List _first;
  final List<int> _offs;
  final _cells = HashMap<int, _Cell?>();

  RouteGraph._(this._f, this.west, this.south, this.cell, this.nx, this.ny, this.nodes, this._first, this._offs);

  static RouteGraph open(String path) {
    final f = File(path).openSync();
    final h = ByteData.sublistView(f.readSync(48));
    if (h.lengthInBytes < 48 || String.fromCharCodes(h.buffer.asUint8List(h.offsetInBytes, 4)) != routeMagic) {
      f.closeSync();
      throw const FormatException('길찾기 자료 파일이 아님');
    }
    if (h.getUint16(4, Endian.little) != routeVersion) {
      f.closeSync();
      throw const RouteException('길찾기 자료가 예전 형식입니다. 오프라인 지도에서 "길찾기"를 업데이트해 주세요');
    }
    final nx = h.getUint32(32, Endian.little), ny = h.getUint32(36, Endian.little);
    final cells = nx * ny;
    final t = ByteData.sublistView(f.readSync(12 * (cells + 1)));
    final first = Uint32List(cells + 1);
    for (var c = 0; c <= cells; c++) {
      first[c] = t.getUint32(4 * c, Endian.little);
    }
    final offs = [for (var c = 0; c <= cells; c++) t.getUint64(4 * (cells + 1) + 8 * c, Endian.little)];
    return RouteGraph._(f, h.getFloat64(8, Endian.little), h.getFloat64(16, Endian.little),
        h.getFloat64(24, Endian.little), nx, ny, h.getUint32(40, Endian.little), first, offs);
  }

  void close() => _f.closeSync();

  int? cellAt(double lat, double lon) {
    final cx = ((lon - west) / cell).floor(), cy = ((lat - south) / cell).floor();
    return cx < 0 || cy < 0 || cx >= nx || cy >= ny ? null : cy * nx + cx;
  }

  _Cell? _load(int c) => _cells.putIfAbsent(c, () {
        final len = _offs[c + 1] - _offs[c];
        if (len == 0) return null;
        _f.setPositionSync(_offs[c]);
        final raw = Uint8List.fromList(zlib.decode(_f.readSync(len)));
        final step = (cell * 1e6).round();
        return _Cell.parse(_first[c], (south * 1e6).round() + (c ~/ nx) * step, (west * 1e6).round() + (c % nx) * step,
            raw);
      });

  /// 갈림길 번호 -> 칸 번호 (first에서 이분 탐색)
  int _cellOfNode(int node) {
    var lo = 0, hi = nx * ny - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_first[mid] <= node) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  _Cell _cellFor(int node) => _load(_cellOfNode(node))!;

  (double, double) nodePos(int node) {
    final c = _cellFor(node), i = node - c.first;
    return (c.latE6(i) / 1e6, c.lonE6(i) / 1e6);
  }

  /// 갈림길 [node]의 [k]번째 연결(칸 안 번호)의 모양: 출발 갈림길부터 도착 갈림길까지 점 목록
  List<(double, double)> edgeShape(int node, int k) {
    final c = _cellFor(node);
    final to = c.to(node - c.first, k), gRef = c.geom[k];
    final reversed = gRef & _rev != 0;
    final ownerNode = reversed ? to : node;
    final owner = reversed ? _cellFor(to) : c;
    final gi = gRef & ~_rev;
    final oi = ownerNode - owner.first;
    var lat = owner.latE6(oi), lon = owner.lonE6(oi);
    final mid = <(double, double)>[];
    var j = owner.gStart[gi];
    final end = owner.gStart[gi + 1];
    int read() {
      var u = 0, shift = 0;
      while (true) {
        final b = owner.pts[j++];
        u |= (b & 0x7f) << shift;
        if (b < 0x80) break;
        shift += 7;
      }
      return u.isEven ? u >> 1 : -((u + 1) >> 1);
    }

    while (j < end) {
      lat += read();
      lon += read();
      mid.add((lat / 1e6, lon / 1e6));
    }
    return [nodePos(node), ...(reversed ? mid.reversed : mid), nodePos(to)];
  }
}

// ---------------- 길 찾기 (A*) ----------------

class RouteException implements Exception {
  final String message;
  const RouteException(this.message);
  @override
  String toString() => message;
}

class FoundRoute {
  final List<(double, double, double?)> pts; // 위도, 경도, 고도 (고도 격자가 있으면)
  final double length, up, down; // m
  final List<double> byClass; // 길 종류별 거리 (m)
  final double startGap, endGap; // 출발·도착점에서 가장 가까운 길까지 (m)
  final int searched; // 살펴본 갈림길 수
  const FoundRoute(this.pts, this.length, this.up, this.down, this.byClass, this.startGap, this.endGap, this.searched);

  /// "큰 도로 1.2 km" 처럼 피하고 싶은 길이 섞였는지 (100 m 이상만)
  List<String> get warnings => [
        for (final c in [WayClass.trunk, WayClass.primary, WayClass.alpineTrail, WayClass.hardTrail])
          if (byClass[c] >= 100) '${classLabel[c]} ${byClass[c] < 1000 ? '${byClass[c].round()} m' : '${(byClass[c] / 1000).toStringAsFixed(1)} km'}'
      ];
}

/// 가장 가까운 길 위의 점
class _Snap {
  final int node, k; // 모양을 가진 쪽 갈림길과 그 연결
  final int other;
  final List<(double, double)> shape;
  final int seg; // 점이 놓인 구간 (shape[seg] ~ shape[seg+1])
  final (double, double) at;
  final double frac, gap; // 연결 처음부터 비율, 길까지 거리
  final double len, up, down;
  final int cls;
  _Snap(this.node, this.k, this.other, this.shape, this.seg, this.at, this.frac, this.gap, this.len, this.up, this.down,
      this.cls);

  /// node 쪽으로 가는 부분 모양 (이 점 -> node)
  List<(double, double)> get toNode => [at, ...shape.sublist(0, seg + 1).reversed];

  /// other 쪽으로 가는 부분 모양 (이 점 -> other)
  List<(double, double)> get toOther => [at, ...shape.sublist(seg + 1)];
}

_Snap? _snap(RouteGraph g, double lat, double lon, double maxGap) {
  final c0 = g.cellAt(lat, lon);
  if (c0 == null) return null;
  final mLat = 111320.0, mLon = 111320.0 * cos(lat * pi / 180);
  var best = maxGap;
  _Snap? out;
  final cx0 = c0 % g.nx, cy0 = c0 ~/ g.nx;
  for (var dy = -1; dy <= 1; dy++) {
    for (var dx = -1; dx <= 1; dx++) {
      final cx = cx0 + dx, cy = cy0 + dy;
      if (cx < 0 || cy < 0 || cx >= g.nx || cy >= g.ny) continue;
      final cell = g._load(cy * g.nx + cx);
      if (cell == null) continue;
      for (var i = 0; i < cell.count; i++) {
        for (var k = cell.start[i]; k < cell.start[i + 1]; k++) {
          if (cell.geom[k] & _rev != 0) continue; // 연결마다 한 번만 (모양을 가진 쪽에서)
          final node = cell.first + i;
          final shape = g.edgeShape(node, k);
          // 빠른 거르기: 연결 전체가 지금 최선보다 멀면 건너뜀
          var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
          for (final p in shape) {
            minLat = min(minLat, p.$1);
            maxLat = max(maxLat, p.$1);
            minLon = min(minLon, p.$2);
            maxLon = max(maxLon, p.$2);
          }
          final ex = max(0.0, max(minLon - lon, lon - maxLon)) * mLon, ey = max(0.0, max(minLat - lat, lat - maxLat)) * mLat;
          if (ex > best || ey > best) continue;
          var along = 0.0, total = 0.0;
          final segLen = <double>[];
          for (var j = 0; j + 1 < shape.length; j++) {
            final l = _distM(shape[j].$1, shape[j].$2, shape[j + 1].$1, shape[j + 1].$2);
            segLen.add(l);
            total += l;
          }
          for (var j = 0; j + 1 < shape.length; j++) {
            final ax = (shape[j].$2 - lon) * mLon, ay = (shape[j].$1 - lat) * mLat;
            final bx = (shape[j + 1].$2 - lon) * mLon, by = (shape[j + 1].$1 - lat) * mLat;
            final l2 = (bx - ax) * (bx - ax) + (by - ay) * (by - ay);
            final t = l2 == 0 ? 0.0 : ((-ax * (bx - ax) - ay * (by - ay)) / l2).clamp(0.0, 1.0);
            final px = ax + (bx - ax) * t, py = ay + (by - ay) * t;
            final d = sqrt(px * px + py * py);
            if (d < best) {
              best = d;
              final at = (shape[j].$1 + (shape[j + 1].$1 - shape[j].$1) * t, shape[j].$2 + (shape[j + 1].$2 - shape[j].$2) * t);
              out = _Snap(node, k, cell.to(i, k), shape, j, at, total == 0 ? 0 : (along + segLen[j] * t) / total, d,
                  cell.len[k].toDouble(), cell.up[k] / 10, cell.down[k] / 10, cell.cls[k]);
            }
            along += segLen[j];
          }
        }
      }
    }
  }
  return out;
}

/// 작은 최소 힙 (비용, 갈림길)
class _Heap {
  final _key = <double>[];
  final _val = <int>[];
  bool get isEmpty => _key.isEmpty;

  void push(double k, int v) {
    _key.add(k);
    _val.add(v);
    var i = _key.length - 1;
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (_key[p] <= k) break;
      _key[i] = _key[p];
      _val[i] = _val[p];
      i = p;
    }
    _key[i] = k;
    _val[i] = v;
  }

  int pop() {
    final top = _val[0];
    final k = _key.removeLast(), v = _val.removeLast();
    if (_key.isNotEmpty) {
      var i = 0;
      final n = _key.length;
      while (true) {
        var c = 2 * i + 1;
        if (c >= n) break;
        if (c + 1 < n && _key[c + 1] < _key[c]) c++;
        if (_key[c] >= k) break;
        _key[i] = _key[c];
        _val[i] = _val[c];
        i = c;
      }
      _key[i] = k;
      _val[i] = v;
    }
    return top;
  }
}

/// 출발(-1)·도착(-2)은 길 위에 새로 놓는 가상 갈림길
const _from = -1, _goal = -2;

/// 가상 연결: 길 하나의 일부 (모양, 길이, 오르막, 내리막, 종류)
typedef _Part = (List<(double, double)>, double, double, double, int);

/// [lat1],[lon1]에서 [lat2],[lon2]까지 걷기 좋은 길. 근처에 길이 없거나 이어지지 않으면 RouteException
FoundRoute findRoute(RouteGraph g, double lat1, double lon1, double lat2, double lon2,
    {DemFile? dem, double maxGap = 1000, int maxSearch = 1500000}) {
  final s = _snap(g, lat1, lon1, maxGap);
  if (s == null) throw RouteException('지금 위치 ${maxGap.round()} m 안에 길이 없습니다');
  final t = _snap(g, lat2, lon2, maxGap);
  if (t == null) throw RouteException('목적지 ${maxGap.round()} m 안에 길이 없습니다');

  // 가상 연결: 출발점 -> 양쪽 갈림길, 양쪽 갈림길 -> 도착점, 같은 길 위면 출발 -> 도착 바로
  _Part part(_Snap x, bool towardNode, {bool reverse = false}) {
    final f = towardNode ? x.frac : 1 - x.frac;
    // 연결 방향(node -> other) 기준 오르막·내리막을 비율만큼 나눔
    final up = (towardNode ? x.down : x.up) * f, down = (towardNode ? x.up : x.down) * f;
    final shape = towardNode ? x.toNode : x.toOther;
    return reverse
        ? (shape.reversed.toList(), x.len * f, down, up, x.cls)
        : (shape, x.len * f, up, down, x.cls);
  }

  final fromEdges = <int, _Part>{s.node: part(s, true), s.other: part(s, false)};
  final toGoal = <int, _Part>{t.node: part(t, true, reverse: true), t.other: part(t, false, reverse: true)};
  _Part? direct;
  if (s.node == t.node && s.k == t.k) {
    final a = s.frac, b = t.frac;
    final f = (b - a).abs();
    final forward = b >= a;
    final i0 = min(s.seg, t.seg), i1 = max(s.seg, t.seg);
    final lo = forward ? s : t, hi = forward ? t : s;
    final shape = [lo.at, ...s.shape.sublist(i0 + 1, i1 + 1), hi.at];
    direct = forward
        ? (shape, s.len * f, s.up * f, s.down * f, s.cls)
        : (shape.reversed.toList(), s.len * f, s.down * f, s.up * f, s.cls);
  }

  final mLat = 111320.0, mLon = 111320.0 * cos(lat2 * pi / 180);
  double h(double lat, double lon) {
    final dx = (lon - t.at.$2) * mLon, dy = (lat - t.at.$1) * mLat;
    return sqrt(dx * dx + dy * dy) / _speed;
  }

  final cost = HashMap<int, double>()..[_from] = 0;
  final prev = HashMap<int, int>(); // 갈림길 -> 이전 갈림길
  final via = HashMap<int, int>(); // 갈림길 -> 이전 갈림길의 연결 번호 (가상 연결이면 -1)
  final done = HashSet<int>();
  final heap = _Heap()..push(h(s.at.$1, s.at.$2), _from);

  void relax(int u, int v, double c, int edge, double vLat, double vLon) {
    final nc = cost[u]! + c;
    final old = cost[v];
    if (old != null && old <= nc) return;
    cost[v] = nc;
    prev[v] = u;
    via[v] = edge;
    heap.push(nc + (v == _goal ? 0 : h(vLat, vLon)), v);
  }

  var found = false;
  while (!heap.isEmpty) {
    final u = heap.pop();
    if (!done.add(u)) continue;
    if (u == _goal) {
      found = true;
      break;
    }
    if (done.length > maxSearch) throw const RouteException('너무 멀어서 길을 찾지 못했습니다');
    if (u == _from) {
      for (final e in fromEdges.entries) {
        final p = e.value;
        final (la, lo) = g.nodePos(e.key);
        relax(u, e.key, edgeCost(p.$2, p.$3, p.$4, p.$5), -1, la, lo);
      }
      if (direct != null) relax(u, _goal, edgeCost(direct.$2, direct.$3, direct.$4, direct.$5), -1, 0, 0);
      continue;
    }
    final c = g._cellFor(u), i = u - c.first;
    for (var k = c.start[i]; k < c.start[i + 1]; k++) {
      final v = c.to(i, k);
      if (done.contains(v)) continue;
      final (la, lo) = g.nodePos(v);
      relax(u, v, edgeCost(c.len[k].toDouble(), c.up[k] / 10, c.down[k] / 10, c.cls[k]), k, la, lo);
    }
    final p = toGoal[u];
    if (p != null) relax(u, _goal, edgeCost(p.$2, p.$3, p.$4, p.$5), -1, 0, 0);
  }
  if (!found) throw const RouteException('길이 이어져 있지 않습니다 (섬·막힌 길)');

  // 거꾸로 따라가며 모양을 이어 붙임
  final chain = <int>[_goal];
  while (chain.last != _from) {
    chain.add(prev[chain.last]!);
  }
  final order = chain.reversed.toList();
  final pts = <(double, double)>[];
  var length = 0.0, up = 0.0, down = 0.0;
  final byClass = List<double>.filled(WayClass.count, 0);
  void add(List<(double, double)> shape, double len, double u2, double d2, int cls) {
    pts.addAll(pts.isEmpty ? shape : shape.skip(1));
    length += len;
    up += u2;
    down += d2;
    byClass[cls] += len;
  }

  for (var j = 1; j < order.length; j++) {
    final a = order[j - 1], b = order[j];
    final _Part p;
    if (a == _from && b == _goal) {
      p = direct!;
    } else if (a == _from) {
      p = fromEdges[b]!;
    } else if (b == _goal) {
      p = toGoal[a]!;
    } else {
      final c = g._cellFor(a), k = via[b]!;
      p = (g.edgeShape(a, k), c.len[k].toDouble(), c.up[k] / 10, c.down[k] / 10, c.cls[k]);
    }
    add(p.$1, p.$2, p.$3, p.$4, p.$5);
  }
  return FoundRoute([for (final (la, lo) in pts) (la, lo, dem?.elevation(la, lo))], length, up, down, byClass, s.gap,
      t.gap, done.length);
}

/// 별도 스레드에서 파일을 열어 길을 찾음 (화면이 멈추지 않게)
Future<FoundRoute> findRouteInBackground(String graphPath, String? demPath, double lat1, double lon1, double lat2,
        double lon2) =>
    Isolate.run(() {
      final g = RouteGraph.open(graphPath);
      DemFile? dem;
      try {
        if (demPath != null) dem = DemFile.open(demPath);
      } catch (_) {}
      try {
        return findRoute(g, lat1, lon1, lat2, lon2, dem: dem);
      } finally {
        g.close();
        dem?.close();
      }
    });
