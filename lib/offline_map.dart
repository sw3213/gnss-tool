import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path_provider/path_provider.dart';

import 'main.dart' show GnssSnapshot;
import 'nav.dart';

// ============================================================
// 오프라인 지도: 나라별 .pmtiles 다운로드/관리 + MapLibre 화면
// 지도 데이터 © OpenStreetMap contributors (ODbL) — 화면에 출처 표시 필수
// ============================================================

const _catalogUrl = 'https://github.com/sw3213/gnss-tool/releases/download/maps/catalog.json';

class MapPack {
  final String id, name, url, date;
  final List<double> bbox; // [서, 남, 동, 북]
  final int size; // bytes
  final String kind; // basemap = 기본 지도, terrain = 등고선·고도 색칠 (기본 지도 위에 겹침)
  const MapPack(this.id, this.name, this.url, this.date, this.bbox, this.size, {this.kind = 'basemap'});

  bool get isTerrain => kind == 'terrain';

  factory MapPack.fromJson(Map<String, dynamic> j) => MapPack(
        j['id'] as String,
        j['name'] as String,
        j['url'] as String,
        j['date'] as String,
        [for (final v in j['bbox'] as List) (v as num).toDouble()],
        (j['size'] as num).toInt(),
        kind: j['kind'] as String? ?? 'basemap',
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'url': url, 'date': date, 'bbox': bbox, 'size': size, 'kind': kind};

  LatLng get center => LatLng((bbox[1] + bbox[3]) / 2, (bbox[0] + bbox[2]) / 2);
}

String formatBytes(int b) =>
    b >= 1 << 30 ? '${(b / (1 << 30)).toStringAsFixed(1)} GB' : '${(b / (1 << 20)).toStringAsFixed(0)} MB';

/// 내려받은 지도 목록. 정보는 앱 내부 저장소 maps/<id>.json, 지도 파일 경로는 그 안의 'path'
/// (다운로드 관리자는 앱 전용 외부 저장소에 받음. 예전 방식으로 받은 지도는 내부 maps/<id>.pmtiles)
class MapStore {
  MapStore._();
  static final instance = MapStore._();

  static const _dl = MethodChannel('gnss_tool/download');

  final installed = ValueNotifier<List<MapPack>>([]);
  final progress = ValueNotifier<Map<String, DlState>>({}); // 다운로드 중인 지도
  final failures = ValueNotifier<Map<String, String>>({}); // 실패 안내
  final _files = <String, String>{}; // id -> .pmtiles 경로
  Timer? _poll;
  Directory? _dir;

