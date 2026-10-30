// 길찾기 자료(kr-routes.grt) 만들기 (routes.yml에서 실행)
//
// osmium export로 뽑은 길(GeoJSONSeq, 한 줄에 길 하나)을 읽어 걷기용 연결망으로 묶고,
// 고도 격자(kr-dem.gdem)가 있으면 연결마다 오르막·내리막을 미리 계산해 둠. 형식은 lib/routing.dart 참고
//
// 사용법: dart run tool/build_routes.dart ways.geojsons kr-routes.grt [kr-dem.gdem]
import 'dart:convert';
import 'dart:io';

import 'package:gnss_tool/dem.dart';
import 'package:gnss_tool/routing.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('사용법: dart run tool/build_routes.dart ways.geojsons out.grt [dem.gdem]');
    exit(2);
  }
  DemFile? dem;
  if (args.length > 2) {
    dem = DemFile.open(args[2])..maxCache = 4000; // 한국 전체 블록이 약 1000개 -> 모두 메모리에
  }
  final b = RouteGraphBuilder(124.5, 33.0, 132.0, 38.7, elevation: dem?.elevation);
  final counts = List<int>.filled(WayClass.count, 0);
  var skipped = 0;
  final lines = File(args[0]).openRead().transform(utf8.decoder).transform(const LineSplitter());
  await for (var line in lines) {
    line = line.trim();
    if (line.startsWith('\x1e')) line = line.substring(1);
    if (line.isEmpty) continue;
    final f = jsonDecode(line) as Map<String, dynamic>;
    final geom = f['geometry'] as Map<String, dynamic>?;
    final cls = wayClass((f['properties'] as Map<String, dynamic>?) ?? const {});
    if (geom == null || geom['type'] != 'LineString' || cls == null) {
      skipped++;
      continue;
    }
    b.addWay(cls, [for (final c in geom['coordinates'] as List) (c as List).cast<num>()]);
    counts[cls]++;
  }
  stdout.writeln('길 ${b.ways}개 (안 쓰는 길 $skipped개)');
  for (var c = 0; c < WayClass.count; c++) {
    stdout.writeln('  ${classLabel[c]}: ${counts[c]}');
  }
  final (nodes, edges) = b.write(args[1]);
  dem?.close();
  stdout.writeln('갈림길 $nodes개, 연결 $edges개, ${(File(args[1]).lengthSync() / 1e6).toStringAsFixed(1)} MB');
}
