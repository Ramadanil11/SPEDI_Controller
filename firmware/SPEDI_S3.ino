// ============================================================================
//  SPEDI BOAT v15.0-S3  —  GPS NEO-M8U + GSM A7670C
//  Target Board : ESP32-S3 Dev Module
//  Arduino Core : 3.x (ESP-IDF 5.x)
//
//  Changelog v14.8 → v15.0:
//  --- v14.9 (NEO-M8U Migration) ---
//  [M8U 1] GPS module: NEO-M8N → NEO-M8U (IMU + Dead Reckoning).
//  [M8U 2] UBX AID-INI → MGA-INI-POS_LLH (kompatibel M8U).
//  [M8U 3] Dynamic model: Portable → Sea (optimal untuk boat).
//  [M8U 4] Sensor fusion: UBX-CFG-NAVX5 + CFG-ESFALG (auto IMU alignment).
//  [M8U 5] UBX-NAV-PVT parser: heading dari IMU/DR saat kecepatan rendah.
//  [M8U 6] Baud rate GPS: 9600 → 38400 (bandwidth untuk sensor fusion data).
//  [M8U 7] Heading priority: DR heading > GPS course > fallback.
//  [M8U 8] GSV rate dikurangi (setiap 5 cycle) untuk hemat bandwidth.
//  [M8U 9] Telemetri: dr_heading, dr_valid, fusion_mode.
//  --- v15.0 (GSM A7670C — WiFi Removal) ---
//  [GSM 1] WiFi dihapus, diganti GSM SIM A7670C via TinyGSM (SIM7600 driver).
//  [GSM 2] Koneksi internet via 4G LTE — jangkauan tidak terbatas.
//  [GSM 3] UART2 (GPIO 13/14) untuk komunikasi AT command ke A7670C.
//  [GSM 4] PWRKEY (GPIO 12) untuk power on/off modem.
//  [GSM 5] Auto-reconnect GPRS dengan throttled status check (10 detik).
//  [GSM 6] GSM failsafe: motor stop setelah 10 detik tanpa koneksi (non-auto).
//  [GSM 7] Telemetri: gsm_connected, signal_quality (CSQ).
//  [GSM 8] WDT disabled sementara saat init GSM (bisa 60+ detik).
//  [OBS 1] Obstacle avoidance hanya aktif di MODE_AUTO (navigasi rute).
//          Di MODE_MANUAL (joystick), avoidance dinonaktifkan — user kontrol langsung.
//
//  Semua fix dari v14.5 / v14.6 / v14.7 / v14.8 dipertahankan.
// ============================================================================
#define TINY_GSM_MODEM_SIM7600   // SIM A7670C kompatibel driver SIM7600
#include <TinyGsmClient.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>
#include <ESP32Servo.h>
#include <TinyGPSPlus.h>
#include <Preferences.h>
#include <math.h>
#include <esp_task_wdt.h>

// ============================================================================
// NETWORK CONFIGURATION — GSM SIM A7670C
// ⚠ SECURITY: Credentials di-hardcode. Jika repo publik, ganti credentials!
//   Idealnya simpan di NVS (Preferences) dan inject saat provisioning.
// ⚠ SECURITY: Koneksi MQTT via plain TCP (tidak terenkripsi).
//   Untuk produksi, gunakan TinyGsmClientSecure + TLS/SSL.
// ============================================================================
#define GSM_APN        "internet"          // APN XL Axiata
#define GSM_USER       ""                  // Kosong untuk XL
#define GSM_PASS_APN   ""                  // Kosong untuk XL
#define GSM_BAUD       115200              // Baud rate komunikasi AT command

#define MQTT_BROKER    "metro.proxy.rlwy.net"
#define MQTT_PORT      41220
#define MQTT_USERNAME  "device"
#define MQTT_PASS      "spedi2026"
#define MQTT_CLIENT_ID "spedi-device-01"

// ============================================================================
// MQTT MESSAGE AUTH — Token sederhana untuk validasi pesan masuk
// Server harus menyertakan field "auth": "SPEDI_AUTH_TOKEN" di setiap pesan.
// ============================================================================
#define MQTT_AUTH_TOKEN "spedi-secret-2026"

// ============================================================================
// AUTO MODE GSM TIMEOUT — Boat berhenti jika GSM putus terlalu lama di AUTO
// ============================================================================
#define GSM_AUTO_TIMEOUT_MS  120000   // 120 detik tanpa koneksi → stop di AUTO mode

// ============================================================================
// PIN MAP — ESP32-S3 Dev Module
// ============================================================================
#define RPWM_PIN        5
#define LPWM_PIN        6
#define R_EN_PIN        7
#define L_EN_PIN        15

#define SERVO_PIN       4

#define TRIG_LEFT_PIN   10
#define ECHO_LEFT_PIN   11
#define TRIG_RIGHT_PIN  39
#define ECHO_RIGHT_PIN  40

#define PIN_BUZZER      21
#define PIN_LED         38

#define GPS_RX_PIN      16
#define GPS_TX_PIN      17

#define GSM_TX_PIN      13    // ESP32 TX → A7670C RX
#define GSM_RX_PIN      14    // ESP32 RX ← A7670C TX
#define GSM_PWRKEY_PIN  12    // Power key control A7670C

// ============================================================================
// LEDC
// ============================================================================
#define PWM_FREQ        16000
#define PWM_RESOLUTION  8

// ============================================================================
// NAVIGATION & PHYSICS
// ============================================================================
#define SERVO_CENTER      90
#define SERVO_MAX_LEFT    45
#define SERVO_MAX_RIGHT   135
#define SERVO_STEP_DEG    2
#define SERVO_INTERVAL_MS 12

#define MAX_SPEED         255
#define TURN_SPEED        120
#define AVOID_SPEED       130
#define APPROACH_SPEED    160

#define OBSTACLE_DIST     80
#define CRITICAL_DIST     35

#define RAMP_INTERVAL_MS  25
#define RAMP_UP_STEP      8
#define RAMP_DOWN_STEP    12
#define JOYSTICK_TIMEOUT  2000
#define SONAR_INTERVAL    60

#define WP_NAV_SPEED         180

// [NAV 3] Dynamic arrival radius — batas min/max
#define WP_ARRIVAL_MIN_M     3.0f    // radius minimum (GPS sempurna)
#define WP_ARRIVAL_MAX_M     8.0f    // radius maximum (GPS buruk)
#define WP_ARRIVAL_HDOP_REF  1.0f    // HDOP referensi (radius = min saat ini)

// [NAV 2] Waypoint timeout
#define WP_TIMEOUT_S         120     // skip WP jika tidak tercapai 120 detik

// [NAV 1] Cross-Track Error gain
#define XTE_KP               0.8f   // gain koreksi XTE (deg per meter)
#define XTE_MAX_CORRECTION   30.0f  // max koreksi XTE dalam derajat

// [NAV 5] Gradual speed — jarak transisi
#define SPEED_APPROACH_DIST  15.0f   // mulai perlambat di 15m
#define SPEED_MIN_APPROACH   100     // kecepatan minimum saat sangat dekat

// [NAV 6] Heading staleness
#define HEADING_STALE_MS     10000   // heading invalid setelah 10 detik tanpa update

// ============================================================================
// STEERING PI CONTROLLER
// ============================================================================
#define STEER_KP       0.50f
#define STEER_KI       0.008f
#define STEER_I_MAX    25.0f
#define STEER_DT_S     0.060f

// ============================================================================
// GPS LOCK THRESHOLDS
// ============================================================================
#define GPS_MIN_SAT         4
#define GPS_HDOP_GOOD       2.5f
#define GPS_HDOP_ACCEPT     5.0f
#define GPS_AGE_MS          3000
#define GPS_DEGRADE_CYCLES  10

// ============================================================================
// GPS POSITION CACHE & DRIFT FILTER
// ============================================================================
#define GPS_DEFAULT_LAT       -2.953923
#define GPS_DEFAULT_LNG      104.748214
#define GPS_SAVE_INTERVAL_MS  300000
#define GPS_MAX_SPEED_MS      10.0
#define GPS_JUMP_BUFFER_M      3.0

// ============================================================================
// GPS NEO-M8U — BAUD RATE & UBX PARSER
// ============================================================================
#define GPS_INITIAL_BAUD      9600      // Default baud saat module boot
#define GPS_TARGET_BAUD       38400     // Target baud setelah konfigurasi
#define UBX_NAV_PVT_LEN      92        // Panjang payload UBX-NAV-PVT
#define UBX_MAX_PAYLOAD       96        // Buffer UBX parser (sedikit > 92)
#define DR_HEADING_ACC_MAX    10.0f     // Max heading accuracy (deg) untuk dianggap valid

// ============================================================================
// GSM & WATCHDOG
// ============================================================================
#define GSM_FAILSAFE_MS    10000    // 10 detik tanpa koneksi → failsafe
#define GSM_RECONNECT_MS   15000    // Interval retry koneksi GPRS
#define GSM_CHECK_MS       10000    // Throttle cek status GPRS (10 detik)
#define WDT_TIMEOUT_S      10

// ============================================================================
// JOYSTICK DEAD ZONE
// ============================================================================
#define JOY_DEADZONE_THROTTLE  0.05f
#define JOY_DEADZONE_STEERING  0.10f

// ============================================================================
// STATE MACHINE ENUMS
// ============================================================================
enum DeviceMode { MODE_IDLE, MODE_MANUAL, MODE_AUTO };

const char* modeToString(DeviceMode m) {
  switch (m) {
    case MODE_MANUAL: return "manual";
    case MODE_AUTO:   return "auto";
    default:          return "idle";
  }
}

// ============================================================================
// GLOBAL OBJECTS
// ============================================================================
HardwareSerial gpsSerial(1);
TinyGPSPlus    gps;
Preferences    prefs;

HardwareSerial gsmSerial(2);              // UART2 untuk GSM A7670C
TinyGsm        modem(gsmSerial);          // TinyGSM modem object
TinyGsmClient  gsmClient(modem);          // TCP client via GSM
PubSubClient   mqttClient(gsmClient);     // MQTT via GSM (drop-in replace WiFiClient)
Servo          steeringServo;

const char* TOPIC_JOYSTICK = "spedi/vehicle/joystick";
const char* TOPIC_ROUTE    = "spedi/vehicle/route";
const char* TOPIC_STATUS   = "spedi/vehicle/status";
const char* TOPIC_NAV_EVENT = "spedi/vehicle/nav_event";  // [NAV 4]

// ============================================================================
// SONAR CACHE
// ============================================================================
int cachedDistLeft  = 400;
int cachedDistRight = 400;

// ============================================================================
// BUZZER — Non-blocking state machine
// ============================================================================
struct BuzzerState {
  bool          active     = false;
  int           totalBeeps = 0;
  int           beepsDone  = 0;
  int           durMs      = 0;
  bool          pinHigh    = false;
  unsigned long lastMs     = 0;
} buzzer;