  Future<Directory> _maps() async {
    final d = _dir ??= Directory('${(await getApplicationSupportDirectory()).path}/maps');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  String? fileOf(String id) => _files[id];

  // 안전 모드: 지도가 화면에 떠 있는 동안 표시 파일을 둠. 표시 파일이 남아 있고 직전 종료가
  // 크래시였을 때만 지도를 바로 열지 않음 (켜자마자 다시 죽는 반복 방지).
  // 업데이트 설치·앱 닫기처럼 정상 종료로 남은 표시 파일은 그냥 지움
  Future<File> _openFlag() async => File('${(await _maps()).parent.path}/map_open.flag');
  Future<bool> crashedWhileMapOpen() async {
    final f = await _openFlag();
    if (!f.existsSync()) return false;
    bool crashed;
    try {
      crashed = await const MethodChannel('gnss_tool/diag').invokeMethod<bool>('lastExitWasCrash') ?? false;
    } catch (_) {
      crashed = false;
    }
    if (!crashed) f.deleteSync();
    return crashed;
  }
  Future<void> markMapOpen(bool open) async {
    final f = await _openFlag();
    if (open) {
      f.writeAsStringSync(DateTime.now().toIso8601String());
    } else if (f.existsSync()) {
      f.deleteSync();
    }
  }

  /// 받은 지도 목록을 읽고, 앱이 꺼져 있는 동안 끝난 다운로드가 있으면 마무리
  Future<void> load() async {
    await _loadInstalled();
    await _checkPending();
    if (progress.value.isNotEmpty) {
      _poll ??= Timer.periodic(const Duration(seconds: 1), (_) => _checkPending());
    }
  }

  Future<void> _loadInstalled() async {
    final d = await _maps();
    final list = <MapPack>[];
    _files.clear();
    for (final f in d.listSync().whereType<File>()) {
      if (!f.path.endsWith('.json') || f.path.endsWith('.pending.json')) continue;
      try {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final p = MapPack.fromJson(j);
        final path = j['path'] as String? ?? '${d.path}/${p.id}.pmtiles';
        if (File(path).existsSync()) {
          list.add(p);
          _files[p.id] = path;
        }
      } catch (_) {}
    }
    installed.value = list;
  }

  Future<List<MapPack>> fetchCatalog() async {
    final res = await http.get(Uri.parse(_catalogUrl)).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    // GitHub Release 파일은 charset 없이 와서 res.body가 Latin-1로 읽힘 -> 한글 깨짐. UTF-8로 직접 해석
    final list = jsonDecode(utf8.decode(res.bodyBytes)) as List;
    return [for (final j in list) MapPack.fromJson(j as Map<String, dynamic>)];
  }

  // ---------- 다운로드: 안드로이드 다운로드 관리자 (MainActivity.kt) ----------
  // 진행 중인 다운로드는 <id>.pending.json에 기록 -> 앱을 닫았다 열어도 이어서 확인·마무리

  File _pendingFile(Directory d, String id) => File('${d.path}/$id.pending.json');

  Future<void> download(MapPack p, {required bool wifiOnly}) async {
    final d = await _maps();
    failures.value = {...failures.value}..remove(p.id);
    final dlId = await _dl.invokeMethod<int>('start', {
      'url': p.url,
      'title': '${p.name} 지도',
      'file': '${p.id}-${p.date}.pmtiles', // 날짜를 넣어 업데이트 중에도 기존 지도와 안 겹침
      'wifiOnly': wifiOnly,
    });
    _pendingFile(d, p.id).writeAsStringSync(jsonEncode({'download': dlId, 'pack': p.toJson()}));
    progress.value = {...progress.value, p.id: const DlState(null, '대기 중')};
    _poll ??= Timer.periodic(const Duration(seconds: 1), (_) => _checkPending());
  }

  Future<void> cancel(String id) async {
    final f = _pendingFile(await _maps(), id);
    if (f.existsSync()) {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      await _dl.invokeMethod<int>('remove', {'id': j['download']}); // 받던 파일도 함께 지워짐
      f.deleteSync();
    }
    progress.value = {...progress.value}..remove(id);
  }

  Future<void> _checkPending() async {
    final d = await _maps();
    final pending = d.listSync().whereType<File>().where((f) => f.path.endsWith('.pending.json')).toList();
    var changed = false;
    for (final f in pending) {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final p = MapPack.fromJson(j['pack'] as Map<String, dynamic>);
      final q = await _dl.invokeMapMethod<String, dynamic>('query', {'id': j['download']});
      if (q == null) {
        // 사용자가 시스템 다운로드 목록에서 지움
        f.deleteSync();
        progress.value = {...progress.value}..remove(p.id);
        continue;
      }
      final status = q['status'] as int, reason = q['reason'] as int;
      final done = (q['done'] as num).toInt();
      final total = (q['total'] as num).toInt() > 0 ? (q['total'] as num).toInt() : p.size;
      if (status == 8) {
        // 성공: 정보 파일에 실제 경로를 기록하고, 예전 버전 지도 파일은 정리
        final path = Uri.parse(q['uri'] as String).toFilePath();
        final old = _files[p.id];
        if (old != null && old != path && File(old).existsSync()) File(old).deleteSync();
        File('${d.path}/${p.id}.json').writeAsStringSync(jsonEncode({...p.toJson(), 'path': path}));
        f.deleteSync();
        progress.value = {...progress.value}..remove(p.id);
        changed = true;
      } else if (status == 16) {
        f.deleteSync();
        await _dl.invokeMethod<int>('remove', {'id': j['download']});
        progress.value = {...progress.value}..remove(p.id);
        failures.value = {
          ...failures.value,
          p.id: reason == 1006 ? '저장 공간이 부족해 실패했습니다' : '다운로드 실패 (코드 $reason). 다시 시도해 주세요',
        };
      } else {
        final pct = (done * 100 / total).floor();
        final text = switch (status) {
          2 => '다운로드 중 $pct%  (${formatBytes(done)} / ${formatBytes(total)})',
          4 => switch (reason) {
              1 => '연결이 끊겨 잠시 후 이어받습니다 ($pct%)',
              2 => '네트워크 연결을 기다리는 중 ($pct%)',
              3 => 'Wi-Fi 연결을 기다리는 중 ($pct%)',
              _ => '일시 정지됨 ($pct%)',
            },
          _ => '대기 중',
        };
        progress.value = {...progress.value, p.id: DlState(status == 1 ? null : done / total, text)};
      }
    }
    if (changed) await _loadInstalled();
    if (pending.isEmpty) {
      _poll?.cancel();
      _poll = null;
    }
  }

  Future<void> delete(String id) async {
    final d = await _maps();
    final path = _files[id];
    if (path != null && File(path).existsSync()) File(path).deleteSync();
    final info = File('${d.path}/$id.json');
    if (info.existsSync()) info.deleteSync();
    await _loadInstalled();
  }
}

/// 다운로드 진행 표시: [fraction]이 null이면 진행률 모름(대기 중)
class DlState {
  final double? fraction;
  final String text;
  const DlState(this.fraction, this.text);
}


// ---------------- 지도 스타일 ----------------
// 바탕은 Protomaps 공식 밝은 테마(assets/map/style-light.json, maps/gen-style.mjs로 생성, 한국어 라벨):
// 건물·번지·아이콘(버스 정류장, 식수대, 봉우리…)·도로 번호판 포함. 여기에 등산로 강조와 건물 이름을 더함.
// 한글 등 CJK 글자는 MapLibre가 폰 기본 글꼴로 그림 -> 라틴/숫자 글리프만 앱에 포함

Future<String> buildStyle(List<MapPack> packs) async {
  var raw = await rootBundle.loadString('assets/map/style-light.json');
  // asset:// 경로에 공백이 들어가지 않도록 글꼴 이름을 앱 폴더 이름에 맞춤.
  // 힌디어 등 데바나가리 문자 전용 글꼴은 한국 지도에 필요 없어 일반 글꼴로 대체
  raw = raw.replaceAll('Noto Sans Devanagari Regular v1', 'NotoSansRegular');
  for (final w in ['Regular', 'Medium', 'Italic']) {
    raw = raw.replaceAll('Noto Sans $w', 'NotoSans$w');
  }
  final base = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();

  const empty = {'type': 'FeatureCollection', 'features': <dynamic>[]};
  final sources = <String, dynamic>{
    for (final id in ['me', 'track', 'wpts', 'water', 'target', 'route']) id: {'type': 'geojson', 'data': empty},
  };
  final layers = <Map<String, dynamic>>[
    for (final l in base)
      if (l['source'] == null) l, // 배경
  ];

  // 지형(등고선·고도 색칠) 레이어: 기본 지도 사이사이에 끼워 넣음
  final terrain = [for (final p in packs) if (p.isTerrain) p];
  for (final p in terrain) {
    sources['t_${p.id}'] = {
      'type': 'vector',
      'url': 'pmtiles://file://${MapStore.instance.fileOf(p.id)}',
      'attribution': '© Copernicus DEM (ESA)',
    };
  }
  final bands = [for (final p in terrain) ..._bandLayers('t_${p.id}')];
  final contours = [for (final p in terrain) ..._contourLayers('t_${p.id}')];
  final contourLabels = [for (final p in terrain) ..._contourLabelLayers('t_${p.id}')];

  // 건물 이름(아파트 동 번호): 기본 지도에 빠져 있어 labels.yml이 따로 만든 지도
  final names = [for (final p in packs) if (p.kind == 'labels') p];
  for (final p in names) {
    sources['l_${p.id}'] = {
      'type': 'vector',
      'url': 'pmtiles://file://${MapStore.instance.fileOf(p.id)}',
      'attribution': '© OpenStreetMap contributors',
    };
  }
  final nameLayers = [for (final p in names) ..._buildingNameLayers('l_${p.id}')];

  // 지형 음영(산 그림자): hillshade.yml이 만든 고도 타일. 고도 색칠 위, 등고선과 같은 높이에 그림
  final shades = [for (final p in packs) if (p.kind == 'hillshade') p];
  for (final p in shades) {
    sources['h_${p.id}'] = {
      'type': 'raster-dem',
      'url': 'pmtiles://file://${MapStore.instance.fileOf(p.id)}',
      'encoding': 'terrarium',
      'tileSize': 256,
      'attribution': '© Copernicus DEM (ESA)',
    };
  }
  contours.insertAll(0, [for (final p in shades) ..._hillshadeLayers('h_${p.id}')]);
  var placed = false;

  for (final p in packs.where((p) => p.kind == 'basemap')) {
    final s = 'm_${p.id}';
    sources[s] = {
      'type': 'vector',
      'url': 'pmtiles://file://${MapStore.instance.fileOf(p.id)}',
      'attribution': '© OpenStreetMap contributors',
    };
    for (final l in base) {
      if (l['source'] == null) continue;
      if (!placed) {
        // 고도 색칠은 물 아래(바다·호수가 덮도록), 등고선은 도로 아래, 등고선 숫자는 라벨층
        if (l['id'] == 'water') layers.addAll(bands);
        if (l['id'] == 'roads_tunnels_other_casing') layers.addAll(contours);
        if (l['id'] == 'address_label') layers.addAll([...contourLabels, ...nameLayers]);
      }
      // 라벨(번지) 바로 앞에 우리 레이어를 끼워 넣어 도로 위, 글자 아래에 그려지게 함
      if (l['id'] == 'address_label') layers.addAll(_extraLayers(s));
      layers.add(_tweak({...l, 'id': '$s-${l['id']}', 'source': s}, l['id'] as String));
      if (l['id'] == 'buildings') layers.add(_buildings3d(s)); // 3D 버튼을 누르면 보임
    }
    placed = true;
  }
  if (!placed) layers.addAll([...bands, ...contours, ...contourLabels, ...nameLayers]); // 기본 지도 없이 받은 경우
  layers.addAll([for (final p in names) ..._complexNameLayers('l_${p.id}')]);
  layers.addAll(_meLayers);

  return jsonEncode({
    'version': 8,
    'name': 'gnss-offline',
    'glyphs': 'asset://flutter_assets/assets/map/fonts/{fontstack}/{range}.pbf',
    'sprite': 'asset://flutter_assets/assets/map/sprites/light',
    'sources': sources,
    'layers': layers,
  });
}

// ---------------- 지형: 고도 색칠 + 등고선 (terrain.yml이 만든 bands / contour 레이어) ----------------

/// 고도 구역 색: 낮은 곳 초록 -> 노랑 -> 주황 -> 갈색 (등산 지도의 고도 단채식)
const _bandColor = [
  'step', ['get', 'amin'], //
  '#a9d18e', 100, '#bfdb92', 200, '#d4e297', 300, '#e6e69c', 400, '#efdf9a', 500, '#f1d18c', //
  600, '#ebbf80', 800, '#e0a975', 1000, '#d3946e', 1200, '#c4836a', 1500, '#b37868', 1800, '#a37069',
];

List<Map<String, dynamic>> _bandLayers(String s) => [
      {
        'id': '$s-bands',
        'type': 'fill',
        'source': s,
        'source-layer': 'bands',
        'paint': {
          'fill-color': _bandColor,
          'fill-opacity': ['interpolate', ['linear'], ['zoom'], 6, 0.75, 14, 0.55],
          'fill-antialias': false, // 구역 경계에 실선이 보이지 않게
        },
      },
    ];

// 100 m마다 굵고 진한 주곡선, 20 m 간격은 가는 선
const _isIndex = ['==', ['%', ['get', 'ele'], 100], 0];

List<Map<String, dynamic>> _contourLayers(String s) => [
      {
        'id': '$s-contour',
        'type': 'line',
        'source': s,
        'source-layer': 'contour',
        'filter': ['>', ['get', 'ele'], 0],
        'paint': {
          'line-color': ['case', _isIndex, '#8a5a2e', '#a8794c'],
          'line-opacity': ['case', _isIndex, 0.75, 0.45],
          'line-width': [
            'interpolate', ['linear'], ['zoom'], //
            10, ['case', _isIndex, 0.6, 0.3],
            14, ['case', _isIndex, 1.3, 0.6],
            17, ['case', _isIndex, 2.0, 1.0],
          ],
        },
      },
    ];

List<Map<String, dynamic>> _contourLabelLayers(String s) => [
      {
        'id': '$s-contour-label',
        'type': 'symbol',
        'source': s,
        'source-layer': 'contour',
        'minzoom': 13,
        'filter': ['all', ['>', ['get', 'ele'], 0], _isIndex],
        'layout': {
          'symbol-placement': 'line',
          'text-field': ['to-string', ['get', 'ele']],
          'text-font': ['NotoSansRegular'],
          'text-size': 10,
          'symbol-spacing': 350,
        },
        'paint': {'text-color': '#7a4f28', 'text-halo-color': '#ffffff', 'text-halo-width': 1.2},
      },
    ];

/// 산 그림자: 북서쪽 빛 기준. 고도 색칠·등고선과 겹쳐 입체감을 줌
List<Map<String, dynamic>> _hillshadeLayers(String s) => [
      {
        'id': '$s-hillshade',
        'type': 'hillshade',
        'source': s,
        'paint': {
          'hillshade-exaggeration': ['interpolate', ['linear'], ['zoom'], 6, 0.45, 12, 0.6, 16, 0.4],
          'hillshade-shadow-color': '#3b3020',
          'hillshade-highlight-color': '#fffdf5',
          'hillshade-accent-color': '#5a4a32',
        },
      },
    ];

/// 3D 건물: 기울여 볼 때만 켬 (MapControl.toggleTilt). 높이 정보가 없는 건물은 2층(6 m)으로
Map<String, dynamic> _buildings3d(String s) => {
      'id': '$s-buildings-3d',
      'type': 'fill-extrusion',
      'source': s,
      'source-layer': 'buildings',
      'minzoom': 14,
      'filter': ['==', ['get', 'kind'], 'building'],
      'layout': {'visibility': 'none'},
      'paint': {
        'fill-extrusion-color': '#d8d0c8',
        'fill-extrusion-height': ['coalesce', ['get', 'height'], 6],
        'fill-extrusion-base': ['coalesce', ['get', 'min_height'], 0],
        'fill-extrusion-opacity': 0.85,
      },
    };

// ---------------- 건물 이름 (labels.yml이 만든 bldg 레이어: name, short, dong) ----------------

const _isDong = ['==', ['get', 'dong'], 1];

/// 아파트 단지 이름("구곡현대2차아파트"): 단지 부지 가운데에 넓은 자간의 회색 글씨.
/// 다른 라벨(동 번호·번지·가게)보다 먼저 자리를 잡도록 모든 지도 레이어 뒤(위)에 둠 — MapLibre는 위 레이어부터 배치.
/// 가운데가 막히면 위·아래·옆으로 조금 비켜서라도 표시
List<Map<String, dynamic>> _complexNameLayers(String s) => [
      {
        'id': '$s-complex',
        'type': 'symbol',
        'source': s,
        'source-layer': 'bldg',
        'minzoom': 14,
        'filter': ['==', ['get', 'kind'], 'complex'],
        'layout': {
          'text-field': ['get', 'name'],
          'text-font': ['NotoSansMedium'],
          'text-size': ['interpolate', ['linear'], ['zoom'], 14, 10, 17, 14],
          'text-letter-spacing': 0.15,
          'text-max-width': 12,
          'text-padding': 1,
          'text-variable-anchor': ['center', 'top', 'bottom', 'left', 'right'],
          'text-radial-offset': 0.8,
        },
        'paint': {'text-color': '#6f6a64', 'text-halo-color': '#ffffff', 'text-halo-width': 1.4},
      },
    ];

/// 건물은 확대 15~16에서 "101동"만 굵게, 17부터는 "잠실엘스 101동" 전체 이름. 동 번호를 다른 건물 이름보다 먼저 자리 잡게 함
List<Map<String, dynamic>> _buildingNameLayers(String s) => [
      {
        'id': '$s-dong',
        'type': 'symbol',
        'source': s,
        'source-layer': 'bldg',
        'minzoom': 15,
        'filter': ['!=', ['get', 'kind'], 'complex'],
        'layout': {
          'text-field': ['step', ['zoom'], ['get', 'short'], 17, ['get', 'name']],
          'text-font': ['NotoSansMedium'],
          'text-size': [
            'interpolate', ['linear'], ['zoom'], //
            15, ['case', _isDong, 11.5, 10],
            18, ['case', _isDong, 15, 12],
          ],
          'symbol-sort-key': ['case', _isDong, 0, 1],
          'text-padding': 1,
          'text-max-width': 7,
        },
        'paint': {
          'text-color': ['case', _isDong, '#3d2f22', '#6b6258'],
          'text-halo-color': '#ffffff',
          'text-halo-width': 1.6,
        },
      },
    ];

/// 기본 스타일은 꽤 확대해야 정보가 보임 -> MAPS.ME처럼 덜 확대해도 보이게 조정
Map<String, dynamic> _tweak(Map<String, dynamic> l, String id) {
  switch (id) {
    case 'pois':
      // 장소마다 "이 확대 단계부터 보임"(min_zoom)이 있음. 2단계 일찍 보이게 하고,
      // 봉우리는 높이를 함께 보여 주는 별도 레이어(peaks)로 그림
      final f = jsonEncode(l['filter']).replaceAll('["+",["get","min_zoom"],0]', '["-",["get","min_zoom"],3]');
      return {
        ...l,
        'filter': [
          'all',
          jsonDecode(f),
          ['!=', ['get', 'kind'], 'peak'],
        ],
        'layout': {
          ...(l['layout'] as Map<String, dynamic>),
          'text-size': ['interpolate', ['linear'], ['zoom'], 14, 10, 17, 11, 19, 16],
        },
      };
    case 'address_label':
      return {...l, 'minzoom': 16}; // 번지: 18 -> 16
    case 'roads_labels_minor':
      return {...l, 'minzoom': 13}; // 골목 이름: 15 -> 13
    case 'water_stream':
      return {...l, 'minzoom': 11}; // 계곡·개울: 14 -> 11 (산에서 가장 중요한 지형지물)
    case 'water_waterway_label':
      return {...l, 'minzoom': 12}; // 하천·계곡 이름: 13 -> 12
    case 'roads_minor_service_casing' || 'roads_link_casing':
      return {...l, 'minzoom': 12};
  }
  return l;
}

List<Map<String, dynamic>> _extraLayers(String s) => [
      // 등산로·오솔길: MAPS.ME처럼 붉은 갈색 점선으로 잘 보이게 (기본 스타일은 흐린 회색)
      {
        'id': '$s-trails',
        'type': 'line',
        'source': s,
        'source-layer': 'roads',
        'minzoom': 11,
        'filter': [
          'in',
          ['get', 'kind_detail'],
          ['literal', ['path', 'footway', 'track', 'bridleway', 'steps']],
        ],
        'paint': {
          'line-color': '#b5562f',
          'line-width': ['interpolate', ['linear'], ['zoom'], 12, 0.8, 17, 2.4],
          'line-dasharray': [2, 1.2],
        },
      },
      // 학교·공원 등 구역 이름 (아파트 단지 이름은 건물 이름 지도의 complex가 그림)
      {
        'id': '$s-area-names',
        'type': 'symbol',
        'source': s,
        'source-layer': 'landuse',
        'minzoom': 13,
        'filter': [
          'all',
          ['has', 'name'],
          [
            'in',
            ['get', 'kind'],
            ['literal', ['school', 'university', 'college', 'hospital', 'park', 'cemetery', 'military', 'industrial', 'commercial']],
          ],
        ],
        'layout': {
          'text-field': ['coalesce', ['get', 'name:ko'], ['get', 'name']],
          'text-font': ['NotoSansRegular'],
          'text-size': ['interpolate', ['linear'], ['zoom'], 14, 10, 17, 12],
          'text-max-width': 8,
        },
        'paint': {'text-color': '#8a8076', 'text-halo-color': '#ffffff', 'text-halo-width': 1},
      },
      // 산봉우리: ▲ 아이콘 + 이름 + 높이 (MAPS.ME "231 m 옥녀봉")
      {
        'id': '$s-peaks',
        'type': 'symbol',
        'source': s,
        'source-layer': 'pois',
        'minzoom': 10,
        'filter': ['==', ['get', 'kind'], 'peak'],
        'layout': {
          'icon-image': 'peak',
          'text-field': [
            'case',
            ['any', ['has', 'elevation'], ['has', 'ele']],
            [
              'concat',
              ['coalesce', ['get', 'name:ko'], ['get', 'name'], ''],
              '\n',
              ['to-string', ['round', ['to-number', ['coalesce', ['get', 'elevation'], ['get', 'ele']]]]],
              ' m',
            ],
            ['coalesce', ['get', 'name:ko'], ['get', 'name'], ''],
          ],
          'text-font': ['NotoSansRegular'],
          'text-size': 11,
          'text-anchor': 'top',
          'text-offset': [0, 0.9],
        },
        'paint': {'text-color': '#4d4a3a', 'text-halo-color': '#ffffff', 'text-halo-width': 1.2},
      },
    ];

// 이동 기록 선, 가까운 수원지, 저장한 지점, 내 위치 (맨 위)
const _meLayers = [
  {
    'id': 'water-pt',
    'type': 'circle',
    'source': 'water',
    'paint': {
      'circle-radius': 9,
      'circle-color': ['case', ['get', 'e'], '#e8590c', '#1c7ed6'], // 긴급 수원지는 주황
      'circle-stroke-color': '#ffffff',
      'circle-stroke-width': 2,
    },
  },
  {
    'id': 'water-num',
    'type': 'symbol',
    'source': 'water',
    'layout': {
      'text-field': ['get', 'n'],
      'text-font': ['NotoSansMedium'],
      'text-size': 11,
      'text-allow-overlap': true,
    },
    'paint': {'text-color': '#ffffff'},
  },
  // 따라가는 GPX 경로: 굵은 보라색 (내 이동 기록보다 아래)
  {
    'id': 'route-line',
    'type': 'line',
    'source': 'route',
    'layout': {'line-cap': 'round', 'line-join': 'round'},
    'paint': {'line-color': '#7048e8', 'line-width': 6, 'line-opacity': 0.75},
  },
  {
    'id': 'track',
    'type': 'line',
    'source': 'track',
    'layout': {'line-cap': 'round', 'line-join': 'round'},
    'paint': {'line-color': '#f76707', 'line-width': 4, 'line-opacity': 0.9},
  },
  // 목표 지점 안내: 내 위치 -> 목표 빨간 점선 + 깃발 점·이름
  {
    'id': 'target-line',
    'type': 'line',
    'source': 'target',
    'filter': ['==', ['geometry-type'], 'LineString'],
    'layout': {'line-cap': 'round'},
    'paint': {'line-color': '#e03131', 'line-width': 3, 'line-dasharray': [1.5, 1.5], 'line-opacity': 0.85},
  },
  {
    'id': 'target-pt',
    'type': 'circle',
    'source': 'target',
    'filter': ['==', ['geometry-type'], 'Point'],
    'paint': {
      'circle-radius': 8,
      'circle-color': '#e03131',
      'circle-stroke-color': '#ffffff',
      'circle-stroke-width': 3,
    },
  },
  {
    'id': 'target-label',
    'type': 'symbol',
    'source': 'target',
    'filter': ['==', ['geometry-type'], 'Point'],
    'layout': {
      'text-field': ['get', 'name'],
      'text-font': ['NotoSansMedium'],
      'text-size': 13,
      'text-offset': [0, 1.3],
      'text-anchor': 'top',
      'text-allow-overlap': true,
    },
    'paint': {'text-color': '#c92a2a', 'text-halo-color': '#ffffff', 'text-halo-width': 1.6},
  },
  {
    'id': 'wpts',
    'type': 'circle',
    'source': 'wpts',
    'paint': {
      'circle-radius': 6,
      'circle-color': '#e8590c',
      'circle-stroke-color': '#ffffff',
      'circle-stroke-width': 2,
    },
  },
  {
    'id': 'wpts-label',
    'type': 'symbol',
    'source': 'wpts',
    'layout': {
      'text-field': ['get', 'name'],
      'text-font': ['NotoSansMedium'],
      'text-size': 12,
      'text-anchor': 'top',
      'text-offset': [0, 0.8],
      'text-allow-overlap': true,
    },
    'paint': {'text-color': '#c2410c', 'text-halo-color': '#ffffff', 'text-halo-width': 1.5},
  },
  {
    'id': 'me-acc',
    'type': 'circle',
    'source': 'me',
    'paint': {'circle-radius': 18, 'circle-color': '#3b6cf6', 'circle-opacity': 0.15},
  },
  {
    'id': 'me',
    'type': 'circle',
    'source': 'me',
    'paint': {
      'circle-radius': 7,
      'circle-color': '#3b6cf6',
      'circle-stroke-color': '#ffffff',
      'circle-stroke-width': 2,
    },
  },
];

// ---------------- 지도 화면 ----------------

CameraPosition? _lastCamera; // 다른 화면에 다녀와도 보던 위치 유지

/// 메인 화면의 버튼들(내 위치, 나침반, 3D)이 지도를 조작하고, 이동 기록·저장한 지점을 지도에 그리는 손잡이
class MapControl {
  MapLibreMapController? _ctl;
  bool _ready = false;
  final camera = ValueNotifier<CameraPosition?>(_lastCamera);
  final follow = ValueNotifier<bool>(true); // 내 위치 따라가기 (지도를 손으로 움직이면 해제)
  final headingUp = ValueNotifier<bool>(false); // 진행 방향이 위로 오게 지도 회전
  final tilted = ValueNotifier<bool>(false); // 3D (기울여 보기)
  Map<String, dynamic> _track = _emptyFc, _wpts = _emptyFc, _water = _emptyFc;

