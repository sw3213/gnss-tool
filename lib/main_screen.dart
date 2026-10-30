import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:maplibre_gl/maplibre_gl.dart' show CameraPosition;
import 'package:path_provider/path_provider.dart';

import 'analysis.dart';
import 'main.dart';
import 'nav.dart';
import 'offline_map.dart';
import 'updater.dart';
import 'water.dart' show WaterSource, waterChipLabel;
import 'weather.dart';

// ============================================================
// 메인 화면: 전체 화면 지도 + 상태·나침반 + 아래 정보 패널 + 아래 버튼 4개
// (목표로 삼은 "Black GPS" 앱 화면 구성)
// ============================================================

class MainScreen extends StatefulWidget {
  final ValueListenable<GnssSnapshot> snap;
  final ValueListenable<List<SensorSample>> sensors;
  final ValueListenable<StormStatus> weather;
  final ValueListenable<List<(DateTime, double)>> qnhHistory;
  final ValueListenable<List<String>> log;
  final ValueListenable<String?> notice, alert;
  final ValueListenable<double?> heading;
  final String sourceLabel;
  final MapControl map;
  final TrackRecorder track;
  final WaypointStore waypoints;
  final DataSource source;
  final void Function(DataSource) onSource;
  final VoidCallback onRetrySource, onDismissAlert;
  final TerrainAnalysis analysis;
  final Guide guide;
  final RouteFollow route;

  const MainScreen({
    required this.analysis,
    required this.guide,
    required this.route,
    super.key,
    required this.snap,
    required this.sensors,
    required this.weather,
    required this.qnhHistory,
    required this.log,
    required this.notice,
    required this.alert,
    required this.heading,
    required this.sourceLabel,
    required this.map,
    required this.track,
    required this.waypoints,
    required this.source,
    required this.onSource,
    required this.onRetrySource,
    required this.onDismissAlert,
  });

  @override
  State<MainScreen> createState() => _MainScreenState();
}

const _waterColor = Color(0xFF1C7ED6), _emergencyColor = Color(0xFFE8590C); // 수원지 번호: 기본 파랑, 긴급 주황
const _panelMin = 0.13, _panelInit = 0.24, _panelMax = 0.62;

class _MainScreenState extends State<MainScreen> {
  final _sheet = ValueNotifier<double>(_panelInit); // 아래 패널이 화면에서 차지하는 비율
  final _viewshedOn = ValueNotifier<bool>(false);
  NavTarget? _arrivedAt; // 도착 알림을 이미 띄운 목표 (한 번만)

  @override
  void initState() {
    super.initState();
    widget.map.onLongPress = _onLongPress;
    widget.guide.info.addListener(_checkArrival);
    widget.route.info.addListener(_checkRoute);
  }

  @override
  void dispose() {
    widget.map.onLongPress = null;
    widget.guide.info.removeListener(_checkArrival);
    widget.route.info.removeListener(_checkRoute);
    super.dispose();
  }

