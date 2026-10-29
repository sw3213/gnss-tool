import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path_provider/path_provider.dart';

import 'main.dart' show GnssSnapshot;

// ============================================================
// 오프라인 지도: 나라별 .pmtiles 다운로드/관리 + MapLibre 화면
// 지도 데이터 © OpenStreetMap contributors (ODbL) — 화면에 출처 표시 필수
// ============================================================

const _catalogUrl = 'https://github.com/sw3213/gnss-tool/releases/download/maps/catalog.json';

class MapPack {
  final String id, name, url, date;
  final List<double> bbox; // [서, 남, 동, 북]
  final int size; // bytes
  const MapPack(this.id, this.name, this.url, this.date, this.bbox, this.size);

  factory MapPack.fromJson(Map<String, dynamic> j) => MapPack(
        j['id'] as String,
        j['name'] as String,
        j['url'] as String,
        j['date'] as String,
        [for (final v in j['bbox'] as List) (v as num).toDouble()],
        (j['size'] as num).toInt(),
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'url': url, 'date': date, 'bbox': bbox, 'size': size};

  LatLng get center => LatLng((bbox[1] + bbox[3]) / 2, (bbox[0] + bbox[2]) / 2);
}

String formatBytes(int b) =>
    b >= 1 << 30 ? '${(b / (1 << 30)).toStringAsFixed(1)} GB' : '${(b / (1 << 20)).toStringAsFixed(0)} MB';

/// 내려받은 지도 목록. 파일은 앱 전용 저장소 maps/<id>.pmtiles + <id>.json(정보)
class MapStore {
  MapStore._();
  static final instance = MapStore._();

  final installed = ValueNotifier<List<MapPack>>([]);
  final progress = ValueNotifier<Map<String, double>>({}); // id -> 0..1 (다운로드 중)
  final _cancel = <String>{};
  Directory? _dir;

  Future<Directory> _maps() async {
    final d = _dir ??= Directory('${(await getApplicationSupportDirectory()).path}/maps');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  Future<String> pathOf(String id) async => '${(await _maps()).path}/$id.pmtiles';

  Future<void> load() async {
    final d = await _maps();
    final list = <MapPack>[];
    for (final f in d.listSync().whereType<File>().where((f) => f.path.endsWith('.json'))) {
      try {
        final p = MapPack.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
        if (File('${d.path}/${p.id}.pmtiles').existsSync()) list.add(p);
      } catch (_) {}
    }
    installed.value = list;
  }

  Future<List<MapPack>> fetchCatalog() async {
    final res = await http.get(Uri.parse(_catalogUrl)).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    return [for (final j in jsonDecode(res.body) as List) MapPack.fromJson(j as Map<String, dynamic>)];
  }

  /// 임시 파일(.part)에 받은 뒤 끝나면 이름을 바꿈 -> 중간에 끊겨도 깨진 지도가 남지 않음
  Future<void> download(MapPack p) async {
    final path = await pathOf(p.id);
    final part = File('$path.part');
    _cancel.remove(p.id);
    progress.value = {...progress.value, p.id: 0};
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', Uri.parse(p.url)));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final total = res.contentLength ?? p.size;
      final sink = part.openWrite();
      var got = 0, lastPct = -1;
      try {
        await for (final chunk in res.stream) {
          if (_cancel.contains(p.id)) throw const _Cancelled();
          sink.add(chunk);
          got += chunk.length;
          final pct = (got * 100 / total).floor();
          if (pct != lastPct) {
            lastPct = pct;
            progress.value = {...progress.value, p.id: got / total};
          }
        }
      } finally {
        await sink.close();
      }
      await part.rename(path);
      await File('${(await _maps()).path}/${p.id}.json').writeAsString(jsonEncode(p.toJson()));
      await load();
    } catch (e) {
      if (part.existsSync()) part.deleteSync();
      if (e is! _Cancelled) rethrow;
    } finally {
      client.close();
      progress.value = {...progress.value}..remove(p.id);
    }
  }

  void cancel(String id) => _cancel.add(id);

