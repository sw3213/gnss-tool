"""민방위 대피소 자료 만들기 (shelters.yml에서 실행).

행정안전부 민방위대피시설 조회서비스(공공데이터포털)에서 전국 대피소를 모두 받아 앱용 JSON으로 만듦.
인증키는 환경변수 DATA_GO_KR_KEY (GitHub Secret). 포털의 Encoding 키를 주소에 그대로 붙여야 동작함.
사용 중인 것만 (OPER_STTS=사용중, 해제일 없음).

결과: {"date": "YYYY-MM-DD", "items": [[이름, 구분, 지하(1/0), 최대수용인원, 도로명주소, 위도, 경도], ...]}

사용법: python3 build_shelters.py kr-shelters.json
"""
import datetime
import json
import os
import sys
import time
import urllib.request

URL = 'https://apis.data.go.kr/1741000/civil_defense_shelter_info/info'
ROWS = 100  # 한 번에 최대 100개


def page(key, no):
    q = f'{URL}?serviceKey={key}&pageNo={no}&numOfRows={ROWS}&returnType=json'
    for attempt in range(5):
        try:
            with urllib.request.urlopen(q, timeout=60) as r:
                body = json.load(r)['response']
            if body['header']['resultCode'] != '0':
                raise RuntimeError(body['header'])
            return body['body']
        except Exception as e:  # 공공 API는 가끔 끊김 -> 잠깐 쉬고 다시
            print(f'  {no}쪽 실패 ({e}), 다시 시도', flush=True)
            time.sleep(3 * (attempt + 1))
    raise SystemExit(f'{no}쪽을 받지 못함')


def main(dst):
    key = os.environ.get('DATA_GO_KR_KEY', '').strip()
    if not key:
        raise SystemExit('DATA_GO_KR_KEY 없음 (GitHub Secret)')
    first = page(key, 1)
    total = first['totalCount']
    pages = (total + ROWS - 1) // ROWS
    print(f'전체 {total}곳, {pages}쪽', flush=True)
    raw = list(first['items']['item'])
    for no in range(2, pages + 1):
        raw += page(key, no)['items']['item']
    items, skipped = [], 0
    for it in raw:
        try:
            lat, lon = float(it.get('LAT_EPSG4326') or 0), float(it.get('LOT_EPST4326') or it.get('LOT_EPSG4326') or 0)
        except ValueError:
            lat = lon = 0
        if it.get('OPER_STTS') != '사용중' or it.get('RMV_YMD') or not (33 < lat < 39 and 124 < lon < 132):
            skipped += 1
            continue
        try:
            cap = int(float(it.get('MAX_ACTC_PERNE') or 0))
        except ValueError:
            cap = 0
        items.append([
            (it.get('FCLT_NM') or '').strip(),
            (it.get('FCLT_SE') or '').strip(),
            1 if it.get('FCLTLOC_GRND_UDGD') == '지하' else 0,
            cap,
            (it.get('ROAD_NM_WHOL_ADDR') or it.get('LCTN_WHOL_ADDR') or '').strip(),
            round(lat, 6),
            round(lon, 6),
        ])
    with open(dst, 'w', encoding='utf-8') as f:
        json.dump({'date': datetime.date.today().isoformat(), 'items': items}, f, ensure_ascii=False,
                  separators=(',', ':'))
    print(f'받은 것 {len(raw)}곳, 쓰는 것 {len(items)}곳 (해제·위치 없음 {skipped}곳), '
          f'{os.path.getsize(dst) / 1e6:.1f} MB')


if __name__ == '__main__':
    main(sys.argv[1])