  void _checkArrival() {
    final i = widget.guide.info.value, t = widget.guide.target.value;
    if (i == null || t == null || !i.arrived || identical(_arrivedAt, t)) return;
    _arrivedAt = t;
    HapticFeedback.heavyImpact();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('"${t.name}"에 도착했습니다'),
      duration: const Duration(seconds: 10),
      action: SnackBarAction(label: '안내 종료', onPressed: widget.guide.stop),
    ));
  }

  bool _wasOff = false, _routeDone = false;

  /// 경로에서 벗어나는 순간 / 경로 끝에 닿는 순간 진동과 알림 (한 번씩)
  void _checkRoute() {
    final i = widget.route.info.value;
    if (i == null) {
      _wasOff = _routeDone = false;
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    if (i.offRoute && !_wasOff) {
      HapticFeedback.heavyImpact();
      messenger.showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade800,
        content: Text('경로 이탈 ${distanceLabel(i.off)} — 경로는 ${directionLabel(i.toRoute)} 쪽'),
      ));
    }
    _wasOff = i.offRoute;
    if (i.finished && !_routeDone) {
      _routeDone = true;
      HapticFeedback.heavyImpact();
      messenger.showSnackBar(SnackBar(
        content: const Text('경로 끝에 도착했습니다'),
        duration: const Duration(seconds: 10),
        action: SnackBarAction(label: '따라가기 종료', onPressed: widget.route.stop),
      ));
    }
  }

  void _guideTo(NavTarget t) {
    widget.guide.start(t);
    final s = widget.snap.value;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(s.lat == null
          ? '"${t.name}" 안내를 시작합니다'
          : '"${t.name}" 안내 시작: ${distanceLabel(distanceM(s.lat!, s.lon!, t.lat, t.lon))}'),
    ));
  }

  /// 지도를 길게 누른 곳: 거리·고도를 보여 주고 "여기로 안내" / "지점으로 저장"
  void _onLongPress(double lat, double lon) {
    final s = widget.snap.value;
    final elev = widget.analysis.elevationAt(lat, lon);
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.push_pin_outlined, color: Colors.redAccent),
            title: Text(s.lat == null
                ? '선택한 곳'
                : '${distanceLabel(distanceM(s.lat!, s.lon!, lat, lon))}  ·  '
                    '${directionLabel(bearingDeg(s.lat!, s.lon!, lat, lon))}'),
            subtitle: Text('${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}'
                '${elev == null ? '' : '  ·  고도 ${elev.round()} m'}'),
          ),
          ListTile(
            leading: const Icon(Icons.flag_outlined),
            title: const Text('여기로 안내'),
            onTap: () {
              Navigator.pop(ctx);
              _guideTo(NavTarget('선택한 곳', lat, lon));
            },
          ),
          ListTile(
            leading: const Icon(Icons.add_location_alt_outlined),
            title: const Text('지점으로 저장'),
            onTap: () {
              Navigator.pop(ctx);
              _saveWaypoint(at: (lat, lon, elev));
            },
          ),
        ]),
      ),
    );
  }

  void _needDem() => ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('지형 분석에는 "대한민국 고도 데이터 (분석용)"이 필요합니다'),
        action: SnackBarAction(
          label: '받기',
          onPressed: () =>
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MapDownloadPage())),
        ),
      ));

  void _showWater() {
    final a = widget.analysis;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true, // 5곳이면 화면 절반을 넘을 수 있음
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: ValueListenableBuilder<bool>(
            valueListenable: a.emergencyWater,
            builder: (_, emergency, __) => ValueListenableBuilder<List<WaterSource>>(
              valueListenable: a.water,
              builder: (_, ws, __) {
                final s = widget.snap.value;
                return Column(mainAxisSize: MainAxisSize.min, children: [
                  ListTile(
                    title: const Text('가까운 수원지', style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(emergency
                        ? '기본 수원지 + 긴급 수원지(소류지·저수지·연못 등 고인 물). 마시기 전 반드시 끓이거나 정수하세요'
                        : '기본 수원지: 흐르는 물·샘·식수대만. 마시기 전 반드시 끓이거나 정수하세요'),
                  ),
                  // 물이 정말 급할 때만 켬: 고인 물까지 거리 계산에 넣음 (설정은 저장됨)
                  SwitchListTile(
                    secondary: Icon(Icons.warning_amber_rounded, color: emergency ? Colors.orange : null),
                    title: const Text('긴급 수원지 포함'),
                    subtitle: const Text('소류지·저수지·연못·호수도 찾기 (오염 위험, 최후의 수단)'),
                    value: emergency,
                    activeThumbColor: Colors.orange,
                    onChanged: a.setEmergencyWater,
                  ),
                  if (ws.isEmpty)
                    const ListTile(title: Text('주변 10 km 안에 찾은 수원지가 없습니다')),
                  for (var i = 0; i < ws.length; i++)
                    ListTile(
                      leading: CircleAvatar(
                        radius: 14,
                        backgroundColor: ws[i].emergency ? _emergencyColor : _waterColor,
                        child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 13)),
                      ),
                      title: Text.rich(TextSpan(children: [
                        if (ws[i].emergency)
                          const TextSpan(
                              text: '긴급  ', style: TextStyle(color: _emergencyColor, fontWeight: FontWeight.bold)),
                        TextSpan(text: '${ws[i].label}${ws[i].name == null ? '' : ' · ${ws[i].name}'}'),
                      ])),
                      subtitle: Text(s.lat == null
                          ? distanceLabel(ws[i].distanceM)
                          : '${distanceLabel(ws[i].distanceM)}  ·  '
                              '${directionLabel(bearingDeg(s.lat!, s.lon!, ws[i].lat, ws[i].lon))}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.flag_outlined),
                        tooltip: '여기로 안내',
                        onPressed: () {
                          Navigator.pop(ctx);
                          _guideTo(NavTarget('${ws[i].emergency ? '긴급 ' : ''}${ws[i].name ?? ws[i].label}', ws[i].lat, ws[i].lon));
                        },
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        widget.map.recenter(ws[i].lat, ws[i].lon);
                        widget.map.follow.value = false;
                      },
                    ),
                ]);
              },
            ),
          ),
        ),
      ),
    );
  }

  /// 레이어 켜고 끄기 (등고선, 고도 색칠, 등산로…). 선택은 저장되어 다음에도 유지
  void _showLayers() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: ValueListenableBuilder<Set<String>>(
            valueListenable: widget.map.hidden,
            builder: (_, hidden, __) => Column(mainAxisSize: MainAxisSize.min, children: [
              const ListTile(title: Text('지도 레이어', style: TextStyle(fontWeight: FontWeight.bold))),
              for (final g in MapControl.layerGroups)
                SwitchListTile(
                  secondary: Icon(g.icon),
                  title: Text(g.label),
                  value: !hidden.contains(g.id),
                  onChanged: (on) => widget.map.setLayerShown(g.id, on),
                ),
            ]),
          ),
        ),
      ),
    );
  }

  /// 👁 가시권: 현재 위치에서 5 km 안 지형에 가려 안 보이는 곳을 어둡게
  Future<void> _toggleViewshed() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_viewshedOn.value) {
      _viewshedOn.value = false;
      await widget.map.hideViewshed();
      return;
    }
    if (!widget.analysis.hasDem.value) return _needDem();
    final img = await widget.analysis.viewshedImage();
    if (img == null) {
      messenger.showSnackBar(const SnackBar(content: Text('현재 위치가 있어야 가시권을 계산할 수 있습니다')));
      return;
    }
    final (png, n, s, w, e) = img;
    await widget.map.showViewshed(png, n, s, w, e);
    _viewshedOn.value = true;
    messenger.showSnackBar(const SnackBar(content: Text('어두운 곳 = 지형에 가려 보이지 않는 곳 (반경 5 km, 나무·건물 제외)')));
  }

  void _push(Widget page, String title) => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(appBar: AppBar(title: Text(title)), body: page),
      ));

  Future<void> _toggleTrack() async {
    final t = widget.track;
    final messenger = ScaffoldMessenger.of(context);
    if (!t.recording.value) {
      t.start();
      messenger.showSnackBar(const SnackBar(content: Text('이동 기록을 시작합니다')));
      return;
    }
    final dist = t.distance.value;
    final path = await t.stop();
    messenger.showSnackBar(SnackBar(
      content: Text(path == null
          ? '기록할 이동이 없어 저장하지 않았습니다'
          : '이동 기록 저장: ${distanceLabel(dist)} (${path.split('/').last})'),
    ));
  }

  /// 현재 위치(또는 지도에서 길게 누른 곳 [at]: 위도, 경도, 고도)를 이름 붙여 저장
  Future<void> _saveWaypoint({(double, double, double?)? at}) async {
    final s = widget.snap.value;
    final messenger = ScaffoldMessenger.of(context);
    if (at == null && (s.lat == null || s.lon == null)) {
      messenger.showSnackBar(const SnackBar(content: Text('현재 위치가 없어 저장할 수 없습니다 (GPS 측위 대기)')));
      return;
    }
    final ctl = TextEditingController(text: widget.waypoints.nextName());
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('지점 저장'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '예: 화장실, 대피소, 샘터'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('저장')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await widget.waypoints.add(Waypoint(name.trim(), at?.$1 ?? s.lat!, at?.$2 ?? s.lon!, at == null ? s.alt : at.$3, DateTime.now()));
    messenger.showSnackBar(SnackBar(content: Text('"${name.trim()}" 저장했습니다')));
  }

  void _openTools() => _push(
        ToolsPage(
          snap: widget.snap,
          sensors: widget.sensors,
          weather: widget.weather,
          qnhHistory: widget.qnhHistory,
          log: widget.log,
          waypoints: widget.waypoints,
          onGuide: _guideTo,
          route: widget.route,
          map: widget.map,
          source: widget.source,
          onSource: widget.onSource,
        ),
        '도구',
      );

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return Scaffold(
      backgroundColor: const Color(0xFF16181C),
      body: LayoutBuilder(builder: (context, box) {
        return Stack(children: [
          Positioned.fill(
            child: isAndroid
                ? MapPage(snap: widget.snap, control: widget.map, topInset: pad.top)
                : SafeArea(child: SkyPage(snap: widget.snap)), // 웹 미리보기: 네이티브 지도 없음
          ),
          // 경보·안내 띠 (맨 위)
          Positioned(
            top: pad.top,
            left: 0,
            right: 0,
            child: Column(children: [
              _banner(widget.alert, Colors.red.shade900, Icons.thunderstorm, '확인', widget.onDismissAlert),
              _banner(widget.notice, Colors.blueGrey.shade800, Icons.info_outline, '다시 시도', widget.onRetrySource),
            ]),
          ),
          // 오른쪽 위: GPS 상태, 나침반, 방위
          Positioned(
            top: pad.top + 8,
            right: 10,
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              _GpsStatusChip(snap: widget.snap, sourceLabel: widget.sourceLabel),
              const SizedBox(height: 10),
              _CompassButton(map: widget.map, heading: widget.heading),
              const SizedBox(height: 6),
              // "전방 내리막 -5m · -4%" (바라보는 방향 100 m 앞)
              ValueListenableBuilder<String?>(
                valueListenable: widget.analysis.slope,
                builder: (_, s, __) => s == null
                    ? const SizedBox.shrink()
                    : _MapChip(
                        icon: s.contains('오르막')
                            ? Icons.north_east
                            : s.contains('내리막')
                                ? Icons.south_east
                                : Icons.east,
                        text: s,
                      ),
              ),
            ]),
          ),
          // 오른쪽 아래(패널 위): 3D, 내 위치
          ValueListenableBuilder<double>(
            valueListenable: _sheet,
            builder: (_, ext, __) => Positioned(
              right: 10,
              bottom: ext * box.maxHeight + 10,
              child: Column(children: [
                _RoundButton(
                  tooltip: '지도 레이어',
                  onTap: _showLayers,
                  child: const Icon(Icons.layers_outlined, size: 22),
                ),
                const SizedBox(height: 10),
                ValueListenableBuilder<bool>(
                  valueListenable: _viewshedOn,
                  builder: (_, on, __) => _RoundButton(
                    tooltip: '가시권 (지형에 가려 안 보이는 곳)',
                    active: on,
                    onTap: _toggleViewshed,
                    child: const Icon(Icons.visibility_outlined, size: 22),
                  ),
                ),
                const SizedBox(height: 10),
                ValueListenableBuilder<bool>(
                  valueListenable: widget.map.tilted,
                  builder: (_, on, __) => _RoundButton(
                    tooltip: '3D (기울여 보기)',
                    active: on,
                    onTap: widget.map.toggleTilt,
                    child: const Text('3D', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  ),
                ),
                const SizedBox(height: 10),
                ValueListenableBuilder<bool>(
                  valueListenable: widget.map.follow,
                  builder: (_, on, __) => _RoundButton(
                    tooltip: '내 위치',
                    active: on,
                    onTap: () {
                      final s = widget.snap.value;
                      if (s.lat != null && s.lon != null) widget.map.recenter(s.lat!, s.lon!);
                    },
                    child: const Icon(Icons.navigation, size: 22),
                  ),
                ),
              ]),
            ),
          ),
          // 왼쪽 아래(패널 위): 일출·일몰까지 남은 시간
          ValueListenableBuilder<double>(
            valueListenable: _sheet,
            builder: (_, ext, __) => Positioned(
              left: 10,
              bottom: ext * box.maxHeight + 10,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // "수원지 1.5 km 외 2곳" — 누르면 목록, 지도에는 1~5 번호 점 (기본 파랑, 긴급 주황)
                ValueListenableBuilder<List<WaterSource>>(
                  valueListenable: widget.analysis.water,
                  builder: (_, ws, __) => ws.isEmpty
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: GestureDetector(
                            onTap: _showWater,
                            child: _MapChip(
                                icon: ws.any((w) => w.emergency) ? Icons.warning_amber_rounded : Icons.water_drop_outlined,
                                text: waterChipLabel(ws)),
                          ),
                        ),
                ),
                GestureDetector(
                  onTap: () {
                    final d = widget.analysis.sunDetail();
                    if (d == null) return _needDem();
                    showDialog<void>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('오늘 해'),
                        content: Text(d),
                        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기'))],
                      ),
                    );
                  },
                  child: _SunChip(analysis: widget.analysis),
                ),
              ]),
            ),
          ),
          // 아래 정보 패널 (끌어올리면 더 보임)
          NotificationListener<DraggableScrollableNotification>(
            onNotification: (n) {
              _sheet.value = n.extent;
              return false;
            },
            child: DraggableScrollableSheet(
              initialChildSize: _panelInit,
              minChildSize: _panelMin,
              maxChildSize: _panelMax,
              builder: (_, scroll) => _InfoPanel(
                scroll: scroll,
                guide: widget.guide,
                analysis: widget.analysis,
                route: widget.route,
                snap: widget.snap,
                sensors: widget.sensors,
                weather: widget.weather,
                track: widget.track,
              ),
            ),
          ),
        ]);
      }),
      bottomNavigationBar: _BottomBar(
        track: widget.track,
        onTrack: _toggleTrack,
        onWaypoint: _saveWaypoint,
        onOffline: () => Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => const MapDownloadPage())),
        onTools: _openTools,
      ),
    );
  }

  Widget _banner(ValueListenable<String?> msg, Color color, IconData icon, String action, VoidCallback onAction) =>
      ValueListenableBuilder<String?>(
        valueListenable: msg,
        builder: (_, m, __) => m == null
            ? const SizedBox.shrink()
            : Material(
                color: color,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                  child: Row(children: [
                    Icon(icon, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(m, style: const TextStyle(fontSize: 13))),
                    TextButton(onPressed: onAction, child: Text(action)),
                  ]),
                ),
              ),
      );
}

