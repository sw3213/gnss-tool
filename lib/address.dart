// 주소·장소 검색 (인터넷 없이 폰 안에서): 도로명주소 "정관로 123", 장소 이름 "정관박물관"
//
// 자료(kr-addr.gad)는 OpenStreetMap 한국 데이터에서 address.yml이 만듦 (tool/build_address.dart).
// 파일 형식 (리틀엔디안):
//   머리: "GADR" u16 판(1) u16 0, u32 지역 수, 도로 수, 번지 수, 장소 수, u32 구역 시작 위치 ×4 (지역, 도로, 번지, 장소)
//   지역: [u8 길이][이름 UTF-8] 시도·시군구·구를 이어 붙인 것 ("부산광역시 기장군")
//   도로: [u8 길이][이름][u16 지역][u32 첫 번지][u32 번지 수][i32 위도][i32 경도]  도로 하나의 대표 위치
//   번지: [u16 본번][u16 부번][i32 위도][i32 경도]  도로별로 본번·부번 순 정렬 (12바이트)
//   장소: [u8 길이][이름][u8 종류][i32 위도][i32 경도]
// 이름은 띄어쓰기를 빼고 저장 (검색어도 띄어쓰기를 빼고 비교). 좌표는 도 × 1e6
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

// Flutter 없이도 쓰도록 dart: 라이브러리만 씀 (자료 만드는 tool/build_address.dart도 사용)

/// 두 점 사이 거리 (m, 대략: 정렬용)
double _distM(double la1, double lo1, double la2, double lo2) {
  final x = (lo2 - lo1) * cos((la1 + la2) / 2 * pi / 180), y = la2 - la1;
  return sqrt(x * x + y * y) * 111320;
}

const addressFormatVersion = 1;

/// 장소 종류 (파일의 종류 번호 = 목록 순서)
const placeKinds = [
  '장소', '산', '역', '학교', '병원', '관공서', '지명', '관광', '공원', '가게', '건물', '주차장', '물', '대피소', '도로', //
  '지하철 출구', '버스 정류장',
];
const exitKind = 15; // "강남역 3번 출구" (tool/build_address.dart가 출구마다 가까운 역 이름을 붙임)
const stationKind = 2, busStopKind = 16;

/// 기차·지하철역인지 (버스 터미널 말고). 이름에 "역"이 없으면 붙여서 저장 ("사직" -> "사직역")
bool isRailStation(Map<String, dynamic> t) =>
    t['railway'] == 'station' ||
    t['railway'] == 'halt' ||
    (t['public_transport'] == 'station' && (t['subway'] == 'yes' || t['train'] == 'yes' || t['light_rail'] == 'yes'));

/// OSM 태그 -> 장소 종류 번호 (검색에 안 넣을 것은 null)
int? placeKind(Map<String, dynamic> t) {
  String? g(String k) => t[k] as String?;
  final amenity = g('amenity'), tourism = g('tourism'), natural = g('natural');
  if (natural == 'peak' || natural == 'saddle' || natural == 'volcano') return 1;
  if (natural == 'spring' || amenity == 'drinking_water') return 12;
  if (amenity == 'shelter' || tourism == 'alpine_hut' || tourism == 'wilderness_hut') return 13;
  // 버스 정류장 (이름이 "사직역"이어도 역이 아님)
  if (g('highway') == 'bus_stop' || (g('public_transport') == 'platform' && g('bus') == 'yes')) return busStopKind;
  if (g('railway') == 'station' || g('public_transport') == 'station' || g('railway') == 'halt') return stationKind;
  if (const {'school', 'university', 'college', 'kindergarten'}.contains(amenity)) return 3;
  if (const {'hospital', 'clinic', 'doctors', 'pharmacy', 'dentist'}.contains(amenity)) return 4;
  if (const {'townhall', 'police', 'fire_station', 'post_office', 'courthouse', 'library', 'community_centre'}
      .contains(amenity)) {
    return 5;
  }
  if (g('place') != null) return 6;
  if (tourism != null || g('historic') != null) return 7;
  if (const {'park', 'nature_reserve', 'garden', 'playground', 'sports_centre', 'stadium'}.contains(g('leisure'))) {
    return 8;
  }
  if (amenity == 'parking') return 11;
  if (g('shop') != null || g('office') != null || g('craft') != null || amenity != null) return 9;
  if (g('building') != null) return 10;
  if (g('highway') != null) return 14;
  if (natural != null || g('waterway') != null || g('landuse') != null || g('leisure') != null) return 0;
  return null;
}

