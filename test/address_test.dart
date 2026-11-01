import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gnss_tool/address.dart';

void main() {
  late String path;

  setUpAll(() {
    final b = AddressIndexBuilder()
      ..addAddress('정관로', '123', '부산광역시 기장군', 35.3210, 129.1780)
      ..addAddress('정관로', '125', '부산광역시 기장군', 35.3212, 129.1782)
      ..addAddress('정관로', '120', '', 35.3208, 129.1779) // 지역 모름 -> 같은 칸의 지역으로
      ..addAddress('정관로', '10', '경기도 김포시', 37.6000, 126.7000) // 다른 도시의 같은 이름
      ..addAddress('대덕대로578번길', '27', '대전광역시 유성구', 36.3700, 127.3800)
      ..addAddress('일출로', '284-12', '제주특별자치도 서귀포시', 33.4580, 126.9300)
      ..addPlace('정관박물관', 7, 35.3250, 129.1800)
      ..addPlace('구목정 공원', 8, 35.3230, 129.1750)
      ..addPlace('관악산', 1, 37.4440, 126.9640)
      ..addPlace('구연방곡로', 14, 35.3300, 129.1700); // 번지 자료 없는 도로
    path = '${Directory.systemTemp.createTempSync('addr').path}/t.gad';
    b.write(path);
  });

  test('parses queries', () {
    final q = parseQuery('부산 기장군 정관로 123-4');
    expect(q.region, ['부산', '기장군']);
    expect(q.road, '정관로');
    expect(q.number, (123, 4));
    expect(parseQuery('대덕대로 578번길 27').road, '대덕대로578번길');
    expect(parseQuery('정관박물관').road, isNull);
    expect(parseHouseNumber('284-12'), (284, 12));
    expect(parseHouseNumber('산12'), isNull);
  });

  test('finds an exact road-name address', () {
    final r = searchAddress(path, '정관로 123', lat: 35.32, lon: 129.17);
    expect(r.first.title, '정관로 123');
    expect(r.first.exact, isTrue);
    expect(r.first.lat, closeTo(35.3210, 1e-6));
    expect(r.first.detail, '부산광역시 기장군');
    expect(searchAddress(path, '대덕대로 578번길 27').single.lat, closeTo(36.37, 1e-6));
    expect(searchAddress(path, '일출로 284-12').single.lon, closeTo(126.93, 1e-6));
  });

  test('missing number falls back to the nearest one on the same side', () {
    final r = searchAddress(path, '부산 정관로 127');
    expect(r.first.exact, isFalse);
    expect(r.first.detail, contains('125'));
  });

  test('region narrows same-named roads; unknown region is filled from the area', () {
    final r = searchAddress(path, '김포 정관로 10');
    expect(r.single.lat, closeTo(37.6, 1e-6));
    final roads = searchAddress(path, '정관로', lat: 35.32, lon: 129.17);
    expect(roads.first.detail, '도로 · 부산광역시 기장군');
  });

  test('finds places by name, ignoring spaces', () {
    expect(searchAddress(path, '정관 박물관').first.title, '정관박물관');
    expect(searchAddress(path, '구목정공원').first.detail, '공원');
    final r = searchAddress(path, '정관', lat: 35.32, lon: 129.17);
    expect(r.map((h) => h.title), containsAll(['정관로', '정관박물관']));
    expect(searchAddress(path, '없는곳'), isEmpty);
  });

  test('a road without house numbers still gives the road position', () {
    final r = searchAddress(path, '구연방곡로 120');
    expect(r.single.exact, isFalse);
    expect(r.single.title, '구연방곡로 120');
    expect(r.single.detail, contains('도로 위치'));
    expect(r.single.lat, closeTo(35.33, 1e-6));
  });

  test('search thread keeps the data loaded', () async {
    final s = await AddressSearcher.open(path);
    expect(identical(await AddressSearcher.open(path), s), isTrue);
    expect((await s.search('정관로 123')).first.title, '정관로 123');
    expect((await s.search('관악산')).first.detail, '산');
  });
}