void beepAsync(int durMs, int count) {
  buzzer.active     = true;
  buzzer.totalBeeps = count;
  buzzer.beepsDone  = 0;
  buzzer.durMs      = durMs;
  buzzer.pinHigh    = false;
  buzzer.lastMs     = millis();
  digitalWrite(PIN_BUZZER, LOW);
}

void updateBuzzer() {
  if (!buzzer.active) return;
  if (millis() - buzzer.lastMs < (unsigned long)buzzer.durMs) return;
  buzzer.lastMs = millis();
  if (!buzzer.pinHigh) {
    digitalWrite(PIN_BUZZER, HIGH);
    buzzer.pinHigh = true;
  } else {
    digitalWrite(PIN_BUZZER, LOW);
    buzzer.pinHigh = false;
    buzzer.beepsDone++;
    if (buzzer.beepsDone >= buzzer.totalBeeps) buzzer.active = false;
  }
}

// ============================================================================
// STATE MACHINE
// ============================================================================
struct Waypoint { double lat; double lng; };
#define MAX_WAYPOINTS 50

struct SystemState {
  DeviceMode    mode             = MODE_IDLE;
  bool          gpsLocked        = false;
  bool          gpsBuzzDone      = false;
  uint8_t       gpsConfirmCount  = 0;
  int           currentSpeed     = 0;
  int           targetSpeed      = 0;
  int           servoTarget      = SERVO_CENTER;
  int           servoCurrent     = SERVO_CENTER;
  bool          smartMoveActive  = false;
  bool          isAvoiding       = false;
  bool          autopilotActive  = false;
  bool          motorDisabled    = false;
  Waypoint      waypoints[MAX_WAYPOINTS];
  int           waypointCount    = 0;
  int           waypointIndex    = 0;
  unsigned long lastRamp         = 0;
  unsigned long lastServoUpdate  = 0;
  unsigned long lastCommand      = 0;
  unsigned long lastSonarRead    = 0;
  unsigned long lastStatusPublish= 0;
  unsigned long lastGpsCheck     = 0;
  unsigned long lastMqttRetry    = 0;
  unsigned long lastGpsLog       = 0;
  unsigned long lastGpsSave      = 0;
  unsigned long bootTime         = 0;

  // Heading
  double        lastValidHeading  = 0.0;
  unsigned long headingUpdateTime = 0;   // [NAV 6] kapan heading terakhir di-update
  bool          headingValid      = false;

  double        steerIntegral     = 0.0;

  // GPS drift filter
  double        filteredLat       = 0.0;
  double        filteredLng       = 0.0;
  unsigned long filteredTime      = 0;
  bool          filterInit        = false;

  // GSM failsafe
  bool          gsmConnected      = false;   // Status koneksi GPRS
  unsigned long gsmLostAt         = 0;       // Kapan koneksi GSM hilang
  bool          gsmFailsafeFired  = false;   // Failsafe sudah trigger
  unsigned long lastGsmCheck      = 0;       // Throttle GPRS status check

  // GPS degradation
  uint8_t       gpsDegradeCount   = 0;

  // [NAV 2] Waypoint timeout
  unsigned long wpStartTime       = 0;    // kapan mulai menuju WP saat ini

  // [NAV 1] Cross-Track Error cache (untuk telemetri)
  double        lastXTE           = 0.0;

  // [NAV 3] Dynamic arrival radius cache
  float         currentArrivalR   = WP_ARRIVAL_MIN_M;

  // [M8U] Dead Reckoning / Sensor Fusion dari UBX-NAV-PVT
  double        drHeading         = 0.0;    // heading dari IMU/DR (derajat)
  float         drHeadingAcc      = 999.0f; // heading accuracy (derajat)
  bool          drHeadingValid    = false;   // apakah DR heading bisa dipakai
  uint8_t       fusionMode        = 0;       // 0=init, 1=calibrating, 2=fused, 3=DR-only
  unsigned long drUpdateTime      = 0;       // kapan terakhir NAV-PVT diterima
} S;

// ============================================================================
// UBX PARSER STATE MACHINE — untuk parse NAV-PVT binary
// ============================================================================
enum UbxParseState {
  UBX_WAIT_SYNC1,
  UBX_WAIT_SYNC2,
  UBX_GOT_CLASS,
  UBX_GOT_ID,
  UBX_GOT_LEN1,
  UBX_GOT_LEN2,
  UBX_PAYLOAD,
  UBX_CK_A,
  UBX_CK_B
};

struct UbxParser {
  UbxParseState state    = UBX_WAIT_SYNC1;
  uint8_t       cls      = 0;
  uint8_t       id       = 0;
  uint16_t      len      = 0;
  uint16_t      idx      = 0;
  uint8_t       ckA      = 0;
  uint8_t       ckB      = 0;
  uint8_t       rxCkA    = 0;
  uint8_t       rxCkB    = 0;
  uint8_t       payload[UBX_MAX_PAYLOAD];
} ubxParser;

#define FILTER_SAMPLES 5
int leftBuf[FILTER_SAMPLES]  = {400,400,400,400,400};
int rightBuf[FILTER_SAMPLES] = {400,400,400,400,400};
int bufIdx = 0;

// ============================================================================
// UTILITY — Haversine, Bearing, Cross-Track Distance
// ============================================================================
double haversineM(double lat1, double lon1, double lat2, double lon2) {
  const double R = 6371000.0;
  double dLat = radians(lat2 - lat1);
  double dLon = radians(lon2 - lon1);
  double a = sin(dLat/2)*sin(dLat/2) +
             cos(radians(lat1))*cos(radians(lat2))*
             sin(dLon/2)*sin(dLon/2);
  return R * 2.0 * atan2(sqrt(a), sqrt(1.0-a));
}

double bearingDeg(double lat1, double lon1, double lat2, double lon2) {
  double dLon = radians(lon2 - lon1);
  double y = sin(dLon) * cos(radians(lat2));
  double x = cos(radians(lat1))*sin(radians(lat2)) -
             sin(radians(lat1))*cos(radians(lat2))*cos(dLon);
  return fmod(degrees(atan2(y, x)) + 360.0, 360.0);
}

// [NAV 1] Cross-Track Distance (XTD)
// Jarak tegak lurus dari posisi kapal ke garis WP_from → WP_to.
// Positif = kapal di kanan garis, Negatif = di kiri garis.
// Rumus: XTD = asin(sin(d13/R) * sin(brng13 - brng12)) * R
//   d13    = jarak dari WP_from ke posisi kapal
//   brng13 = bearing dari WP_from ke posisi kapal
//   brng12 = bearing dari WP_from ke WP_to
double crossTrackM(double fromLat, double fromLng,
                   double toLat,   double toLng,
                   double curLat,  double curLng) {
  const double R = 6371000.0;
  double d13    = haversineM(fromLat, fromLng, curLat, curLng);
  double brng13 = radians(bearingDeg(fromLat, fromLng, curLat, curLng));
  double brng12 = radians(bearingDeg(fromLat, fromLng, toLat, toLng));
  return asin(sin(d13 / R) * sin(brng13 - brng12)) * R;
}

// ============================================================================
// GPS DRIFT FILTER
// ============================================================================
bool acceptGpsPosition(double lat, double lng) {
  if (!S.filterInit) {
    S.filteredLat  = lat;
    S.filteredLng  = lng;
    S.filteredTime = millis();
    S.filterInit   = true;
    return true;
  }

  unsigned long now = millis();
  unsigned long dt  = now - S.filteredTime;
  double dist       = haversineM(S.filteredLat, S.filteredLng, lat, lng);
  double maxAllowed = GPS_MAX_SPEED_MS * (dt / 1000.0) + GPS_JUMP_BUFFER_M;

  if (dist > maxAllowed && dt < 2000) {
    Serial.printf("[GPS FILTER] Lompatan ditolak! dist=%.1fm max=%.1fm dt=%lums\n",
      dist, maxAllowed, dt);
    return false;
  }

  S.filteredLat  = lat;
  S.filteredLng  = lng;
  S.filteredTime = now;
  return true;
}

// ============================================================================
// MOTOR DRIVER
// ============================================================================
void motorInit() {
  ledcAttachChannel(RPWM_PIN, PWM_FREQ, PWM_RESOLUTION, 2);
  ledcAttachChannel(LPWM_PIN, PWM_FREQ, PWM_RESOLUTION, 3);
  ledcWrite(RPWM_PIN, 0);
  ledcWrite(LPWM_PIN, 0);
  Serial.printf("[MOTOR] LEDC ch2(RPWM) & ch3(LPWM) @ %dHz OK\n", PWM_FREQ);
}

void emergencyStop(const char* reason) {
  ledcWrite(RPWM_PIN, 0);
  ledcWrite(LPWM_PIN, 0);
  digitalWrite(R_EN_PIN, LOW);
  digitalWrite(L_EN_PIN, LOW);
  S.targetSpeed     = 0;
  S.currentSpeed    = 0;
  S.motorDisabled   = true;
  // [v15.1 #2] Lock semua — bukan cuma motor, tapi juga mode dan steering
  S.autopilotActive = false;
  S.mode            = MODE_IDLE;
  setServoTarget(SERVO_CENTER);
  Serial.printf("[SAFETY] EMERGENCY STOP: %s\n", reason);
  beepAsync(100, 4);

  // [FIX #9] Gunakan global prefs, bukan buat Preferences baru
  //          untuk menghindari konflik NVS handle
  if (S.gpsLocked && gps.location.isValid()) {
    if (prefs.begin("gps", false)) {
      prefs.putDouble("lat", gps.location.lat());
      prefs.putDouble("lng", gps.location.lng());
      prefs.end();
    }
  }
}

void reenableMotor() {
  if (!S.motorDisabled) return;
  digitalWrite(R_EN_PIN, HIGH);
  digitalWrite(L_EN_PIN, HIGH);
  S.motorDisabled = false;
  Serial.println("[MOTOR] EN pin aktif kembali.");
}

void setMotorRaw(int speed) {
  speed = constrain(speed, -MAX_SPEED, MAX_SPEED);
  if (speed > 0) {
    ledcWrite(LPWM_PIN, 0);
    ledcWrite(RPWM_PIN, (uint32_t)speed);
  } else if (speed < 0) {
    ledcWrite(RPWM_PIN, 0);
    ledcWrite(LPWM_PIN, (uint32_t)(-speed));
  } else {
    ledcWrite(RPWM_PIN, 0);
    ledcWrite(LPWM_PIN, 0);
  }
}

