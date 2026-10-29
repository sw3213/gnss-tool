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
    for (final id in ['me', 'track', 'wpts']) id: {'type': 'geojson', 'data': empty},
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
  var placed = false;

  for (final p in packs.where((p) => !p.isTerrain)) {
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
        if (l['id'] == 'address_label') layers.addAll(contourLabels);
      }
      // 라벨(번지) 바로 앞에 우리 레이어를 끼워 넣어 도로 위, 글자 아래에 그려지게 함
      if (l['id'] == 'address_label') layers.addAll(_extraLayers(s));
      layers.add(_tweak({...l, 'id': '$s-${l['id']}', 'source': s}, l['id'] as String));
    }
    placed = true;
  }
  if (!placed) layers.addAll([...bands, ...contours, ...contourLabels]); // 지형만 받은 경우
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

/// 기본 스타일은 꽤 확대해야 정보가 보임 -> MAPS.ME처럼 덜 확대해도 보이게 조정
Map<String, dynamic> _tweak(Map<String, dynamic> l, String id) {
  switch (id) {
    case 'pois':
      // 장소마다 "이 확대 단계부터 보임"(min_zoom)이 있음. 2단계 일찍 보이게 하고,
      // 봉우리는 높이를 함께 보여 주는 별도 레이어(peaks)로 그림
      final f = jsonEncode(l['filter']).replaceAll('["+",["get","min_zoom"],0]', '["-",["get","min_zoom"],2]');
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
      return {...l, 'minzoom': 17}; // 번지: 18 -> 17
    case 'roads_labels_minor':
      return {...l, 'minzoom': 14}; // 골목 이름: 15 -> 14
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
        'minzoom': 12,
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
      // 건물 이름 (아파트 "201동" 등)
      {
        'id': '$s-building-names',
        'type': 'symbol',
        'source': s,
        'source-layer': 'buildings',
        'minzoom': 16,
        'filter': ['has', 'name'],
        'layout': {
          'text-field': ['coalesce', ['get', 'name:ko'], ['get', 'name']],
          'text-font': ['NotoSansRegular'],
          'text-size': 11,
        },
        'paint': {'text-color': '#6b6258', 'text-halo-color': '#ffffff', 'text-halo-width': 1},
      },
      // 아파트 단지·학교·공원 등 구역 이름 ("구곡청솔1차아파트")
      {
        'id': '$s-area-names',
        'type': 'symbol',
        'source': s,
        'source-layer': 'landuse',
        'minzoom': 14,
        'filter': [
          'all',
          ['has', 'name'],
          [
            'in',
            ['get', 'kind'],
            ['literal', ['residential', 'school', 'university', 'college', 'hospital', 'park', 'cemetery', 'military', 'industrial', 'commercial']],
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
        'minzoom': 11,
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

// 이동 기록 선, 저장한 지점, 내 위치 (맨 위)
const _meLayers = [
  {
    'id': 'track',
    'type': 'line',
    'source': 'track',
    'layout': {'line-cap': 'round', 'line-join': 'round'},
    'paint': {'line-color': '#f76707', 'line-width': 4, 'line-opacity': 0.9},
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
  Map<String, dynamic> _track = _emptyFc, _wpts = _emptyFc;

  static const _emptyFc = <String, dynamic>{'type': 'FeatureCollection', 'features': <dynamic>[]};

  void _attach(MapLibreMapController c) {
    _ctl = c;
    _ready = false;
  }

  void _styleLoaded() {
    _ready = true;
    _ctl?.setGeoJsonSource('track', _track);
    _ctl?.setGeoJsonSource('wpts', _wpts);
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
    final ids = [for (final p in packs) p.id];
    if (listEquals(ids, _styleIds) && _style != null) return;
    final style = await buildStyle(packs);
    if (!mounted) return;
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
        if (packs.isEmpty) return _empty();
        final style = _style;
        if (style == null || _safeMode == null) return const Center(child: CircularProgressIndicator());
        if (_safeMode!) return _safe(packs);
        if (!_marked) {
          _marked = true;
          store.markMapOpen(true);
        }
        return Stack(children: [
          MapLibreMap(
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
            onMapClick: (_, __) => ctl.follow.value = false,
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
                  '  ·  ${packs.where((p) => !p.isTerrain).map((p) => p.date).join(', ')}',
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

  Future<void> _download(MapPack p) async {
    // 어떤 네트워크로 받을지 누를 때마다 고름
    final wifiOnly = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${p.name} 지도 (${formatBytes(p.size)})'),
        content: Text('어떻게 받을까요?\n\n'
            '안드로이드 다운로드 관리자가 받으므로 앱을 닫거나 화면을 꺼도 계속 받고, '
            '끊기면 자동으로 이어받습니다. 진행률은 알림창에서도 볼 수 있습니다.\n\n지도 날짜: ${p.date}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('모바일 데이터도 사용')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Wi-Fi에서만')),
        ],
      ),
    );
    if (wifiOnly == null) return;
    try {
      await store.download(p, wifiOnly: wifiOnly);
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
                  for (final p in catalog) _tile(p, installed, progress),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.crop_free),
                    title: const Text('영역 직접 지정'),
                    subtitle: const Text('지도에서 원하는 범위만 골라 받기 (준비 중)'),
                    enabled: false,
                  ),
                ),
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

  Widget _tile(MapPack p, List<MapPack> installed, Map<String, DlState> progress) {
    final mine = installed.where((x) => x.id == p.id).firstOrNull;
    final pr = progress[p.id];
    final failed = store.failures.value[p.id];
    final String sub;
    final Widget trailing;
    if (pr != null) {
      sub = pr.text;
      trailing = IconButton(icon: const Icon(Icons.close), tooltip: '취소', onPressed: () => store.cancel(p.id));
    } else if (mine == null) {
      sub = failed ?? '${formatBytes(p.size)}  ·  ${p.date}';
      trailing = IconButton(icon: const Icon(Icons.download), tooltip: '다운로드', onPressed: () => _download(p));
    } else {
      final outdated = mine.date.compareTo(p.date) < 0;
      sub = outdated ? '받은 지도 ${mine.date} → 새 버전 ${p.date}' : '받음  ·  ${formatBytes(mine.size)}  ·  ${mine.date}';
      trailing = Row(mainAxisSize: MainAxisSize.min, children: [
        if (outdated)
          IconButton(icon: const Icon(Icons.update), tooltip: '업데이트', onPressed: () => _download(p)),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: '삭제',
          onPressed: () => store.delete(p.id),
        ),
      ]);
    }
    return Card(
      child: Column(children: [
        ListTile(
          leading: Icon(mine != null ? Icons.check_circle : Icons.public,
              color: mine != null ? Colors.lightGreenAccent : null),
          title: Text(p.name),
          subtitle: Text(sub),
          trailing: trailing,
        ),
        if (pr != null) LinearProgressIndicator(value: pr.fraction),
      ]),
    );
  }
}
