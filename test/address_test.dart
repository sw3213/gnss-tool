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
      ..addPlace('구연방곡로', 14, 35.3300, 129.1700) // 번지 자료 없는 도로
      // 칸 경계(위도 37.9)를 걸친 도로: 두 조각으로 저장됨
      ..addAddress('공지로', '43', '춘천시', 37.8950, 127.7300)
      ..addAddress('공지로', '87', '강원특별자치도 춘천시', 37.9050, 127.7300);
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
    // 붙여 써도 나눔
    expect(parseQuery('공지로69-9').road, '공지로');
    expect(parseQuery('공지로69-9').number, (69, 9));
    expect(parseQuery('대덕대로578번길27번지').road, '대덕대로578번길');
    expect(parseQuery('대덕대로578번길27번지').number, (27, 0));
    expect(parseQuery('산단4로160').road, '산단4로');
    expect(parseQuery('산단4로160').number, (160, 0));
    expect(parseQuery('부산 정관로123').region, ['부산']);
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

  test('a road split into pieces gives one answer, estimated between neighbours', () {
    final r = searchAddress(path, '공지로 65');
    expect(r.length, 1);
    expect(r.single.detail, '강원특별자치도 춘천시 · 번지 자료가 없어 43~87번 사이로 추정');
    expect(r.single.lat, closeTo(37.9000, 1e-6)); // 43과 87의 가운데
    expect(searchAddress(path, '공지로 43-9').single.detail, contains('43번 위치')); // 같은 본번 건물
  });

  test('region narrows same-named roads; unknown region is filled from the area', () {
    final r = searchAddress(path, '김포 정관로 10');
    expect(r.single.lat, closeTo(37.6, 1e-6));
    final roads = searchAddress(path, '정관로', lat: 35.32, lon: 129.17);
    expect(roads.first.detail, '도로 · 부산광역시 기장군');
  });

  test('finds places by name, ignoring spaces', () {
    expect(searchAddress(path, '정관 박물관').first.title, '정관박물관');
    // 장소에는 어느 동네인지 붙음 (300 m 안에 주소가 없어 지역만)
    expect(searchAddress(path, '구목정공원').first.detail, '공원 · 부산광역시 기장군');
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

  test('nearest road-name address of a tapped spot', () async {
    final data = File(path).readAsBytesSync();
    final h = nearestAddress(data, 35.32101, 129.17801)!;
    expect(h.title, '정관로 123');
    expect(h.detail, '부산광역시 기장군');
    expect(nearestAddress(data, 36.0, 128.0), isNull); // 120 m 안에 주소 없음
    expect((await (await AddressSearcher.open(path)).nearest(33.4580, 126.9300))!.title, '일출로 284-12');
    final place = nearestPlace(data, 35.3251, 129.1801)!; // 정관박물관 옆
    expect(place.title, '정관박물관');
    expect(place.detail, '관광');
    expect(nearestPlace(data, 35.3300, 129.1700), isNull); // 도로(구연방곡로)는 빼고, 40 m 안에 없음
    expect((await (await AddressSearcher.open(path)).nearestPlaceAt(37.4440, 126.9640)), isNull); // 산은 뺌
  });

  test('search thread keeps the data loaded', () async {
    final s = await AddressSearcher.open(path);
    expect(identical(await AddressSearcher.open(path), s), isTrue);
    expect((await s.search('정관로 123')).first.title, '정관로 123');
    expect((await s.search('관악산')).first.detail, '산');
  });

  test('nearer places come before farther ones that merely start with the query', () {
    final b = AddressIndexBuilder()
      ..addPlace('삼익2차아파트', 10, 35.80, 128.60) // 멀리 (앞부분이 같음)
      ..addPlace('석사삼익2차아파트', 10, 37.86, 127.74) // 가까이 (가운데 들어 있음)
      ..addPlace('삼익2차', 10, 36.50, 127.50) // 이름이 똑같음 -> 맨 앞
      ..addAddress('공지로', '100', '강원특별자치도 춘천시', 37.861, 127.741);
    final p = '${Directory.systemTemp.createTempSync('addr2').path}/t.gad';
    b.write(p);
    final r = searchAddress(p, '삼익2차', lat: 37.86, lon: 127.74);
    expect(r.map((h) => h.title), ['삼익2차', '석사삼익2차아파트', '삼익2차아파트']);
    expect(r[1].detail, '건물 · 강원특별자치도 춘천시 공지로 100');
  });
}
