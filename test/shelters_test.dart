import 'package:flutter_test/flutter_test.dart';
import 'package:gnss_tool/shelters.dart';

void main() {
  const json = '{"date":"2026-11-06","items":['
      '["보은교회(지하1층 예배실)","공공용시설",1,158,"충청북도 보은군 보은읍 보은로 134",36.486107,127.718355],'
      '["사동리 제1공영주차장 지하 1층","공공용시설",1,1617,"경기도 이천시 대월면 대산로208번길 93-46",37.243783,127.48243],'
      '["가까운 학교 운동장","정부지원시설",0,0,"",36.4870,127.7190]]}';

  test('reads the shelter file', () {
    final s = parseShelters(json);
    expect(s.length, 3);
    expect(s[1].name, '사동리 제1공영주차장 지하 1층');
    expect(s[1].underground, isTrue);
    expect(s[1].summary, '지하 · 공공용시설 · 1,617명');
    expect(s[2].summary, '지상 · 정부지원시설');
  });

  test('finds the nearest shelters within range', () {
    final idx = ShelterIndex(parseShelters(json));
    final near = idx.nearest(36.4862, 127.7185);
    expect(near.map((e) => e.$1.name), ['보은교회(지하1층 예배실)', '가까운 학교 운동장']); // 이천은 5 km 밖
    expect(near.first.$2, lessThan(30));
    expect(shelterChipLabel(near), startsWith('대피소 '));
    expect(shelterChipLabel(near), endsWith(' 외 1곳'));
    expect(idx.nearest(35.0, 129.0), isEmpty);
    expect(shelterChipLabel(const []), '');
  });

  test('facility files carry their kind and an info line', () {
    final s = parseShelters('{"date":"2026-11-06","cat":"dust","items":['
        '["대잠3 경로당","마을회관",0,48,"경북 포항시 남구 새천년대로422번길 7-7",36.013563,129.345144,"평일 09:00~18:00 · 054-275-6259"]]}');
    expect(s.single.cat, 'dust');
    expect(s.single.info, '평일 09:00~18:00 · 054-275-6259');
    expect(s.single.summary, '마을회관 · 48명'); // 지하/지상은 민방위 대피소만
    expect(facilityLabel('dust'), '미세먼지쉼터');
    expect(parseShelters('{"items":[["a","b",1,0,"",36.0,127.0]]}').single.cat, 'shelter');
  });
}
