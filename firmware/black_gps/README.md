# BlackGPS 외부 장치 펌웨어

ESP32-S3 + Quectel LC29H(듀얼밴드 GNSS) + AHT20(온·습도) + BMP280(기압) 장치용입니다.
폰 앱 **GNSS Tool**과 블루투스로 연결됩니다.

## 연결 방식
- 블루투스 이름: `BlackGPS`
- 서비스: Nordic UART(NUS) `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`, 장치→폰 `6E400003-…` (notify)
- 보내는 글 (한 줄씩, 줄바꿈 `\n`)
  - LC29H NMEA 문장 그대로 (`$GNGGA`, `$GPGSV`, …)
  - 1초마다 `$PSENS,<기압 hPa>,<기온 °C>,<습도 %>,<배터리 %>*체크섬` (센서가 없으면 빈칸)

## 배선 (기본값, `black_gps.ino` 맨 위에서 바꿀 수 있음)
| 부품 | ESP32-S3 핀 |
|---|---|
| LC29H TXD → | GPIO18 (RX) |
| LC29H RXD ← | GPIO17 (TX) |
| AHT20·BMP280 SDA | GPIO8 |
| AHT20·BMP280 SCL | GPIO9 |
| 배터리 전압 (100k:100k 분압) | GPIO1 |
| 3.3 V / GND | 공통 |

## 올리는 방법
1. Arduino IDE에서 보드 **esp32 by Espressif (3.x)** 설치, 보드 **ESP32S3 Dev Module** 선택
2. 라이브러리 관리에서 **NimBLE-Arduino**, **Adafruit AHTX0**, **Adafruit BMP280 Library** 설치
3. `black_gps.ino`를 열고 업로드
4. 시리얼 모니터(115200)에 `AHT20 OK, BMP280 OK`, `BLE 광고 시작: BlackGPS`가 나오면 성공

## 앱에서 쓰기
앱 **도구 → 설정 → 위치 출처 → 외부 GPS 장치**를 고르면 자동으로 찾아 연결합니다.
장치가 위성을 잡기 전이나 연결이 끊기면 **폰 GPS로 자동 전환**되고, 다시 연결되면 돌아갑니다.

## 문제 해결
- NMEA가 안 들어오면 `GNSS_BAUD`를 460800으로 바꿔 보세요 (LC29H 모델마다 기본 속도가 다름).
- microSD 기록은 `ENABLE_SD`를 1로 바꾸면 켜집니다 (`/nmea.log`).
