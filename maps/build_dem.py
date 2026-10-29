"""분석용 고도 격자(.gdem)를 만든다. dem.yml(GitHub Actions)에서 실행.

앱이 전방 경사, 지형 일출·일몰, 가시권을 계산할 때 쓰는 파일.
등고선 패키지(지도 그리기용)와 달리 임의 지점 높이를 빨리 읽도록 단순한 격자로 저장.

형식 (리틀엔디언):
  헤더 48바이트: b'GDEM', u16 버전(1), u16 블록 크기(256),
                 f64 서쪽 경도, f64 북쪽 위도, f64 칸 크기(도), u32 가로 칸, u32 세로 칸,
                 u32 가로 블록 수, u32 세로 블록 수
  u64 오프셋 (블록 수 + 1)개: 블록 i 데이터 = [off[i], off[i+1])
  블록: 256x256 int16(m), 행 우선, zlib 압축. 바다·자료 없음 = 0
lib/dem.dart 의 DemFile 이 읽음.
"""
import struct
import sys
import zlib

import numpy as np
from osgeo import gdal

src, out, west, south, east, north, arcsec = sys.argv[1:8]
west, south, east, north = map(float, (west, south, east, north))
step = float(arcsec) / 3600

ds = gdal.Warp('/vsimem/dem.tif', src, outputBounds=(west, south, east, north),
               xRes=step, yRes=step, resampleAlg='average',
               dstNodata=-32768, outputType=gdal.GDT_Float32)
a = ds.ReadAsArray()
a = np.where(np.isnan(a) | (a < -1000), 0, a)  # 바다(DEM 칸 없음) -> 0 m
a = np.round(a).astype('<i2')
h, w = a.shape

B = 256
nbx, nby = (w + B - 1) // B, (h + B - 1) // B
blocks = []
for by in range(nby):
    for bx in range(nbx):
        blk = np.zeros((B, B), '<i2')
        sub = a[by * B:(by + 1) * B, bx * B:(bx + 1) * B]
        blk[:sub.shape[0], :sub.shape[1]] = sub
        blocks.append(zlib.compress(blk.tobytes(), 9))

hdr = struct.pack('<4sHHdddIIII', b'GDEM', 1, B, west, north, step, w, h, nbx, nby)
assert len(hdr) == 48
off = len(hdr) + 8 * (len(blocks) + 1)
offs = []
for b in blocks:
    offs.append(off)
    off += len(b)
offs.append(off)
with open(out, 'wb') as f:
    f.write(hdr)
    f.write(struct.pack('<%dQ' % len(offs), *offs))
    for b in blocks:
        f.write(b)
print(f'{w}x{h} cells, {nbx}x{nby} blocks, max {a.max()} m, {off / 1e6:.1f} MB')