void updateMotorPhysics() {
  if (millis() - S.lastRamp < RAMP_INTERVAL_MS) return;
  S.lastRamp = millis();
  int diff = S.targetSpeed - S.currentSpeed;
  if      (diff >  RAMP_UP_STEP)   S.currentSpeed += RAMP_UP_STEP;
  else if (diff < -RAMP_DOWN_STEP) S.currentSpeed -= RAMP_DOWN_STEP;
  else                             S.currentSpeed  = S.targetSpeed;
  setMotorRaw(S.currentSpeed);
}

// ============================================================================
// UBX HELPER
// ============================================================================
void sendUBXCmd(uint8_t cls, uint8_t id, const uint8_t* payload, uint16_t len) {
  uint8_t ckA = 0, ckB = 0;
  auto addByte = [&](uint8_t b) {
    ckA = (ckA + b) & 0xFF;
    ckB = (ckB + ckA) & 0xFF;
  };
  addByte(cls); addByte(id);
  addByte((uint8_t)(len & 0xFF));
  addByte((uint8_t)(len >> 8));
  for (uint16_t i = 0; i < len; i++) addByte(payload[i]);

  gpsSerial.write(0xB5); gpsSerial.write(0x62);
  gpsSerial.write(cls);  gpsSerial.write(id);
  gpsSerial.write((uint8_t)(len & 0xFF));
  gpsSerial.write((uint8_t)(len >> 8));
  if (len > 0) gpsSerial.write(payload, len);
  gpsSerial.write(ckA);  gpsSerial.write(ckB);
  gpsSerial.flush();
}

// ============================================================================
// SAVE / INJECT POSITION
// ============================================================================
void saveLastPosition(double lat, double lng) {
  if (!prefs.begin("gps", false)) {
    Serial.println(F("[GPS CACHE] GAGAL membuka NVS untuk write!"));
    return;
  }
  prefs.putDouble("lat", lat);
  prefs.putDouble("lng", lng);
  prefs.end();
  Serial.printf("[GPS CACHE] Disimpan: %.8f, %.8f\n", lat, lng);
}

void injectPosition() {
  bool nvsOk = prefs.begin("gps", true);
  if (!nvsOk) {
    Serial.println(F("[GPS CACHE] GAGAL membuka NVS — pakai default."));
  }
  double lat = prefs.getDouble("lat", GPS_DEFAULT_LAT);
  double lng = prefs.getDouble("lng", GPS_DEFAULT_LNG);
  if (nvsOk) prefs.end();

  Serial.printf("[GPS CACHE] Inject posisi awal: %.8f, %.8f\n", lat, lng);

  // [M8U 2] UBX-MGA-INI-POS_LLH (0x13/0x40) — pengganti AID-INI
  // Payload 20 bytes:
  //   [0]     type     = 0x01 (LLH)
  //   [1]     version  = 0x00
  //   [2-3]   reserved
  //   [4-7]   lat      (int32, 1e-7 deg)
  //   [8-11]  lon      (int32, 1e-7 deg)
  //   [12-15] alt      (int32, cm)
  //   [16-19] posAcc   (uint32, cm)
  int32_t  latI   = (int32_t)(lat * 1e7);
  int32_t  lngI   = (int32_t)(lng * 1e7);
  int32_t  altCm  = 0;           // altitude tidak diketahui
  uint32_t posAcc = 500000;      // 5 km accuracy (cm)

  uint8_t payload[20];
  memset(payload, 0, sizeof(payload));

  payload[0] = 0x01;             // type = LLH
  payload[1] = 0x00;             // version

  // lat (bytes 4-7, little-endian)
  payload[4]  = (uint8_t)(latI);
  payload[5]  = (uint8_t)(latI >> 8);
  payload[6]  = (uint8_t)(latI >> 16);
  payload[7]  = (uint8_t)(latI >> 24);

  // lon (bytes 8-11, little-endian)
  payload[8]  = (uint8_t)(lngI);
  payload[9]  = (uint8_t)(lngI >> 8);
  payload[10] = (uint8_t)(lngI >> 16);
  payload[11] = (uint8_t)(lngI >> 24);

  // alt (bytes 12-15, little-endian)
  payload[12] = (uint8_t)(altCm);
  payload[13] = (uint8_t)(altCm >> 8);
  payload[14] = (uint8_t)(altCm >> 16);
  payload[15] = (uint8_t)(altCm >> 24);

  // posAcc (bytes 16-19, little-endian)
  payload[16] = (uint8_t)(posAcc);
  payload[17] = (uint8_t)(posAcc >> 8);
  payload[18] = (uint8_t)(posAcc >> 16);
  payload[19] = (uint8_t)(posAcc >> 24);

  sendUBXCmd(0x13, 0x40, payload, sizeof(payload));
  Serial.println(F("[GPS CACHE] UBX MGA-INI-POS_LLH terkirim (M8U)"));
}

// ============================================================================
// GPS CONFIGURATION (UBX) — NEO-M8U
// ============================================================================
void configureGPS() {
  Serial.println(F("[GPS M8U] Mengirim konfigurasi UBX..."));

  // ── [M8U 3] CFG-NAV5: Dynamic model = Sea (0x05) ──────────────────────
  static const uint8_t nav5[36] = {
    0xFF, 0xFF,
    0x05,                         // dynModel: 5 = Sea (optimal untuk boat)
    0x03,                         // fixMode: 3 = auto 2D/3D
    0x00, 0x00, 0x00, 0x00,       // fixedAlt
    0x10, 0x27, 0x00, 0x00,       // fixedAltVar
    0x05, 0x00,                   // minElev: 5 deg
    0xFA, 0x00,                   // pDOP: 25.0
    0xFA, 0x00,                   // tDOP: 25.0
    0x64, 0x00,                   // pAcc: 100
    0x2C, 0x01,                   // tAcc: 300
    0x00, 0x3C,                   // staticHoldThresh: 0, dgnssTimeout: 60
    0x00, 0x00,
    0x00, 0x00,
    0x00, 0x00,
    0x00,
    0x00, 0x00, 0x00, 0x00, 0x00
  };
  sendUBXCmd(0x06, 0x24, nav5, sizeof(nav5));
  delay(50);
  Serial.println(F("[GPS M8U] CFG-NAV5: dynModel=Sea"));

  // ── [M8U 4] CFG-NAVX5: Enable sensor fusion (ADR/UDR) ─────────────────
  // UBX-CFG-NAVX5 (0x06/0x23), payload 40 bytes
  // Byte 2-3: mask1 — bit 14 (0x4000) = apply adr config
  // Byte 27:  adrCfg — bit 0 = enable ADR/UDR sensor fusion
  uint8_t navx5[40];
  memset(navx5, 0, sizeof(navx5));
  // mask1: enable adr config (bit 14 = 0x4000)
  navx5[2] = 0x00;
  navx5[3] = 0x40;               // mask1 high byte = 0x40 → bit 14
  // adrCfg: enable sensor fusion
  navx5[27] = 0x01;              // bit 0 = enable ADR
  sendUBXCmd(0x06, 0x23, navx5, sizeof(navx5));
  delay(50);
  Serial.println(F("[GPS M8U] CFG-NAVX5: Sensor fusion ENABLED"));

  // ── [M8U 4] CFG-ESFALG: Auto IMU alignment ────────────────────────────
  // UBX-CFG-ESFALG (0x06/0x56), payload 12 bytes
  // Byte 4: bitfield — bit 0 = doAutoMntAlg (automatic mounting alignment)
  uint8_t esfalg[12];
  memset(esfalg, 0, sizeof(esfalg));
  esfalg[0] = 0x00;              // version
  esfalg[4] = 0x01;              // bitfield: doAutoMntAlg = 1
  sendUBXCmd(0x06, 0x56, esfalg, sizeof(esfalg));
  delay(50);
  Serial.println(F("[GPS M8U] CFG-ESFALG: Auto IMU alignment ENABLED"));

  // ── SBAS ───────────────────────────────────────────────────────────────
  static const uint8_t sbas[8] = { 0x01,0x03,0x03,0x00, 0x00,0x00,0x00,0x00 };
  sendUBXCmd(0x06, 0x16, sbas, sizeof(sbas));
  delay(50);

  // ── CFG-RATE: 5 Hz (200ms) ────────────────────────────────────────────
  static const uint8_t rate[6] = { 0xC8,0x00, 0x01,0x00, 0x01,0x00 };
  sendUBXCmd(0x06, 0x08, rate, sizeof(rate));
  delay(50);

  // ── NMEA Messages: GGA + RMC setiap cycle, GSV setiap 5 cycle ─────────
  static const uint8_t msgGGA[8] = { 0xF0,0x00, 0x00,0x01,0x00,0x00,0x00,0x00 };
  static const uint8_t msgRMC[8] = { 0xF0,0x04, 0x00,0x01,0x00,0x00,0x00,0x00 };
  static const uint8_t msgGSV[8] = { 0xF0,0x03, 0x00,0x05,0x00,0x00,0x00,0x00 }; // [M8U 8] rate=5
  sendUBXCmd(0x06, 0x01, msgGGA, 8);
  sendUBXCmd(0x06, 0x01, msgRMC, 8);
  sendUBXCmd(0x06, 0x01, msgGSV, 8);
  delay(50);

  // ── [M8U 5] Enable UBX-NAV-PVT pada UART1 ────────────────────────────
  // CFG-MSG (0x06/0x01): class=0x01, id=0x07 (NAV-PVT), rate=1 pada UART1
  static const uint8_t msgPVT[8] = { 0x01,0x07, 0x00,0x01,0x00,0x00,0x00,0x00 };
  sendUBXCmd(0x06, 0x01, msgPVT, 8);
  delay(50);
  Serial.println(F("[GPS M8U] UBX-NAV-PVT ENABLED pada UART1"));

  // ── [M8U 6] CFG-PRT: Ubah baud rate UART1 ke 38400 ───────────────────
  // UBX-CFG-PRT (0x06/0x00), payload 20 bytes
  // Byte 0:    portID = 1 (UART1)
  // Byte 4-7:  reserved1
  // Byte 8-11: mode = 0x000008D0 (8N1)
  // Byte 12-15: baudRate = 38400
  // Byte 16-17: inProtoMask = 0x0007 (UBX + NMEA + RTCM)
  // Byte 18-19: outProtoMask = 0x0003 (UBX + NMEA)
  uint8_t cfgPrt[20];
  memset(cfgPrt, 0, sizeof(cfgPrt));
  cfgPrt[0]  = 0x01;             // portID = UART1
  // mode: 8N1 = 0x000008D0
  cfgPrt[8]  = 0xD0;
  cfgPrt[9]  = 0x08;
  cfgPrt[10] = 0x00;
  cfgPrt[11] = 0x00;
  // baudRate: 38400 = 0x00009600
  uint32_t baud = GPS_TARGET_BAUD;
  cfgPrt[12] = (uint8_t)(baud);
  cfgPrt[13] = (uint8_t)(baud >> 8);
  cfgPrt[14] = (uint8_t)(baud >> 16);
  cfgPrt[15] = (uint8_t)(baud >> 24);
  // inProtoMask: UBX + NMEA + RTCM
  cfgPrt[16] = 0x07;
  cfgPrt[17] = 0x00;
  // outProtoMask: UBX + NMEA
  cfgPrt[18] = 0x03;
  cfgPrt[19] = 0x00;
  sendUBXCmd(0x06, 0x00, cfgPrt, sizeof(cfgPrt));
  delay(100);
  Serial.printf("[GPS M8U] CFG-PRT: Baud rate → %lu\n", (unsigned long)GPS_TARGET_BAUD);

  // ── Save semua konfigurasi ke flash/BBR ────────────────────────────────
  // Catatan: CFG-CFG dikirim SEBELUM switch baud, karena setelah CFG-PRT
  // module sudah pindah ke baud baru. Kita kirim save di baud lama dulu.
  // Namun CFG-PRT sudah terkirim, jadi module sudah switch.
  // Solusi: kirim CFG-CFG di baud baru setelah reconnect (di setup).

  Serial.println(F("[GPS M8U] Konfigurasi UBX selesai (save di baud baru)."));
}

