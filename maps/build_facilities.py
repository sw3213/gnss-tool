"""대피·안전 시설 자료 만들기 (facilities.yml에서 실행). 종류마다 kr-fac-<종류>.json 하나.

파일: {"date": "YYYY-MM-DD", "cat": 종류, "items": [[이름, 구분, 지하(1/0), 수용인원, 주소, 위도, 경도, 안내], ...]}
(앱 쪽 lib/shelters.dart의 parseShelters, 종류 이름·색은 facilityCats)

  dust: 한국환경공단 에어코리아 미세먼지 쉼터 (공공데이터포털, 인증키 DATA_GO_KR_KEY)
        전체 건수가 400만 건이 넘게 나오지만 같은 쉼터가 되풀이됨 -> 새 쉼터가 10쪽 연속 안 나오면 멈추고,
        뒤쪽은 100쪽마다 하나씩만 훑어 빠진 것이 있는지 봄

사용법: python3 build_facilities.py <종류> <결과.json>
"""
import datetime
import json
import os
import re
import sys
import time
import urllib.request


def get_json(url):
    for attempt in range(6):
        try:
            with urllib.request.urlopen(url, timeout=90) as r:
                return json.load(r)
        except Exception as e:  # 공공 API는 가끔 끊김 -> 쉬었다가 다시
            print(f'  실패 ({e}), 다시 시도', flush=True)
            time.sleep(5 * (attempt + 1))
    raise SystemExit('받지 못함: ' + url.split('?')[0])


def hm(s):
    """'오후 6:00:00' -> '18:00'"""
    m = re.search(r'(오전|오후)?\s*(\d{1,2}):(\d{2})', s or '')
    if not m:
        return ''
    h = int(m.group(2)) % 12 + (12 if m.group(1) == '오후' else 0) if m.group(1) else int(m.group(2))
    return f'{h:02d}:{m.group(3)}'


def dust(key):
    base = 'https://apis.data.go.kr/B552584/ptcShuntPlaceService/getList'
    seen, items = set(), []

    def take(page):
        body = get_json(f'{base}?serviceKey={key}&returnType=json&pageNo={page}&numOfRows=1000')['body']
        new = 0
        for it in body.get('items') or []:
            lat, lon = it.get('lat'), it.get('lot')
            if not lat or not lon or not (33 < lat < 39 and 124 < lon < 132):
                continue
            k = (it.get('shltrNm'), round(lat, 5), round(lon, 5))
            if k in seen:
                continue
            seen.add(k)
            new += 1
            wd = f"평일 {hm(it.get('wkdyOperBgngTmCn'))}~{hm(it.get('wkdyOperEndTmCn'))}" if it.get('wkdyOperBgngTmCn') else ''
            we = f"주말 {hm(it.get('wkndOperBgngTmCn'))}~{hm(it.get('wkndOperEndTmCn'))}" if it.get('wkndOperBgngTmCn') else ''
            info = ' · '.join(x for x in [wd, we, (it.get('fcltTelnoCn') or '').strip()] if x)
            items.append([(it.get('shltrNm') or '').strip(), (it.get('fcltTypeNm') or '').strip(), 0,
                          int(it.get('utztnPsbltyNope') or 0),
                          (it.get('roadNmAddr') or it.get('daddr') or '').strip(), round(lat, 6), round(lon, 6), info])
        return new, body.get('totalCount', 0)

    page, quiet, total = 1, 0, 0
    while quiet < 10:
        new, total = take(page)
        quiet = 0 if new else quiet + 1
        print(f'{page}쪽: 새 쉼터 {new}, 지금까지 {len(items)}', flush=True)
        page += 1
    pages = (total + 999) // 1000
    for p in range(page + 100, pages + 1, 100):  # 뒤쪽 훑기
        new, _ = take(p)
        if new:
            print(f'{p}쪽에서 새 쉼터 {new}', flush=True)
    return items


SOURCES = {'dust': (dust, 'DATA_GO_KR_KEY')}
LABELS = {'dust': '미세먼지쉼터'}  # 앱의 facilityCats와 같게


def main(cat, dst):
    fetch, env = SOURCES[cat]
    key = os.environ.get(env, '').strip()
    if not key:
        raise SystemExit(f'{env} 없음 (GitHub Secret)')
    items = fetch(key)
    with open(dst, 'w', encoding='utf-8') as f:
        json.dump({'date': datetime.date.today().isoformat(), 'cat': cat, 'items': items}, f, ensure_ascii=False,
                  separators=(',', ':'))
    print(f'{cat}: {len(items)}곳, {os.path.getsize(dst) / 1e6:.1f} MB')


if __name__ == '__main__':
    if sys.argv[1] == '--label':  # 워크플로가 카탈로그 이름을 붙일 때
        print(LABELS[sys.argv[2]])
    else:
        main(sys.argv[1], sys.argv[2])
