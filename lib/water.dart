import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'nav.dart';

// ============================================================
// 가장 가까운 수원지: 내려받은 지도(.pmtiles)를 직접 읽어 계곡·하천·샘·호수·식수대를 찾음 (바다 제외)
// PMTiles v3 + Mapbox Vector Tile을 필요한 만큼만 해석하는 작은 리더
// ============================================================

int _varint(Uint8List b, List<int> pos) {
  var r = 0, shift = 0;
  while (true) {
    final x = b[pos[0]++];
    r |= (x & 0x7f) << shift;
    if (x < 0x80) return r;
    shift += 7;
  }
}

class _Entry {
  final int tileId, offset, length, runLength;
  const _Entry(this.tileId, this.offset, this.length, this.runLength);
}

class PmTiles {
  final RandomAccessFile _f;
  final int _rootOff, _rootLen, _leafOff, _dataOff;
  final int _internalComp, _tileComp;
  final List<_Entry> _root;
  final _leafCache = <int, List<_Entry>>{};

  PmTiles._(this._f, this._rootOff, this._rootLen, this._leafOff, this._dataOff, this._internalComp, this._tileComp)
      : _root = [] {
    _root.addAll(_readDir(_rootOff, _rootLen));
  }

  static PmTiles open(String path) {
    final f = File(path).openSync();
    final h = ByteData.sublistView(f.readSync(127));
    if (String.fromCharCodes(h.buffer.asUint8List(h.offsetInBytes, 7)) != 'PMTiles' || h.getUint8(7) != 3) {
      f.closeSync();
      throw const FormatException('PMTiles v3 파일이 아님');
    }
    int u64(int o) => h.getUint64(o, Endian.little);
    return PmTiles._(f, u64(8), u64(16), u64(40), u64(56), h.getUint8(97), h.getUint8(98));
  }

  void close() => _f.closeSync();

  Uint8List _read(int off, int len) {
    _f.setPositionSync(off);
    return _f.readSync(len);
  }

  static Uint8List _decompress(Uint8List b, int comp) =>
      comp == 2 ? Uint8List.fromList(gzip.decode(b)) : b; // 1 = 압축 없음, 2 = gzip

  List<_Entry> _readDir(int off, int len) {
    final b = _decompress(_read(off, len), _internalComp);
    final p = [0];
    final n = _varint(b, p);
    final ids = List<int>.filled(n, 0), runs = List<int>.filled(n, 0), lens = List<int>.filled(n, 0);
    final offs = List<int>.filled(n, 0);
    var last = 0;
    for (var i = 0; i < n; i++) {
      last += _varint(b, p);
      ids[i] = last;
    }
    for (var i = 0; i < n; i++) {
      runs[i] = _varint(b, p);
    }
    for (var i = 0; i < n; i++) {
      lens[i] = _varint(b, p);
    }
    for (var i = 0; i < n; i++) {
      final v = _varint(b, p);
      offs[i] = v == 0 && i > 0 ? offs[i - 1] + lens[i - 1] : v - 1;
    }
    return [for (var i = 0; i < n; i++) _Entry(ids[i], offs[i], lens[i], runs[i])];
  }