// Helper: kirim CFG-CFG save command (dipanggil setelah baud switch)
void saveGPSConfig() {
  static const uint8_t saveCfg[12] = {
    0x00,0x00,0x00,0x00, 0xFF,0xFF,0x00,0x00, 0x00,0x00,0x00,0x00
  };
  sendUBXCmd(0x06, 0x09, saveCfg, sizeof(saveCfg));
  delay(100);
  Serial.println(F("[GPS M8U] CFG-CFG: Konfigurasi DISIMPAN ke flash."));
}

// ============================================================================
// [M8U 5] UBX BINARY PARSER — NAV-PVT untuk heading dari sensor fusion
// ============================================================================
void processNavPVT(const uint8_t* p, uint16_t len) {
  if (len < UBX_NAV_PVT_LEN) return;

  // NAV-PVT payload layout (u-blox M8 protocol spec):
  //   Byte 0-3:   iTOW (ms)
  //   Byte 20:    fixType (0=no, 2=2D, 3=3D, 4=GNSS+DR, 5=time-only)
  //   Byte 21:    flags
  //     bit 0:    gnssFixOK
  //     bit 5:    headVehValid (heading of vehicle valid, dari sensor fusion)
  //   Byte 23:    numSV (jumlah satelit)
  //   Byte 24-27: lon (int32, 1e-7 deg)
  //   Byte 28-31: lat (int32, 1e-7 deg)
  //   Byte 60-63: headMot (int32, 1e-5 deg) — heading of motion
  //   Byte 64-67: headAcc (uint32, 1e-5 deg) — heading accuracy
  //   Byte 84-87: headVeh (int32, 1e-5 deg) — heading of vehicle (dari IMU/DR)

  uint8_t fixType = p[20];
  uint8_t flags   = p[21];
  bool headVehValid = (flags >> 5) & 0x01;

  // headVeh: heading of vehicle dari sensor fusion (byte 84-87)
  int32_t headVehRaw = (int32_t)((uint32_t)p[84]
                     | ((uint32_t)p[85] << 8)
                     | ((uint32_t)p[86] << 16)
                     | ((uint32_t)p[87] << 24));
  double headVeh = headVehRaw * 1e-5;

  // headAcc: heading accuracy (byte 64-67)
  uint32_t headAccRaw = (uint32_t)p[64]
                      | ((uint32_t)p[65] << 8)
                      | ((uint32_t)p[66] << 16)
                      | ((uint32_t)p[67] << 24);
  float headAcc = headAccRaw * 1e-5f;

  // Fusion mode berdasarkan fixType dan headVehValid:
  //   fixType: 0=no fix, 2=2D, 3=3D, 4=GNSS+DR combined, 5=time-only
  //   0 = init       — belum ada fix dan IMU belum ready
  //   1 = calibrating — ada GNSS fix tapi IMU belum aligned
  //   2 = fused      — GNSS + IMU combined (fixType=4 atau headVeh valid + 3D fix)
  //   3 = DR only    — heading dari IMU saja (tanpa GNSS fix yang baik)
  if (fixType == 4) {
    S.fusionMode = 2;  // fused (GNSS + DR combined solution)
  } else if (headVehValid && fixType >= 3) {
    S.fusionMode = 2;  // fused (3D fix + valid vehicle heading)
  } else if (headVehValid) {
    S.fusionMode = 3;  // DR only (heading valid tapi fix buruk)
  } else if (fixType >= 2) {
    S.fusionMode = 1;  // calibrating (ada fix tapi IMU belum aligned)
  } else {
    S.fusionMode = 0;  // init (belum ada fix)
  }

  // Normalize heading ke 0-360
  if (headVeh < 0) headVeh += 360.0;
  if (headVeh >= 360.0) headVeh -= 360.0;

  S.drHeading      = headVeh;
  S.drHeadingAcc   = headAcc;
  S.drHeadingValid = headVehValid && (headAcc < DR_HEADING_ACC_MAX);
  S.drUpdateTime   = millis();

  // Debug log (setiap 2 detik)
  static unsigned long lastDrLog = 0;
  if (millis() - lastDrLog > 2000) {
    lastDrLog = millis();
    Serial.printf("[M8U DR] Heading:%.1f Acc:%.1f Valid:%d Fusion:%u Fix:%u\n",
      headVeh, headAcc, S.drHeadingValid ? 1 : 0, S.fusionMode, fixType);
  }
}

void ubxProcessByte(uint8_t b) {
  switch (ubxParser.state) {
    case UBX_WAIT_SYNC1:
      if (b == 0xB5) ubxParser.state = UBX_WAIT_SYNC2;
      break;

    case UBX_WAIT_SYNC2:
      ubxParser.state = (b == 0x62) ? UBX_GOT_CLASS : UBX_WAIT_SYNC1;
      break;

    case UBX_GOT_CLASS:
      ubxParser.cls = b;
      ubxParser.ckA = b;
      ubxParser.ckB = b;
      ubxParser.state = UBX_GOT_ID;
      break;

    case UBX_GOT_ID:
      ubxParser.id = b;
      ubxParser.ckA += b; ubxParser.ckB += ubxParser.ckA;
      ubxParser.state = UBX_GOT_LEN1;
      break;

    case UBX_GOT_LEN1:
      ubxParser.len = b;
      ubxParser.ckA += b; ubxParser.ckB += ubxParser.ckA;
      ubxParser.state = UBX_GOT_LEN2;
      break;

    case UBX_GOT_LEN2:
      ubxParser.len |= ((uint16_t)b << 8);
      ubxParser.ckA += b; ubxParser.ckB += ubxParser.ckA;
      ubxParser.idx = 0;
      // [FIX #4] Tolak pesan UBX yang lebih panjang dari buffer
      if (ubxParser.len > UBX_MAX_PAYLOAD) {
        Serial.printf("[UBX] Pesan terlalu panjang (%u > %u) — skip\n", ubxParser.len, UBX_MAX_PAYLOAD);
        ubxParser.state = UBX_WAIT_SYNC1;
      } else {
        ubxParser.state = (ubxParser.len > 0) ? UBX_PAYLOAD : UBX_CK_A;
      }
      break;

    case UBX_PAYLOAD:
      if (ubxParser.idx < UBX_MAX_PAYLOAD) {
        ubxParser.payload[ubxParser.idx] = b;
      }
      ubxParser.ckA += b; ubxParser.ckB += ubxParser.ckA;
      ubxParser.idx++;
      if (ubxParser.idx >= ubxParser.len) {
        ubxParser.state = UBX_CK_A;
      }
      break;

    case UBX_CK_A:
      ubxParser.rxCkA = b;
      ubxParser.state = UBX_CK_B;
      break;

    case UBX_CK_B:
      ubxParser.rxCkB = b;
      // Verifikasi checksum
      if (ubxParser.rxCkA == ubxParser.ckA && ubxParser.rxCkB == ubxParser.ckB) {
        // Checksum valid — proses message
        if (ubxParser.cls == 0x01 && ubxParser.id == 0x07) {
          // NAV-PVT
          processNavPVT(ubxParser.payload, ubxParser.len);
        }
      }
      ubxParser.state = UBX_WAIT_SYNC1;
      break;
  }
}

// ============================================================================
// GPS — Feed & Quality
// [M8U] Dual parse: setiap byte ke TinyGPS++ (NMEA) DAN UBX parser (binary)
// ============================================================================
void feedGPS() {
  while (gpsSerial.available()) {
    uint8_t c = gpsSerial.read();
    gps.encode(c);          // NMEA parser (TinyGPS++)
    ubxProcessByte(c);      // UBX binary parser (NAV-PVT heading)
  }
}

uint8_t getGpsQuality() {
  if (!gps.location.isValid())              return 0;
  if (gps.location.age() > GPS_AGE_MS)      return 0;
  if (!gps.satellites.isValid())            return 1;
  if (gps.satellites.value() < GPS_MIN_SAT) return 1;
  if (!gps.hdop.isValid())                  return 1;
  if (gps.hdop.hdop() > GPS_HDOP_ACCEPT)    return 1;
  if (gps.hdop.hdop() > GPS_HDOP_GOOD)      return 2;
  return 3;
}

bool checkGpsLock() { return getGpsQuality() >= 2; }

// ============================================================================
// [NAV 3] Dynamic Arrival Radius
// Semakin buruk HDOP, semakin besar radius agar kapal tidak berputar-putar.
// Formula: radius = min + (hdop - ref) * scale, clamped ke [min, max]
// ============================================================================
float calcArrivalRadius() {
  float hdop = (gps.hdop.isValid()) ? gps.hdop.hdop() : 5.0f;
  float radius = WP_ARRIVAL_MIN_M + (hdop - WP_ARRIVAL_HDOP_REF) * 1.5f;
  return constrain(radius, WP_ARRIVAL_MIN_M, WP_ARRIVAL_MAX_M);
}