/// 띄어쓰기 빼고 영문은 소문자로 (저장·검색 공통)
String normalizeName(String s) => s.replaceAll(RegExp(r'\s+'), '').toLowerCase();

/// "284-12" -> (284, 12), "28" -> (28, 0). 숫자로 시작하지 않으면 null
(int, int)? parseHouseNumber(String s) {
  final m = RegExp(r'^\s*(\d{1,5})(?:\s*-\s*(\d{1,5}))?').firstMatch(s);
  if (m == null) return null;
  final a = int.parse(m.group(1)!), b = m.group(2) == null ? 0 : int.parse(m.group(2)!);
  return a > 65535 || b > 65535 ? null : (a, b);
}

// ---------------- 만들기 (tool/build_address.dart) ----------------

class AddressIndexBuilder {
  final _regions = <String, int>{'': 0};
  final _streets = <String, _Street>{}; // 이름|지역|칸 -> 번지들
  final _places = <String, (int, int, int)>{}; // 이름|종류|칸 -> (종류, 위도, 경도) 같은 이름은 칸마다 하나
  final _cellRegion = <int, Map<int, int>>{}; // 칸 -> 지역별 번지 수 (지역 없는 번지에 채워 넣기)

  int get addresses => _streets.values.fold(0, (n, s) => n + s.main.length);
  int get places => _places.length;

  static int _cell(double lat, double lon) => (lat * 10).floor() * 10000 + (lon * 10).floor();

  /// 번지 하나. [region]은 "부산광역시 기장군"처럼 아는 만큼 (모르면 빈 글자)
  void addAddress(String street, String houseNumber, String region, double lat, double lon) {
    final name = normalizeName(street), n = parseHouseNumber(houseNumber);
    if (name.isEmpty || n == null) return;
    final r = _regions.putIfAbsent(region.trim(), () => _regions.length);
    final c = _cell(lat, lon);
    if (r != 0) _cellRegion.putIfAbsent(c, () => {}).update(r, (v) => v + 1, ifAbsent: () => 1);
    _streets.putIfAbsent('$name|$r|$c', () => _Street(name, r, c)).add(n.$1, n.$2, lat, lon);
  }

  void addPlace(String name, int kind, double lat, double lon) {
    final n = normalizeName(name);
    if (n.isEmpty || utf8.encode(n).length > 255) return;
    _places.putIfAbsent('$n|$kind|${_cell(lat, lon)}', () => (kind, (lat * 1e6).round(), (lon * 1e6).round()));
  }

  void write(String path) {
    // 지역 없는 번지: 같은 칸에서 가장 흔한 지역으로
    int regionOf(_Street s) {
      if (s.region != 0) return s.region;
      final m = _cellRegion[s.cell];
      return m == null ? 0 : m.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    }

    final regionNames = List.filled(_regions.length, '');
    _regions.forEach((k, v) => regionNames[v] = k);
    final streets = _streets.values.toList()..sort((a, b) => a.name.compareTo(b.name));

    final head = BytesBuilder(), regions = BytesBuilder(), st = BytesBuilder(), recs = BytesBuilder();
    final pl = BytesBuilder();
    for (final r in regionNames) {
      _str(regions, r);
    }
    var start = 0;
    for (final s in streets) {
      final order = s.sorted();
      final mid = order[order.length ~/ 2];
      _str(st, s.name);
      st.add(_u16(regionOf(s)));
      st.add(_u32(start));
      st.add(_u32(order.length));
      st.add(_i32(s.lat[mid]));
      st.add(_i32(s.lon[mid]));
      for (final i in order) {
        recs.add(_u16(s.main[i]));
        recs.add(_u16(s.sub[i]));
        recs.add(_i32(s.lat[i]));
        recs.add(_i32(s.lon[i]));
      }
      start += order.length;
    }
    _places.forEach((k, v) {
      _str(pl, k.substring(0, k.indexOf('|')));
      pl.addByte(v.$1);
      pl.add(_i32(v.$2));
      pl.add(_i32(v.$3));
    });
    const headLen = 4 + 4 + 16 + 16;
    head.add(ascii.encode('GADR'));
    head.add(_u16(addressFormatVersion));
    head.add(_u16(0));
    for (final n in [regionNames.length, streets.length, start, _places.length]) {
      head.add(_u32(n));
    }
    var off = headLen;
    for (final b in [regions, st, recs]) {
      head.add(_u32(off));
      off += b.length;
    }
    head.add(_u32(off));
    final f = File(path).openSync(mode: FileMode.write);
    for (final b in [head, regions, st, recs, pl]) {
      f.writeFromSync(b.takeBytes());
    }
    f.closeSync();
  }