  /// z/x/y 타일 (압축 해제된 MVT 바이트), 없으면 null
  Uint8List? tile(int z, int x, int y) {
    final id = zxyToTileId(z, x, y);
    var dir = _root;
    for (var depth = 0; depth < 4; depth++) {
      // tileId <= id 인 마지막 항목
      var lo = 0, hi = dir.length - 1, found = -1;
      while (lo <= hi) {
        final mid = (lo + hi) >> 1;
        if (dir[mid].tileId <= id) {
          found = mid;
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }
      if (found < 0) return null;
      final e = dir[found];
      if (e.runLength == 0) {
        dir = _leafCache.putIfAbsent(e.offset, () => _readDir(_leafOff + e.offset, e.length));
        continue;
      }
      if (id >= e.tileId + e.runLength) return null;
      return _decompress(_read(_dataOff + e.offset, e.length), _tileComp);
    }
    return null;
  }
}

/// PMTiles 타일 번호 (확대 단계별 누적 + 힐베르트 곡선 순서)
int zxyToTileId(int z, int x, int y) {
  var acc = 0;
  for (var i = 0; i < z; i++) {
    acc += 1 << (2 * i);
  }
  final n = 1 << z;
  var d = 0;
  var rx = 0, ry = 0;
  for (var s = n ~/ 2; s > 0; s ~/= 2) {
    rx = (x & s) > 0 ? 1 : 0;
    ry = (y & s) > 0 ? 1 : 0;
    d += s * s * ((3 * rx) ^ ry);
    if (ry == 0) {
      if (rx == 1) {
        x = s - 1 - x;
        y = s - 1 - y;
      }
      final t = x;
      x = y;
      y = t;
    }
  }
  return acc + d;
}

// ---------------- Mapbox Vector Tile (필요한 부분만) ----------------

class MvtFeature {
  final int type; // 1 점, 2 선, 3 면
  final Map<String, Object?> props;
  final List<List<Point<int>>> rings; // 타일 좌표 (0..extent)
  const MvtFeature(this.type, this.props, this.rings);
}

class MvtLayer {
  final String name;
  final int extent;
  final List<MvtFeature> features;
  const MvtLayer(this.name, this.extent, this.features);
}

class _Pb {
  final Uint8List b;
  int pos;
  final int end;
  _Pb(this.b, [this.pos = 0, int? end]) : end = end ?? b.length;
  bool get more => pos < end;
  int varint() {
    final p = [pos];
    final v = _varint(b, p);
    pos = p[0];
    return v;
  }

  _Pb sub() {
    final len = varint();
    final s = _Pb(b, pos, pos + len);
    pos += len;
    return s;
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        varint();
      case 1:
        pos += 8;
      case 2:
        pos += varint();
      case 5:
        pos += 4;
    }
  }
}

/// [only]에 있는 레이어만 해석
List<MvtLayer> decodeMvt(Uint8List bytes, Set<String> only) {
  final out = <MvtLayer>[];
  final t = _Pb(bytes);
  while (t.more) {
    final key = t.varint();
    if (key >> 3 != 3) {
      t.skip(key & 7);
      continue;
    }
    final l = t.sub();
    String? name;
    var extent = 4096;
    final keys = <String>[], values = <Object?>[];
    final raw = <_Pb>[];
    while (l.more) {
      final k = l.varint();
      switch (k >> 3) {
        case 1:
          final s = l.sub();
          name = utf8.decode(s.b.sublist(s.pos, s.end));
        case 2:
          raw.add(l.sub());
        case 3:
          final s = l.sub();
          keys.add(utf8.decode(s.b.sublist(s.pos, s.end)));
        case 4:
          values.add(_value(l.sub()));
        case 5:
          extent = l.varint();
        default:
          l.skip(k & 7);
      }
    }
    if (name == null || !only.contains(name)) continue;
    out.add(MvtLayer(name, extent, [for (final f in raw) _feature(f, keys, values)]));
  }
  return out;
}

Object? _value(_Pb v) {
  Object? r;
  while (v.more) {
    final k = v.varint();
    switch (k >> 3) {
      case 1:
        final s = v.sub();
        r = utf8.decode(s.b.sublist(s.pos, s.end));
      case 2:
        r = ByteData.sublistView(v.b, v.pos, v.pos + 4).getFloat32(0, Endian.little);
        v.pos += 4;
      case 3:
        r = ByteData.sublistView(v.b, v.pos, v.pos + 8).getFloat64(0, Endian.little);
        v.pos += 8;
      case 4 || 5:
        r = v.varint();
      case 6:
        final z = v.varint();
        r = (z >> 1) ^ -(z & 1);
      case 7:
        r = v.varint() != 0;
      default:
        v.skip(k & 7);
    }
  }
  return r;
}

