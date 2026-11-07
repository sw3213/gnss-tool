"""대피·안전 시설 자료 만들기 (facilities.yml에서 실행). 종류마다 kr-fac-<종류>.json 하나.

파일: {"date": "YYYY-MM-DD", "cat": 종류, "items": [[이름, 구분, 지하(1/0), 수용인원, 주소, 위도, 경도, 안내], ...]}
(앱 쪽 lib/shelters.dart의 parseShelters, 종류 이름·색은 facilityCats)

  dust: 한국환경공단 에어코리아 미세먼지 쉼터 (공공데이터포털, 인증키 DATA_GO_KR_KEY)
        전체 건수가 400만 건이 넘게 나오지만 같은 쉼터가 되풀이됨 -> 새 쉼터가 10쪽 연속 안 나오면 멈추고,
        뒤쪽은 100쪽마다 하나씩만 훑어 빠진 것이 있는지 봄

  재난안전데이터공유플랫폼(safetydata.go.kr) 자료: 자료마다 인증키가 따로 (Secret SD_KEY_<종류>)
        quake 지진옥외 대피장소, tsunami 지진해일 대피장소, chemical 화학사고 대피장소, heat 무더위쉼터,
        cold 한파쉼터, housing 이재민 임시주거시설, quake_housing 지진겸용 임시주거시설, water 비상급수시설 (좌표가 웹 메르카토르라 위도·경도로 바꿈)

사용법: python3 build_facilities.py <종류> <결과.json>
"""
import datetime
import json
import math
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


def sd_rows(api, key):
    """재난안전데이터공유플랫폼에서 한 자료를 1000줄씩 끝까지 (같은 쪽이 되풀이되면 멈춤)"""
    base = f'https://www.safetydata.go.kr/V2/api/{api}'
    page, rows, quiet, seen = 1, [], 0, set()
    while True:
        d = get_json(f'{base}?serviceKey={key}&returnType=json&pageNo={page}&numOfRows=1000')
        body = d.get('body') or []
        if isinstance(body, dict):
            body = body.get('items') or []
        new = 0
        for it in body:
            k = json.dumps(it, sort_keys=True, ensure_ascii=False)
            if k not in seen:
                seen.add(k)
                rows.append(it)
                new += 1
        total = int(d.get('totalCount') or 0)
        print(f'{api} {page}쪽: {len(body)}줄 (새 {new}), 지금까지 {len(rows)} / {total}', flush=True)
        quiet = 0 if new else quiet + 1
        if not body or len(rows) >= total or quiet >= 3 or page * 1000 >= total + 1000:
            return rows
        page += 1
        time.sleep(1)  # 너무 빨리 이어서 부르면 서버가 끊음


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def txt(v):
    return ' '.join(str(v).split()) if v not in (None, '') else ''


def hhmm(v):
    """'0900' -> '09:00'"""
    v = txt(v).replace(':', '')
    return f'{v[:2]}:{v[2:4]}' if len(v) >= 4 and v[:4].isdigit() else ''


def span(label, a, b):
    a, b = hhmm(a), hhmm(b)
    return f'{label} {a}~{b}' if a and b else ''


def short(v, n=60):
    v = txt(v)
    return v if len(v) <= n else v[:n - 1] + '…'


def collect(rows, conv):
    """conv(행) -> [이름, 구분, 지하, 인원, 주소, 위도, 경도, 안내] 또는 None. 한국 밖 좌표·겹치는 곳은 뺌"""
    seen, out = set(), []
    for r in rows:
        it = conv(r)
        if not it or not it[0]:
            continue
        lat, lon = it[5], it[6]
        if lat is None or lon is None or not (33 < lat < 39 and 124 < lon < 132):
            continue
        k = (it[0], round(lat, 5), round(lon, 5))
        if k in seen:
            continue
        seen.add(k)
        it[5], it[6] = round(lat, 6), round(lon, 6)
        out.append(it)
    return out


def quake(key):
    return collect(sd_rows('DSSP-IF-10943', key), lambda r: None if txt(r.get('USE_SE_CD')) not in ('', '1') else [
        txt(r.get('VT_ACMDFCLTY_NM')), '', 0, int(num(r.get('VT_ACMD_PSBL_NMPR')) or 0),
        txt(r.get('RN_DTL_ADRES')) or txt(r.get('EQK_ACMDFCLTY_ADRES')), num(r.get('LA')), num(r.get('LO')),
        txt(r.get('TELNO'))])


def tsunami(key):
    return collect(sd_rows('DSSP-IF-10944', key), lambda r: None if txt(r.get('USE_AT')) == 'N' else [
        txt(r.get('SHNT_PLACE_NM')), '', 0, int(num(r.get('PSBL_NMPR')) or 0),
        txt(r.get('RN_DTL_ADRES')) or txt(r.get('SHNT_PLACE_DTL_POSITION')), num(r.get('LA')), num(r.get('LO')),
        ''])


def chemical(key):
    return collect(sd_rows('DSSP-IF-00707', key), lambda r: None if txt(r.get('DEL_YN')) == 'Y' else [
        txt(r.get('SHNT_PLC_NM')), txt(r.get('FCLT_SE')), 0, int(num(r.get('ACTC_TNOP')) or 0),
        txt(r.get('RONA_DADDR')), num(r.get('LAT')), num(r.get('LOT')), short(r.get('RMRK'))])