  static void _str(BytesBuilder b, String s) {
    final e = utf8.encode(s);
    final n = min(e.length, 255);
    b.addByte(n);
    b.add(e.sublist(0, n));
  }

  static Uint8List _u16(int v) => Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);
  static Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
  static Uint8List _i32(int v) => Uint8List(4)..buffer.asByteData().setInt32(0, v, Endian.little);
}

class _Street {
  final String name;
  final int region, cell;
  final main = <int>[], sub = <int>[], lat = <int>[], lon = <int>[];
  _Street(this.name, this.region, this.cell);

  void add(int a, int b, double la, double lo) {
    main.add(a);
    sub.add(b);
    lat.add((la * 1e6).round());
    lon.add((lo * 1e6).round());
  }

  /// 본번·부번 순서 (같은 번지가 여러 개면 하나만)
  List<int> sorted() {
    final idx = List.generate(main.length, (i) => i)
      ..sort((x, y) => main[x] != main[y] ? main[x] - main[y] : sub[x] - sub[y]);
    final out = <int>[];
    for (final i in idx) {
      if (out.isEmpty || main[out.last] != main[i] || sub[out.last] != sub[i]) out.add(i);
    }
    return out;
  }
}

// ---------------- 찾기 ----------------

class SearchHit {
  final String title; // "정관로 123" / "정관박물관"
  final String detail; // "부산광역시 기장군" / "관광" / "근처 번지 (121)"
  final double lat, lon;
  final bool exact; // 정확히 찾은 번지·이름
  final bool place; // 장소 이름으로 찾은 것 (주소·도로가 아님)
  const SearchHit(this.title, this.detail, this.lat, this.lon, {this.exact = true, this.place = false});

  @override
  String toString() => '$title ($detail) $lat,$lon';
}

/// 검색어 나누기: "부산 기장군 정관로 123-4" -> 지역 ["부산", "기장군"], 도로 "정관로", 번지 (123, 4)
({List<String> region, String? road, (int, int)? number}) parseQuery(String q) {
  var t = q.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  // 붙여 쓴 번호 떼기: "공지로69-9" -> "공지로" "69-9", "대덕대로578번길27번지" -> "대덕대로578번길" "27"
  if (t.isNotEmpty) {
    final m = RegExp(r'^(.+?(?:로|길))(\d{1,5}(?:-\d{1,5})?)(?:번지)?$').firstMatch(t.last);
    if (m != null) t = [...t.sublist(0, t.length - 1), m.group(1)!, m.group(2)!];
  }
  (int, int)? number;
  if (t.isNotEmpty) {
    final last = t.last.replaceAll('번지', '');
    if (RegExp(r'^\d{1,5}(-\d{1,5})?$').hasMatch(last)) {
      number = parseHouseNumber(last);
      t = t.sublist(0, t.length - 1);
    }
  }
  // "대덕대로 578번길" -> "대덕대로578번길"
  final joined = <String>[];
  for (final s in t) {
    if (joined.isNotEmpty && RegExp(r'^\d+번?(길|가길)$').hasMatch(s)) {
      joined[joined.length - 1] += s;
    } else {
      joined.add(s);
    }
  }
  final roadAt = joined.lastIndexWhere((s) => RegExp(r'(로|길)$').hasMatch(s) || RegExp(r'(로|길)\d+$').hasMatch(s));
  if (roadAt < 0) return (region: const <String>[], road: null, number: null);
  return (region: joined.sublist(0, roadAt), road: normalizeName(joined[roadAt]), number: number);
}