  static const _emptyFc = <String, dynamic>{'type': 'FeatureCollection', 'features': <dynamic>[]};

  /// 지도를 길게 눌렀을 때 (메인 화면이 "여기로 안내 / 지점 저장" 메뉴를 띄움)
  void Function(double lat, double lon)? onLongPress;

  // ---- 목표 지점 안내 선 ----
  NavTarget? _target;
  (double, double)? _me;

  void setTarget(NavTarget? t) {
    _target = t;
    _drawTarget();
  }

  void _drawTarget() {
    final t = _target, me = _me;
    if (!_ready) return;
    _ctl?.setGeoJsonSource('target', {
      'type': 'FeatureCollection',
      'features': [
        if (t != null && me != null)
          {
            'type': 'Feature',
            'geometry': {
              'type': 'LineString',
              'coordinates': [
                [me.$2, me.$1],
                [t.lon, t.lat]
              ],
            },
            'properties': <String, dynamic>{},
          },
        if (t != null)
          {
            'type': 'Feature',
            'geometry': {'type': 'Point', 'coordinates': [t.lon, t.lat]},
            'properties': {'name': t.name},
          },
      ],
    });
  }

  void _attach(MapLibreMapController c) {
    _ctl = c;
    _ready = false;
  }

  void _styleLoaded() {
    _ready = true;
    if (tilted.value) _show3dBuildings();
    _ctl?.setGeoJsonSource('track', _track);
    _ctl?.setGeoJsonSource('wpts', _wpts);
    _ctl?.setGeoJsonSource('water', _water);
    _drawTarget();
    _ctl?.setGeoJsonSource('route', _route);
    for (final g in layerGroups) {
      if (hidden.value.contains(g.id)) _applyGroup(g, false);
    }
  }