// ============================================================================
// GPS LOCK FSM
// ============================================================================
void updateGpsLockFSM() {
  feedGPS();

  if (S.gpsLocked) {
    if (!checkGpsLock()) {
      S.gpsDegradeCount++;
      if (S.gpsDegradeCount >= GPS_DEGRADE_CYCLES) {
        S.gpsLocked       = false;
        S.gpsConfirmCount = 0;
        S.gpsDegradeCount = 0;
        Serial.println(F("[GPS] LOCK HILANG! Quality buruk terlalu lama."));

        if (S.autopilotActive) {
          S.autopilotActive = false;
          S.targetSpeed     = 0;
          S.steerIntegral   = 0.0;
          S.mode            = MODE_IDLE;
          setServoTarget(SERVO_CENTER);
          Serial.println(F("[NAV] Autopilot DIHENTIKAN — GPS lock hilang!"));
          beepAsync(300, 5);
        }
      }
    } else {
      S.gpsDegradeCount = 0;
    }
  }

  if (S.gpsLocked && S.gpsBuzzDone) return;

  if (!S.gpsLocked && millis() - S.lastGpsLog >= 1000) {
    S.lastGpsLog = millis();
    uint8_t  q    = getGpsQuality();
    uint8_t  sats = gps.satellites.isValid() ? (uint8_t)gps.satellites.value() : 0;
    float    hdop = gps.hdop.isValid()        ? gps.hdop.hdop()                 : 99.9f;
    double   lat  = gps.location.isValid()    ? gps.location.lat()              : 0.0;
    double   lng  = gps.location.isValid()    ? gps.location.lng()              : 0.0;
    unsigned long elapsed = (millis() - S.bootTime) / 1000;

    const char* qlabel;
    switch (q) {
      case 0:  qlabel = "SEARCHING"; break;
      case 1:  qlabel = "WEAK SAT "; break;
      case 2:  qlabel = "WEAK FIX "; break;
      case 3:  qlabel = "GOOD FIX "; break;
      default: qlabel = "???      "; break;
    }
    Serial.printf("[GPS] T+%3lus | %s | Sat:%2u | HDOP:%.1f | Lat:%.6f Lng:%.6f\n",
      elapsed, qlabel, sats, hdop, lat, lng);
  }

  if (!S.gpsLocked) {
    if (checkGpsLock()) S.gpsConfirmCount++;
    else                S.gpsConfirmCount = 0;

    if (S.gpsConfirmCount >= 4) {
      S.gpsLocked       = true;
      S.gpsDegradeCount = 0;
      digitalWrite(PIN_LED, HIGH);

      Serial.println(F("\n[GPS] ============================================"));
      Serial.println(F("[GPS]  *** GPS TERKUNCI! ***"));
      Serial.printf( "[GPS]  Lat       : %.8f\n",      gps.location.lat());
      Serial.printf( "[GPS]  Lng       : %.8f\n",      gps.location.lng());
      Serial.printf( "[GPS]  Satelit   : %u\n",        (unsigned)gps.satellites.value());
      Serial.printf( "[GPS]  HDOP      : %.2f\n",      gps.hdop.hdop());
      Serial.printf( "[GPS]  Quality   : %u/3\n",      getGpsQuality());
      Serial.printf( "[GPS]  Waktu lock: %lu detik\n", (millis() - S.bootTime) / 1000);
      Serial.println(F("[GPS] ============================================\n"));

      S.filteredLat  = gps.location.lat();
      S.filteredLng  = gps.location.lng();
      S.filteredTime = millis();
      S.filterInit   = true;

      saveLastPosition(gps.location.lat(), gps.location.lng());
      S.lastGpsSave = millis();

      if (!S.gpsBuzzDone) {
        beepAsync(200, 3);
        S.gpsBuzzDone = true;
      }
    }
  }

  if (!S.gpsLocked) {
    static unsigned long lastToggle = 0;
    static bool ledState = false;
    uint8_t q = getGpsQuality();
    unsigned long interval;
    switch (q) {
      case 0:  interval = 120; break;
      case 1:  interval = 400; break;
      default: interval = 800; break;
    }
    if (millis() - lastToggle >= interval) {
      lastToggle = millis();
      ledState   = !ledState;
      digitalWrite(PIN_LED, ledState);
    }
  }
}

// ============================================================================
// SERVO
// ============================================================================
void servoInit() {
  ESP32PWM::allocateTimer(0);
  steeringServo.setPeriodHertz(50);
  steeringServo.attach(SERVO_PIN, 500, 2400);
  steeringServo.write(SERVO_CENTER);
  S.servoCurrent = SERVO_CENTER;
  S.servoTarget  = SERVO_CENTER;
  Serial.println(F("[SERVO] Timer 0, 50Hz, GPIO4 — posisi tengah."));
}

void updateServoSmooth() {
  if (millis() - S.lastServoUpdate < SERVO_INTERVAL_MS) return;
  S.lastServoUpdate = millis();
  if (S.servoCurrent == S.servoTarget) return;
  int diff = S.servoTarget - S.servoCurrent;
  S.servoCurrent += (abs(diff) <= SERVO_STEP_DEG)
    ? diff : ((diff > 0) ? SERVO_STEP_DEG : -SERVO_STEP_DEG);
  steeringServo.write(S.servoCurrent);
}

void setServoTarget(int angle) {
  S.servoTarget = constrain(angle, SERVO_MAX_LEFT, SERVO_MAX_RIGHT);
}

// ============================================================================
// ULTRASONIC
// ============================================================================
int readFilteredDist(int trig, int echo, int* buf) {
  digitalWrite(trig, LOW);  delayMicroseconds(2);
  digitalWrite(trig, HIGH); delayMicroseconds(10);
  digitalWrite(trig, LOW);
  long dur = pulseIn(echo, HIGH, 15000);
  int  raw = (dur == 0) ? 400 : (int)(dur * 0.017f);
  buf[bufIdx] = raw;
  long sum = 0;
  for (int i = 0; i < FILTER_SAMPLES; i++) sum += buf[i];
  return (int)(sum / FILTER_SAMPLES);
}

// ============================================================================
// AVOIDANCE
// ============================================================================
bool processAvoidance() {
  if (millis() - S.lastSonarRead < SONAR_INTERVAL) return S.isAvoiding;
  S.lastSonarRead = millis();

  // [v15.1 #3] feedGPS() di sekitar pulseIn() yang blocking ~15ms per sensor
  //            Di 38400 baud, ~144 byte GPS bisa hilang dalam 30ms tanpa ini
  feedGPS();
  int dL = readFilteredDist(TRIG_LEFT_PIN,  ECHO_LEFT_PIN,  leftBuf);
  feedGPS();
  int dR = readFilteredDist(TRIG_RIGHT_PIN, ECHO_RIGHT_PIN, rightBuf);
  feedGPS();
  bufIdx = (bufIdx + 1) % FILTER_SAMPLES;

  cachedDistLeft  = dL;
  cachedDistRight = dR;

  if (dL < CRITICAL_DIST && dR < CRITICAL_DIST) {
    S.targetSpeed = -AVOID_SPEED;
    setServoTarget(SERVO_CENTER);
    S.isAvoiding = true;
  } else if (dL < OBSTACLE_DIST) {
    S.targetSpeed = AVOID_SPEED;
    setServoTarget(SERVO_MAX_RIGHT);
    S.isAvoiding = true;
  } else if (dR < OBSTACLE_DIST) {
    S.targetSpeed = AVOID_SPEED;
    setServoTarget(SERVO_MAX_LEFT);
    S.isAvoiding = true;
  } else {
    S.isAvoiding = false;
  }

  S.smartMoveActive = S.isAvoiding;
  return S.isAvoiding;
}

// ============================================================================
// [NAV 4] MQTT Navigation Event Publisher
// Kirim notifikasi ke server saat event navigasi terjadi.
// ============================================================================
void publishNavEvent(const char* event, int wpIndex, double dist) {
  if (!mqttClient.connected()) return;

  // [v15.1 #4] Explicit size
  JsonDocument doc(256);
  doc["event"]    = event;
  doc["wp_index"] = wpIndex;
  doc["wp_total"] = S.waypointCount;
  doc["dist_m"]   = dist;
  doc["lat"]      = S.filteredLat;
  doc["lng"]      = S.filteredLng;
  doc["uptime_s"] = (millis() - S.bootTime) / 1000;

  size_t sz = measureJson(doc);
  if (mqttClient.beginPublish(TOPIC_NAV_EVENT, sz, false)) {
    serializeJson(doc, mqttClient);
    mqttClient.endPublish();
  }
}

// ============================================================================
// JOYSTICK
// ============================================================================
void handleJoystick(JsonDocument& doc) {
  // smartMoveActive guard dihapus — avoidance tidak aktif di manual mode.
  // Jika user kirim joystick saat AUTO (avoidance sedang aktif),
  // autopilot dibatalkan dan mode pindah ke MANUAL (avoidance berhenti).

  if (S.mode == MODE_AUTO) {
    S.autopilotActive = false;
    S.waypointCount   = 0;
    S.waypointIndex   = 0;
    S.steerIntegral   = 0.0;  // [v15.1 #6] Reset integral agar tidak terbawa ke sesi AUTO berikutnya
    Serial.println("[NAV] Rute otonom dibatalkan — manual override");
  }

  if (S.motorDisabled) reenableMotor();

  S.mode        = MODE_MANUAL;
  S.lastCommand = millis();

  // [FIX #12] Gunakan operator | (ArduinoJson v7), bukan containsKey() yang deprecated
  float throttleRaw = doc["throttle"] | 0.0f;
  float steeringRaw = doc["steering"] | 0.0f;

  // [FIX #11] Normalisasi input yang lebih robust
  // Threshold 1.5 untuk membedakan range [-1,1] vs [-100,100]
  // Nilai 1.0-1.5 tetap dianggap normalized (bukan dibagi 100)
  float throttle = (fabsf(throttleRaw) > 1.5f)
    ? constrain(throttleRaw / 100.0f, -1.0f, 1.0f)
    : constrain(throttleRaw, -1.0f, 1.0f);

  float steering = (fabsf(steeringRaw) > 1.5f)
    ? constrain(steeringRaw / 100.0f, -1.0f, 1.0f)
    : constrain(steeringRaw, -1.0f, 1.0f);

  if (fabsf(throttle) < JOY_DEADZONE_THROTTLE) throttle = 0.0f;
  if (fabsf(steering) < JOY_DEADZONE_STEERING) steering = 0.0f;

  int steerAngle = SERVO_CENTER + (int)(steering * 45.0f);
  setServoTarget(steerAngle);

  int baseSpeed = 0;

  if (fabsf(throttle) < JOY_DEADZONE_THROTTLE && fabsf(steering) > JOY_DEADZONE_STEERING) {
    baseSpeed = (steering < 0.0f) ? TURN_SPEED : -TURN_SPEED;
    Serial.printf("[JOY] Pivot | str=%.2f | spd=%d | svo=%d\n",
      steering, baseSpeed, steerAngle);

  } else if (fabsf(throttle) >= JOY_DEADZONE_THROTTLE && fabsf(steering) > JOY_DEADZONE_STEERING) {
    baseSpeed = (int)(throttle * MAX_SPEED * 0.9f);
    Serial.printf("[JOY] Turn  | thr=%.2f str=%.2f | spd=%d | svo=%d\n",
      throttle, steering, baseSpeed, steerAngle);

  } else if (fabsf(throttle) >= JOY_DEADZONE_THROTTLE) {
    baseSpeed = (int)(throttle * MAX_SPEED);
    setServoTarget(SERVO_CENTER);
    Serial.printf("[JOY] Lurus | thr=%.2f | spd=%d\n", throttle, baseSpeed);

  } else {
    baseSpeed = 0;
    setServoTarget(SERVO_CENTER);
  }

  S.targetSpeed = constrain(baseSpeed, -MAX_SPEED, MAX_SPEED);
}