class _Reader {
  final ByteData d;
  int p = 0;
  _Reader(Uint8List b) : d = b.buffer.asByteData(b.offsetInBytes, b.length);
  int u8() => d.getUint8(p++);
  int u16() {
    p += 2;
    return d.getUint16(p - 2, Endian.little);
  }

  int u32() {
    p += 4;
    return d.getUint32(p - 4, Endian.little);
  }

  int i32() {
    p += 4;
    return d.getInt32(p - 4, Endian.little);
  }

  /// [u8 길이][UTF-8]
  String str() {
    final n = u8();
    p += n;
    return utf8.decode(Uint8List.sublistView(d, p - n, p));
  }
}

/// 주소·장소 찾기. [lat]/[lon]은 기준 위치 (지도 중심이나 내 위치, 가까운 순으로 정렬, 모르면 null)
List<SearchHit> searchAddress(String path, String query, {double? lat, double? lon, int limit = 30}) =>
    searchIndex(File(path).readAsBytesSync(), query, lat: lat, lon: lon, limit: limit);

/// 번지 위치 색인: 약 1 km 칸마다 번지 목록. 가까운 도로명주소를 빨리 찾음 (검색 스레드가 한 번 만들어 둠)
class AddressGrid {
  final List<String> _regions, _streetName;
  final Uint16List _streetRegion;
  final Int32List _recStreet;
  final ByteData _rec;
  final _cells = HashMap<int, List<int>>();

  static int _key(double lat, double lon) => (lat * 100).floor() * 100000 + (lon * 100).floor();

  AddressGrid._(this._regions, this._streetName, this._streetRegion, this._recStreet, this._rec);

  factory AddressGrid(Uint8List data) {
    final h = _Reader(Uint8List.sublistView(data, 0, 40))..p = 8;
    final nRegions = h.u32(), nStreets = h.u32(), nRecs = h.u32();
    h.p = 24;
    final regionsOff = h.u32(), streetsOff = h.u32(), recsOff = h.u32();
    final rr = _Reader(Uint8List.sublistView(data, regionsOff, streetsOff));
    final regions = [for (var i = 0; i < nRegions; i++) rr.str()];
    final sr = _Reader(Uint8List.sublistView(data, streetsOff, recsOff));
    final names = <String>[];
    final regionOf = Uint16List(nStreets), recStreet = Int32List(nRecs);
    final rec = ByteData.sublistView(data, recsOff, recsOff + nRecs * 12);
    final g = AddressGrid._(regions, names, regionOf, recStreet, rec);
    for (var i = 0; i < nStreets; i++) {
      names.add(sr.str());
      regionOf[i] = sr.u16();
      final start = sr.u32(), count = sr.u32();
      sr.p += 8;
      for (var k = start; k < start + count; k++) {
        recStreet[k] = i;
        g._cells
            .putIfAbsent(_key(rec.getInt32(k * 12 + 4, Endian.little) / 1e6, rec.getInt32(k * 12 + 8, Endian.little) / 1e6),
                () => [])
            .add(k);
      }
    }
    return g;
  }

  /// 가장 가까운 도로명주소 ([maxM] 안, 없으면 null). 제목 "정관로 123", 설명 "부산광역시 기장군"
  SearchHit? nearest(double lat, double lon, {double maxM = 120}) {
    final r = (maxM / 1000).ceil() + 1; // 칸 약 1 km
    final cy = (lat * 100).floor(), cx = (lon * 100).floor();
    var best = maxM;
    int? bk;
    for (var dy = -r; dy <= r; dy++) {
      for (var dx = -r; dx <= r; dx++) {
        for (final k in _cells[(cy + dy) * 100000 + cx + dx] ?? const <int>[]) {
          final d = _distM(lat, lon, _rec.getInt32(k * 12 + 4, Endian.little) / 1e6,
              _rec.getInt32(k * 12 + 8, Endian.little) / 1e6);
          if (d < best) (best, bk) = (d, k);
        }
      }
    }
    final k = bk;
    if (k == null) return null;
    final st = _recStreet[k];
    return SearchHit('${_streetName[st]} ${_numLabel(_rec.getUint16(k * 12, Endian.little), _rec.getUint16(k * 12 + 2, Endian.little))}',
        _regions[_streetRegion[st]], _rec.getInt32(k * 12 + 4, Endian.little) / 1e6,
        _rec.getInt32(k * 12 + 8, Endian.little) / 1e6);
  }