  /// 3D 건물은 기울여 볼 때만 (위에서 볼 때는 평면 건물과 같아 보이고 그리기만 무거움)
  void _show3dBuildings() {
    for (final id in _layerIds) {
      if (id.endsWith('-buildings-3d')) _ctl?.setLayerVisibility(id, tilted.value);
    }
  }

  // ---- 레이어 켜고 끄기 (레이어 버튼). 끈 목록은 map_layers.json에 저장 ----

  /// 스타일의 레이어 id 끝부분([suffixes])으로 묶음
  static const layerGroups = [
    (id: 'contour', label: '등고선', icon: Icons.terrain_outlined, suffixes: ['-contour', '-contour-label']),
    (id: 'bands', label: '고도 색칠', icon: Icons.gradient, suffixes: ['-bands']),
    (id: 'hillshade', label: '산 그림자 (입체 음영)', icon: Icons.landscape_outlined, suffixes: ['-hillshade']),
    (id: 'trails', label: '등산로 강조', icon: Icons.hiking, suffixes: ['-trails']),
    (id: 'pois', label: '장소 아이콘', icon: Icons.place_outlined, suffixes: ['-pois']),
    (id: 'dong', label: '건물·아파트 이름', icon: Icons.apartment, suffixes: ['-dong', '-complex']),
    (id: 'water', label: '수원지 번호', icon: Icons.water_drop_outlined, suffixes: ['water-pt', 'water-num']),
  ];