// ============================================================================
// ROUTE
// ============================================================================
void handleRoute(JsonDocument& doc) {
  if (!S.gpsLocked) {
    Serial.println(F("[NAV] Rute ditolak — GPS belum lock!"));
    return;
  }

  const char* action = doc["action"] | "";

  if (strcmp(action, "start") == 0) {
    JsonArray wps = doc["waypoints"];
    int count = min((int)wps.size(), MAX_WAYPOINTS);
    if (count < 2) {
      Serial.println("[NAV] Rute ditolak — butuh >= 2 waypoint");
      return;
    }
    // [v15.1 #5] Validasi 2-pass: validasi dulu, baru copy
    //            Jika WP ke-3 dari 5 invalid, rute lama tetap utuh
    // ── Pass 1: Validasi saja (tidak tulis ke S.waypoints) ──
    for (int i = 0; i < count; i++) {
      double wLat = wps[i]["lat"] | 0.0;
      double wLng = wps[i]["lng"] | 0.0;
      if (wLat < -90.0 || wLat > 90.0 || wLng < -180.0 || wLng > 180.0) {
        Serial.printf("[NAV] WP%d koordinat di luar range: lat=%.6f lng=%.6f\n", i, wLat, wLng);
        Serial.println(F("[NAV] Rute ditolak — koordinat waypoint tidak valid!"));
        return;
      }
      if (fabs(wLat) < 0.0001 && fabs(wLng) < 0.0001) {
        Serial.printf("[NAV] WP%d koordinat (0,0) — kemungkinan invalid\n", i);
        Serial.println(F("[NAV] Rute ditolak — koordinat waypoint tidak valid!"));
        return;
      }
      if (isnan(wLat) || isnan(wLng) || isinf(wLat) || isinf(wLng)) {
        Serial.printf("[NAV] WP%d koordinat NaN/Inf — ditolak\n", i);
        Serial.println(F("[NAV] Rute ditolak — koordinat waypoint tidak valid!"));
        return;
      }
    }
    // ── Pass 2: Semua valid — copy ke S.waypoints ──
    for (int i = 0; i < count; i++) {
      S.waypoints[i].lat = wps[i]["lat"] | 0.0;
      S.waypoints[i].lng = wps[i]["lng"] | 0.0;
    }
    S.waypointCount   = count;
    S.waypointIndex   = 0;
    S.autopilotActive = true;
    S.steerIntegral   = 0.0;
    S.mode            = MODE_AUTO;
    S.wpStartTime     = millis();   // [NAV 2] mulai hitung timeout WP pertama
    S.lastXTE         = 0.0;
    S.headingValid    = false;      // [NAV 6] reset heading validity

    if (S.motorDisabled) reenableMotor();

    Serial.printf("[NAV] Rute dimulai: %d waypoint\n", count);
    publishNavEvent("route_start", 0, 0.0);

  } else if (strcmp(action, "stop") == 0) {
    S.autopilotActive = false;
    S.waypointCount   = 0;
    S.waypointIndex   = 0;
    S.targetSpeed     = 0;
    S.steerIntegral   = 0.0;
    S.mode            = MODE_IDLE;
    setServoTarget(SERVO_CENTER);
    Serial.println("[NAV] Rute dihentikan oleh server");
    publishNavEvent("route_stop", 0, 0.0);
  }
}

// ============================================================================
// AUTOPILOT — v14.8 Navigation Grid
//
// [NAV 1] Cross-Track Error (XTE):
//   Hitung jarak tegak lurus kapal dari garis WP[n-1] → WP[n].
//   Tambahkan koreksi bearing agar kapal kembali ke garis.
//   Ini mencegah kapal menyimpang jauh akibat arus/angin.
//
// [NAV 2] WP Timeout:
//   Jika WP tidak tercapai dalam WP_TIMEOUT_S detik, skip ke WP berikutnya.
//   Mencegah kapal stuck selamanya di satu titik.
//
// [NAV 3] Dynamic Arrival Radius:
//   Radius arrival berdasarkan HDOP. GPS buruk = radius lebih besar.
//   Mencegah kapal berputar-putar di sekitar WP.
//
// [NAV 5] Gradual Speed:
//   Speed berkurang smooth saat mendekati WP, bukan 3 level diskrit.
//   Formula: lerp dari WP_NAV_SPEED ke SPEED_MIN_APPROACH.
//
// [NAV 6] Heading Staleness:
//   Jika heading tidak di-update > 10 detik (kapal diam), heading dianggap
//   invalid. Kapal akan mengarah langsung ke WP tanpa koreksi heading.
// ============================================================================
void advanceWaypoint(const char* reason, double dist) {
  Serial.printf("[NAV] WP %d %s (%.1fm). Next: %d/%d\n",
    S.waypointIndex, reason, dist, S.waypointIndex + 1, S.waypointCount);
  publishNavEvent(reason, S.waypointIndex, dist);
  S.waypointIndex++;
  S.steerIntegral = 0.0;
  S.wpStartTime   = millis();   // reset timeout untuk WP berikutnya
  S.lastXTE       = 0.0;
}

void updateAutopilot() {
  // ── Cek apakah rute selesai ─────────────────────────────────────────────
  if (!S.autopilotActive || S.waypointIndex >= S.waypointCount) {
    if (S.autopilotActive) {
      S.autopilotActive = false;
      S.targetSpeed     = 0;
      S.steerIntegral   = 0.0;
      S.mode            = MODE_IDLE;
      setServoTarget(SERVO_CENTER);
      Serial.println("[NAV] Semua waypoint tercapai — rute selesai");
      publishNavEvent("route_complete", S.waypointCount, 0.0);
    }
    return;
  }

  // ── GPS data valid? ─────────────────────────────────────────────────────
  // [v15.1 #1] Stop motor saat GPS stale — jangan jalan buta
  if (!gps.location.isValid() || gps.location.age() > 2000) {
    S.targetSpeed = 0;
    setServoTarget(SERVO_CENTER);
    return;
  }
  if (!acceptGpsPosition(gps.location.lat(), gps.location.lng())) return;

  double curLat = S.filteredLat;
  double curLng = S.filteredLng;
  double tgtLat = S.waypoints[S.waypointIndex].lat;
  double tgtLng = S.waypoints[S.waypointIndex].lng;

  double dist    = haversineM(curLat, curLng, tgtLat, tgtLng);
  double bearing = bearingDeg(curLat, curLng, tgtLat, tgtLng);

  // ── [M8U 7] Heading dengan prioritas: DR > GPS course > fallback ─────────
  // Prioritas 1: DR heading dari IMU/sensor fusion (valid saat kecepatan rendah)
  // Prioritas 2: GPS course (valid saat kecepatan > 2 km/h)
  // Prioritas 3: Last valid heading (jika < 10 detik)
  // Prioritas 4: Bearing ke WP (no correction)
  double heading;
  bool   headingFresh = false;

  if (S.drHeadingValid && (millis() - S.drUpdateTime < 2000)) {
    // [M8U 7] Prioritas 1: DR heading dari sensor fusion M8U
    heading              = S.drHeading;
    S.lastValidHeading   = heading;
    S.headingUpdateTime  = millis();
    S.headingValid       = true;
    headingFresh         = true;
  } else if (gps.speed.isValid() && gps.speed.kmph() > 2.0 && gps.course.isValid()) {
    // Prioritas 2: GPS course (kecepatan cukup tinggi)
    heading              = gps.course.deg();
    S.lastValidHeading   = heading;
    S.headingUpdateTime  = millis();
    S.headingValid       = true;
    headingFresh         = true;
  } else if (S.headingValid && (millis() - S.headingUpdateTime < HEADING_STALE_MS)) {
    // Prioritas 3: Heading masih cukup baru, pakai fallback
    heading      = S.lastValidHeading;
    headingFresh = false;
  } else {
    // Prioritas 4: Heading sudah stale — arahkan langsung ke WP tanpa koreksi
    heading        = bearing;  // anggap heading = bearing (no error)
    S.headingValid = false;
    headingFresh   = false;
  }

  // ── [NAV 3] Dynamic arrival radius ──────────────────────────────────────
  S.currentArrivalR = calcArrivalRadius();

  // ── Waypoint tercapai ───────────────────────────────────────────────────
  if (dist < S.currentArrivalR) {
    advanceWaypoint("wp_reached", dist);
    return;
  }

  // ── [NAV 2] Waypoint timeout ────────────────────────────────────────────
  unsigned long wpElapsed = (millis() - S.wpStartTime) / 1000;
  if (wpElapsed >= WP_TIMEOUT_S) {
    Serial.printf("[NAV] WP %d TIMEOUT setelah %lu detik! Skip.\n",
      S.waypointIndex, wpElapsed);
    advanceWaypoint("wp_timeout", dist);
    beepAsync(200, 3);  // warning beep
    return;
  }

  // ── Obstacle avoidance (aktif di AUTO — kapal jalan sendiri) ──────────────
  if (processAvoidance()) {
    S.steerIntegral = 0.0;  // [v15.1 #7] Reset integral agar steering tidak loncat setelah avoidance
    return;
  }

  // ── [NAV 1] Cross-Track Error ───────────────────────────────────────────
  // Hitung XTE: jarak tegak lurus dari garis WP[n-1] → WP[n]
  double xte = 0.0;
  if (S.waypointIndex > 0) {
    // Garis dari WP sebelumnya ke WP saat ini
    double fromLat = S.waypoints[S.waypointIndex - 1].lat;
    double fromLng = S.waypoints[S.waypointIndex - 1].lng;
    xte = crossTrackM(fromLat, fromLng, tgtLat, tgtLng, curLat, curLng);
  }
  // Untuk WP pertama (index 0), XTE = 0 (tidak ada garis referensi)
  S.lastXTE = xte;

  // ── Heading error + XTE correction ──────────────────────────────────────
  double headingError = bearing - heading;
  if (headingError >  180.0) headingError -= 360.0;
  if (headingError < -180.0) headingError += 360.0;

  // XTE koreksi: dorong kapal kembali ke garis
  // xte positif = kapal di kanan garis → koreksi ke kiri (negatif)
  double xteCorrection = constrain(-xte * XTE_KP, -XTE_MAX_CORRECTION, XTE_MAX_CORRECTION);

  // Total error = heading error + XTE correction
  double totalError = headingError + xteCorrection;
  if (totalError >  180.0) totalError -= 360.0;
  if (totalError < -180.0) totalError += 360.0;

  // ── PI steering controller ──────────────────────────────────────────────
  S.steerIntegral = constrain(
    S.steerIntegral + totalError * STEER_DT_S,
    -STEER_I_MAX, STEER_I_MAX
  );

  double steerOutput = STEER_KP * (totalError / 90.0 * 45.0)
                     + STEER_KI * S.steerIntegral;

  int steerAngle = SERVO_CENTER + (int)steerOutput;
  setServoTarget(constrain(steerAngle, SERVO_MAX_LEFT, SERVO_MAX_RIGHT));

  // ── [NAV 5] Gradual speed ──────────────────────────────────────────────
  // Belok tajam → lambat. Dekat WP → lambat. Jauh & lurus → cepat.
  int speedFromError;
  double absError = fabs(totalError);
  if (absError > 60.0) {
    speedFromError = TURN_SPEED;
  } else if (absError > 20.0) {
    // Lerp: 60 deg → TURN_SPEED, 20 deg → WP_NAV_SPEED
    float t = (float)(absError - 20.0) / 40.0f;
    speedFromError = WP_NAV_SPEED - (int)(t * (WP_NAV_SPEED - TURN_SPEED));
  } else {
    speedFromError = WP_NAV_SPEED;
  }

  int speedFromDist;
  if (dist < S.currentArrivalR * 2.0f) {
    // Sangat dekat — kecepatan minimum
    speedFromDist = SPEED_MIN_APPROACH;
  } else if (dist < SPEED_APPROACH_DIST) {
    // Lerp: arrivalR*2 → SPEED_MIN_APPROACH, SPEED_APPROACH_DIST → WP_NAV_SPEED
    // [FIX #8] Guard division by zero jika currentArrivalR*2 >= SPEED_APPROACH_DIST
    float denominator = SPEED_APPROACH_DIST - S.currentArrivalR * 2.0f;
    float t;
    if (denominator <= 0.001f) {
      t = 0.0f;  // Sangat dekat — gunakan kecepatan minimum
    } else {
      t = (float)(dist - S.currentArrivalR * 2.0f) / denominator;
    }
    t = constrain(t, 0.0f, 1.0f);
    speedFromDist = SPEED_MIN_APPROACH + (int)(t * (WP_NAV_SPEED - SPEED_MIN_APPROACH));
  } else {
    speedFromDist = WP_NAV_SPEED;
  }

  // Ambil yang lebih lambat (lebih aman)
  S.targetSpeed = min(speedFromError, speedFromDist);

  // Log periodik (setiap ~2 detik, berdasarkan sonar interval)
  static unsigned long lastNavLog = 0;
  if (millis() - lastNavLog > 2000) {
    lastNavLog = millis();
    Serial.printf("[NAV] WP%d | dist:%.1fm | brng:%.0f | hdg:%.0f | err:%.0f | xte:%.1fm | spd:%d | R:%.1fm | T:%lus/%ds\n",
      S.waypointIndex, dist, bearing, heading, totalError, xte,
      S.targetSpeed, S.currentArrivalR, wpElapsed, WP_TIMEOUT_S);
  }
}