  /// 장소 설명에 붙일 위치: 300 m 안에 주소가 있으면 "지역 도로명주소", 3 km 안이면 "지역"
  String? describe(double lat, double lon) {
    final a = nearest(lat, lon, maxM: 300);
    if (a != null) return [a.detail, a.title].where((t) => t.isNotEmpty).join(' ');
    final r = nearest(lat, lon, maxM: 3000)?.detail;
    return r == null || r.isEmpty ? null : r;
  }
}

/// 메모리에 올린 자료([data] = 파일 전체)에서 찾기. [grid]가 있으면 장소마다 지역·도로명주소를 붙임
/// (없으면 장소가 나올 때 만듦)
List<SearchHit> searchIndex(Uint8List data, String query,
    {double? lat, double? lon, int limit = 30, AddressGrid? grid}) {
  Uint8List read(int off, int len) => Uint8List.sublistView(data, off, off + len);

  final h = _Reader(read(0, 40));
  if (String.fromCharCodes([h.u8(), h.u8(), h.u8(), h.u8()]) != 'GADR') {
    throw const FormatException('주소 검색 자료 파일이 아님');
  }
  if (h.u16() != addressFormatVersion) throw const FormatException('주소 검색 자료 형식이 다름. 다시 받아 주세요');
  h.u16();
  final nRegions = h.u32(), nStreets = h.u32();
  h.u32(); // 번지 수
  final nPlaces = h.u32();
  final regionsOff = h.u32(), streetsOff = h.u32(), recsOff = h.u32(), placesOff = h.u32();

  final rr = _Reader(read(regionsOff, streetsOff - regionsOff));
  final regions = [for (var i = 0; i < nRegions; i++) rr.str()];

  double dist(double la, double lo) => lat == null || lon == null ? 0 : _distM(lat, lon, la, lo);
  final hits = <(int, double, SearchHit)>[]; // (순위: 작을수록 앞, 거리, 결과)

  final q = parseQuery(query);
  final qs = Uint8List.fromList(utf8.encode(q.road ?? normalizeName(query)));
  if (qs.isEmpty) return const [];

  // 도로
  final sb = read(streetsOff, recsOff - streetsOff);
  final sr = _Reader(sb);
  final roads = <(int rank, String name, String region, int start, int count, double la, double lo)>[];
  for (var i = 0; i < nStreets; i++) {
    final n = sr.u8(), at = sr.p;
    sr.p += n;
    final region = sr.u16(), start = sr.u32(), count = sr.u32(), la = sr.i32() / 1e6, lo = sr.i32() / 1e6;
    final rank = _match(sb, at, n, qs);
    if (rank == null || (q.road != null && q.number != null && rank > 0)) continue; // 번지 검색은 도로 이름이 같아야
    roads.add((rank, utf8.decode(Uint8List.sublistView(sb, at, at + n)), regions[region], start, count, la, lo));
  }
  // "부산 기장군"처럼 지역을 쳤으면 그 지역만 (맞는 게 하나도 없으면 지역은 무시)
  bool inRegion(String reg) => q.region.every((w) => normalizeName(reg).contains(normalizeName(w)));
  final local = roads.where((r) => inRegion(r.$3)).toList();
  final num = q.number;
  if (q.road != null && num != null) {
    // 같은 도로가 지도 칸(약 10 km)마다 나뉘어 있음 -> 가까운 조각끼리(같은 동네) 묶어 한 번만 답함
    final groups = <List<_Road>>[];
    for (final r in local.isEmpty ? roads : local) {
      final g = groups.where((g) => _distM(g.first.$6, g.first.$7, r.$6, r.$7) < 20000).firstOrNull;
      g == null ? groups.add([r]) : g.add(r);
    }
    for (final g in groups) {
      final recs = <(int, int, double, double)>[];
      for (final r in g) {
        final rb = _Reader(read(recsOff + r.$4 * 12, r.$5 * 12));
        for (var k = 0; k < r.$5; k++) {
          recs.add((rb.u16(), rb.u16(), rb.i32() / 1e6, rb.i32() / 1e6));
        }
      }
      final region = g.map((r) => r.$3).reduce((x, y) => y.length > x.length ? y : x); // 가장 자세한 지역 이름
      final h = _houseHit('${g.first.$2} ${_numLabel(num.$1, num.$2)}', region, num, recs);
      if (h != null) hits.add((h.exact ? 0 : 1, dist(h.lat, h.lon), h));
    }
  } else {
    for (final r in local.isEmpty ? roads : local) {
      // 이름이 같으면 먼저, 앞부분이 같거나 들어 있으면 가까운 순으로 섞음
      hits.add((r.$1 == 0 ? 2 : 3, dist(r.$6, r.$7),
          SearchHit(r.$2, r.$3.isEmpty ? '도로' : '도로 · ${r.$3}', r.$6, r.$7)));
    }
  }

  // 번지 자료가 없는 도로: 도로 위치라도 (OSM 도로 이름에서)
  final roadOnly = q.road != null && q.number != null && hits.isEmpty;
  // 장소 이름 (번지까지 친 주소면 안 찾음)
  if (q.number == null || q.road == null || roadOnly) {
    final ps = roadOnly ? q.road! : normalizeName(query);
    final pq = Uint8List.fromList(utf8.encode(ps));
    final pb = read(placesOff, data.length - placesOff);
    final pr = _Reader(pb);
    for (var i = 0; i < nPlaces; i++) {
      final n = pr.u8(), at = pr.p;
      pr.p += n;
      final kind = pr.u8(), la = pr.i32() / 1e6, lo = pr.i32() / 1e6;
      final rank = _match(pb, at, n, pq);
      if (rank == null) continue;
      final name = utf8.decode(Uint8List.sublistView(pb, at, at + n));
      if (roadOnly) {
        if (rank == 0 && kind == 14) {
          hits.add((1, dist(la, lo), SearchHit(query.trim(), '$name · 번지 자료가 없어 도로 위치만', la, lo, exact: false)));
        }
        continue;
      }
      hits.add((rank == 0 ? 2 : 3, dist(la, lo),
          SearchHit(name, placeKinds[kind < placeKinds.length ? kind : 0], la, lo, place: true)));
      if (hits.length > 20000) break;
    }
  }
  hits.sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2.compareTo(b.$2));
  // 정확한 번지가 있으면 "가까운 번지"는 빼고, 같은 이름·설명은 가장 가까운 하나만
  final hasExact = hits.any((h) => h.$1 == 0 && q.number != null);
  final seen = <String>{}, out = <SearchHit>[];
  for (final h in hits) {
    if (hasExact && h.$1 == 1) continue;
    if (!seen.add('${h.$3.title}|${h.$3.detail}')) continue;
    out.add(h.$3);
    if (out.length >= limit) break;
  }
  // 장소: "가게" -> "가게 · 부산광역시 기장군 정관로 123" (어느 동네인지)
  if (out.any((h) => h.place)) {
    final g = grid ?? AddressGrid(data);
    for (var i = 0; i < out.length; i++) {
      final h = out[i];
      if (!h.place) continue;
      final where = g.describe(h.lat, h.lon);
      if (where != null) out[i] = SearchHit(h.title, '${h.detail} · $where', h.lat, h.lon, exact: h.exact, place: true);
    }
  }
  return out;
}