// ---------------- 지도 위 작은 위젯들 ----------------

/// 오차에 따라 초록(5 m 미만) / 노랑(15 m 미만) / 빨강
Color accuracyColor(double? hAcc) => hAcc == null
    ? Colors.grey
    : hAcc < 5
        ? Colors.greenAccent.shade400
        : hAcc < 15
            ? Colors.amberAccent
            : Colors.redAccent;

class _GpsStatusChip extends StatelessWidget {
  final ValueListenable<GnssSnapshot> snap;
  final String sourceLabel;
  const _GpsStatusChip({required this.snap, required this.sourceLabel});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<GnssSnapshot>(
        valueListenable: snap,
        builder: (_, s, __) {
          final used = s.sats.where((x) => x.used).length;
          final fix = s.lat != null && used > 0;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(16)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.circle, size: 10, color: fix ? accuracyColor(s.hAcc) : Colors.grey),
              const SizedBox(width: 6),
              Text(
                fix ? '$sourceLabel · 위성 $used' : '$sourceLabel · 위성 탐색 중',
                style: const TextStyle(fontSize: 12, color: Colors.white),
              ),
            ]),
          );
        },
      );
}

class _CompassButton extends StatelessWidget {
  final MapControl map;
  final ValueListenable<double?> heading;
  const _CompassButton({required this.map, required this.heading});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
      // 지도 회전에 맞춰 N 표시가 실제 북쪽을 가리킴. 누르면 진행 방향 위 <-> 북쪽 위
      ValueListenableBuilder<CameraPosition?>(
        valueListenable: map.camera,
        builder: (_, cam, __) => ValueListenableBuilder<bool>(
          valueListenable: map.headingUp,
          builder: (_, up, __) => _RoundButton(
            tooltip: up ? '북쪽을 위로' : '진행 방향을 위로',
            active: up,
            onTap: () => map.toggleHeadingUp(heading.value),
            child: Transform.rotate(
              angle: -(cam?.bearing ?? 0) * math.pi / 180,
              child: const Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.navigation, size: 16, color: Colors.redAccent),
                Text('N', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, height: 1)),
              ]),
            ),
          ),
        ),
      ),
      const SizedBox(height: 6),
      ValueListenableBuilder<double?>(
        valueListenable: heading,
        builder: (_, h, __) => h == null
            ? const SizedBox.shrink()
            : Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(10)),
                child: Text(directionLabel(h), style: const TextStyle(fontSize: 12, color: Colors.white)),
              ),
      ),
    ]);
  }
}