  final hidden = ValueNotifier<Set<String>>({});
  List<String> _layerIds = []; // 지금 스타일의 레이어 id (MapPage가 채움)

  MapControl() {
    _layersFile().then((f) {
      if (!f.existsSync()) return;
      try {
        hidden.value = {for (final v in jsonDecode(f.readAsStringSync()) as List) v as String};
        if (_ready) _styleLoaded();
      } catch (_) {}
    }).catchError((Object _) {});
  }

  static Future<File> _layersFile() async => File('${(await getApplicationSupportDirectory()).path}/map_layers.json');

  void _applyGroup(({String id, String label, IconData icon, List<String> suffixes}) g, bool shown) {
    for (final id in _layerIds) {
      if (g.suffixes.any(id.endsWith)) _ctl?.setLayerVisibility(id, shown);
    }
  }

  Future<void> setLayerShown(String group, bool shown) async {
    hidden.value = shown ? ({...hidden.value}..remove(group)) : {...hidden.value, group};
    if (_ready) _applyGroup(layerGroups.firstWhere((g) => g.id == group), shown);
    (await _layersFile()).writeAsStringSync(jsonEncode(hidden.value.toList()));
  }

  /// 가까운 수원지를 1~5 번호 붙은 점으로 (기본 파랑, 긴급 주황)
  void setWater(List<({double lat, double lon, bool emergency})> pts) {
    _water = {
      'type': 'FeatureCollection',
      'features': [
        for (var i = 0; i < pts.length; i++)
          {
            'type': 'Feature',
            'geometry': {'type': 'Point', 'coordinates': [pts[i].lon, pts[i].lat]},
            'properties': {'n': '${i + 1}', 'e': pts[i].emergency},
          }
      ],
    };
    if (_ready) _ctl?.setGeoJsonSource('water', _water);
  }