/// [lat]/[lon]에서 가장 가까운 이름 있는 건물·가게·시설 (도로·지명·산은 빼고). [maxM] 넘게 멀면 null
/// 결과: 제목 = 이름, 설명 = 종류 (건물, 가게, 학교…)
SearchHit? nearestPlace(Uint8List data, double lat, double lon, {double maxM = 40}) {
  final h = _Reader(Uint8List.sublistView(data, 0, 40))..p = 20;
  final nPlaces = h.u32();
  h.p = 36;
  final placesOff = h.u32();
  final pr = _Reader(Uint8List.sublistView(data, placesOff));
  const skip = {1, 6, 14}; // 산, 지명, 도로
  final dLat = maxM / 111320, dLon = maxM / (111320 * cos(lat * pi / 180));
  var best = maxM;
  SearchHit? hit;
  for (var i = 0; i < nPlaces; i++) {
    final n = pr.u8(), at = pr.p;
    pr.p += n;
    final kind = pr.u8(), la = pr.i32() / 1e6, lo = pr.i32() / 1e6;
    if ((la - lat).abs() > dLat || (lo - lon).abs() > dLon || skip.contains(kind)) continue;
    final d = _distM(lat, lon, la, lo);
    if (d < best) {
      best = d;
      hit = SearchHit(utf8.decode(Uint8List.sublistView(pr.d, at, at + n)),
          placeKinds[kind < placeKinds.length ? kind : 0], la, lo);
    }
  }
  return hit;
}