// ============================================================================
// GSM MODEM — Power On & Init
// ============================================================================
void modemPowerOn() {
  Serial.println(F("[GSM] Power on modem A7670C..."));
  pinMode(GSM_PWRKEY_PIN, OUTPUT);
  digitalWrite(GSM_PWRKEY_PIN, LOW);
  delay(100);
  digitalWrite(GSM_PWRKEY_PIN, HIGH);
  delay(1000);
  digitalWrite(GSM_PWRKEY_PIN, LOW);
  delay(3000);  // Tunggu module boot
  Serial.println(F("[GSM] PWRKEY pulse selesai."));
}

bool initGSM() {
  Serial.println(F("[GSM] Inisialisasi modem A7670C..."));
  modemPowerOn();

  gsmSerial.begin(GSM_BAUD, SERIAL_8N1, GSM_RX_PIN, GSM_TX_PIN);
  delay(3000);

  Serial.println(F("[GSM] Mengirim AT init..."));
  if (!modem.restart()) {
    Serial.println(F("[GSM] Modem restart GAGAL — coba init tanpa restart..."));
    if (!modem.init()) {
      Serial.println(F("[GSM] Modem init GAGAL!"));
      return false;
    }
  }

  String modemInfo = modem.getModemInfo();
  Serial.printf("[GSM] Modem: %s\n", modemInfo.c_str());

  String imei = modem.getIMEI();
  Serial.printf("[GSM] IMEI: %s\n", imei.c_str());

  Serial.println(F("[GSM] Menunggu registrasi jaringan..."));
  if (!modem.waitForNetwork(60000)) {
    Serial.println(F("[GSM] Registrasi jaringan GAGAL (timeout 60s)!"));
    return false;
  }

  if (modem.isNetworkConnected()) {
    Serial.println(F("[GSM] Jaringan terdaftar."));
  }

  Serial.printf("[GSM] Menghubungkan ke APN: %s\n", GSM_APN);
  if (!modem.gprsConnect(GSM_APN, GSM_USER, GSM_PASS_APN)) {
    Serial.println(F("[GSM] GPRS connect GAGAL!"));
    return false;
  }

  Serial.println(F("[GSM] GPRS terhubung!"));
  int csq = modem.getSignalQuality();
  Serial.printf("[GSM] Signal quality (CSQ): %d/31\n", csq);
  S.gsmConnected = true;
  return true;
}

// ============================================================================
// GSM FAILSAFE — throttled GPRS check setiap 10 detik
// ============================================================================
void updateGsmFailsafe() {
  // Throttle: cek status GPRS hanya setiap GSM_CHECK_MS (10 detik)
  // karena modem.isGprsConnected() kirim AT command (~100ms)
  if (millis() - S.lastGsmCheck < GSM_CHECK_MS) return;
  S.lastGsmCheck = millis();

  bool connected = modem.isGprsConnected();

  if (!connected) {
    S.gsmConnected = false;
    if (S.gsmLostAt == 0) {
      S.gsmLostAt          = millis();
      S.gsmFailsafeFired   = false;
      Serial.println(F("[GSM] Koneksi hilang — hitung mundur failsafe..."));
    }

    // Failsafe: stop motor jika bukan autopilot (10 detik)
    if (!S.gsmFailsafeFired && millis() - S.gsmLostAt > GSM_FAILSAFE_MS) {
      if (S.mode != MODE_AUTO) {
        // [FIX #15] Gunakan emergencyStop() untuk konsistensi
        emergencyStop("GSM Failsafe — koneksi hilang > 10 detik");
        Serial.println(F("[SAFETY] GSM Failsafe — Emergency stop!"));
      }
      S.gsmFailsafeFired = true;
    }

    // [FIX #7] AUTO mode timeout — boat HARUS berhenti jika GSM putus terlalu lama
    // Tanpa ini, boat navigasi tanpa batas tanpa koneksi (tidak bisa di-stop remote)
    if (S.mode == MODE_AUTO && millis() - S.gsmLostAt > GSM_AUTO_TIMEOUT_MS) {
      emergencyStop("GSM AUTO Timeout — koneksi hilang > 120 detik");
      S.autopilotActive = false;
      S.waypointCount   = 0;
      S.waypointIndex   = 0;
      S.mode            = MODE_IDLE;
      Serial.println(F("[SAFETY] AUTO mode dihentikan — GSM timeout 120 detik!"));
      beepAsync(200, 5);
    }

    // Auto-reconnect GPRS
    static unsigned long lastGsmRetry = 0;
    if (millis() - lastGsmRetry > GSM_RECONNECT_MS) {
      lastGsmRetry = millis();
      Serial.println(F("[GSM] Mencoba reconnect GPRS..."));
      if (modem.isNetworkConnected()) {
        if (modem.gprsConnect(GSM_APN, GSM_USER, GSM_PASS_APN)) {
          Serial.println(F("[GSM] GPRS reconnect berhasil!"));
          S.gsmConnected = true;
        } else {
          Serial.println(F("[GSM] GPRS reconnect gagal."));
        }
      } else {
        Serial.println(F("[GSM] Jaringan belum terdaftar — tunggu..."));
      }
    }
  } else {
    if (S.gsmLostAt != 0) {
      Serial.println(F("[GSM] Koneksi pulih — failsafe direset."));
    }
    S.gsmConnected     = true;
    S.gsmLostAt        = 0;
    S.gsmFailsafeFired = false;
  }
}

// ============================================================================
// MQTT
// ============================================================================
void reconnectMqtt() {
  if (millis() - S.lastMqttRetry < 5000) return;
  S.lastMqttRetry = millis();
  Serial.println("[MQTT] Menghubungkan...");
  if (!mqttClient.connect(MQTT_CLIENT_ID, MQTT_USERNAME, MQTT_PASS)) {
    Serial.printf("[MQTT] Gagal, rc=%d\n", mqttClient.state());
    return;
  }
  mqttClient.subscribe(TOPIC_JOYSTICK);
  mqttClient.subscribe(TOPIC_ROUTE);
  Serial.println("[MQTT] Terhubung ke broker.");
}

void onMqttMessage(char* topic, byte* payload, unsigned int length) {
  // [FIX #10] Tolak payload terlalu besar untuk mencegah heap exhaustion
  if (length > 1024) {
    Serial.println(F("[MQTT] Payload terlalu besar — ditolak"));
    return;
  }

  // [v15.1 #4] Explicit size untuk mencegah alokasi memori tak terkontrol
  JsonDocument doc(512);
  DeserializationError err = deserializeJson(doc, payload, length);
  if (err != DeserializationError::Ok) {
    Serial.printf("[MQTT] JSON parse error: %s\n", err.c_str());
    return;
  }

  // [FIX #2] Validasi auth token — tolak pesan tanpa token yang benar
  const char* token = doc["auth"] | "";
  if (strcmp(token, MQTT_AUTH_TOKEN) != 0) {
    Serial.println(F("[MQTT] AUTH GAGAL — pesan ditolak (token tidak valid)"));
    return;
  }

  // [FIX #24] Gunakan strcmp() langsung, hindari String heap allocation
  if      (strcmp(topic, TOPIC_JOYSTICK) == 0) handleJoystick(doc);
  else if (strcmp(topic, TOPIC_ROUTE) == 0)    handleRoute(doc);
}