MvtFeature _feature(_Pb f, List<String> keys, List<Object?> values) {
  var type = 0;
  final props = <String, Object?>{};
  final rings = <List<Point<int>>>[];
  while (f.more) {
    final k = f.varint();
    switch (k >> 3) {
      case 2:
        final s = f.sub();
        while (s.more) {
          final ki = s.varint(), vi = s.varint();
          if (ki < keys.length && vi < values.length) props[keys[ki]] = values[vi];
        }
      case 3:
        type = f.varint();
      case 4:
        final g = f.sub();
        var x = 0, y = 0;
        List<Point<int>>? ring;
        while (g.more) {
          final cmd = g.varint();
          final id = cmd & 7, count = cmd >> 3;
          if (id == 7) {
            if (ring != null && ring.isNotEmpty) ring.add(ring.first); // ClosePath
            continue;
          }
          for (var i = 0; i < count; i++) {
            final dx = g.varint(), dy = g.varint();
            x += (dx >> 1) ^ -(dx & 1);
            y += (dy >> 1) ^ -(dy & 1);
            if (id == 1) rings.add(ring = <Point<int>>[]);
            ring!.add(Point(x, y));
          }
        }
      default:
        f.skip(k & 7);
    }
  }
  return MvtFeature(type, props, rings);
}

// ---------------- 가장 가까운 수원지 ----------------

class WaterSource {
  final String label; // 샘, 계곡, 하천, 호수, 식수대 …
  final String? name;
  final double lat, lon, distanceM;
  const WaterSource(this.label, this.name, this.lat, this.lon, this.distanceM);
}

/// 이름으로 걸러낼 고인 물·인공 수로 (OSM에서 호수나 일반 물로 잘못 분류된 경우까지 잡기 위해)
const _stagnantNames = ['소류지', '저수지', '유수지', '저류지', '연못', '양어장', '배수', '농수로', '수로', '침사지', '못'];

/// 생존용 수원지로 쓸 만한 물만 고름. 흐르는 물(계곡·개울·하천), 샘, 식수대, 자연 호수.
/// 고인 물(소류지·저수지·연못)과 농수로·배수로·운하는 정체·오염 위험이 커서 제외. 바다·수영장·분수도 제외
String? waterLabel(String layer, Map<String, Object?> p) {
  final kind = p['kind'] as String?, detail = p['kind_detail'] as String?;
  final name = (p['name:ko'] ?? p['name']) as String?;
  if (name != null && _stagnantNames.any((s) => s.length > 1 ? name.contains(s) : name.endsWith(s))) return null;
  if (layer == 'pois') {
    return switch (kind) {
      'drinking_water' => '식수대',
      'water_point' || 'watering_place' => '급수 지점',
      'spring' => '샘',
      _ => null,
    };
  }
  // 실제 한국 지도에서 확인한 종류: 선은 kind=river/stream, 면은 kind=water + kind_detail(river/lake/stream).
  // kind_detail 없는 kind=water 면은 대부분 연못·소류지라 제외
  if (const {'ocean', 'playa', 'swimming_pool', 'fountain'}.contains(kind)) return null;
  return switch (kind == 'water' ? detail : kind) {
    'stream' => '계곡·개울',
    'river' || 'riverbank' => '하천',
    'lake' => '호수',
    _ => null, // reservoir, basin, pond, ditch, drain, canal, 분류 없음
  };
}

const _zoom = 14;

(int, int) _tileXY(double lat, double lon) {
  final n = 1 << _zoom;
  final x = ((lon + 180) / 360 * n).floor();
  final r = lat * pi / 180;
  final y = ((1 - log(tan(r) + 1 / cos(r)) / pi) / 2 * n).floor();
  return (x, y);
}

(double, double) _tileToLatLon(int tx, int ty, int extent, Point<int> p) {
  final n = 1 << _zoom;
  final lon = (tx + p.x / extent) / n * 360 - 180;
  final yy = (ty + p.y / extent) / n;
  final lat = atan(_sinh(pi * (1 - 2 * yy))) * 180 / pi;
  return (lat, lon);
}

double _sinh(double x) => (exp(x) - exp(-x)) / 2;