class _RoundButton extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  final bool active;
  final String tooltip;
  const _RoundButton({required this.child, required this.onTap, required this.tooltip, this.active = false});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: active ? const Color(0xFF2F6BFF) : const Color(0xE61E2026),
          shape: const CircleBorder(),
          elevation: 3,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(width: 50, height: 50, child: Center(child: child)),
          ),
        ),
      );
}

/// "일출까지 7시간 31분" — 고도 데이터가 있으면 산 능선 위로 해가 보이는 시각 기준
class _SunChip extends StatefulWidget {
  final TerrainAnalysis analysis;
  const _SunChip({required this.analysis});

  @override
  State<_SunChip> createState() => _SunChipState();
}

class _SunChipState extends State<_SunChip> {
  late final Stream<int> _tick = Stream.periodic(const Duration(seconds: 30), (i) => i);

  @override
  Widget build(BuildContext context) => StreamBuilder<int>(
        stream: _tick,
        builder: (_, __) => ValueListenableBuilder(
          valueListenable: widget.analysis.sunToday,
          builder: (_, __, ___) {
            final text = widget.analysis.sunChip(DateTime.now());
            if (text == null) return const SizedBox.shrink();
            return _MapChip(icon: text.startsWith('일출') ? Icons.wb_twilight : Icons.wb_sunny_outlined, text: text);
          },
        ),
      );
}

