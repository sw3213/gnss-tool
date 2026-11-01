// 길찾기 자료(kr-routes.grt) 만들기 (routes.yml에서 실행)
//
// osmium export로 뽑은 길(GeoJSONSeq, 한 줄에 길 하나)을 읽어 걷기용 연결망으로 묶고,
// 고도 격자(kr-dem.gdem)가 있으면 연결마다 오르막·내리막을 미리 계산해 둠. 형식은 lib/routing.dart 참고
//
// 사용법: dart run tool/build_routes.dart ways.geojsons kr-routes.grt [kr-dem.gdem]
//        dart run tool/build_routes.dart --car ways.geojsons kr-drive.grt   (자동차: 차 길만, 일방통행, 고도 없음)
import 'dart:convert';
import 'dart:io';

import 'package:gnss_tool/dem.dart';
import 'package:gnss_tool/routing.dart';

Future<void> main(List<String> argv) async {
  final car = argv.contains('--car');
  final args = [for (final a in argv) if (a != '--car') a];
  if (args.length < 2) {
    stderr.writeln('사용법: dart run tool/build_routes.dart ways.geojsons out.grt [dem.gdem]');
    exit(2);
  }
  DemFile? dem;
  if (args.length > 2) {
    dem = DemFile.open(args[2])..maxCache = 4000; // 한국 전체 블록이 약 1000개 -> 모두 메모리에
  }
  final b = RouteGraphBuilder(124.5, 33.0, 132.0, 38.7, elevation: dem?.elevation);
  final counts = List<int>.filled(car ? CarClass.count : WayClass.count, 0);
  var skipped = 0, oneway = 0;
  final lines = File(args[0]).openRead().transform(utf8.decoder).transform(const LineSplitter());
  await for (var line in lines) {
    line = line.trim();
    if (line.startsWith('\x1e')) line = line.substring(1);
    if (line.isEmpty) continue;
    final f = jsonDecode(line) as Map<String, dynamic>;
    final geom = f['geometry'] as Map<String, dynamic>?;
    final tags = (f['properties'] as Map<String, dynamic>?) ?? const {};
    final (int, int)? way = car
        ? carWay(tags)
        : switch (wayClass(tags)) { final c? => (c, dirBoth), null => null };
    if (geom == null || geom['type'] != 'LineString' || way == null) {
      skipped++;
      continue;
    }
    final (cls, dir) = way;
    b.addWay(cls, [for (final c in geom['coordinates'] as List) (c as List).cast<num>()], dir: dir);
    counts[cls]++;
    if (dir != dirBoth) oneway++;
  }
  stdout.writeln('길 ${b.ways}개 (안 쓰는 길 $skipped개${car ? ', 일방통행 $oneway개' : ''})');
  for (var c = 0; c < counts.length; c++) {
    stdout.writeln('  ${(car ? carClassLabel : classLabel)[c]}: ${counts[c]}');
  }
  final (nodes, edges) = b.write(args[1], car: car);
  dem?.close();
  stdout.writeln('갈림길 $nodes개, 연결 $edges개, ${(File(args[1]).lengthSync() / 1e6).toStringAsFixed(1)} MB');
}
