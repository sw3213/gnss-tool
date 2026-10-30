import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

// ============================================================
// 고도 격자(.gdem) 읽기. 형식은 maps/build_dem.py 참고 (한국 3초 ≈ 90 m 간격)
// Flutter 없이도 쓰도록 dart: 라이브러리만 씀 (길찾기 자료 만드는 tool/build_routes.dart도 사용)
// ============================================================

class DemFile {
  final RandomAccessFile _f;
  final double west, north, step; // 도
  final int width, height, block, nbx, nby;
  final List<int> _offs;
  final _cache = LinkedHashMap<int, Int16List>(); // 최근 쓴 블록 (LRU)
  int maxCache = 64; // 블록 하나 128 KB -> 최대 약 8 MB (자료 만들 때는 늘려 씀)

  DemFile._(this._f, this.west, this.north, this.step, this.width, this.height, this.block, this.nbx, this.nby,
      this._offs);

  static DemFile open(String path) {
    final f = File(path).openSync();
    final h = ByteData.sublistView(f.readSync(48));
    if (String.fromCharCodes(h.buffer.asUint8List(h.offsetInBytes, 4)) != 'GDEM') {
      f.closeSync();
      throw const FormatException('고도 격자 파일이 아님');
    }
    final block = h.getUint16(6, Endian.little);
    final nbx = h.getUint32(40, Endian.little), nby = h.getUint32(44, Endian.little);
    final n = nbx * nby + 1;
    final ob = ByteData.sublistView(f.readSync(8 * n));
    return DemFile._(
      f,
      h.getFloat64(8, Endian.little),
      h.getFloat64(16, Endian.little),
      h.getFloat64(24, Endian.little),
      h.getUint32(32, Endian.little),
      h.getUint32(36, Endian.little),
      block,
      nbx,
      nby,
      [for (int i = 0; i < n; i++) ob.getUint64(8 * i, Endian.little)],
    );
  }

  void close() => _f.closeSync();

  double get cellMeters => step * 111320; // 남북 방향 칸 크기 (m)

  Int16List _block(int bi) {
    final hit = _cache.remove(bi);
    if (hit != null) return _cache[bi] = hit;
    _f.setPositionSync(_offs[bi]);
    final raw = zlib.decode(_f.readSync(_offs[bi + 1] - _offs[bi]));
    final data = Int16List.view(Uint8List.fromList(raw).buffer);
    if (_cache.length >= maxCache) _cache.remove(_cache.keys.first);
    return _cache[bi] = data;
  }

  int _cell(int x, int y) {
    x = x.clamp(0, width - 1);
    y = y.clamp(0, height - 1);
    final b = _block((y ~/ block) * nbx + x ~/ block);
    return b[(y % block) * block + x % block];
  }

  /// 해발고도 (m, 칸 중심 사이 쌍선형 보간). 격자 밖이면 null
  double? elevation(double lat, double lon) {
    final fx = (lon - west) / step - 0.5, fy = (north - lat) / step - 0.5;
    if (fx < -0.5 || fy < -0.5 || fx > width - 0.5 || fy > height - 0.5) return null;
    final x0 = fx.floor(), y0 = fy.floor();
    final tx = fx - x0, ty = fy - y0;
    final a = _cell(x0, y0), b = _cell(x0 + 1, y0), c = _cell(x0, y0 + 1), d = _cell(x0 + 1, y0 + 1);
    return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty;
  }
}