  Future<void> delete(String id) async {
    final d = await _maps();
    for (final ext in ['pmtiles', 'json']) {
      final f = File('${d.path}/$id.$ext');
      if (f.existsSync()) f.deleteSync();
    }
    await load();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

// ---------------- 지도 스타일 (Protomaps v4 스키마, 어두운 테마) ----------------
// 한글 등 CJK 글자는 MapLibre가 폰 기본 글꼴로 그림 -> 라틴/숫자 글리프만 앱에 포함

Future<String> buildStyle(List<MapPack> packs) async {
  final sources = <String, dynamic>{
    'me': {
      'type': 'geojson',
      'data': {'type': 'FeatureCollection', 'features': []},
    },
  };
  final layers = <Map<String, dynamic>>[
    {'id': 'bg', 'type': 'background', 'paint': {'background-color': '#16181c'}},
  ];
  const name = ['coalesce', ['get', 'name:ko'], ['get', 'name']];
  const font = ['NotoSansRegular'];
  const fontBold = ['NotoSansMedium'];

  for (final p in packs) {
    final s = 'm_${p.id}';
    sources[s] = {
      'type': 'vector',
      'url': 'pmtiles://file://${await MapStore.instance.pathOf(p.id)}',
      'attribution': '© OpenStreetMap contributors',
    };
    Map<String, dynamic> l(String id, String type, String layer, Map<String, dynamic> rest) =>
        {'id': '$s-$id', 'type': type, 'source': s, 'source-layer': layer, ...rest};

    layers.addAll([
      l('earth', 'fill', 'earth', {'paint': {'fill-color': '#202328'}}),
      l('landcover', 'fill', 'landcover', {
        'paint': {
          'fill-color': ['match', ['get', 'kind'], ['forest', 'scrub'], '#1f2e24', 'grassland', '#232f26', '#202328'],
          'fill-opacity': ['interpolate', ['linear'], ['zoom'], 5, 1, 8, 0],
        },
      }),
      l('green', 'fill', 'landuse', {
        'filter': ['in', ['get', 'kind'], ['literal', ['forest', 'wood', 'park', 'national_park', 'nature_reserve', 'protected_area', 'grass', 'meadow', 'scrub', 'garden', 'golf_course']]],
        'paint': {'fill-color': '#1f3125'},
      }),
      l('urban', 'fill', 'landuse', {
        'filter': ['in', ['get', 'kind'], ['literal', ['residential', 'commercial', 'industrial', 'school', 'hospital', 'university', 'college']]],
        'paint': {'fill-color': '#26292f'},
      }),
      l('water', 'fill', 'water', {'paint': {'fill-color': '#1d3346'}}),
      l('buildings', 'fill', 'buildings', {'minzoom': 14, 'paint': {'fill-color': '#30333a'}}),
      l('boundaries', 'line', 'boundaries', {
        'filter': ['<=', ['get', 'kind_detail'], 4],
        'paint': {'line-color': '#7a7d85', 'line-width': 1, 'line-dasharray': [3, 2]},
      }),
      // 등산로·오솔길: 아웃도어 용도라 점선으로 잘 보이게
      l('paths', 'line', 'roads', {
        'minzoom': 12,
        'filter': ['==', ['get', 'kind'], 'path'],
        'paint': {
          'line-color': '#c9a46a',
          'line-width': ['interpolate', ['linear'], ['zoom'], 12, 0.6, 16, 1.6],
          'line-dasharray': [2, 1.5],
        },
      }),
      l('minor', 'line', 'roads', {
        'filter': ['==', ['get', 'kind'], 'minor_road'],
        'paint': {'line-color': '#4b4f57', 'line-width': ['interpolate', ['linear'], ['zoom'], 12, 0.5, 16, 4]},
      }),
      l('major', 'line', 'roads', {
        'filter': ['==', ['get', 'kind'], 'major_road'],
        'paint': {'line-color': '#7d7360', 'line-width': ['interpolate', ['linear'], ['zoom'], 7, 0.5, 16, 6]},
      }),
      l('highway', 'line', 'roads', {
        'filter': ['==', ['get', 'kind'], 'highway'],
        'paint': {'line-color': '#b98a45', 'line-width': ['interpolate', ['linear'], ['zoom'], 5, 0.6, 16, 8]},
      }),
      l('rail', 'line', 'roads', {
        'filter': ['==', ['get', 'kind'], 'rail'],
        'paint': {'line-color': '#6b6f78', 'line-width': 1, 'line-dasharray': [4, 2]},
      }),
      l('water-label', 'symbol', 'water', {
        'minzoom': 11,
        'layout': {'text-field': name, 'text-font': font, 'text-size': 11},
        'paint': {'text-color': '#6f9cc0', 'text-halo-color': '#16181c', 'text-halo-width': 1},
      }),
      l('road-label', 'symbol', 'roads', {
        'minzoom': 13,
        'filter': ['in', ['get', 'kind'], ['literal', ['highway', 'major_road', 'minor_road', 'path']]],
        'layout': {'symbol-placement': 'line', 'text-field': name, 'text-font': font, 'text-size': 11},
        'paint': {'text-color': '#b0b3ba', 'text-halo-color': '#16181c', 'text-halo-width': 1},
      }),
      // 산봉우리: 이름 + 높이
      l('peaks', 'symbol', 'pois', {
        'minzoom': 10,
        'filter': ['==', ['get', 'kind'], 'peak'],
        'layout': {
          'text-field': [
            'format', '▲ ', {}, name, {},
            ['case', ['has', 'elevation'], ['concat', '\n', ['to-string', ['round', ['get', 'elevation']]], ' m'], ''], {'font-scale': 0.85},
          ],
          'text-font': font,
          'text-size': 12,
          'text-anchor': 'top',
        },
        'paint': {'text-color': '#d8c39a', 'text-halo-color': '#16181c', 'text-halo-width': 1.2},
      }),
      // 물 (식수대·급수 지점) — 수원지 기능의 바탕
      l('water-poi', 'symbol', 'pois', {
        'minzoom': 13,
        'filter': ['in', ['get', 'kind'], ['literal', ['drinking_water', 'water_point', 'watering_place', 'spring']]],
        'layout': {'text-field': ['concat', '💧 ', ['coalesce', ['get', 'name:ko'], ['get', 'name'], '물']], 'text-font': font, 'text-size': 11},
        'paint': {'text-color': '#7fc4ff', 'text-halo-color': '#16181c', 'text-halo-width': 1.2},
      }),
      l('places', 'symbol', 'places', {
        'filter': ['in', ['get', 'kind'], ['literal', ['country', 'region', 'locality', 'neighbourhood', 'macrohood']]],
        'layout': {
          'text-field': name,
          'text-font': fontBold,
          'text-size': ['match', ['get', 'kind'], 'country', 16, 'region', 14, 'locality', 13, 11],
          'symbol-sort-key': ['get', 'sort_rank'],
        },
        'paint': {'text-color': '#e6e6e6', 'text-halo-color': '#16181c', 'text-halo-width': 1.5},
      }),
    ]);
  }

  // 내 위치 (맨 위)
  layers.addAll([
    {
      'id': 'me-acc',
      'type': 'circle',
      'source': 'me',
      'paint': {'circle-radius': 18, 'circle-color': '#4aa3ff', 'circle-opacity': 0.15},
    },
    {
      'id': 'me',
      'type': 'circle',
      'source': 'me',
      'paint': {
        'circle-radius': 7,
        'circle-color': '#4aa3ff',
        'circle-stroke-color': '#ffffff',
        'circle-stroke-width': 2,
      },
    },
  ]);

  return jsonEncode({
    'version': 8,
    'name': 'gnss-offline',
    'glyphs': 'asset://flutter_assets/assets/map/fonts/{fontstack}/{range}.pbf',
    'sources': sources,
    'layers': layers,
  });
}

// ---------------- 지도 화면 ----------------

class MapPage extends StatefulWidget {
  final ValueListenable<GnssSnapshot> snap;
  const MapPage({super.key, required this.snap});

  @override
  State<MapPage> createState() => _MapPageState();
}

CameraPosition? _lastCamera; // 탭을 오가도 보던 위치 유지

class _MapPageState extends State<MapPage> {
  final store = MapStore.instance;
  MapLibreMapController? _ctl;
  String? _style;
  List<String> _styleIds = [];
  bool _styleReady = false;
  bool _follow = true; // 내 위치 따라가기 (지도를 손으로 움직이면 해제)

  @override
  void initState() {
    super.initState();
    store.installed.addListener(_rebuildStyle);
    widget.snap.addListener(_onSnap);
    store.load();
  }

  @override
  void dispose() {
    store.installed.removeListener(_rebuildStyle);
    widget.snap.removeListener(_onSnap);
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
      _styleReady = false;
    });
  }