/// [lat]/[lon]에서 가장 가까운 도로명주소 (지도에서 누른 곳의 주소). [maxM] 넘게 멀면 null
SearchHit? nearestAddress(Uint8List data, double lat, double lon, {double maxM = 120}) {
  final h = _Reader(Uint8List.sublistView(data, 0, 40))..p = 8;
  final nRegions = h.u32(), nStreets = h.u32();
  h.p = 24;
  final regionsOff = h.u32(), streetsOff = h.u32(), recsOff = h.u32();
  final rr = _Reader(Uint8List.sublistView(data, regionsOff, streetsOff));
  final regions = [for (var i = 0; i < nRegions; i++) rr.str()];
  final sr = _Reader(Uint8List.sublistView(data, streetsOff, recsOff));
  final rec = ByteData.sublistView(data, recsOff);
  var best = maxM;
  SearchHit? hit;
  for (var i = 0; i < nStreets; i++) {
    final name = sr.str();
    final region = sr.u16(), start = sr.u32(), count = sr.u32(), la = sr.i32() / 1e6, lo = sr.i32() / 1e6;
    if (_distM(lat, lon, la, lo) > 20000) continue; // 도로 조각은 지도 칸(약 10 km) 안에 있음
    for (var k = start; k < start + count; k++) {
      final o = k * 12;
      final rla = rec.getInt32(o + 4, Endian.little) / 1e6, rlo = rec.getInt32(o + 8, Endian.little) / 1e6;
      final d = _distM(lat, lon, rla, rlo);
      if (d < best) {
        best = d;
        final a = rec.getUint16(o, Endian.little), b = rec.getUint16(o + 2, Endian.little);
        hit = SearchHit('$name ${_numLabel(a, b)}', regions[region], rla, rlo);
      }
    }
  }
  return hit;
}

typedef _Road = (int rank, String name, String region, int start, int count, double la, double lo);

String _numLabel(int a, int b) => b == 0 ? '$a' : '$a-$b';

/// 한 도로의 번지들([recs]: 본번, 부번, 위도, 경도)에서 [num] 찾기.
/// 없으면: 같은 본번 건물 -> 같은 쪽(홀짝) 앞뒤 번지 사이를 번호 비율로 나눈 곳 -> 가장 가까운 번지.
/// 도로명주소 번호는 도로 시작점부터 거리(10 m마다 2씩)로 매겨서 비율로 나누면 대체로 맞음
SearchHit? _houseHit(String title, String region, (int, int) num, List<(int, int, double, double)> recs) {
  if (recs.isEmpty) return null;
  final pre = region.isEmpty ? '' : '$region · ';
  final (m, sub) = num;
  for (final r in recs) {
    if (r.$1 == m && r.$2 == sub) return SearchHit(title, region, r.$3, r.$4);
  }
  final sameMain = recs.where((r) => r.$1 == m).firstOrNull;
  if (sameMain != null) {
    return SearchHit(title, '$pre이 번지는 없어 ${_numLabel(sameMain.$1, sameMain.$2)}번 위치', sameMain.$3, sameMain.$4,
        exact: false);
  }
  (int, int, double, double)? lo, hi;
  for (final r in recs.where((r) => r.$1 % 2 == m % 2)) {
    if (r.$1 < m && (lo == null || r.$1 > lo.$1)) lo = r;
    if (r.$1 > m && (hi == null || r.$1 < hi.$1)) hi = r;
  }
  if (lo != null && hi != null && _distM(lo.$3, lo.$4, hi.$3, hi.$4) < 3000) {
    final t = (m - lo.$1) / (hi.$1 - lo.$1);
    return SearchHit(title, '$pre번지 자료가 없어 ${lo.$1}~${hi.$1}번 사이로 추정', lo.$3 + (hi.$3 - lo.$3) * t,
        lo.$4 + (hi.$4 - lo.$4) * t,
        exact: false);
  }
  final near = lo ?? hi ?? recs.reduce((x, y) => (y.$1 - m).abs() < (x.$1 - m).abs() ? y : x);
  return SearchHit(title, '$pre이 번지는 없어 가까운 ${_numLabel(near.$1, near.$2)}번 위치', near.$3, near.$4, exact: false);
}

