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
const placeKinds = ['장소', '산', '역', '학교', '병원', '관공서', '지명', '관광', '공원', '가게', '건물', '주차장', '물', '대피소', '도로'];

/// OSM 태그 -> 장소 종류 번호 (검색에 안 넣을 것은 null)
int? placeKind(Map<String, dynamic> t) {
  String? g(String k) => t[k] as String?;
  final amenity = g('amenity'), tourism = g('tourism'), natural = g('natural');
  if (natural == 'peak' || natural == 'saddle' || natural == 'volcano') return 1;
  if (natural == 'spring' || amenity == 'drinking_water') return 12;
  if (amenity == 'shelter' || tourism == 'alpine_hut' || tourism == 'wilderness_hut') return 13;
  if (g('railway') == 'station' || g('public_transport') == 'station' || g('railway') == 'halt') return 2;
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
  const SearchHit(this.title, this.detail, this.lat, this.lon, {this.exact = true});

  @override
  String toString() => '$title ($detail) $lat,$lon';
}

/// 검색어 나누기: "부산 기장군 정관로 123-4" -> 지역 ["부산", "기장군"], 도로 "정관로", 번지 (123, 4)
({List<String> region, String? road, (int, int)? number}) parseQuery(String q) {
  var t = q.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
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

/// 주소·장소 찾기. [lat]/[lon]은 지금 위치 (가까운 순으로 정렬, 모르면 null)
List<SearchHit> searchAddress(String path, String query, {double? lat, double? lon, int limit = 30}) {
  final f = File(path).openSync();
  try {
    Uint8List read(int off, int len) {
      f.setPositionSync(off);
      return f.readSync(len);
    }

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
    for (final r in local.isEmpty ? roads : local) {
      final num = q.number;
      if (q.road != null && num != null) {
        final rb = _Reader(read(recsOff + r.$4 * 12, r.$5 * 12));
        (int, int, double, double)? exact, near;
        var nearGap = 1 << 30;
        for (var k = 0; k < r.$5; k++) {
          final a = rb.u16(), b = rb.u16(), la = rb.i32() / 1e6, lo = rb.i32() / 1e6;
          if (a == num.$1 && b == num.$2) exact = (a, b, la, lo);
          // 없는 번지: 같은 쪽(홀짝) 가장 가까운 번지
          final gap = (a - num.$1).abs() * 2 + (a % 2 == num.$1 % 2 ? 0 : 1000000) + (b == 0 ? 0 : 1);
          if (gap < nearGap) (nearGap, near) = (gap, (a, b, la, lo));
        }
        final title = '${r.$2} ${num.$1}${num.$2 == 0 ? '' : '-${num.$2}'}';
        if (exact != null) {
          hits.add((0, dist(exact.$3, exact.$4), SearchHit(title, r.$3, exact.$3, exact.$4)));
        } else if (near != null) {
          final nn = '${near.$1}${near.$2 == 0 ? '' : '-${near.$2}'}';
          hits.add((1, dist(near.$3, near.$4),
              SearchHit(title, '${r.$3.isEmpty ? '' : '${r.$3} · '}이 번지는 없어 가까운 $nn번 위치', near.$3, near.$4,
                  exact: false)));
        }
      } else {
        hits.add((2 + r.$1, dist(r.$6, r.$7), SearchHit(r.$2, r.$3.isEmpty ? '도로' : '도로 · ${r.$3}', r.$6, r.$7)));
      }
    }

    // 장소 이름 (번지까지 친 주소면 안 찾음)
    if (q.number == null || q.road == null) {
      final ps = normalizeName(query);
      final pq = Uint8List.fromList(utf8.encode(ps));
      final pb = read(placesOff, f.lengthSync() - placesOff);
      final pr = _Reader(pb);
      for (var i = 0; i < nPlaces; i++) {
        final n = pr.u8(), at = pr.p;
        pr.p += n;
        final kind = pr.u8(), la = pr.i32() / 1e6, lo = pr.i32() / 1e6;
        final rank = _match(pb, at, n, pq);
        if (rank == null) continue;
        final name = utf8.decode(Uint8List.sublistView(pb, at, at + n));
        hits.add((2 + rank, dist(la, lo), SearchHit(name, placeKinds[kind < placeKinds.length ? kind : 0], la, lo)));
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
    return out;
  } finally {
    f.closeSync();
  }
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

/// 별도 스레드에서 찾기 (화면이 멈추지 않게)
Future<List<SearchHit>> searchAddressInBackground(String path, String query, {double? lat, double? lon}) =>
    Isolate.run(() => searchAddress(path, query, lat: lat, lon: lon));
