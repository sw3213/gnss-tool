import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:ota_update/ota_update.dart';
import 'package:package_info_plus/package_info_plus.dart';

// ============================================================
// 앱 내 업데이트: GitHub Release(build-N 태그)의 빌드 번호와 내 빌드 번호 비교
// ============================================================

const _latestUrl = 'https://api.github.com/repos/sw3213/gnss-tool/releases/latest';
const _apkName = 'gnss_tool.apk'; // build.yml에서 Release에 올리는 파일 이름과 같아야 함

class AppRelease {
  final int build;
  final String apkUrl;
  final String notes;
  const AppRelease(this.build, this.apkUrl, this.notes);
}

bool get updateSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// 새 빌드가 있으면 반환, 없으면 null. 네트워크 오류는 예외로 던짐
Future<AppRelease?> findUpdate() async {
  final info = await PackageInfo.fromPlatform();
  final mine = int.tryParse(info.buildNumber) ?? 0;
  final res = await http.get(Uri.parse(_latestUrl),
      headers: {'Accept': 'application/vnd.github+json'}).timeout(const Duration(seconds: 8));
  if (res.statusCode == 404) return null; // 아직 Release 없음
  if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');

  final j = jsonDecode(res.body) as Map<String, dynamic>;
  final tag = j['tag_name'] as String? ?? '';
  final build = int.tryParse(RegExp(r'(\d+)$').firstMatch(tag)?.group(1) ?? '');
  if (build == null || build <= mine) return null;

  final asset = (j['assets'] as List)
      .cast<Map<String, dynamic>>()
      .where((a) => a['name'] == _apkName)
      .firstOrNull;
  if (asset == null) return null;
  return AppRelease(build, asset['browser_download_url'] as String, (j['body'] as String? ?? '').trim());
}

/// 앱 시작 시 자동 확인은 조용히(오프라인 사용이 기본), [manual]이면 결과를 알려 줌
Future<void> checkForUpdate(BuildContext context, {bool manual = false}) async {
  if (!updateSupported) return;
  final messenger = ScaffoldMessenger.of(context);
  AppRelease? rel;
  try {
    rel = await findUpdate();
  } catch (_) {
    if (manual) {
      messenger.showSnackBar(const SnackBar(content: Text('업데이트 확인 실패 (인터넷 연결 확인)')));
    }
    return;
  }
  if (rel == null) {
    if (manual) messenger.showSnackBar(const SnackBar(content: Text('최신 버전입니다')));
    return;
  }
  if (!context.mounted) return;

  final r = rel;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('새 버전 (빌드 ${r.build})'),
      content: SingleChildScrollView(
        child: Text(r.notes.isEmpty ? '설치할까요?' : '${r.notes}\n\n설치할까요?'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('나중에')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('업데이트')),
      ],
    ),
  );
  if (ok == true && context.mounted) _install(context, r);
}

void _install(BuildContext context, AppRelease rel) {
  final status = ValueNotifier<String>('다운로드 준비 중...');
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('업데이트'),
      content: ValueListenableBuilder<String>(
        valueListenable: status,
        builder: (_, s, __) => Text(s),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기'))],
    ),
  );

  OtaUpdate().execute(rel.apkUrl, destinationFilename: _apkName).listen(
    (e) {
      status.value = switch (e.status) {
        OtaStatus.DOWNLOADING => '다운로드 중... ${e.value ?? 0}%',
        OtaStatus.INSTALLING => '설치 화면에서 [업데이트]를 눌러 주세요',
        OtaStatus.INSTALLATION_DONE => '설치 완료',
        OtaStatus.PERMISSION_NOT_GRANTED_ERROR =>
          '설치 권한이 필요합니다.\n설정에서 이 앱의 "출처를 알 수 없는 앱 설치"를 허용한 뒤 다시 시도해 주세요.',
        _ => '업데이트 실패: ${e.status.name} ${e.value ?? ''}',
      };
    },
    onError: (Object e) => status.value = '업데이트 실패: $e',
  );
}
