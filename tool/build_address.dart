// 주소 검색 자료(kr-addr.gad) 만들기 (address.yml에서 실행)
//
// osmium export로 뽑은 번지·이름 있는 것(GeoJSONSeq, 한 줄에 하나)을 읽어
// 도로명주소(addr:street + addr:housenumber)와 장소 이름을 묶음. 형식은 lib/address.dart 참고.
// 지하철역 출구(railway=subway_entrance)는 500 m 안 가장 가까운 역 이름을 붙여 "강남역 3번 출구"로
//
// 사용법: dart run tool/build_address.dart features.geojsons kr-addr.gad
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:gnss_tool/address.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('사용법: dart run tool/build_address.dart features.geojsons out.gad');
    exit(2);
  }
  final b = AddressIndexBuilder();
  final kinds = List<int>.filled(placeKinds.length, 0);
  var lines = 0, noPoint = 0;
  final stations = <(double, double, String)>[], exits = <(double, double, String)>[];
  final exitNo = RegExp(r'(\d+(?:-\d+)?)');
  final input = File(args[0]).openRead().transform(utf8.decoder).transform(const LineSplitter());
  await for (var line in input) {
    line = line.trim();
    if (line.startsWith('\x1e')) line = line.substring(1);
    if (line.isEmpty) continue;
    lines++;
    final f = jsonDecode(line) as Map<String, dynamic>;
    final t = (f['properties'] as Map<String, dynamic>?) ?? const {};
    final p = representativePoint(f['geometry'] as Map<String, dynamic>?);
    if (p == null) {
      noPoint++;
      continue;
    }
    final (lat, lon) = p;
    final rail = t['railway'];
    if (rail == 'subway_entrance' || rail == 'train_station_entrance') {
      final m = exitNo.firstMatch((t['ref'] ?? t['name'] ?? '').toString());
      if (m != null) exits.add((lat, lon, m.group(1)!));
      continue;
    }
    if ((rail == 'station' || t['public_transport'] == 'station') && (t['name:ko'] ?? t['name']) is String) {
      stations.add((lat, lon, (t['name:ko'] ?? t['name']) as String));
    }
    final street = t['addr:street'] as String?, num = t['addr:housenumber'] as String?;
    if (street != null && num != null) {
      final region = [t['addr:province'], t['addr:city'], t['addr:district']].whereType<String>().join(' ');
      b.addAddress(street, num, region, lat, lon);
    }
    final name = (t['name:ko'] ?? t['name']) as String?;
    final k = name == null ? null : placeKind(t);
    if (name != null && k != null) {
      b.addPlace(name, k, lat, lon);
      kinds[k]++;
    }
  }
  for (final (lat, lon, no) in exits) {
    String? best;
    var bd = 500.0;
    for (final (sla, slo, name) in stations) {
      final d = _distM(lat, lon, sla, slo);
      if (d < bd) (bd, best) = (d, name);
    }
    if (best == null) continue;
    b.addPlace('${best.endsWith('역') ? best : '$best역'} $no번 출구', exitKind, lat, lon);
    kinds[exitKind]++;
  }
  stdout.writeln('읽은 것 $lines개 (위치 없음 $noPoint개), 번지 ${b.addresses}개, 장소 ${b.places}개');
  for (var k = 0; k < placeKinds.length; k++) {
    stdout.writeln('  ${placeKinds[k]}: ${kinds[k]}');
  }
  b.write(args[1]);
  stdout.writeln('${(File(args[1]).lengthSync() / 1e6).toStringAsFixed(1)} MB');
}

/// 대표 위치: 점은 그대로, 선은 가운데 점, 면은 바깥 테두리 점들의 평균
(double, double)? representativePoint(Map<String, dynamic>? g) {
  if (g == null) return null;
  final c = g['coordinates'];
  List<dynamic>? ring;
  switch (g['type']) {
    case 'Point':
      final p = (c as List).cast<num>();
      return (p[1].toDouble(), p[0].toDouble());
    case 'LineString':
      final l = c as List;
      final p = (l[l.length ~/ 2] as List).cast<num>();
      return (p[1].toDouble(), p[0].toDouble());
    case 'Polygon':
      ring = (c as List).first as List;
    case 'MultiPolygon':
      ring = ((c as List).first as List).first as List;
    default:
      return null;
  }
  var la = 0.0, lo = 0.0;
  for (final p in ring) {
    final q = (p as List).cast<num>();
    lo += q[0];
    la += q[1];
  }
  return ring.isEmpty ? null : (la / ring.length, lo / ring.length);
}

double _distM(double la1, double lo1, double la2, double lo2) {
  final x = (lo2 - lo1) * cos((la1 + la2) / 2 * pi / 180), y = la2 - la1;
  return sqrt(x * x + y * y) * 111320;
}
