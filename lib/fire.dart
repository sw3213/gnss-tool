import 'water.dart' show PmTiles, nearestArea;

// ============================================================
// 불 사용(화기) 참고: 지도 자료의 숲·국립공원 경계로 "여기서 불을 피워도 되는지" 어림
//   - 산림보호법: 산림과 산림에서 100 m 안(산림인접지역)에서는 불을 피우면 안 됨 (과태료)
//   - 자연공원법: 국립공원 안에서는 지정된 곳 밖에서 불을 쓰면 안 됨
// 지도에 그려진 숲만 알 수 있고, 지자체가 따로 정한 금지·건조특보·사유지는 모름 -> 참고용으로만 보여 줌
// ============================================================

const forestBufferM = 100.0; // 산림인접지역

class FireStatus {
  final double? forestM; // 가장 가까운 숲까지 (m, 숲 안이면 0). 주변 약 2 km 안에 없으면 null
  final bool inPark; // 국립공원 안
  final String? parkName;
  const FireStatus({this.forestM, this.inPark = false, this.parkName});

  /// 법으로 금지된 곳으로 보임 (국립공원 안, 숲 안이나 숲 100 m 안)
  bool get banned => inPark || (forestM != null && forestM! < forestBufferM);

  /// 지도 칩 글씨: "불 금지" / "불 가능"
  String get chip => banned ? '불 금지' : '불 가능';

  /// 한 줄 설명
  String get summary {
    final f = forestM;
    if (inPark) return '${parkName ?? '국립공원'} 안: 지정된 곳 밖에서 불 사용 금지 (자연공원법)';
    if (f == null) return '주변 2 km 안에 지도에 그려진 숲 없음: 산림인접지역 밖으로 보임';
    if (f == 0) return '숲 안: 불 피우기 금지 (산림보호법)';
    if (f < forestBufferM) return '숲까지 ${f.round()} m: 100 m 안이라 불 피우기 금지 (산림보호법)';
    return '숲까지 ${f.round()} m: 산림인접지역(100 m) 밖으로 보임';
  }

  /// 주의 사항 (판단은 사용자가)
  static const caution = '지도에 그려진 숲만 봅니다. 지자체 금지, 산불조심기간·건조특보, 사유지는 따로 확인하세요. '
      '긴급할 때도 바람을 피하고 주변을 정리한 뒤 작게, 반드시 완전히 끄세요';
}

/// 숲: landuse의 forest(조림지)·wood(자연림)
bool isForest(Map<String, Object?> p) => p['kind'] == 'forest' || p['kind'] == 'wood';

/// 국립공원
bool isNationalPark(Map<String, Object?> p) => p['kind'] == 'national_park';

/// 기본 지도(z14 타일)로 불 사용 참고 정보 계산
FireStatus fireStatus(PmTiles pm, double lat, double lon) {
  final forest = nearestArea(pm, lat, lon, 'landuse', isForest);
  final park = nearestArea(pm, lat, lon, 'landuse', isNationalPark, maxRing: 0);
  final inPark = park != null && park.$1 == 0;
  return FireStatus(
    forestM: forest?.$1,
    inPark: inPark,
    parkName: inPark ? (park.$2['name:ko'] ?? park.$2['name']) as String? : null,
  );
}
