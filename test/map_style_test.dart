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
    expect(ids, containsAll(['m_kr-buildings', 'm_kr-pois', 'm_kr-trails', 'me']));
    expect(ids.first, 'background');
  });
}
