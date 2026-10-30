"""지형 음영(입체감)용 고도 타일 만들기 (hillshade.yml에서 실행).

MapLibre 안드로이드는 3D 지형을 지원하지 않지만 고도 타일(raster-dem)로 산 그림자(hillshade)는 그림.
DEM(VRT)을 웹 메르카토르 256x256 타일로 잘라 Terrarium 방식 PNG로 저장하고 MBTiles로 묶음.
  Terrarium: 고도 = R*256 + G + B/256 - 32768  (여기서는 1 m 단위로 반올림해 B=0 -> PNG가 더 작아짐)
바다만 있는 타일은 건너뜀.

사용법: python3 build_hillshade.py dem.vrt out.mbtiles minzoom maxzoom 서 남 동 북
"""
import io
import math
import multiprocessing as mp
import sqlite3
import sys

import numpy as np
from osgeo import gdal
from PIL import Image

gdal.UseExceptions()
R = 6378137.0
HALF = math.pi * R

_ds = None


def tile_range(z, w, s, e, n):
    def tx(lon):
        return int((lon + 180) / 360 * 2 ** z)

    def ty(lat):
        r = math.radians(lat)
        return int((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * 2 ** z)

    return tx(w), tx(e), ty(n), ty(s)


def bounds(z, x, y):
    size = 2 * HALF / 2 ** z
    minx = -HALF + x * size
    maxy = HALF - y * size
    return minx, maxy - size, minx + size, maxy


def init(vrt):
    global _ds
    _ds = gdal.Open(vrt)


def render(job):
    z, x, y = job
    minx, miny, maxx, maxy = bounds(z, x, y)
    out = gdal.Warp('', _ds, format='MEM', dstSRS='EPSG:3857', outputBounds=(minx, miny, maxx, maxy),
                    width=256, height=256, resampleAlg='average' if z < 10 else 'bilinear',
                    dstNodata=-9999)
    a = out.GetRasterBand(1).ReadAsArray().astype(np.float64)
    a[a < -1000] = 0
    if a.max() <= 0:
        return None  # 바다
    v = np.clip(np.round(a) + 32768, 0, 65535).astype(np.uint32)
    rgb = np.zeros((256, 256, 3), np.uint8)
    rgb[..., 0] = v // 256
    rgb[..., 1] = v % 256
    buf = io.BytesIO()
    Image.fromarray(rgb, 'RGB').save(buf, 'PNG', optimize=True)
    return z, x, y, buf.getvalue()


def main(vrt, dst, minz, maxz, w, s, e, n):
    jobs = []
    for z in range(minz, maxz + 1):
        x0, x1, y0, y1 = tile_range(z, w, s, e, n)
        jobs += [(z, x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)]
    print(f'{len(jobs)} tiles to render')

    db = sqlite3.connect(dst)
    db.execute('CREATE TABLE metadata (name TEXT, value TEXT)')
    db.execute('CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB)')
    db.execute('CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row)')
    for k, v in {'name': 'kr-hillshade', 'format': 'png', 'type': 'baselayer', 'minzoom': str(minz),
                 'maxzoom': str(maxz), 'bounds': f'{w},{s},{e},{n}', 'encoding': 'terrarium',
                 'attribution': '© Copernicus DEM (ESA)'}.items():
        db.execute('INSERT INTO metadata VALUES (?, ?)', (k, v))

    done = kept = size = 0
    with mp.Pool(initializer=init, initargs=(vrt,)) as pool:
        for r in pool.imap_unordered(render, jobs, chunksize=16):
            done += 1
            if r:
                z, x, y, png = r
                db.execute('INSERT INTO tiles VALUES (?, ?, ?, ?)', (z, x, 2 ** z - 1 - y, png))  # MBTiles는 y가 뒤집힘
                kept += 1
                size += len(png)
            if done % 2000 == 0:
                print(f'{done}/{len(jobs)}  kept {kept}  {size / 2**20:.0f} MB', flush=True)
    db.commit()
    db.close()
    print(f'done: {kept} tiles, {size / 2**20:.0f} MB')


if __name__ == '__main__':
    a = sys.argv
    main(a[1], a[2], int(a[3]), int(a[4]), *map(float, a[5:9]))