class _MapChip extends StatelessWidget {
  final IconData icon;
  final String text;
  const _MapChip({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: const Color(0xE61E2026), borderRadius: BorderRadius.circular(16)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: Colors.white70),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(fontSize: 12, color: Colors.white)),
        ]),
      );
}

// ---------------- 아래 정보 패널 ----------------

class _InfoPanel extends StatelessWidget {
  final ScrollController scroll;
  final Guide guide;
  final RouteFollow route;
  final TerrainAnalysis analysis;
  final ValueListenable<GnssSnapshot> snap;
  final ValueListenable<List<SensorSample>> sensors;
  final ValueListenable<StormStatus> weather;
  final TrackRecorder track;
  const _InfoPanel({
    required this.scroll,
    required this.guide,
    required this.route,
    required this.analysis,
    required this.snap,
    required this.sensors,
    required this.weather,
    required this.track,
  });

  @override
  Widget build(BuildContext context) {
    const label = TextStyle(fontSize: 12, color: Colors.white60);
    return Material(
      color: const Color(0xFF16181C),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(16, 6, 16, 16), children: [
        Center(
          child: Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
          ),
        ),
        _RouteCard(route: route),
        _GuideCard(guide: guide, analysis: analysis),
        Row(children: [
          Expanded(
            child: ValueListenableBuilder<GnssSnapshot>(
              valueListenable: snap,
              builder: (_, s, __) => _PanelItem(
                icon: Icons.navigation,
                iconColor: const Color(0xFF4D7CFE),
                title: 'GPS 현재 위치',
                value: s.hAcc != null
                    ? '오차범위 ±${s.hAcc!.toStringAsFixed(1)} m'
                    : s.lat != null
                        ? '측위 중'
                        : '측위 대기',
                valueColor: s.hAcc == null ? null : accuracyColor(s.hAcc),
              ),
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<double>(
              valueListenable: track.distance,
              builder: (_, d, __) => ValueListenableBuilder<bool>(
                valueListenable: track.recording,
                builder: (_, rec, __) => _PanelItem(
                  icon: Icons.timeline,
                  iconColor: Colors.orangeAccent,
                  title: rec ? '이동 기록 중' : '이동 기록',
                  value: distanceLabel(d),
                ),
              ),
            ),
          ),
        ]),
        const Divider(height: 24, color: Colors.white12),
        ValueListenableBuilder<List<SensorSample>>(
          valueListenable: sensors,
          builder: (_, list, __) {
            final last = list.isEmpty ? null : list.last;
            return Row(children: [
              _mini('기압', last?.pressure, 'hPa', 1, 2, Colors.lightBlueAccent, (s) => s.pressure),
              _mini('온도', last?.temp, '°C', 1, 2, Colors.orangeAccent, (s) => s.temp),
              _mini('습도', last?.humidity, '%', 0, 5, Colors.tealAccent, (s) => s.humidity),
            ]);
          },
        ),
        const SizedBox(height: 14),
        ValueListenableBuilder<List<SensorSample>>(
          valueListenable: sensors,
          builder: (_, list, __) {
            final last = list.isEmpty ? null : list.last;
            final alt = last?.baroAlt ?? last?.gnssAlt;
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('고도', style: label),
              Text(alt == null ? '--' : '${alt.round()} m',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
            ]);
          },
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 56,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: LineChartPainter<SensorSample>(
                  sensors, (s) => s.baroAlt ?? s.gnssAlt, Colors.lightGreenAccent, 0, 5,
                  second: (s) => s.gnssAlt),
              size: Size.infinite,
            ),
          ),
        ),
        const SizedBox(height: 12),
        ValueListenableBuilder<StormStatus>(
          valueListenable: weather,
          builder: (_, w, __) => Text(
            w.qnh == null ? w.text : '해면기압 ${w.qnh!.toStringAsFixed(1)} hPa · ${w.text}',
            style: TextStyle(
              fontSize: 12,
              color: switch (w.level) {
                StormLevel.storm => Colors.redAccent,
                StormLevel.warning => Colors.orangeAccent,
                StormLevel.none => Colors.white60,
              },
            ),
          ),
        ),
        const SizedBox(height: 6),
        ValueListenableBuilder<GnssSnapshot>(
          valueListenable: snap,
          builder: (_, s, __) => Text(
            s.lat == null ? '' : '위치 ${s.lat!.toStringAsFixed(5)}, ${s.lon!.toStringAsFixed(5)}',
            style: label,
          ),
        ),
      ]),
    );
  }

  Widget _mini(String title, double? v, String unit, int digits, double minSpan, Color color,
          double? Function(SensorSample) f) =>
      Expanded(
        child: Padding(
          padding: const EdgeInsets.only(right: 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 12, color: Colors.white60)),
            Text(v == null ? '—' : '${v.toStringAsFixed(digits)} $unit',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            SizedBox(
              height: 30,
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: LineChartPainter<SensorSample>(sensors, f, color, digits, minSpan, labels: false),
                  size: Size.infinite,
                ),
              ),
            ),
          ]),
        ),
      );
}

class _PanelItem extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title, value;
  final Color? valueColor;
  const _PanelItem({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icon, color: iconColor, size: 26),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            Text(value, style: TextStyle(fontSize: 12, color: valueColor ?? Colors.white60)),
          ]),
        ),
      ]);
}

class _BottomBar extends StatelessWidget {
  final TrackRecorder track;
  final VoidCallback onTrack, onWaypoint, onOffline, onTools;
  const _BottomBar({
    required this.track,
    required this.onTrack,
    required this.onWaypoint,
    required this.onOffline,
    required this.onTools,
  });