  void recenter(double lat, double lon) {
    follow.value = true;
    _ctl?.animateCamera(CameraUpdate.newLatLngZoom(LatLng(lat, lon), math.max(camera.value?.zoom ?? 15, 15)));
  }

  /// 나침반 방위가 바뀔 때 (진행 방향 위 모드일 때만 지도를 돌림)
  void onHeading(double deg) {
    if (headingUp.value) _ctl?.animateCamera(CameraUpdate.bearingTo(deg), duration: const Duration(milliseconds: 200));
  }

  void toggleHeadingUp(double? heading) {
    headingUp.value = !headingUp.value;
    _ctl?.animateCamera(CameraUpdate.bearingTo(headingUp.value ? (heading ?? 0) : 0));
  }

  void toggleTilt() {
    tilted.value = !tilted.value;
    _ctl?.animateCamera(CameraUpdate.tiltTo(tilted.value ? 60 : 0));
    _show3dBuildings();
  }

  Map<String, dynamic> _route = _emptyFc;

  /// 따라가는 GPX 경로 (null이면 지움)
  void setRoute(List<TrackPoint>? pts) {
    _route = pts == null || pts.length < 2
        ? _emptyFc
        : {
            'type': 'FeatureCollection',
            'features': [
              {
                'type': 'Feature',
                'geometry': {
                  'type': 'LineString',
                  'coordinates': [for (final p in pts) [p.lon, p.lat]],
                },
                'properties': <String, dynamic>{},
              }
            ],
          };
    if (_ready) _ctl?.setGeoJsonSource('route', _route);
  }

  void setTrack(List<TrackPoint> pts) {
    _track = {
      'type': 'FeatureCollection',
      'features': [
        if (pts.length >= 2)
          {
            'type': 'Feature',
            'geometry': {
              'type': 'LineString',
              'coordinates': [for (final p in pts) [p.lon, p.lat]],
            },
            'properties': <String, dynamic>{},
          }
      ],
    };
    if (_ready) _ctl?.setGeoJsonSource('track', _track);
  }

  /// 가시권 그림(가려진 곳 어둡게)을 지도에 겹침. 내 위치·이동 기록 선 아래에 그림
  Future<void> showViewshed(Uint8List png, double north, double south, double west, double east) async {
    final c = _ctl;
    if (c == null || !_ready) return;
    await hideViewshed();
    await c.addImageSource(
      'viewshed',
      png,
      LatLngQuad(
        topLeft: LatLng(north, west),
        topRight: LatLng(north, east),
        bottomRight: LatLng(south, east),
        bottomLeft: LatLng(south, west),
      ),
    );
    // 두 번째 인자가 그림 소스, 세 번째가 "이 레이어 아래에" (플러그인 인자 이름이 헷갈리게 되어 있음)
    await c.addImageLayerBelow('viewshed', 'viewshed', 'track');
    _viewshedShown = true;
  }

  bool _viewshedShown = false;

  Future<void> hideViewshed() async {
    if (!_viewshedShown) return;
    _viewshedShown = false;
    try {
      await _ctl?.removeLayer('viewshed');
      await _ctl?.removeSource('viewshed');
    } catch (_) {}
  }

  void setWaypoints(List<Waypoint> list) {
    _wpts = {
      'type': 'FeatureCollection',
      'features': [
        for (final w in list)
          {
            'type': 'Feature',
            'geometry': {'type': 'Point', 'coordinates': [w.lon, w.lat]},
            'properties': {'name': w.name},
          }
      ],
    };
    if (_ready) _ctl?.setGeoJsonSource('wpts', _wpts);
  }
}

class MapPage extends StatefulWidget {
  final ValueListenable<GnssSnapshot> snap;
  final MapControl control;
  final double topInset; // 화면 위쪽 상태바 높이 (축척·출처 표시 위치)
  const MapPage({super.key, required this.snap, required this.control, this.topInset = 0});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final store = MapStore.instance;
  MapControl get ctl => widget.control;
  String? _style;
  List<String> _styleIds = [];
  bool? _safeMode; // null = 확인 중, true = 지난번 지도를 보다 앱이 죽음
  bool _marked = false;
  final _pointers = <int, Offset>{}; // 화면에 닿아 있는 손가락 (끌기 감지)

  @override
  void initState() {
    super.initState();
    store.installed.addListener(_rebuildStyle);
    widget.snap.addListener(_onSnap);
    store.load();
    store.crashedWhileMapOpen().then((c) {
      if (mounted) setState(() => _safeMode = c);
    });
  }

  @override
  void dispose() {
    store.installed.removeListener(_rebuildStyle);
    widget.snap.removeListener(_onSnap);
    if (_marked) store.markMapOpen(false);
    super.dispose();
  }

  Future<void> _rebuildStyle() async {
    final packs = store.installed.value;
    // 지도 업데이트로 파일만 바뀌어도(예전 파일은 지워짐) 새 파일로 다시 그려야 하므로 경로까지 비교
    final ids = [for (final p in packs) '${p.id}@${store.fileOf(p.id)}'];
    if (listEquals(ids, _styleIds) && _style != null) return;
    final style = await buildStyle(packs);
    if (!mounted) return;
    ctl._layerIds = [for (final l in (jsonDecode(style) as Map)['layers'] as List) (l as Map)['id'] as String];
    setState(() {
      _styleIds = ids;
      _style = style;
    });
  }

