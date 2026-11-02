"""건물·아파트 단지 이름 라벨 점 만들기 (labels.yml에서 실행).

Protomaps 기본 지도에는 건물 이름이 빠져 있어 아파트 "101동"이 안 보임.
osmium export로 뽑은 이름 있는 건물·주거 단지 다각형(GeoJSONSeq)을 읽어 가운데 점 하나로 바꿈.
  kind:  bldg = 건물, complex = 아파트 단지 등 주거 구역 (landuse=residential), exit = 지하철역 출구
  name:  전체 이름 ("잠실엘스 101동", "구곡현대2차아파트", "강남역 3번 출구")
  short: 동 번호만 ("101동"), 출구는 번호만 ("3"), 그 밖에는 전체 이름
  dong:  1 = 동 번호 있음

출구는 역·출구 점(stations.geojsons)에서: 출구마다 500 m 안 가장 가까운 역 이름을 붙임

사용법: python3 build_labels.py areas.geojsons labels.geojsons [stations.geojsons]
"""
import json
import math
import re
import sys

DONG = re.compile(r'(\d+[A-Za-z]?)\s*동$')


def ring_centroid(ring):
    """다각형 무게중심 (좁은 범위라 경위도를 평면처럼 계산). 넓이가 0이면 꼭짓점 평균"""
    a = cx = cy = 0.0
    for (x0, y0), (x1, y1) in zip(ring, ring[1:]):
        c = x0 * y1 - x1 * y0
        a += c
        cx += (x0 + x1) * c
        cy += (y0 + y1) * c
    if abs(a) < 1e-14:
        n = len(ring)
        return sum(p[0] for p in ring) / n, sum(p[1] for p in ring) / n, 0.0
    return cx / (3 * a), cy / (3 * a), abs(a) / 2


def label_point(geom):
    if geom['type'] == 'Polygon':
        polys = [geom['coordinates']]
    elif geom['type'] == 'MultiPolygon':
        polys = geom['coordinates']
    else:
        return None
    best = None
    for poly in polys:
        x, y, area = ring_centroid(poly[0])
        if best is None or area > best[2]:
            best = (x, y, area)
    return best


EXIT_NO = re.compile(r'(\d+(?:-\d+)?)')


def point_of(geom):
    if geom['type'] == 'Point':
        return geom['coordinates'][0], geom['coordinates'][1]
    p = label_point(geom)
    return None if p is None else (p[0], p[1])


def station_exits(path):
    """역·출구 점 -> [(경도, 위도, "강남역 3번 출구", "3")]. 번호를 모르거나 500 m 안에 역이 없으면 뺌"""
    stations, exits = [], []
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.strip().lstrip('\x1e')
            if not line:
                continue
            feat = json.loads(line)
            tags = feat.get('properties') or {}
            p = point_of(feat['geometry'])
            if p is None:
                continue
            if tags.get('railway') in ('subway_entrance', 'train_station_entrance'):
                m = EXIT_NO.search(tags.get('ref') or tags.get('name') or '')
                if m:
                    exits.append((p[0], p[1], m.group(1)))
            elif tags.get('railway') == 'station' or tags.get('public_transport') == 'station':
                name = tags.get('name:ko') or tags.get('name')
                if name:
                    stations.append((p[0], p[1], name))
    out = []
    for x, y, no in exits:
        k = math.cos(math.radians(y))
        best, bd = None, 500.0
        for sx, sy, name in stations:
            d = math.hypot((sx - x) * k, sy - y) * 111320
            if d < bd:
                best, bd = name, d
        if best:
            station = best if best.endswith('역') else best + '역'
            out.append((x, y, f'{station} {no}번 출구', no))
    return out


def main(src, dst, stations=None):
    counts = {'bldg': 0, 'complex': 0, 'dong': 0, 'exit': 0}
    with open(src, encoding='utf-8') as f, open(dst, 'w', encoding='utf-8') as out:
        for x, y, name, no in station_exits(stations) if stations else []:
            out.write(json.dumps({
                'type': 'Feature',
                'geometry': {'type': 'Point', 'coordinates': [round(x, 6), round(y, 6)]},
                'properties': {'kind': 'exit', 'name': name, 'short': no, 'dong': 0},
            }, ensure_ascii=False) + '\n')
            counts['exit'] += 1
        for line in f:
            line = line.strip().lstrip('\x1e')
            if not line:
                continue
            feat = json.loads(line)
            tags = feat.get('properties') or {}
            name = tags.get('name:ko') or tags.get('name') or tags.get('addr:housename')
            if not name:
                continue
            if tags.get('building'):
                kind = 'bldg'
            elif tags.get('landuse') == 'residential':
                kind = 'complex'
            else:
                continue
            p = label_point(feat['geometry'])
            if p is None:
                continue
            m = DONG.search(name) if kind == 'bldg' else None
            short = f'{m.group(1)}동' if m else name
            out.write(json.dumps({
                'type': 'Feature',
                'geometry': {'type': 'Point', 'coordinates': [round(p[0], 6), round(p[1], 6)]},
                'properties': {'kind': kind, 'name': name, 'short': short, 'dong': 1 if m else 0},
            }, ensure_ascii=False) + '\n')
            counts[kind] += 1
            counts['dong'] += 1 if m else 0
    print(counts)


if __name__ == '__main__':
    main(*sys.argv[1:4])