  @override
  Widget build(BuildContext context) => Material(
        color: const Color(0xFF0F1013),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 64,
            child: Row(children: [
              ValueListenableBuilder<bool>(
                valueListenable: track.recording,
                builder: (_, rec, __) => _item(
                  rec ? Icons.stop_circle_outlined : Icons.navigation_outlined,
                  rec ? '이동 중지' : '이동 시작',
                  rec ? Colors.redAccent : Colors.orangeAccent,
                  onTrack,
                ),
              ),
              _item(Icons.add_location_alt_outlined, '지점 저장', Colors.amber, onWaypoint),
              _item(Icons.download_for_offline_outlined, '오프라인', const Color(0xFF4D7CFE), onOffline),
              _item(Icons.more_horiz, '도구', Colors.white70, onTools),
            ]),
          ),
        ),
      );

  Widget _item(IconData icon, String label, Color color, VoidCallback onTap) => Expanded(
        child: InkWell(
          onTap: onTap,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, color: color),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 12)),
          ]),
        ),
      );
}

// ---------------- 도구 ----------------

class ToolsPage extends StatelessWidget {
  final RouteFollow route;
  final ValueListenable<GnssSnapshot> snap;
  final ValueListenable<List<SensorSample>> sensors;
  final ValueListenable<StormStatus> weather;
  final ValueListenable<List<(DateTime, double)>> qnhHistory;
  final ValueListenable<List<String>> log;
  final void Function(NavTarget) onGuide;
  final WaypointStore waypoints;
  final MapControl map;
  final DataSource source;
  final void Function(DataSource) onSource;
  const ToolsPage({
    required this.route,
    required this.onGuide,
    super.key,
    required this.snap,
    required this.sensors,
    required this.weather,
    required this.qnhHistory,
    required this.log,
    required this.waypoints,
    required this.map,
    required this.source,
    required this.onSource,
  });

  @override
  Widget build(BuildContext context) {
    void open(Widget page, String title) => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => Scaffold(appBar: AppBar(title: Text(title)), body: page),
        ));
    Widget tile(IconData icon, String title, String sub, VoidCallback onTap) =>
        ListTile(leading: Icon(icon), title: Text(title), subtitle: Text(sub), onTap: onTap);
    return ListView(children: [
      tile(Icons.public, '스카이플롯', '하늘의 위성 위치와 신호 세기', () => open(SkyPage(snap: snap), '스카이플롯')),
      tile(Icons.speed, '위성 품질', 'DOP, 오차, 위성별 신호', () => open(QualityPage(snap: snap), '위성 품질')),
      tile(Icons.show_chart, '센서 그래프', '해면기압 추세, 기압·온도·습도·고도',
          () => open(SensorPage(data: sensors, weather: weather, qnhHistory: qnhHistory), '센서 그래프')),
      tile(Icons.place_outlined, '저장한 지점', '거리·방위 보기, 지도에서 찾기',
          () => open(WaypointsPage(waypoints: waypoints, snap: snap, map: map, onGuide: onGuide), '저장한 지점')),
      tile(Icons.route, '경로 따라가기', 'GPX 불러오기, 내 이동 기록, 왔던 길로 돌아가기',
          () => open(RoutesPage(route: route), '경로 따라가기')),
      tile(Icons.terminal, 'NMEA 로그', '수신기 원시 문장', () => open(LogPage(log: log), 'NMEA 로그')),
      const Divider(),
      tile(Icons.settings, '설정', '위치 출처 (폰 GPS / 외부 장치)',
          () => open(SettingsPage(source: source, onSource: onSource), '설정')),
      if (updateSupported)
        tile(Icons.system_update, '앱 업데이트 확인', '새 버전이 있으면 설치',
            () => checkForUpdate(context, manual: true)),
    ]);
  }
}

class WaypointsPage extends StatelessWidget {
  final WaypointStore waypoints;
  final ValueListenable<GnssSnapshot> snap;
  final MapControl map;
  final void Function(NavTarget) onGuide;
  const WaypointsPage(
      {super.key, required this.waypoints, required this.snap, required this.map, required this.onGuide});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<Waypoint>>(
        valueListenable: waypoints.items,
        builder: (_, list, __) => list.isEmpty
            ? const Center(child: Text('아래 [지점 저장]으로 현재 위치를 저장할 수 있습니다'))
            : ValueListenableBuilder<GnssSnapshot>(
                valueListenable: snap,
                builder: (_, s, __) => ListView(children: [
                  for (final w in list.reversed)
                    ListTile(
                      leading: const Icon(Icons.place, color: Colors.deepOrangeAccent),
                      title: Text(w.name),
                      subtitle: Text(s.lat == null
                          ? '${w.lat.toStringAsFixed(5)}, ${w.lon.toStringAsFixed(5)}'
                          : '${distanceLabel(distanceM(s.lat!, s.lon!, w.lat, w.lon))}  ·  '
                              '${directionLabel(bearingDeg(s.lat!, s.lon!, w.lat, w.lon))}'),
                      onTap: () {
                        map.follow.value = false;
                        map.recenter(w.lat, w.lon);
                        map.follow.value = false;
                        Navigator.of(context).popUntil((r) => r.isFirst);
                      },
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          icon: const Icon(Icons.flag_outlined),
                          tooltip: '여기로 안내',
                          onPressed: () {
                            onGuide(NavTarget(w.name, w.lat, w.lon));
                            Navigator.of(context).popUntil((r) => r.isFirst);
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: '삭제',
                          onPressed: () => waypoints.remove(w),
                        ),
                      ]),
                    ),
                ]),
              ),
      );
}

/// 경로 따라가기: 불러온 GPX 경로와 내 이동 기록 목록. 따라가기 / 거꾸로(왔던 길로 돌아가기)
class RoutesPage extends StatefulWidget {
  final RouteFollow route;
  const RoutesPage({super.key, required this.route});

