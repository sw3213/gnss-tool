// ============================================================
// BlackGPS 외부 장치 펌웨어 (ESP32-S3 + Quectel LC29H + AHT20 + BMP280)
//
// 하는 일
//   1. LC29H(듀얼밴드 L1+L5 GNSS)가 UART로 보내는 NMEA 문장을 그대로 폰에 전달
//   2. 1초마다 센서 문장 전송:  $PSENS,<기압 hPa>,<기온 °C>,<습도 %>,<배터리 %>*체크섬
//   3. (선택) microSD에 NMEA 기록
// 폰 앱(GNSS Tool)은 "설정 > 위치 출처 > 외부 GPS 장치"에서 이 장치를 자동으로 찾아 연결.
// 블루투스: Nordic UART 서비스(NUS). 이름 "BlackGPS"
//
// 필요한 라이브러리 (Arduino IDE > 라이브러리 관리)
//   - NimBLE-Arduino (h2zero) 2.x
//   - Adafruit AHTX0, Adafruit BMP280 Library (Adafruit Unified Sensor 포함)
// 보드: "ESP32S3 Dev Module" (esp32 by Espressif 3.x)
// ============================================================

#include <Adafruit_AHTX0.h>
#include <Adafruit_BMP280.h>
#include <NimBLEDevice.h>
#include <Wire.h>

// ---------- 배선 (내 보드에 맞게 바꾸기) ----------
constexpr int GNSS_RX = 18;    // ESP32 RX  <- LC29H TXD
constexpr int GNSS_TX = 17;    // ESP32 TX  -> LC29H RXD
constexpr uint32_t GNSS_BAUD = 115200;  // LC29H 기본 속도 (모델에 따라 460800일 수 있음: 글자가 깨지면 바꿔 보기)
constexpr int I2C_SDA = 8;     // AHT20 + BMP280 (같은 I2C 선에 같이 연결)
constexpr int I2C_SCL = 9;
constexpr int BATT_ADC = 1;    // 18650 전압을 저항 2개(100k:100k)로 반 나눠 연결. 없으면 -1
constexpr float BATT_DIVIDER = 2.0;

#define ENABLE_SD 0            // 1로 바꾸면 microSD에 NMEA 기록 (SPI 핀은 아래)
#if ENABLE_SD
#include <SD.h>
#include <SPI.h>
constexpr int SD_CS = 10, SD_MOSI = 11, SD_SCK = 12, SD_MISO = 13;
File logFile;
#endif

// ---------- 블루투스 (Nordic UART 서비스) ----------
static const char *NUS_SERVICE = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
static const char *NUS_RX = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E";  // 폰 -> 장치 (지금은 안 씀)
static const char *NUS_TX = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";  // 장치 -> 폰 (notify)

NimBLECharacteristic *tx = nullptr;
volatile bool connected = false;
volatile uint16_t chunk = 20;  // 한 번에 보낼 수 있는 크기 (MTU - 3), 연결 후 늘어남

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer *s, NimBLEConnInfo &info) override {
    connected = true;
    chunk = 20;
  }
  void onDisconnect(NimBLEServer *s, NimBLEConnInfo &info, int reason) override {
    connected = false;
    NimBLEDevice::startAdvertising();  // 다시 찾을 수 있게
  }
  void onMTUChange(uint16_t mtu, NimBLEConnInfo &info) override { chunk = min<uint16_t>(mtu - 3, 244); }
};

Adafruit_AHTX0 aht;
Adafruit_BMP280 bmp;
bool hasAht = false, hasBmp = false;

// 폰으로 한 줄 보내기 (MTU보다 길면 잘라서)
void sendLine(const String &line) {
  if (!connected || tx == nullptr) return;
  String s = line + "\n";
  const uint8_t *p = (const uint8_t *)s.c_str();
  size_t left = s.length();
  while (left > 0) {
    size_t n = min<size_t>(left, chunk);
    tx->notify(p, n);
    p += n;
    left -= n;
  }
}

String withChecksum(const String &body) {
  uint8_t cs = 0;
  for (size_t i = 0; i < body.length(); i++) cs ^= (uint8_t)body[i];
  char buf[4];
  snprintf(buf, sizeof(buf), "%02X", cs);
  return "$" + body + "*" + buf;
}

float batteryPercent() {
  if (BATT_ADC < 0) return NAN;
  float v = analogReadMilliVolts(BATT_ADC) * BATT_DIVIDER / 1000.0;
  // 18650: 3.3 V = 0 %, 4.2 V = 100 % (대략, 직선 근사)
  return constrain((v - 3.3) / (4.2 - 3.3) * 100.0, 0.0, 100.0);
}

void sendSensors() {
  String body = "PSENS,";
  if (hasBmp) body += String(bmp.readPressure() / 100.0, 2);
  body += ",";
  if (hasAht) {
    sensors_event_t hum, temp;
    aht.getEvent(&hum, &temp);
    body += String(temp.temperature, 1) + "," + String(hum.relative_humidity, 1);
  } else {
    body += ",";
  }
  body += ",";
  float b = batteryPercent();
  if (!isnan(b)) body += String(b, 0);
  sendLine(withChecksum(body));
}

void setup() {
  Serial.begin(115200);
  Serial1.begin(GNSS_BAUD, SERIAL_8N1, GNSS_RX, GNSS_TX);

  Wire.begin(I2C_SDA, I2C_SCL);
  hasAht = aht.begin();
  hasBmp = bmp.begin(0x76) || bmp.begin(0x77);
  if (hasBmp) {
    // 실외 고도 측정용: 기압 오버샘플링 16배, 필터 16
    bmp.setSampling(Adafruit_BMP280::MODE_NORMAL, Adafruit_BMP280::SAMPLING_X2, Adafruit_BMP280::SAMPLING_X16,
                    Adafruit_BMP280::FILTER_X16, Adafruit_BMP280::STANDBY_MS_500);
  }
  Serial.printf("AHT20 %s, BMP280 %s\n", hasAht ? "OK" : "없음", hasBmp ? "OK" : "없음");

#if ENABLE_SD
  SPI.begin(SD_SCK, SD_MISO, SD_MOSI, SD_CS);
  if (SD.begin(SD_CS)) logFile = SD.open("/nmea.log", FILE_APPEND);
#endif

  NimBLEDevice::init("BlackGPS");
  NimBLEDevice::setMTU(247);
  NimBLEServer *server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  NimBLEService *svc = server->createService(NUS_SERVICE);
  tx = svc->createCharacteristic(NUS_TX, NIMBLE_PROPERTY::NOTIFY);
  svc->createCharacteristic(NUS_RX, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  svc->start();
  NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
  adv->setName("BlackGPS");
  adv->addServiceUUID(NUS_SERVICE);
  adv->enableScanResponse(true);
  adv->start();
  Serial.println("BLE 광고 시작: BlackGPS");
}

String nmea;
uint32_t lastSensor = 0;

void loop() {
  // GNSS: 한 줄씩 모아서 그대로 전달
  while (Serial1.available()) {
    char c = Serial1.read();
    if (c == '\n') {
      nmea.trim();
      if (nmea.startsWith("$")) {
        sendLine(nmea);
#if ENABLE_SD
        if (logFile) logFile.println(nmea);
#endif
      }
      nmea = "";
    } else if (nmea.length() < 120) {
      nmea += c;
    }
  }
  if (millis() - lastSensor >= 1000) {
    lastSensor = millis();
    sendSensors();
#if ENABLE_SD
    if (logFile) logFile.flush();
#endif
  }
}