def heat(key):
    def conv(r):
        info = [span('평일', r.get('WKDAY_OPER_BEGIN_TIME'), r.get('WKDAY_OPER_END_TIME')),
                span('주말·휴일', r.get('WKEND_HDAY_OPER_BEGIN_TIME'), r.get('WKEND_HDAY_OPER_END_TIME')),
                '야간 운영' if r.get('CHCK_MATTER_NIGHT_OPN_AT') == 'Y' else '',
                '숙박 가능' if r.get('CHCK_MATTER_STAYNG_PSBL_AT') == 'Y' else '', short(r.get('RM'))]
        return [txt(r.get('RSTR_NM')), '', 0, int(num(r.get('USE_PSBL_NMPR')) or 0),
                txt(r.get('RN_DTL_ADRES')) or txt(r.get('DTL_ADRES')), num(r.get('LA')), num(r.get('LO')),
                ' · '.join(x for x in info if x)]
    return collect(sd_rows('DSSP-IF-10942', key), conv)


def cold(key):
    def conv(r):
        info = [span('평일', r.get('WKDY_OPER_BGNG_HR'), r.get('WKDY_OPER_END_HR')),
                span('토', r.get('STDY_OPER_BGNG_HR'), r.get('STDY_OPER_END_HR')),
                span('일', r.get('SNDY_OPER_BGNG_HR'), r.get('SNDY_OPER_END_HR')),
                span('공휴일', r.get('LHLDY_OPER_BGNG_HR'), r.get('LHLDY_OPER_END_HR')), short(r.get('RMRK'))]
        return [txt(r.get('REARE_NM')), '', 0, int(num(r.get('UTZTN_PSBLTY_TNOP')) or 0),
                txt(r.get('RONA_DADDR')) or txt(r.get('DADDR')), num(r.get('LAT')), num(r.get('LOT')),
                ' · '.join(x for x in info if x)]
    return collect(sd_rows('DSSP-IF-10804', key), conv)


def merc(x, y):
    """웹 메르카토르(EPSG:3857) -> 위도, 경도"""
    if x is None or y is None:
        return None, None
    return math.degrees(2 * math.atan(math.exp(y / 6378137)) - math.pi / 2), math.degrees(x / 6378137)


def water(key):
    def conv(r):
        lat, lon = merc(num(r.get('XMAP_CRTS')), num(r.get('YMAP_CRTS')))
        no = f"{r.get('ADDR_MNO')}" + (f"-{r.get('ADDR_SNO')}" if r.get('ADDR_SNO') else '') if r.get('ADDR_MNO') else ''
        addr = ' '.join(x for x in [txt(r.get('CTPV_NM')), txt(r.get('SGG_NM')), txt(r.get('ROAD_NM')), no] if x)
        return [txt(r.get('HALAREA_NM')), '', 1 if r.get('UDGD_YN') == 'Y' else 0, 0, addr, lat, lon, '']
    return collect(sd_rows('DSSP-IF-00098', key), conv)


def housing(key):
    def detail(r):  # 층·방 같은 자세한 위치 (이름을 되풀이한 것은 뺌)
        d = txt(r.get('RN_DTL_ADRES'))
        return '' if d == txt(r.get('VT_ACMDFCLTY_NM')) else d

    return collect(sd_rows('DSSP-IF-10945', key), lambda r: [
        txt(r.get('VT_ACMDFCLTY_NM')), detail(r), 0, int(num(r.get('VT_ACMD_PSBL_NMPR')) or 0),
        txt(r.get('DTL_ADRES')), num(r.get('LA')), num(r.get('LO')), ''])


def quake_housing(key):
    def conv(r):
        if txt(r.get('USE_SE_CD')) not in ('', '1'):
            return None
        no = txt(r.get('BULD_MNNM'))
        if no and txt(r.get('BULD_SLNO')) not in ('', '0'):
            no += '-' + txt(r.get('BULD_SLNO'))
        road = ' '.join(x for x in [txt(r.get('KOREAN_CTPRVN_NM')), txt(r.get('SIGUN_RESC_KOREAN')),
                                     txt(r.get('SGG_RN')), no] if x) if r.get('SGG_RN') else ''
        return [txt(r.get('VT_ACMDFCLTY_NM')), txt(r.get('ACMDFCLTY_DTL_CN')), 1 if r.get('UNDGRND_AT') == '1' else 0,
                int(num(r.get('VT_ACMD_PSBL_NMPR')) or 0), road, num(r.get('LA')), num(r.get('LO')), '']
    return collect(sd_rows('DSSP-IF-20661', key), conv)


SOURCES = {
    'dust': (dust, 'DATA_GO_KR_KEY'),
    'quake': (quake, 'SD_KEY_QUAKE'),
    'tsunami': (tsunami, 'SD_KEY_TSUNAMI'),
    'chemical': (chemical, 'SD_KEY_CHEMICAL'),
    'heat': (heat, 'SD_KEY_HEAT'),
    'cold': (cold, 'SD_KEY_COLD'),
    'housing': (housing, 'SD_KEY_HOUSING'),
    'quake_housing': (quake_housing, 'SD_KEY_QUAKE_HOUSING'),
    'water': (water, 'SD_KEY_WATER'),
}
LABELS = {'dust': '미세먼지쉼터', 'quake': '지진옥외 대피장소', 'tsunami': '지진해일 대피장소', 'chemical': '화학사고 대피장소',
          'heat': '무더위쉼터', 'cold': '한파쉼터', 'housing': '이재민 임시주거시설',
          'quake_housing': '지진겸용 임시주거시설', 'water': '비상급수시설'}  # 앱의 facilityCats와 같게


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
