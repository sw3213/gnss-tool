import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gnss_tool/offline_map.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('style uses only bundled fonts and sprite icons', () async {
    const pack = MapPack('kr', '대한민국', 'u', '2026-10-29', [124.5, 33, 132, 38.7], 1);
    final style = jsonDecode(await buildStyle([pack])) as Map<String, dynamic>;
    final text = jsonEncode(style['layers']);

    // 모든 글꼴 이름에 해당하는 글리프 폴더가 있어야 함 (없으면 라벨이 비어 보임)
    final fonts = RegExp(r'NotoSans\w+').allMatches(text).map((m) => m.group(0)!).toSet();
    expect(fonts, isNotEmpty);
    for (final f in fonts) {
      expect(File('assets/map/fonts/$f/0-255.pbf').existsSync(), isTrue, reason: f);
    }
    expect(text.contains('Noto Sans '), isFalse); // 공백 있는 이름이 남으면 asset:// 경로가 깨짐

    // 고정 이름으로 쓰는 아이콘이 아이콘 시트에 있어야 함
    final sprite = jsonDecode(File('assets/map/sprites/light.json').readAsStringSync()) as Map;
    for (final icon in ['bus_stop', 'peak', 'drinking_water', 'arrow', 'townspot']) {
      expect(sprite.containsKey(icon), isTrue, reason: icon);
    }

    // 지도 레이어는 내려받은 지도 소스를 가리키고, 우리 레이어가 들어가 있어야 함
    final ids = [for (final l in style['layers'] as List) (l as Map)['id']];
    expect(ids, containsAll(['m_kr-buildings', 'm_kr-pois', 'm_kr-trails', 'm_kr-peaks', 'm_kr-area-names', 'me']));
    expect(ids.first, 'background');

    // 장소 아이콘이 3단계 일찍 보이도록 바뀌었는지 (원본 스타일 형식이 바뀌면 여기서 잡힘)
    final pois = (style['layers'] as List).cast<Map>().firstWhere((l) => l['id'] == 'm_kr-pois');
    expect(jsonEncode(pois['filter']), contains('["-",["get","min_zoom"],3]'));
  });

  test('terrain layers sit under water and roads, labels on top', () async {
    const base = MapPack('kr', '대한민국', 'u', '2026-10-29', [124.5, 33, 132, 38.7], 1);
    const terrain = MapPack('kr-terrain', '지형', 'u', '2026-10-30', [124.5, 33, 132, 38.7], 1, kind: 'terrain');
    final style = jsonDecode(await buildStyle([base, terrain])) as Map<String, dynamic>;
    final ids = [for (final l in style['layers'] as List) (l as Map)['id'] as String];
    int at(String id) => ids.indexOf(id);
    expect(at('t_kr-terrain-bands'), lessThan(at('m_kr-water')));
    expect(at('t_kr-terrain-contour'), greaterThan(at('m_kr-water')));
    expect(at('t_kr-terrain-contour'), lessThan(at('m_kr-roads_minor')));
    expect(at('t_kr-terrain-contour-label'), greaterThan(at('m_kr-roads_highway')));
    expect((style['sources'] as Map).containsKey('t_kr-terrain'), isTrue);

    // 지형만 있어도 그려짐
    final only = jsonDecode(await buildStyle([terrain])) as Map<String, dynamic>;
    expect([for (final l in only['layers'] as List) (l as Map)['id']], contains('t_kr-terrain-contour'));
  });

  test('building names (apartment dong) sit in the label band', () async {
    const base = MapPack('kr', '대한민국', 'u', '2026-10-29', [124.5, 33, 132, 38.7], 1);
    const names = MapPack('kr-labels', '건물 이름', 'u', '2026-10-30', [124.5, 33, 132, 38.7], 1, kind: 'labels');
    final style = jsonDecode(await buildStyle([base, names])) as Map<String, dynamic>;
    final ids = [for (final l in style['layers'] as List) (l as Map)['id'] as String];
    expect(ids.indexOf('l_kr-labels-dong'), greaterThan(ids.indexOf('m_kr-roads_highway')));
    expect(ids.indexOf('l_kr-labels-dong'), lessThan(ids.indexOf('me')));
    expect((style['sources'] as Map).containsKey('l_kr-labels'), isTrue);

    // 레이어 버튼의 묶음마다 실제 레이어가 하나 이상 걸려야 함
    const terrain = MapPack('kr-terrain', '지형', 'u', '2026-10-30', [124.5, 33, 132, 38.7], 1, kind: 'terrain');
    const shade = MapPack('kr-hillshade', '음영', 'u', '2026-10-30', [124.5, 33, 132, 38.7], 1, kind: 'hillshade');
    final all = jsonDecode(await buildStyle([base, terrain, names, shade])) as Map<String, dynamic>;
    final allIds = [for (final l in all['layers'] as List) (l as Map)['id'] as String];
    for (final g in MapControl.layerGroups) {
      expect(allIds.where((id) => g.suffixes.any(id.endsWith)), isNotEmpty, reason: g.id);
    }
  });

  test('download list merges a country into one card', () {
    MapPack p(String id, String kind) => MapPack(id, id == 'kr' ? '대한민국' : '대한민국 x', 'u', '2026-10-30', const [0, 0, 1, 1], 1, kind: kind);
    final b = bundleCatalog([p('kr-dem', 'dem'), p('kr-labels', 'labels'), p('kr', 'basemap'), p('kr-terrain', 'terrain'), p('jp', 'basemap')]);
    expect(b.length, 2);
    expect([for (final x in b.first) x.kind], ['basemap', 'terrain', 'labels', 'dem']);
    expect(bundleTitle(b.first), '대한민국');
  });

  test('scale bar picks a round length that fits', () {
    // 원주(위도 37.3), 확대 15: dp당 약 1.9 m -> 100 dp 안에 100 m
    final mpp = ScaleBar.metersPerDp(37.3, 15);
    expect(mpp, closeTo(1.9, 0.1));
    expect(ScaleBar.niceLength(mpp), 100);
    expect(ScaleBar.niceLength(ScaleBar.metersPerDp(37.3, 10)), 5000);
  });
}