/// 가까운 수원지 [count]곳. 같은 계곡이 타일마다 조각나 있으므로 이름이 같거나 300 m 안에 붙은 것은 하나로 침
List<WaterSource> nearestWaters(PmTiles pm, double lat, double lon, {int count = 5, int maxRing = 4}) {
  final (cx, cy) = _tileXY(lat, lon);
  final mLat = 111320.0, mLon = 111320.0 * cos(lat * pi / 180);
  final tileM = 40075016.686 * cos(lat * pi / 180) / (1 << _zoom);
  final all = <WaterSource>[];
  List<WaterSource> pick() {
    final sorted = [...all]..sort((a, b) => a.distanceM.compareTo(b.distanceM));
    final out = <WaterSource>[];
    for (final w in sorted) {
      final dup = out.any((o) =>
          (w.name != null && w.name == o.name) || distanceM(w.lat, w.lon, o.lat, o.lon) < 300);
      if (!dup) out.add(w);
      if (out.length == count) break;
    }
    return out;
  }

  for (var ring = 0; ring <= maxRing; ring++) {
    _scanRing(pm, cx, cy, ring, lat, lon, mLat, mLon, all.add);
    // 이번 고리까지 찾은 것보다 다음 고리가 더 가까울 수 없으면 종료 (타일 한 칸 ≈ 2.4 km)
    final got = pick();
    if (got.length == count && got.last.distanceM <= ring * tileM) return got;
  }
  return pick();
}

WaterSource? nearestWater(PmTiles pm, double lat, double lon, {int maxRing = 4}) =>
    nearestWaters(pm, lat, lon, count: 1, maxRing: maxRing).firstOrNull;

/// 한 고리(가운데 타일에서 ring칸 떨어진 테두리)의 수원지를 찾아 [add]로 넘김 (지물마다 가장 가까운 점 하나)
void _scanRing(PmTiles pm, int cx, int cy, int ring, double lat, double lon, double mLat, double mLon,
    void Function(WaterSource) add) {
  {
    for (var dy = -ring; dy <= ring; dy++) {
      for (var dx = -ring; dx <= ring; dx++) {
        if (max(dx.abs(), dy.abs()) != ring) continue;
        final bytes = pm.tile(_zoom, cx + dx, cy + dy);
        if (bytes == null) continue;
        for (final layer in decodeMvt(bytes, const {'water', 'pois'})) {
          for (final f in layer.features) {
            final label = waterLabel(layer.name, f.props);
            if (label == null) continue;
            final pts = [
              for (final r in f.rings) [for (final p in r) _tileToLatLon(cx + dx, cy + dy, layer.extent, p)]
            ];
            // 지역 평면 좌표(m)에서 점-선분 거리
            double toX(double lo) => (lo - lon) * mLon;
            double toY(double la) => (la - lat) * mLat;
            var bestD = double.infinity;
            (double, double)? bestP;
            void consider(double la, double lo) {
              final d = sqrt(pow(toX(lo), 2) + pow(toY(la), 2));
              if (d < bestD) {
                bestD = d;
                bestP = (la, lo);
              }
            }

            for (final r in pts) {
              if (r.length == 1 || f.type == 1) {
                for (final (la, lo) in r) {
                  consider(la, lo);
                }
                continue;
              }
              for (var i = 0; i + 1 < r.length; i++) {
                final (a1, o1) = r[i];
                final (a2, o2) = r[i + 1];
                final ax = toX(o1), ay = toY(a1), bx = toX(o2), by = toY(a2);
                final l2 = (bx - ax) * (bx - ax) + (by - ay) * (by - ay);
                final t = l2 == 0 ? 0.0 : ((-ax) * (bx - ax) + (-ay) * (by - ay)) / l2;
                final tc = t.clamp(0.0, 1.0);
                consider(a1 + (a2 - a1) * tc, o1 + (o2 - o1) * tc);
              }
            }
            if (f.type == 3 && pts.isNotEmpty && _inside(pts.first, lat, lon)) {
              bestD = 0;
              bestP = (lat, lon);
            }
            if (bestP != null) {
              add(WaterSource(label, (f.props['name:ko'] ?? f.props['name']) as String?, bestP!.$1, bestP!.$2, bestD));
            }
          }
        }
      }
    }
  }
}

bool _inside(List<(double, double)> ring, double lat, double lon) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final (yi, xi) = ring[i];
    final (yj, xj) = ring[j];
    if ((yi > lat) != (yj > lat) && lon < (xj - xi) * (lat - yi) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

String waterChipLabel(List<WaterSource> ws) =>
    '수원지 ${distanceLabel(ws.first.distanceM)}${ws.length > 1 ? ' 외 ${ws.length - 1}곳' : ''}';