  @override
  State<RoutesPage> createState() => _RoutesPageState();
}

class _RoutesPageState extends State<RoutesPage> {
  List<File>? _routes, _tracks;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    List<File> gpx(Directory d) => d.existsSync()
        ? (d.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.gpx')).toList()
          ..sort((a, b) => b.path.compareTo(a.path)))
        : <File>[];
    final routes = gpx(await routesDir());
    final tracks = gpx(Directory('${(await getApplicationDocumentsDirectory()).path}/tracks'));
    if (mounted) {
      setState(() {
        _routes = routes;
        _tracks = tracks;
      });
    }
  }

  static String _baseName(File f) =>
      f.path.split('/').last.split(Platform.pathSeparator).last.replaceAll(RegExp(r'\.gpx$', caseSensitive: false), '');

  /// 휴대폰에서 GPX 파일을 골라 앱 폴더로 복사 (저장소 권한 없이 시스템 파일 선택기 사용)
  Future<void> _import() async {
    final messenger = ScaffoldMessenger.of(context);
    final files = await FilePicker.pickFiles(type: FileType.any);
    if (files.isEmpty) return;
    final f = files.first;
    final text = utf8.decode(await f.readAsBytes(), allowMalformed: true);
    final name = f.name.replaceAll(RegExp(r'\.gpx$', caseSensitive: false), '');
    final r = parseGpx(text, name);
    if (r == null) {
      messenger.showSnackBar(const SnackBar(content: Text('GPX 경로를 찾지 못했습니다 (trkpt/rtept 점이 없음)')));
      return;
    }
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    await File('${(await routesDir()).path}/$safe.gpx').writeAsString(text);
    messenger.showSnackBar(SnackBar(content: Text('"${r.name}" 불러옴: ${distanceLabel(r.total)}, 점 ${r.pts.length}개')));
    _load();
  }

  Future<void> _follow(File f, {bool reverse = false}) async {
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    final r = parseGpx(await f.readAsString(), _baseName(f));
    if (r == null) {
      messenger.showSnackBar(const SnackBar(content: Text('경로 점이 2개 미만입니다')));
      return;
    }
    final use = reverse ? r.reversed() : r;
    await widget.route.start(use);
    messenger.showSnackBar(SnackBar(content: Text('"${use.name}" 따라가기 시작 (${distanceLabel(use.total)})')));
    nav.popUntil((p) => p.isFirst);
  }

  Widget _tile(File f, {required bool imported}) => ListTile(
        leading: Icon(imported ? Icons.route : Icons.timeline),
        title: Text(_baseName(f)),
        subtitle: Text('${(f.lengthSync() / 1024).toStringAsFixed(1)} KB'),
        onTap: () => _follow(f),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(icon: const Icon(Icons.play_arrow), tooltip: '따라가기', onPressed: () => _follow(f)),
          IconButton(
            icon: const Icon(Icons.u_turn_left),
            tooltip: '거꾸로 (왔던 길로 돌아가기)',
            onPressed: () => _follow(f, reverse: true),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '삭제',
            onPressed: () {
              f.deleteSync();
              _load();
            },
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final routes = _routes, tracks = _tracks;
    const head = TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white70);
    return Stack(children: [
      if (routes == null || tracks == null)
        const Center(child: CircularProgressIndicator())
      else
        ListView(padding: const EdgeInsets.only(bottom: 90), children: [
          ValueListenableBuilder<GpxRoute?>(
            valueListenable: widget.route.route,
            builder: (_, r, __) => r == null
                ? const SizedBox.shrink()
                : Card(
                    margin: const EdgeInsets.all(12),
                    child: ListTile(
                      leading: const Icon(Icons.directions_walk, color: Color(0xFF9775FA)),
                      title: Text('따라가는 중: ${r.name}'),
                      subtitle: Text(distanceLabel(r.total)),
                      trailing: TextButton(onPressed: widget.route.stop, child: const Text('종료')),
                    ),
                  ),
          ),
          const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('불러온 경로', style: head)),
          if (routes.isEmpty)
            const ListTile(
              title: Text('아래 [GPX 불러오기]로 등산로 파일을 넣을 수 있습니다'),
              subtitle: Text('등산 앱·산림청 등에서 받은 .gpx 파일'),
            ),
          for (final f in routes) _tile(f, imported: true),
          const Padding(padding: EdgeInsets.fromLTRB(16, 16, 16, 4), child: Text('내 이동 기록', style: head)),
          if (tracks.isEmpty) const ListTile(title: Text('아래 [이동 시작]으로 기록하면 여기에 저장됩니다')),
          for (final f in tracks) _tile(f, imported: false),
        ]),
      Positioned(
        right: 16,
        bottom: 16,
        child: FloatingActionButton.extended(
          onPressed: _import,
          icon: const Icon(Icons.file_open_outlined),
          label: const Text('GPX 불러오기'),
        ),
      ),
    ]);
  }
}

class SettingsPage extends StatefulWidget {
  final DataSource source;
  final void Function(DataSource) onSource;
  const SettingsPage({super.key, required this.source, required this.onSource});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late DataSource _source = widget.source;