// ============================================================================
// TELEMETRY — [NAV 7] diperkaya dengan data navigasi grid
// ============================================================================
void publishTelemetry() {
  if (!mqttClient.connected()) return;
  if (millis() - S.lastStatusPublish < 2000) return;
  S.lastStatusPublish = millis();

  // [v15.1 #4] Explicit size — telemetri banyak field
  JsonDocument doc(1536);
  // [v15.1 #8] Pakai filtered coordinates — sama dengan yang dipakai autopilot
  doc["lat"]               = S.filterInit ? S.filteredLat : 0.0;
  doc["lng"]               = S.filterInit ? S.filteredLng : 0.0;
  doc["satellite_count"]   = gps.satellites.isValid() ? (int)gps.satellites.value() : 0;
  doc["waypoint_index"]    = S.waypointIndex;
  doc["waypoint_count"]    = S.waypointCount;
  doc["mode"]              = modeToString(S.mode);
  doc["obstacle_left"]     = cachedDistLeft;
  doc["obstacle_right"]    = cachedDistRight;
  doc["smart_move_active"] = S.smartMoveActive;
  doc["autopilot_active"]  = S.autopilotActive;
  doc["bearing"]           = gps.course.isValid() ? gps.course.deg() : 0.0;
  doc["speed"]             = gps.speed.isValid()  ? gps.speed.kmph() : 0.0;
  doc["hdop"]              = gps.hdop.isValid()   ? gps.hdop.hdop()  : 99.99;
  doc["motor_speed"]       = S.currentSpeed;
  doc["gps_fix"]           = S.gpsLocked;
  doc["gps_quality"]       = getGpsQuality();
  doc["steer_integral"]    = S.steerIntegral;
  doc["last_heading"]      = S.lastValidHeading;
  doc["heading_valid"]     = S.headingValid;          // [NAV 6]
  doc["motor_disabled"]    = S.motorDisabled;
  doc["uptime_s"]          = (millis() - S.bootTime) / 1000;

  // [GSM] Status koneksi seluler
  doc["gsm_connected"]     = S.gsmConnected;
  // Signal quality di-cache dari updateGsmFailsafe() (throttled 10s)
  static int cachedCSQ = 0;
  static unsigned long lastCSQUpdate = 0;
  if (S.gsmConnected && millis() - lastCSQUpdate > 30000) {
    cachedCSQ = modem.getSignalQuality();  // CSQ 0-31, update setiap 30 detik
    lastCSQUpdate = millis();
  }
  doc["signal_quality"]    = cachedCSQ;

  // [M8U 9] Dead Reckoning / Sensor Fusion telemetri
  doc["dr_heading"]        = S.drHeading;              // heading dari IMU/DR (deg)
  doc["dr_heading_acc"]    = S.drHeadingAcc;           // heading accuracy (deg)
  doc["dr_valid"]          = S.drHeadingValid;         // apakah DR heading valid
  doc["fusion_mode"]       = S.fusionMode;             // 0=init, 1=calib, 2=fused, 3=DR

  // [NAV 7] Data navigasi grid
  doc["xte"]               = S.lastXTE;               // [NAV 1] cross-track error (m)
  doc["arrival_radius"]    = S.currentArrivalR;        // [NAV 3] dynamic radius (m)

  if (S.autopilotActive && S.waypointIndex < S.waypointCount) {
    unsigned long wpSec = (millis() - S.wpStartTime) / 1000;
    doc["wp_elapsed_s"]  = wpSec;                      // [NAV 2] detik sejak mulai WP
    doc["wp_timeout_s"]  = WP_TIMEOUT_S;               // [NAV 2] batas timeout

    // Jarak ke WP aktif
    double d = haversineM(S.filteredLat, S.filteredLng,
                          S.waypoints[S.waypointIndex].lat,
                          S.waypoints[S.waypointIndex].lng);
    doc["wp_dist_m"]     = d;
  }

  size_t payloadSize = measureJson(doc);
  if (mqttClient.beginPublish(TOPIC_STATUS, payloadSize, false)) {
    serializeJson(doc, mqttClient);
    mqttClient.endPublish();
  }
}

// ============================================================================
// SETUP
// ============================================================================
void setup() {
  Serial.begin(115200);
  delay(500);
  // [FIX #14] Set bootTime di awal setup(), bukan di akhir setelah GSM init
  S.bootTime = millis();
  Serial.println(F("\n=== SPEDI BOAT v15.0-S3 — M8U + GSM A7670C ==="));
  Serial.println(F("=== M8U DR/IMU | GSM 4G LTE | Sea Mode | Sensor Fusion ===\n"));

  pinMode(PIN_LED,    OUTPUT); digitalWrite(PIN_LED,    LOW);
  pinMode(PIN_BUZZER, OUTPUT); digitalWrite(PIN_BUZZER, LOW);

  pinMode(R_EN_PIN, OUTPUT); digitalWrite(R_EN_PIN, HIGH);
  pinMode(L_EN_PIN, OUTPUT); digitalWrite(L_EN_PIN, HIGH);

  pinMode(TRIG_LEFT_PIN,  OUTPUT); pinMode(ECHO_LEFT_PIN,   INPUT);
  pinMode(TRIG_RIGHT_PIN, OUTPUT); pinMode(ECHO_RIGHT_PIN,  INPUT);
  Serial.println(F("[INIT] Pin OK"));

  motorInit();
  setMotorRaw(0);
  Serial.println(F("[INIT] Motor OK"));

  servoInit();
  Serial.println(F("[INIT] Servo OK"));

  S.lastCommand      = millis();
  S.lastValidHeading = 0.0;
  S.headingValid     = false;

  // [M8U 6] GPS init: mulai di 9600 (default), kirim config, lalu switch ke 38400
  gpsSerial.begin(GPS_INITIAL_BAUD, SERIAL_8N1, GPS_RX_PIN, GPS_TX_PIN);
  delay(500);
  Serial.printf("[GPS M8U] Serial1 mulai @ %d, RX=%d TX=%d\n", GPS_INITIAL_BAUD, GPS_RX_PIN, GPS_TX_PIN);

  injectPosition();       // MGA-INI-POS_LLH di baud 9600
  configureGPS();         // Semua config termasuk CFG-PRT (baud→38400)

  // Module sudah switch ke baud baru setelah CFG-PRT, reconnect ESP32
  delay(200);
  gpsSerial.end();
  delay(100);
  gpsSerial.begin(GPS_TARGET_BAUD, SERIAL_8N1, GPS_RX_PIN, GPS_TX_PIN);
  delay(200);
  Serial.printf("[GPS M8U] Serial1 switch ke %d baud\n", GPS_TARGET_BAUD);

  // Kirim CFG-CFG save di baud baru
  saveGPSConfig();
  Serial.println(F("[GPS M8U] NEO-M8U siap (Sea mode, DR, 5Hz, 38400 baud)"));

  // ── GSM A7670C init (WDT timeout diperpanjang sementara) ──────
  // [FIX #6] Jangan disable WDT total — perpanjang timeout ke 120 detik
  //          agar device tetap bisa recovery jika modem hang total.
  Serial.println(F("[GSM] Memulai inisialisasi modem (WDT timeout 120s sementara)..."));
  {
    esp_task_wdt_config_t wdtLong = {
      .timeout_ms    = 120000,   // 120 detik untuk init GSM
      .idle_core_mask = 0,
      .trigger_panic  = true
    };
    esp_task_wdt_reconfigure(&wdtLong);
  }

  if (initGSM()) {
    mqttClient.setServer(MQTT_BROKER, MQTT_PORT);
    mqttClient.setBufferSize(1024);
    mqttClient.setCallback(onMqttMessage);
    reconnectMqtt();
  } else {
    Serial.println(F("[GSM] Gagal — akan retry di loop."));
    // Tetap setup MQTT agar bisa connect nanti
    mqttClient.setServer(MQTT_BROKER, MQTT_PORT);
    mqttClient.setBufferSize(1024);
    mqttClient.setCallback(onMqttMessage);
  }

  // Re-enable WDT setelah GSM init selesai
  esp_task_wdt_config_t wdtConfig = {
    .timeout_ms    = WDT_TIMEOUT_S * 1000,
    .idle_core_mask = 0,
    .trigger_panic  = true
  };
  esp_task_wdt_reconfigure(&wdtConfig);
  esp_task_wdt_add(NULL);
  Serial.printf("[INIT] Watchdog aktif: %d detik\n", WDT_TIMEOUT_S);

  // bootTime sudah di-set di awal setup() [FIX #14]

  Serial.println(F("[SYSTEM] Siap. Menunggu GPS lock..."));
  Serial.println(F("[SYSTEM] Buzzer 3x saat GPS terkunci.\n"));
}

// ============================================================================
// MAIN LOOP
// ============================================================================
void loop() {
  esp_task_wdt_reset();

  // 1. GPS lock FSM
  updateGpsLockFSM();

  // 2. Buzzer
  updateBuzzer();

  // 3. GPS quality warning
  if (S.gpsLocked && millis() - S.lastGpsCheck > 5000) {
    S.lastGpsCheck = millis();
    uint8_t q = getGpsQuality();
    if (q < 2) {
      Serial.printf("[GPS] PERINGATAN: Fix lemah! Q:%u Sat:%u HDOP:%.1f (degrade:%u/%u)\n",
        q,
        gps.satellites.isValid() ? (unsigned)gps.satellites.value() : 0,
        gps.hdop.isValid() ? gps.hdop.hdop() : 99.9f,
        S.gpsDegradeCount, GPS_DEGRADE_CYCLES);
    }
  }

  // 4. Auto-save posisi
  // [FIX #13] Hanya simpan ke NVS jika posisi berubah > 10 meter
  //           untuk mengurangi NVS flash wear (~100K write cycles)
  if (S.gpsLocked && gps.location.isValid() &&
      millis() - S.lastGpsSave >= GPS_SAVE_INTERVAL_MS) {
    static double lastSavedLat = 0.0;
    static double lastSavedLng = 0.0;
    static bool   hasSaved     = false;
    double curLat = gps.location.lat();
    double curLng = gps.location.lng();
    bool shouldSave = !hasSaved ||
                      haversineM(lastSavedLat, lastSavedLng, curLat, curLng) > 10.0;
    if (shouldSave) {
      saveLastPosition(curLat, curLng);
      lastSavedLat = curLat;
      lastSavedLng = curLng;
      hasSaved     = true;
    }
    S.lastGpsSave = millis();
  }

  // 5. Servo smooth
  updateServoSmooth();

  // 6. Motor ramp
  updateMotorPhysics();

  // 7. GSM failsafe (throttled setiap 10 detik)
  updateGsmFailsafe();

  // 8. Mode FSM
  switch (S.mode) {
    case MODE_MANUAL:
      if (millis() - S.lastCommand > JOYSTICK_TIMEOUT) {
        S.targetSpeed = 0;
      }
      // Avoidance TIDAK aktif di manual — user kontrol langsung via joystick
      break;
    case MODE_AUTO:
      updateAutopilot();
      break;
    case MODE_IDLE:
    default:
      S.targetSpeed = 0;
      break;
  }

  // 9. MQTT loop (via GSM)
  if (S.gsmConnected) {
    if (!mqttClient.connected()) reconnectMqtt();
    mqttClient.loop();
  }

  // 10. Telemetri
  publishTelemetry();

  // 11. Feed GPS tambahan
  feedGPS();
}
