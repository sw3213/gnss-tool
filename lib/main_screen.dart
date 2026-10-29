import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show CameraPosition;
import 'package:path_provider/path_provider.dart';

import 'main.dart';
import 'nav.dart';
import 'offline_map.dart';
import 'updater.dart';
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

  const MainScreen({
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

const _panelMin = 0.13, _panelInit = 0.24, _panelMax = 0.62;

class _MainScreenState extends State<MainScreen> {
  final _sheet = ValueNotifier<double>(_panelInit); // 아래 패널이 화면에서 차지하는 비율

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

  Future<void> _saveWaypoint() async {
    final s = widget.snap.value;
    final messenger = ScaffoldMessenger.of(context);
    if (s.lat == null || s.lon == null) {
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
    await widget.waypoints.add(Waypoint(name.trim(), s.lat!, s.lon!, s.alt, DateTime.now()));
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
            ]),
          ),
          // 오른쪽 아래(패널 위): 3D, 내 위치
          ValueListenableBuilder<double>(
            valueListenable: _sheet,
            builder: (_, ext, __) => Positioned(
              right: 10,
              bottom: ext * box.maxHeight + 10,
              child: Column(children: [
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
              child: _SunChip(snap: widget.snap),
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

class _SunChip extends StatefulWidget {
  final ValueListenable<GnssSnapshot> snap;
  const _SunChip({required this.snap});

  @override
  State<_SunChip> createState() => _SunChipState();
}

class _SunChipState extends State<_SunChip> {
  late final Stream<int> _tick = Stream.periodic(const Duration(seconds: 30), (i) => i);

  @override
  Widget build(BuildContext context) => StreamBuilder<int>(
        stream: _tick,
        builder: (_, __) {
          final s = widget.snap.value;
          final text = s.lat == null ? null : sunCountdown(DateTime.now(), s.lat!, s.lon!);
          if (text == null) return const SizedBox.shrink();
          return _MapChip(icon: text.startsWith('일출') ? Icons.wb_twilight : Icons.wb_sunny_outlined, text: text);
        },
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
  final ValueListenable<GnssSnapshot> snap;
  final ValueListenable<List<SensorSample>> sensors;
  final ValueListenable<StormStatus> weather;
  final TrackRecorder track;
  const _InfoPanel({
    required this.scroll,
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
  final ValueListenable<GnssSnapshot> snap;
  final ValueListenable<List<SensorSample>> sensors;
  final ValueListenable<StormStatus> weather;
  final ValueListenable<List<(DateTime, double)>> qnhHistory;
  final ValueListenable<List<String>> log;
  final WaypointStore waypoints;
  final MapControl map;
  final DataSource source;
  final void Function(DataSource) onSource;
  const ToolsPage({
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
          () => open(WaypointsPage(waypoints: waypoints, snap: snap, map: map), '저장한 지점')),
      tile(Icons.route, '이동 기록 파일', '저장된 GPX 파일', () => open(const TracksPage(), '이동 기록 파일')),
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
  const WaypointsPage({super.key, required this.waypoints, required this.snap, required this.map});

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
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: '삭제',
                        onPressed: () => waypoints.remove(w),
                      ),
                    ),
                ]),
              ),
      );
}

class TracksPage extends StatefulWidget {
  const TracksPage({super.key});

  @override
  State<TracksPage> createState() => _TracksPageState();
}

class _TracksPageState extends State<TracksPage> {
  List<File>? _files;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = Directory('${(await getApplicationDocumentsDirectory()).path}/tracks');
    final files = d.existsSync() ? d.listSync().whereType<File>().where((f) => f.path.endsWith('.gpx')).toList() : <File>[];
    files.sort((a, b) => b.path.compareTo(a.path));
    if (mounted) setState(() => _files = files);
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    if (files == null) return const Center(child: CircularProgressIndicator());
    if (files.isEmpty) return const Center(child: Text('아래 [이동 시작]으로 기록하면 여기에 저장됩니다'));
    return ListView(children: [
      for (final f in files)
        ListTile(
          leading: const Icon(Icons.route),
          title: Text(f.path.split(Platform.pathSeparator).last.split('/').last),
          subtitle: Text('${(f.lengthSync() / 1024).toStringAsFixed(1)} KB'),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '삭제',
            onPressed: () {
              f.deleteSync();
              _load();
            },
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
