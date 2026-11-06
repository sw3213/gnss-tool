import 'dart:convert';
import 'dart:math';

// ============================================================
// 대피·안전 시설: 민방위 대피소(maps/build_shelters.py -> kr-shelters.json)와
// 종류별 시설(maps/build_facilities.py -> kr-fac-<종류>.json: 미세먼지쉼터, 무더위쉼터 …)
// 앱은 파일을 한 번 읽어 지도에 종류별 색 점으로 그리고, 내 위치에서 가까운 곳을 찾아 안내함
// 파일: {"date": ..., "cat": 종류, "items": [[이름, 구분, 지하(1/0), 수용인원, 주소, 위도, 경도, (안내)], ...]}
// ============================================================

/// 시설 종류: (id, 이름, 지도 점 색). 민방위 대피소가 'shelter'
const facilityCats = [
  (id: 'shelter', label: '민방위 대피소', color: 0xFF7048E8),
  (id: 'quake', label: '지진옥외 대피장소', color: 0xFFE8590C),
  (id: 'tsunami', label: '지진해일 대피장소', color: 0xFF1971C2),
  (id: 'chemical', label: '화학사고 대피장소', color: 0xFF5C940D),
  (id: 'housing', label: '이재민 임시주거시설', color: 0xFF0B7285),
  (id: 'quake_housing', label: '지진겸용 임시주거시설', color: 0xFFD9480F),
  (id: 'heat', label: '무더위쉼터', color: 0xFFF03E3E),
  (id: 'cold', label: '한파쉼터', color: 0xFF4DABF7),
  (id: 'dust', label: '미세먼지쉼터', color: 0xFF868E96),
  (id: 'water', label: '비상급수시설', color: 0xFF228BE6),
];

String facilityLabel(String cat) => facilityCats.where((c) => c.id == cat).firstOrNull?.label ?? '안전시설';

class Shelter {
  final String name, type, address; // 이름, 구분(공공용시설 등), 도로명주소
  final bool underground;
  final int capacity; // 최대 수용 인원
  final double lat, lon;
  final String cat; // 종류 ([facilityCats]의 id)
  final String info; // 운영시간·전화·급수량 같은 안내 (없으면 빈 글자)
  const Shelter(this.name, this.type, this.underground, this.capacity, this.address, this.lat, this.lon,
      {this.cat = 'shelter', this.info = ''});

  /// "지하 · 공공용시설 · 1,617명"
  String get summary => [
        if (cat == 'shelter' || underground) underground ? '지하' : '지상',
        if (type.isNotEmpty) type,
        if (capacity > 0) '${_comma(capacity)}명',
      ].join(' · ');
}

String _comma(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => ',');

double _distM(double la1, double lo1, double la2, double lo2) {
  final x = (lo2 - lo1) * cos((la1 + la2) / 2 * pi / 180), y = la2 - la1;
  return sqrt(x * x + y * y) * 111320;
}

/// kr-shelters.json / kr-fac-*.json 읽기 (종류는 파일의 "cat", 없으면 민방위 대피소)
List<Shelter> parseShelters(String json) {
  final d = jsonDecode(json) as Map<String, dynamic>;
  final cat = d['cat'] as String? ?? 'shelter';
  return [
    for (final it in (d['items'] as List).cast<List>())
      Shelter(it[0] as String, it[1] as String, it[2] == 1, (it[3] as num).toInt(), it[4] as String,
          (it[5] as num).toDouble(), (it[6] as num).toDouble(),
          cat: cat, info: it.length > 7 ? (it[7] as String? ?? '') : ''),
  ];
}

/// 약 1 km 칸마다 대피소 목록 -> 가까운 것을 빨리 찾음 (전국 약 1만 9천 곳)
class ShelterIndex {
  final List<Shelter> all;
  final _cells = <int, List<int>>{};
  static int _key(int cy, int cx) => cy * 100000 + cx;

  ShelterIndex(this.all) {
    for (var i = 0; i < all.length; i++) {
      _cells.putIfAbsent(_key((all[i].lat * 100).floor(), (all[i].lon * 100).floor()), () => []).add(i);
    }
  }

  /// [lat]/[lon]에서 가까운 대피소 [n]곳 (거리 m와 함께, [maxM] 안에서)
  List<(Shelter, double)> nearest(double lat, double lon, {int n = 5, double maxM = 5000}) {
    final r = (maxM / 1000).ceil() + 1;
    final cy = (lat * 100).floor(), cx = (lon * 100).floor();
    final out = <(Shelter, double)>[];
    for (var dy = -r; dy <= r; dy++) {
      for (var dx = -r; dx <= r; dx++) {
        for (final i in _cells[_key(cy + dy, cx + dx)] ?? const <int>[]) {
          final d = _distM(lat, lon, all[i].lat, all[i].lon);
          if (d <= maxM) out.add((all[i], d));
        }
      }
    }
    out.sort((a, b) => a.$2.compareTo(b.$2));
    return out.take(n).toList();
  }
}

/// 지도 칩 글씨: "대피소 350 m 외 4곳"
String shelterChipLabel(List<(Shelter, double)> near) {
  if (near.isEmpty) return '';
  final d = near.first.$2;
  final dist = d < 1000 ? '${d.round()} m' : '${(d / 1000).toStringAsFixed(1)} km';
  return '대피소 $dist${near.length > 1 ? ' 외 ${near.length - 1}곳' : ''}';
}