  void _onSnap() {
    final s = widget.snap.value;
    final ctl = _ctl;
    if (ctl == null || !_styleReady || s.lat == null || s.lon == null) return;
    ctl.setGeoJsonSource('me', {
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'geometry': {'type': 'Point', 'coordinates': [s.lon, s.lat]},
          'properties': {},
        }
      ],
    });
    if (_follow) ctl.animateCamera(CameraUpdate.newLatLng(LatLng(s.lat!, s.lon!)));
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
        if (style == null) return const Center(child: CircularProgressIndicator());
        return Stack(children: [
          MapLibreMap(
            key: ValueKey(_styleIds.join(',')), // 지도 추가/삭제 시 새 스타일로 다시 생성
            styleString: style,
            initialCameraPosition: _initialCamera(),
            trackCameraPosition: true,
            compassEnabled: true,
            onMapCreated: (c) => _ctl = c,
            onStyleLoadedCallback: () {
              _styleReady = true;
              _onSnap();
            },
            onCameraIdle: () {
              final cam = _ctl?.cameraPosition;
              if (cam != null) _lastCamera = cam;
            },
            onCameraTrackingDismissed: () => setState(() => _follow = false),
            onMapClick: (_, __) => setState(() => _follow = false),
          ),
          Positioned(
            right: 12,
            bottom: 40,
            child: Column(children: [
              FloatingActionButton.small(
                heroTag: 'dl',
                tooltip: '지도 다운로드',
                onPressed: _openDownloads,
                child: const Icon(Icons.download_for_offline),
              ),
              const SizedBox(height: 10),
              FloatingActionButton.small(
                heroTag: 'me',
                tooltip: '내 위치',
                backgroundColor: _follow ? Colors.blueAccent : null,
                onPressed: () {
                  setState(() => _follow = true);
                  final s = widget.snap.value;
                  if (s.lat != null && s.lon != null) {
                    _ctl?.animateCamera(CameraUpdate.newLatLngZoom(LatLng(s.lat!, s.lon!), 15));
                  }
                },
                child: const Icon(Icons.my_location),
              ),
            ]),
          ),
          Positioned(
            left: 8,
            bottom: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              color: Colors.black54,
              child: Text('© OpenStreetMap contributors  ·  지도 ${packs.map((p) => p.date).join(', ')}',
                  style: const TextStyle(fontSize: 10, color: Colors.white70)),
            ),
          ),
          ValueListenableBuilder<GnssSnapshot>(
            valueListenable: widget.snap,
            builder: (_, s, __) => s.lat == null
                ? const Positioned(
                    left: 0,
                    right: 0,
                    top: 8,
                    child: Center(
                      child: Chip(label: Text('현재 위치 없음 (GPS 측위 대기)', style: TextStyle(fontSize: 12))),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ]);
      },
    );
  }

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
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${p.name} 지도'),
        content: Text('${formatBytes(p.size)}를 내려받습니다. 데이터 요금이 들 수 있으니 Wi-Fi를 권장합니다.\n\n'
            '지도 날짜: ${p.date}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('다운로드')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await store.download(p);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('다운로드 실패: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('지도 다운로드')),
      body: ValueListenableBuilder<List<MapPack>>(
        valueListenable: store.installed,
        builder: (_, installed, __) => ValueListenableBuilder<Map<String, double>>(
          valueListenable: store.progress,
          builder: (_, progress, __) {
            final catalog = _catalog;
            return ListView(
              padding: const EdgeInsets.all(12),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: Text('나라별 지도', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
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

  Widget _tile(MapPack p, List<MapPack> installed, Map<String, double> progress) {
    final mine = installed.where((x) => x.id == p.id).firstOrNull;
    final pr = progress[p.id];
    final String sub;
    final Widget trailing;
    if (pr != null) {
      sub = '다운로드 중... ${(pr * 100).floor()}%  (${formatBytes((p.size * pr).round())} / ${formatBytes(p.size)})';
      trailing = IconButton(icon: const Icon(Icons.close), tooltip: '취소', onPressed: () => store.cancel(p.id));
    } else if (mine == null) {
      sub = '${formatBytes(p.size)}  ·  ${p.date}';
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
        if (pr != null) LinearProgressIndicator(value: pr),
      ]),
    );
  }
}
