import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gnss_tool/terrain.dart';

/// 시험용 .gdem 파일 (maps/build_dem.py와 같은 형식). [f]: (위도, 경도) -> 높이
File writeDem(String path, double west, double north, double step, int w, int h,
    double Function(double lat, double lon) f) {
  const b = 256;
  final nbx = (w + b - 1) ~/ b, nby = (h + b - 1) ~/ b;
  final blocks = <List<int>>[];
  for (var by = 0; by < nby; by++) {
    for (var bx = 0; bx < nbx; bx++) {
      final blk = Int16List(b * b);
      for (var y = 0; y < b; y++) {
        for (var x = 0; x < b; x++) {
          final gx = bx * b + x, gy = by * b + y;
          if (gx >= w || gy >= h) continue;
          blk[y * b + x] = f(north - (gy + 0.5) * step, west + (gx + 0.5) * step).round();
        }
      }
      blocks.add(zlib.encode(blk.buffer.asUint8List()));
    }
  }
  final hdr = ByteData(48)
    ..setUint8(0, 0x47)
    ..setUint8(1, 0x44)
    ..setUint8(2, 0x45)
    ..setUint8(3, 0x4d)
    ..setUint16(4, 1, Endian.little)
    ..setUint16(6, b, Endian.little)
    ..setFloat64(8, west, Endian.little)
    ..setFloat64(16, north, Endian.little)
    ..setFloat64(24, step, Endian.little)
    ..setUint32(32, w, Endian.little)
    ..setUint32(36, h, Endian.little)
    ..setUint32(40, nbx, Endian.little)
    ..setUint32(44, nby, Endian.little);
  final offs = ByteData(8 * (blocks.length + 1));
  var off = 48 + offs.lengthInBytes;
  for (var i = 0; i < blocks.length; i++) {
    offs.setUint64(8 * i, off, Endian.little);
    off += blocks[i].length;
  }
  offs.setUint64(8 * blocks.length, off, Endian.little);
  final bytes = BytesBuilder()
    ..add(hdr.buffer.asUint8List())
    ..add(offs.buffer.asUint8List());
  for (final x in blocks) {
    bytes.add(x);
  }
  return File(path)..writeAsBytesSync(bytes.toBytes());
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('dem'));
  tearDown(() => tmp.deleteSync(recursive: true));

  const step = 3 / 3600; // 약 90 m
  const lat0 = 37.0, lon0 = 128.0;

  test('elevation reads back and interpolates', () {
    // 동쪽으로 갈수록 1 km당 100 m 높아지는 비탈
    final dem = DemFile.open(writeDem('${tmp.path}/a.gdem', 127.9, 37.1, step, 300, 300,
            (la, lo) => 500 + (lo - lon0) * 111320 * cos(37 * pi / 180) * 0.1)
        .path);
    expect(dem.elevation(lat0, lon0), closeTo(500, 2));
    expect(dem.elevation(10, 10), isNull);

    // 동쪽을 보면 100 m 앞이 약 10 m 높음 (+10%), 서쪽은 내리막
    final (dh, pct) = forwardSlope(dem, lat0, lon0, 90)!;
    expect(dh, closeTo(10, 1.5));
    expect(pct, closeTo(10, 1.5));
    expect(slopeLabel(forwardSlope(dem, lat0, lon0, 270)!), startsWith('전방 내리막 -1'));
    dem.close();
  });

  test('a ridge to the east delays sunrise; flat ground does not', () {
    // 관측 지점 동쪽 2 km에 높이 600 m 능선 (평지 100 m)
    double ridge(double la, double lo) {
      final ex = (lo - lon0) * 111320 * cos(37 * pi / 180);
      return ex > 1800 && ex < 2400 ? 600 : 100;
    }

    final hilly = DemFile.open(writeDem('${tmp.path}/r.gdem', 127.8, 37.2, step, 600, 500, ridge).path);
    final flat = DemFile.open(writeDem('${tmp.path}/f.gdem', 127.8, 37.2, step, 600, 500, (_, __) => 100).path);
    final day = DateTime(2026, 10, 30);

    final f = terrainSun(flat, day, lat0, lon0);
    expect(f.rise!.difference(f.astroRise!).inMinutes.abs(), lessThanOrEqualTo(4));

    // 2 km 앞 500 m 높이 = 올려본각 약 14° -> 해가 그만큼 올라올 때까지 1시간 넘게 늦어짐
    final h = terrainSun(hilly, day, lat0, lon0);
    expect(h.rise!.difference(h.astroRise!).inMinutes, greaterThan(60));
    expect(h.set!.difference(h.astroSet!).inMinutes.abs(), lessThanOrEqualTo(4)); // 서쪽은 트임
    hilly.close();
    flat.close();
  });

  test('viewshed hides the far side of a wall', () {
    // 동쪽 1 km에 높이 300 m 벽
    double wall(double la, double lo) {
      final ex = (lo - lon0) * 111320 * cos(37 * pi / 180);
      return ex > 950 && ex < 1150 ? 400 : 100;
    }

    final dem = DemFile.open(writeDem('${tmp.path}/w.gdem', 127.9, 37.1, step, 300, 300, wall).path);
    final v = viewshed(dem, lat0, lon0, radius: 3000);
    final half = v.size ~/ 2;
    int at(double eastM, double northM) =>
        v.visible[(half - (northM / v.cellM).round()) * v.size + half + (eastM / v.cellM).round()];
    expect(at(500, 0), 1); // 벽 앞: 보임
    expect(at(2000, 0), 0); // 벽 뒤: 가려짐
    expect(at(-2000, 0), 1); // 반대쪽 평지: 보임
    expect(at(2900, 2900), 255); // 반경 밖
    dem.close();
  });

  test('sun position at local noon is due south and high', () {
    // 원주 2026-10-30 12:30 KST 무렵 남중, 고도 약 39°
    final (az, el) = sunPosition(DateTime.utc(2026, 10, 30, 3, 30), 37.34, 127.92);
    expect(az, closeTo(180, 8));
    expect(el, closeTo(39, 2));
  });

  test('sun rises in the east-southeast in late October (UTC wraps to the previous day)', () {
    // 07:00 KST = 전날 22:00 UTC
    final (az, el) = sunPosition(DateTime.utc(2026, 10, 29, 22, 0), 37.34, 127.92);
    expect(az, closeTo(108, 5));
    expect(el, closeTo(1.5, 2));
  });
}