  void _onSnap() {
    final s = widget.snap.value;
    final c = ctl._ctl;
    if (c == null || !ctl._ready || s.lat == null || s.lon == null) return;
    c.setGeoJsonSource('me', {
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'geometry': {'type': 'Point', 'coordinates': [s.lon, s.lat]},
          'properties': <String, dynamic>{},
        }
      ],
    });
    ctl._me = (s.lat!, s.lon!);
    if (ctl._target != null) ctl._drawTarget();
    if (ctl.follow.value) c.animateCamera(CameraUpdate.newLatLng(LatLng(s.lat!, s.lon!)));
  }

  CameraPosition _initialCamera() {
    if (_lastCamera != null) return _lastCamera!;
    final s = widget.snap.value;
    if (s.lat != null && s.lon != null) return CameraPosition(target: LatLng(s.lat!, s.lon!), zoom: 14);
    final packs = store.installed.value;
    return CameraPosition(target: packs.isEmpty ? const LatLng(36.5, 127.8) : packs.first.center, zoom: 7);
  }

  void _openDownloads() =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MapDownloadPage()));

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<MapPack>>(
      valueListenable: store.installed,
      builder: (_, packs, __) {
        // 분석용 고도 데이터(dem)만 있으면 그릴 지도가 없음
        if (!packs.any((p) => p.kind == 'basemap' || p.isTerrain)) return _empty();
        final style = _style;
        if (style == null || _safeMode == null) return const Center(child: CircularProgressIndicator());
        if (_safeMode!) return _safe(packs);
        if (!_marked) {
          _marked = true;
          store.markMapOpen(true);
        }
        return Stack(children: [
          // 손가락 하나로 끌면 내 위치 따라가기 해제 (지도 SDK가 손 조작인지 알려주지 않아 직접 감지).
          // 두 손가락 확대·축소는 따라가기 유지
          Listener(
            onPointerDown: (e) => _pointers[e.pointer] = e.position,
            onPointerMove: (e) {
              final start = _pointers[e.pointer];
              if (_pointers.length == 1 && start != null && (e.position - start).distance > 16) {
                ctl.follow.value = false;
              }
            },
            onPointerUp: (e) => _pointers.remove(e.pointer),
            onPointerCancel: (e) => _pointers.remove(e.pointer),
            child: MapLibreMap(
            key: ValueKey(_styleIds.join(',')), // 지도 추가/삭제 시 새 스타일로 다시 생성
            styleString: style,
            initialCameraPosition: _initialCamera(),
            trackCameraPosition: true,
            compassEnabled: false, // 나침반은 메인 화면의 버튼이 대신함
            onMapCreated: ctl._attach,
            onCameraMove: (cam) => ctl.camera.value = cam,
            onStyleLoadedCallback: () {
              ctl._styleLoaded();
              _onSnap();
            },
            onCameraIdle: () {
              final cam = ctl._ctl?.cameraPosition;
              if (cam != null) _lastCamera = ctl.camera.value = cam;
            },
            onCameraTrackingDismissed: () => ctl.follow.value = false,
            onMapLongClick: (_, ll) => ctl.onLongPress?.call(ll.latitude, ll.longitude),
            ),
          ),
          // 왼쪽 위: 축척 막대 + 지도 출처 (OpenStreetMap 표시는 필수)
          Positioned(
            left: 12,
            top: widget.topInset + 8,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ValueListenableBuilder<CameraPosition?>(
                valueListenable: ctl.camera,
                builder: (_, cam, __) => cam == null ? const SizedBox.shrink() : ScaleBar(camera: cam),
              ),
              const SizedBox(height: 4),
              Text(
                  '© OpenStreetMap${packs.any((p) => p.isTerrain) ? ' · © Copernicus DEM' : ''}'
                  '  ·  ${packs.where((p) => p.kind == 'basemap').map((p) => p.date).join(', ')}',
                  style: const TextStyle(fontSize: 9, color: Colors.black54)),
            ]),
          ),
        ]);
      },
    );
  }

  Widget _safe(List<MapPack> packs) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.warning_amber, size: 56, color: Colors.orangeAccent),
            const SizedBox(height: 12),
            const Text('지난번 지도를 보던 중 앱이 종료됐습니다', style: TextStyle(fontSize: 17)),
            const SizedBox(height: 6),
            const Text('같은 문제가 반복되지 않도록 지도를 바로 열지 않았습니다.',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.white60)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () async {
                await store.markMapOpen(false);
                setState(() => _safeMode = false);
              },
              icon: const Icon(Icons.refresh),
              label: const Text('지도 다시 열기'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () async {
                for (final p in packs) {
                  await store.delete(p.id);
                }
                await store.markMapOpen(false);
                if (mounted) setState(() => _safeMode = false);
              },
              icon: const Icon(Icons.delete_outline),
              label: const Text('받은 지도 삭제'),
            ),
          ]),
        ),
      );

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.map_outlined, size: 64, color: Colors.white38),
            const SizedBox(height: 12),
            const Text('내려받은 지도가 없습니다', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 6),
            const Text('지도를 한 번 내려받으면 인터넷 없이도 볼 수 있습니다.',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.white60)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _openDownloads,
              icon: const Icon(Icons.download),
              label: const Text('지도 다운로드'),
            ),
          ]),
        ),
      );
}

/// 축척 막대: 화면 100 dp 안에 들어가는 1·2·5×10ⁿ m 길이를 골라 표시.
/// MapLibre는 확대 단계 z에서 지구 둘레를 512×2^z dp로 그림 -> dp당 미터 = 둘레·cos(위도) / (512·2^z)
class ScaleBar extends StatelessWidget {
  final CameraPosition camera;
  const ScaleBar({super.key, required this.camera});

  static double metersPerDp(double lat, double zoom) =>
      40075016.686 * math.cos(lat * math.pi / 180) / (512 * math.pow(2, zoom));

  /// [maxDp] 이하로 들어가는 보기 좋은 길이 (m)
  static double niceLength(double mpp, {double maxDp = 100}) {
    final maxM = mpp * maxDp;
    final p = math.pow(10, (math.log(maxM) / math.ln10).floor()).toDouble();
    for (final k in [5, 2, 1]) {
      if (k * p <= maxM) return k * p;
    }
    return p;
  }

  @override
  Widget build(BuildContext context) {
    final mpp = metersPerDp(camera.target.latitude, camera.zoom);
    final m = niceLength(mpp);
    final label = m >= 1000 ? '${(m / 1000).toStringAsFixed(m >= 10000 ? 0 : (m % 1000 == 0 ? 0 : 1))} km' : '${m.round()} m';
    const style = TextStyle(fontSize: 11, color: Colors.black87, fontWeight: FontWeight.w600);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: style),
      Container(
        width: m / mpp,
        height: 5,
        decoration: const BoxDecoration(
          border: Border(
            left: BorderSide(width: 2),
            right: BorderSide(width: 2),
            bottom: BorderSide(width: 2),
          ),
        ),
      ),
    ]);
  }
}

// ---------------- 지도 다운로드 화면 ----------------

class MapDownloadPage extends StatefulWidget {
  const MapDownloadPage({super.key});

  @override
  State<MapDownloadPage> createState() => _MapDownloadPageState();
}