  @override
  Widget build(BuildContext context) {
    void pick(DataSource? s) {
      if (s == null) return;
      setState(() => _source = s);
      widget.onSource(s);
    }

    return ListView(children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text('위치 출처', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      RadioGroup<DataSource>(
        groupValue: _source,
        onChanged: pick,
        child: const Column(children: [
          RadioListTile<DataSource>(
            value: DataSource.phone,
            title: Text('폰 내장 GPS'),
            subtitle: Text('폰의 GPS와 기압계 사용'),
          ),
          ListTile(
            enabled: false,
            leading: Icon(Icons.radio_button_unchecked),
            title: Text('외부 GPS 장치 (ESP32 · LC29H)'),
            subtitle: Text('준비 중 — 장치가 완성되면 BLE로 연결'),
          ),
          RadioListTile<DataSource>(
            value: DataSource.sim,
            title: Text('시뮬레이션'),
            subtitle: Text('가짜 위성·센서 데이터 (테스트용)'),
          ),
        ]),
      ),
    ]);
  }
}

// ---------------- 목표 지점 안내 카드 (아래 패널 맨 위) ----------------

/// 목표까지 직선 거리·방향 화살표·걷는 시간·고도 차이·목표 방향 경사. 안내 중이 아니면 아무것도 안 그림
class _GuideCard extends StatelessWidget {
  final Guide guide;
  final TerrainAnalysis analysis;
  const _GuideCard({required this.guide, required this.analysis});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<NavTarget?>(
        valueListenable: guide.target,
        builder: (_, t, __) => t == null
            ? const SizedBox.shrink()
            : ValueListenableBuilder<GuideInfo?>(
                valueListenable: guide.info,
                builder: (_, i, __) {
                  const sub = TextStyle(fontSize: 12, color: Colors.white70);
                  final slope = i == null ? null : analysis.slopeToward(i.bearing);
                  final climb = i?.climb;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                    decoration: BoxDecoration(
                      color: i?.arrived == true ? const Color(0xFF1F3B2A) : const Color(0xFF2A1E1E),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: i?.arrived == true ? Colors.greenAccent : Colors.redAccent, width: 1),
                    ),
                    child: Row(children: [
                      // 화살표: 나침반이 있으면 폰이 향한 방향 기준(위 = 정면), 없으면 북쪽 기준
                      Transform.rotate(
                        angle: ((i?.turn ?? i?.bearing ?? 0) * math.pi / 180),
                        child: Icon(i?.arrived == true ? Icons.flag : Icons.navigation,
                            size: 40, color: i?.arrived == true ? Colors.greenAccent : Colors.redAccent),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(t.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13, color: Colors.white70)),
                          Text(
                            i == null
                                ? '현재 위치를 기다리는 중'
                                : i.arrived
                                    ? '도착 (${distanceLabel(i.distance)})'
                                    : '${distanceLabel(i.distance)}  ·  '
                                        '${i.turn == null ? directionLabel(i.bearing) : turnLabel(i.turn!)}',
                            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
                          ),
                          if (i != null && !i.arrived)
                            Text(
                              [
                                if (i.turn != null) '방위 ${directionLabel(i.bearing)}',
                                '걸어서 약 ${durationLabel(i.walk)}',
                                if (climb != null && climb.abs() >= 10)
                                  '목표가 ${climb.abs().round()} m ${climb > 0 ? '높음' : '낮음'}',
                              ].join('  ·  '),
                              style: sub,
                            ),
                          if (slope != null && i != null && !i.arrived) Text('목표 방향 $slope', style: sub),
                        ]),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: '안내 종료',
                        onPressed: guide.stop,
                      ),
                    ]),
                  );
                },
              ),
      );
}

// ---------------- GPX 경로 따라가기 카드 (아래 패널 맨 위) ----------------

class _RouteCard extends StatelessWidget {
  final RouteFollow route;
  const _RouteCard({required this.route});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<GpxRoute?>(
        valueListenable: route.route,
        builder: (_, r, __) => r == null
            ? const SizedBox.shrink()
            : ValueListenableBuilder<RouteInfo?>(
                valueListenable: route.info,
                builder: (_, i, __) {
                  const sub = TextStyle(fontSize: 12, color: Colors.white70);
                  final off = i?.offRoute == true;
                  final pct = i == null || r.total == 0 ? 0 : (i.done / r.total * 100).round();
                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                    decoration: BoxDecoration(
                      color: off ? const Color(0xFF3B1E1E) : const Color(0xFF241E36),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: off ? Colors.redAccent : const Color(0xFF9775FA)),
                    ),
                    child: Row(children: [
                      Icon(off ? Icons.wrong_location_outlined : Icons.directions_walk,
                          size: 34, color: off ? Colors.redAccent : const Color(0xFF9775FA)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(r.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13, color: Colors.white70)),
                          Text(
                            i == null
                                ? '현재 위치를 기다리는 중'
                                : i.finished
                                    ? '경로 끝 도착'
                                    : off
                                        ? '경로 이탈 ${distanceLabel(i.off)}'
                                        : '남은 ${distanceLabel(i.left)}  ·  $pct%',
                            style: TextStyle(
                                fontSize: 19, fontWeight: FontWeight.w700, color: off ? Colors.redAccent : null),
                          ),
                          if (i != null && !i.finished)
                            Text(
                              off
                                  ? '경로로 돌아가기: ${directionLabel(i.toRoute)} 방향'
                                  : [
                                      '진행 방향 ${directionLabel(i.ahead)}',
                                      '걸어서 약 ${durationLabel(i.walk)}',
                                      if (i.climbLeft >= 10) '남은 오르막 ${i.climbLeft.round()} m',
                                    ].join('  ·  '),
                              style: sub,
                            ),
                          if (i != null && r.total > 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 6, right: 8),
                              child: LinearProgressIndicator(
                                value: (i.done / r.total).clamp(0.0, 1.0),
                                color: const Color(0xFF9775FA),
                                backgroundColor: Colors.white12,
                              ),
                            ),
                        ]),
                      ),
                      IconButton(icon: const Icon(Icons.close), tooltip: '따라가기 종료', onPressed: route.stop),
                    ]),
                  );
                },
              ),
      );
}
