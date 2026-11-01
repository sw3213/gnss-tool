import 'dart:async';

import 'package:flutter/material.dart';

import 'address.dart';
import 'nav.dart';
import 'offline_map.dart';

// ---------------- 주소·장소 검색 화면 ----------------
// 도로명주소("정관로 123")나 이름("정관박물관")을 치면 폰 안의 자료(kr-addr.gad)에서 찾음.
// 결과를 누르면 그 결과를 돌려주고 닫힘 (메인 화면이 지도를 옮기고 "길 따라 안내" 메뉴를 띄움)

class SearchPage extends StatefulWidget {
  final double? lat, lon; // 지금 위치: 가까운 순 정렬과 거리 표시
  const SearchPage({super.key, this.lat, this.lon});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _text = TextEditingController();
  Timer? _wait;
  List<SearchHit>? _hits; // null: 아직 안 찾음
  bool _busy = false;
  String? _error;
  int _seq = 0; // 늦게 끝난 옛 검색 결과는 버림

  String? get _file {
    final store = MapStore.instance;
    final p = store.installed.value.where((p) => p.kind == 'address').firstOrNull;
    return p == null ? null : store.fileOf(p.id);
  }

  @override
  void dispose() {
    _wait?.cancel();
    _text.dispose();
    super.dispose();
  }

  void _changed(String q) {
    _wait?.cancel();
    _wait = Timer(const Duration(milliseconds: 500), () => _search(q)); // 다 칠 때까지 잠깐 기다림
  }

  Future<void> _search(String q) async {
    final path = _file;
    if (path == null || q.trim().isEmpty) {
      setState(() => _hits = null);
      return;
    }
    final seq = ++_seq;
    setState(() => _busy = true);
    try {
      final r = await (await AddressSearcher.open(path)).search(q, lat: widget.lat, lon: widget.lon);
      if (mounted && seq == _seq) setState(() {
          _hits = r;
          _error = null;
        });
    } catch (e) {
      if (mounted && seq == _seq) setState(() => _error = '$e');
    } finally {
      if (mounted && seq == _seq) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasData = _file != null;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _text,
          autofocus: hasData,
          enabled: hasData,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(hintText: '주소나 장소 이름 (예: 정관로 123)', border: InputBorder.none),
          onChanged: _changed,
          onSubmitted: _search,
        ),
        actions: [
          if (_text.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              tooltip: '지우기',
              onPressed: () {
                _text.clear();
                setState(() => _hits = null);
              },
            ),
        ],
        // 높이를 항상 같게 (찾는 중 표시가 생겼다 없어지며 입력칸이 들썩이지 않게)
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: _busy ? const LinearProgressIndicator(minHeight: 2) : const SizedBox(height: 2),
        ),
      ),
      body: !hasData ? _needData(context) : _results(),
    );
  }

  Widget _needData(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.travel_explore, size: 48, color: Colors.white38),
            const SizedBox(height: 12),
            const Text('주소 검색에는 "대한민국 주소 검색" 자료가 필요합니다', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.download),
              label: const Text('자료 받으러 가기'),
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MapDownloadPage()));
                if (mounted) setState(() {});
              },
            ),
          ]),
        ),
      );

  Widget _results() {
    if (_error != null) return Center(child: Text('검색 실패: $_error'));
    final hits = _hits;
    if (hits == null) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Text('도로명주소: 정관로 123, 부산 정관로 123-4\n장소 이름: 정관박물관, 관악산\n\n인터넷 없이 폰 안에서 찾습니다',
            style: TextStyle(color: Colors.white60, height: 1.6)),
      );
    }
    if (hits.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Text('찾지 못했습니다. 도로 이름과 번호 사이를 띄어 보세요 (예: 정관로 123)',
            style: TextStyle(color: Colors.white60)),
      );
    }
    final lat = widget.lat, lon = widget.lon;
    return ListView.separated(
      itemCount: hits.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final h = hits[i];
        return ListTile(
          leading: Icon(h.exact ? Icons.place_outlined : Icons.wrong_location_outlined,
              color: h.exact ? null : Colors.orangeAccent),
          title: Text(h.title),
          subtitle: Text(h.detail),
          trailing: lat == null || lon == null
              ? null
              : Text(distanceLabel(distanceM(lat, lon, h.lat, h.lon)), style: const TextStyle(color: Colors.white70)),
          onTap: () => Navigator.of(context).pop(h),
        );
      },
    );
  }
}