class _MapDownloadPageState extends State<MapDownloadPage> {
  final store = MapStore.instance;
  List<MapPack>? _catalog;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetch();
    store.load(); // 진행 중인 다운로드가 있으면 상태 확인 시작
  }

  Future<void> _fetch() async {
    setState(() => _error = null);
    try {
      final c = await store.fetchCatalog();
      if (mounted) setState(() => _catalog = c);
    } catch (e) {
      if (mounted) setState(() => _error = '목록을 불러오지 못했습니다 (인터넷 연결 확인)');
    }
  }

  /// 한 나라의 지도·지형·건물 이름·분석 데이터를 한꺼번에 받음 ([parts]는 아직 없거나 새 버전이 나온 것만)
  Future<void> _downloadAll(String title, List<MapPack> parts) async {
    final size = parts.fold<int>(0, (a, p) => a + p.size);
    // 어떤 네트워크로 받을지 누를 때마다 고름
    final wifiOnly = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$title (${formatBytes(size)})'),
        content: Text('어떻게 받을까요?\n\n'
            '안드로이드 다운로드 관리자가 받으므로 앱을 닫거나 화면을 꺼도 계속 받고, '
            '끊기면 자동으로 이어받습니다. 진행률은 알림창에서도 볼 수 있습니다.\n\n'
            '${parts.map((p) => '· ${p.name}').join('\n')}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('모바일 데이터도 사용')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Wi-Fi에서만')),
        ],
      ),
    );
    if (wifiOnly == null) return;
    try {
      for (final p in parts) {
        await store.download(p, wifiOnly: wifiOnly);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('다운로드를 시작하지 못했습니다: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('지도 다운로드')),
      body: ValueListenableBuilder<List<MapPack>>(
        valueListenable: store.installed,
        builder: (_, installed, __) => ValueListenableBuilder<Map<String, DlState>>(
          valueListenable: store.progress,
          builder: (_, progress, __) {
            final catalog = _catalog;
            return ListView(
              padding: const EdgeInsets.all(12),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: Text('지도 · 지형', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                if (_error != null)
                  ListTile(
                    leading: const Icon(Icons.wifi_off),
                    title: Text(_error!),
                    trailing: TextButton(onPressed: _fetch, child: const Text('다시 시도')),
                  )
                else if (catalog == null)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else
                  for (final parts in bundleCatalog(catalog)) _bundle(parts, installed, progress),
                const SizedBox(height: 12),
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text(
                    '지도 데이터 © OpenStreetMap contributors (ODbL). 매월 새로 만들어집니다.',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 나라 하나 = 카드 하나. 지도·지형·건물 이름·분석 데이터를 한 번에 받고, 진행률도 합쳐서 보여 줌
  Widget _bundle(List<MapPack> parts, List<MapPack> installed, Map<String, DlState> progress) {
    final title = bundleTitle(parts);
    final total = parts.fold<int>(0, (a, p) => a + p.size);
    MapPack? mine(MapPack p) => installed.where((x) => x.id == p.id).firstOrNull;
    // 같은 날 다시 만든 파일은 날짜가 같으므로 크기도 비교
    bool fresh(MapPack p) => mine(p) != null && mine(p)!.date.compareTo(p.date) >= 0 && mine(p)!.size == p.size;
    final busy = [for (final p in parts) if (progress.containsKey(p.id)) p];
    final need = [for (final p in parts) if (!fresh(p) && !progress.containsKey(p.id)) p];
    final failed = [for (final p in parts) if (store.failures.value[p.id] != null) store.failures.value[p.id]!];
    final have = parts.where((p) => mine(p) != null).toList();
    final newest = parts.map((p) => p.date).reduce((a, b) => a.compareTo(b) >= 0 ? a : b);

    final String sub;
    final Widget trailing;
    double? fraction;
    if (busy.isNotEmpty) {
      // 받은 크기 합 / 전체 크기 (진행률을 아직 모르는 항목은 0으로)
      var done = 0.0;
      for (final p in parts) {
        if (progress.containsKey(p.id)) {
          done += (progress[p.id]!.fraction ?? 0) * p.size;
        } else if (fresh(p)) {
          done += p.size;
        }
      }
      fraction = done / total;
      final waiting = busy.map((p) => progress[p.id]!.text).firstWhere((t) => !t.startsWith('다운로드 중'),
          orElse: () => '');
      sub = '받는 중 ${(fraction * 100).floor()}%  (${formatBytes(done.round())} / ${formatBytes(total)})'
          '${waiting.isEmpty ? '' : '\n$waiting'}';
      trailing = IconButton(
        icon: const Icon(Icons.close),
        tooltip: '취소',
        onPressed: () async {
          for (final p in busy) {
            await store.cancel(p.id);
          }
        },
      );
    } else if (need.isEmpty) {
      sub = '받음  ·  ${formatBytes(total)}  ·  $newest';
      trailing = IconButton(icon: const Icon(Icons.delete_outline), tooltip: '삭제', onPressed: () => _deleteAll(title, have));
    } else {
      final needSize = need.fold<int>(0, (a, p) => a + p.size);
      sub = failed.isNotEmpty
          ? failed.first
          : have.isEmpty
              ? '${formatBytes(total)}  ·  $newest'
              : '새 버전·빠진 항목 ${need.length}개 (${formatBytes(needSize)})';
      trailing = Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          icon: Icon(have.isEmpty ? Icons.download : Icons.update),
          tooltip: have.isEmpty ? '다운로드' : '업데이트',
          onPressed: () => _downloadAll(title, need),
        ),
        if (have.isNotEmpty)
          IconButton(icon: const Icon(Icons.delete_outline), tooltip: '삭제', onPressed: () => _deleteAll(title, have)),
      ]);
    }
    final complete = need.isEmpty && busy.isEmpty;
    return Card(
      child: Column(children: [
        ListTile(
          leading: Icon(complete ? Icons.check_circle : Icons.public, color: complete ? Colors.lightGreenAccent : null),
          title: Text(title),
          subtitle: Text(sub),
          trailing: trailing,
        ),
        if (busy.isNotEmpty) LinearProgressIndicator(value: fraction),
        // 무엇이 들어 있는지 (작게)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (final p in parts)
              Chip(
                visualDensity: VisualDensity.compact,
                avatar: Icon(
                  fresh(p)
                      ? Icons.check
                      : progress.containsKey(p.id)
                          ? Icons.downloading
                          : Icons.cloud_outlined,
                  size: 16,
                ),
                label: Text('${partLabel(p)} ${formatBytes(p.size)}', style: const TextStyle(fontSize: 12)),
              ),
          ]),
        ),
      ]),
    );
  }

  Future<void> _deleteAll(String title, List<MapPack> parts) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$title 지도를 지울까요?'),
        content: const Text('지도·지형·건물 이름·분석 데이터를 모두 지웁니다. 다시 받을 수 있습니다.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('삭제')),
        ],
      ),
    );
    if (ok != true) return;
    for (final p in parts) {
      await store.delete(p.id);
    }
  }
}

/// 카탈로그를 나라별로 묶음: "kr", "kr-terrain", "kr-labels", "kr-dem" -> 대한민국 하나
List<List<MapPack>> bundleCatalog(List<MapPack> catalog) {
  const order = ['basemap', 'terrain', 'hillshade', 'labels', 'dem'];
  final groups = <String, List<MapPack>>{};
  for (final p in catalog) {
    groups.putIfAbsent(p.id.split('-').first, () => []).add(p);
  }
  int rank(MapPack p) => order.contains(p.kind) ? order.indexOf(p.kind) : order.length;
  return [for (final g in groups.values) g..sort((a, b) => rank(a).compareTo(rank(b)))];
}

String bundleTitle(List<MapPack> parts) =>
    (parts.where((p) => p.kind == 'basemap').firstOrNull ?? parts.first).name.split(' ').first;

String partLabel(MapPack p) => switch (p.kind) {
      'basemap' => '지도',
      'terrain' => '등고선',
      'labels' => '건물·아파트 이름',
      'hillshade' => '산 그림자',
      'dem' => '지형 분석',
      _ => p.name,
    };