/// 이름 바이트 [b][at, at+n)와 검색어 [q] 비교: 같으면 0, 앞부분이 같으면 1, 들어 있으면 2, 아니면 null
int? _match(Uint8List b, int at, int n, Uint8List q) {
  final m = q.length;
  if (m > n) return null;
  bool eqAt(int s) {
    for (var j = 0; j < m; j++) {
      if (b[s + j] != q[j]) return false;
    }
    return true;
  }

  if (eqAt(at)) return m == n ? 0 : 1;
  final first = q[0];
  for (var s = at + 1; s + m <= at + n; s++) {
    if (b[s] == first && eqAt(s)) return 2;
  }
  return null;
}

/// 검색 전용 스레드: 자료를 한 번만 읽어 메모리에 두고 계속 씀 (글자 칠 때마다 파일을 다시 읽으면 화면이 버벅임)
class AddressSearcher {
  static AddressSearcher? _open;
  final String path;
  final SendPort _to;
  AddressSearcher._(this.path, this._to);

  /// [path] 자료로 검색 스레드 준비 (같은 파일이면 있던 것을 다시 씀)
  static Future<AddressSearcher> open(String path) async {
    final o = _open;
    if (o != null && o.path == path) return o;
    o?._to.send(null); // 옛 자료(업데이트 전) 스레드 끝내기
    final ready = ReceivePort();
    await Isolate.spawn(_serve, (path, ready.sendPort));
    final to = await ready.first as SendPort;
    return _open = AddressSearcher._(path, to);
  }

  Future<List<SearchHit>> search(String query, {double? lat, double? lon}) async =>
      await _ask((query, lat, lon)) as List<SearchHit>;

  /// 가장 가까운 도로명주소 (없으면 null)
  Future<SearchHit?> nearest(double lat, double lon) async => await _ask((null, lat, lon)) as SearchHit?;

  /// 가장 가까운 이름 있는 건물·가게 (40 m 안, 없으면 null)
  Future<SearchHit?> nearestPlaceAt(double lat, double lon) async =>
      await _ask((_placeAsk, lat, lon)) as SearchHit?;

  static const _placeAsk = '\u0000place';

  Future<Object?> _ask((String?, double?, double?) q) async {
    final reply = ReceivePort();
    _to.send((q.$1, q.$2, q.$3, reply.sendPort));
    final r = await reply.first;
    if (r is String) throw FormatException(r);
    return r;
  }

  static void _serve((String, SendPort) a) {
    final data = File(a.$1).readAsBytesSync();
    AddressGrid? grid; // 처음 필요할 때 만들어 계속 씀
    AddressGrid g() => grid ??= AddressGrid(data);
    final inbox = ReceivePort();
    a.$2.send(inbox.sendPort);
    inbox.listen((m) {
      if (m == null) return inbox.close();
      final (q, lat, lon, reply) = m as (String?, double?, double?, SendPort);
      try {
        reply.send(switch (q) {
          null => g().nearest(lat!, lon!),
          _placeAsk => nearestPlace(data, lat!, lon!),
          _ => searchIndex(data, q, lat: lat, lon: lon, grid: g()),
        });
      } catch (e) {
        reply.send('$e');
      }
    });
  }
}
