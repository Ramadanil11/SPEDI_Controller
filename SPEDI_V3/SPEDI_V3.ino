/*
 * SPEDI Controller - ESP32-S3 4G LTE MQTT Vehicle Controller
 * Version: 6.0 - AUTO-PILOT RIVER NAVIGATION
 * Hardware: ESP32-S3 + FS-HCORE-A7670C (4G) + BTS7960 + Servo + GPS NEO-M8N + 2x Ultrasonic
 * Features: Smart Move, Manual Joystick, Real-Time Telemetry, Multi-Waypoint Auto-Navigation
 */

// Konfigurasi Modul 4G (FS-HCORE-A7670C / SIM7600)
#define TINY_GSM_MODEM_SIM7600
#define TINY_GSM_RX_BUFFER 1024

#include <Arduino.h>
#include <ESP32Servo.h>
#include <TinyGPS++.h>
#include <TinyGsmClient.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>

// ==========================================
// 1. PENGATURAN PIN (ESP32-S3)
// ==========================================
// Motor Driver BTS7960 (Dinamo Utama)
#define RPWM_PIN 4  
#define LPWM_PIN 5  
#define R_EN 6      
#define L_EN 7      

// Servo & Pompa Air
#define SERVO_PIN 15
#define PUMP_PIN 8

// Sensor Ultrasonik
#define TRIG_KIRI 16
#define ECHO_KIRI 17
#define TRIG_KANAN 18
#define ECHO_KANAN 19

// Hardware Serial Pins
#define RX_GPS 43
#define TX_GPS 44
#define RX_4G 10
#define TX_4G 11

// ==========================================
// 2. KONFIGURASI JARINGAN & MQTT
// ==========================================
const char apn[]      = "internet";
const char gprsUser[] = "";
const char gprsPass[] = "";

const char* MQTT_BROKER = "8062184d88664b75a4b4b4e8c609d73a.s1.eu.hivemq.cloud";
const int MQTT_PORT = 8883; // Pakai 1883 jika SSL gagal
const char* MQTT_USERNAME = "spedi";
const char* MQTT_PASSWORD = "Spedi1234";
const char* MQTT_CLIENT_ID = "esp32_spedi_vehicle_4g";

// Topik MQTT
const char* TOPIC_JOYSTICK = "spedi/vehicle/joystick";
const char* TOPIC_ROUTE    = "spedi/vehicle/route";
const char* TOPIC_STATUS   = "spedi/vehicle/status";

// ==========================================
// 3. OBJEK GLOBAL & VARIABEL
// ==========================================
HardwareSerial SerialGPS(1);
HardwareSerial Serial4G(2);

TinyGPSPlus gps;
Servo servoKemudi;
TinyGsm modem(Serial4G);
TinyGsmClientSecure gsmClient(modem);
PubSubClient mqttClient(gsmClient);

// Variabel Ultrasonik & Smart Move
long jarakKiri, jarakKanan;
const int BATAS_AMAN_CM = 50; 
bool isSmartMoveActive = false;

// Variabel Auto-Pilot (Waypoint Navigation)
const int MAX_WAYPOINTS = 20; 
double targetLats[MAX_WAYPOINTS];
double targetLngs[MAX_WAYPOINTS];
int totalWaypoints = 0;
int currentWaypointIndex = 0;
bool isAutoNavMode = false; 
const int BATAS_RADIUS_METER = 3; // Jarak toleransi capai titik bantu

// Variabel Keamanan Manual
unsigned long lastCommandTime = 0;
const unsigned long TIMEOUT_MS = 2000; 

// ==========================================
// 4. FUNGSI PENGGERAK & SENSOR
// ==========================================

long ukurJarak(int trigPin, int echoPin) {
  digitalWrite(trigPin, LOW); delayMicroseconds(2);
  digitalWrite(trigPin, HIGH); delayMicroseconds(10);
  digitalWrite(trigPin, LOW);
  long durasi = pulseIn(echoPin, HIGH, 30000); 
  if (durasi == 0) return 999; 
  return durasi * 0.034 / 2;
}

void kontrolMotor(int pwmMaju, int pwmMundur) {
  analogWrite(RPWM_PIN, pwmMaju);
  analogWrite(LPWM_PIN, pwmMundur);
}

void stopMotors() {
  kontrolMotor(0, 0);
  servoKemudi.write(90);
}

// ==========================================
// 5. LOGIKA SMART MOVE (PRIORITAS 1)
// ==========================================
void cekDanEksekusiSmartMove() {
  jarakKiri = ukurJarak(TRIG_KIRI, ECHO_KIRI);
  jarakKanan = ukurJarak(TRIG_KANAN, ECHO_KANAN);

  if (jarakKiri < BATAS_AMAN_CM || jarakKanan < BATAS_AMAN_CM) {
    isSmartMoveActive = true;
    Serial.println("⚠️ RINTANGAN! MENGAMBIL ALIH KEMUDI!");
    
    if (jarakKiri < BATAS_AMAN_CM && jarakKanan >= BATAS_AMAN_CM) {
      servoKemudi.write(135); 
      kontrolMotor(150, 0); 
    } else if (jarakKanan < BATAS_AMAN_CM && jarakKiri >= BATAS_AMAN_CM) {
      servoKemudi.write(45);  
      kontrolMotor(150, 0); 
    } else {
      servoKemudi.write(90);  
      kontrolMotor(0, 150); 
    }
  } else {
    isSmartMoveActive = false; 
  }
}

// ==========================================
// 6. LOGIKA AUTO-PILOT JALUR SUNGAI (PRIORITAS 2)
// ==========================================
void navigasiJalurSungai() {
  if (!isAutoNavMode || totalWaypoints == 0) return;

  double latSekarang = gps.location.lat();
  double lonSekarang = gps.location.lng();
  double arahKapalSekarang = gps.course.deg(); 

  double targetLat = targetLats[currentWaypointIndex];
  double targetLng = targetLngs[currentWaypointIndex];

  double jarakKeTitik = TinyGPSPlus::distanceBetween(latSekarang, lonSekarang, targetLat, targetLng);
  
  if (jarakKeTitik <= BATAS_RADIUS_METER) {
    currentWaypointIndex++; 
    
    if (currentWaypointIndex >= totalWaypoints) {
      Serial.println("🏆 MISI SELESAI! SPEDI SAMPAI DI TUJUAN AKHIR!");
      isAutoNavMode = false; 
      stopMotors();
      return;
    } else {
      Serial.println("✅ Checkpoint " + String(currentWaypointIndex) + " tercapai!");
    }
  }

  double arahKeTarget = TinyGPSPlus::courseTo(latSekarang, lonSekarang, targetLat, targetLng);
  double errorArah = arahKeTarget - arahKapalSekarang;
  
  if (errorArah > 180) errorArah -= 360;
  if (errorArah < -180) errorArah += 360;

  int sudutServo = 90 + (errorArah * 0.5); 
  sudutServo = constrain(sudutServo, 45, 135); 
  
  servoKemudi.write(sudutServo);
  kontrolMotor(200, 0); // Kecepatan jelajah sungai
}

// ==========================================
// 7. KOMUNIKASI MQTT & TELEMETRI
// ==========================================
void publishStatus() {
  if (!mqttClient.connected()) return;
  
  JsonDocument doc;
  doc["status"] = "online";
  doc["lat"] = gps.location.isValid() ? gps.location.lat() : 0.0;
  doc["lng"] = gps.location.isValid() ? gps.location.lng() : 0.0;
  doc["gps_sats"] = gps.satellites.value();
  doc["jarak_kiri"] = jarakKiri;
  doc["jarak_kanan"] = jarakKanan;
  doc["smart_move"] = isSmartMoveActive;
  doc["auto_pilot"] = isAutoNavMode;
  doc["waypoint_aktif"] = currentWaypointIndex;
  
  char buffer[256];
  serializeJson(doc, buffer);
  mqttClient.publish(TOPIC_STATUS, buffer);
}

void onMqttMessage(char* topic, byte* payload, unsigned int length) {
  JsonDocument doc;
  DeserializationError error = deserializeJson(doc, payload, length);
  if (error) return;

  String topicStr = String(topic);

  // A. KONTROL MANUAL (JOYSTICK)
  if (topicStr == TOPIC_JOYSTICK) {
    if (isSmartMoveActive) return; // Abaikan jika sedang menghindar
    
    // Matikan auto-pilot jika ada intervensi manual dari joystick
    isAutoNavMode = false; 

    float throttle = doc["throttle"]; 
    float steering = doc["steering"]; 
    
    int sudutServo = 90 + (steering * 45);
    sudutServo = constrain(sudutServo, 45, 135);
    servoKemudi.write(sudutServo);

    if (throttle > 0.1) {
      kontrolMotor(throttle * 255, 0);
    } else if (throttle < -0.1) {
      kontrolMotor(0, abs(throttle) * 255);
    } else {
      kontrolMotor(0, 0);
    }
    lastCommandTime = millis();
  }
  
  // B. TERIMA RUTE GARIS (AUTO-PILOT)
  else if (topicStr == TOPIC_ROUTE) {
    String action = doc["action"];
    if (action == "start_route") {
      JsonArray arrayRute = doc["waypoints"];
      totalWaypoints = 0;
      currentWaypointIndex = 0; 

      for (JsonVariant v : arrayRute) {
        if (totalWaypoints < MAX_WAYPOINTS) {
          targetLats[totalWaypoints] = v["lat"].as<double>();
          targetLngs[totalWaypoints] = v["lng"].as<double>();
          totalWaypoints++;
        }
      }

      if (totalWaypoints > 0) {
        isAutoNavMode = true; 
        Serial.println("🗺️ Rute baru diterima! Total titik: " + String(totalWaypoints));
      }
    }
    else if (action == "stop_route") {
      isAutoNavMode = false;
      stopMotors();
      Serial.println("🛑 Auto-Pilot dibatalkan dari Aplikasi.");
    }
  }
}

void connectToInternetAndMQTT() {
  Serial.println("Mencari Sinyal 4G...");
  if (!modem.gprsConnect(apn, gprsUser, gprsPass)) {
    Serial.println("❌ Gagal GPRS!");
    delay(3000);
    return;
  }
  Serial.println("✅ 4G Terhubung!");

  mqttClient.setServer(MQTT_BROKER, MQTT_PORT);
  mqttClient.setCallback(onMqttMessage);
  
  if (mqttClient.connect(MQTT_CLIENT_ID, MQTT_USERNAME, MQTT_PASSWORD)) {
    Serial.println("✅ MQTT Terhubung!");
    mqttClient.subscribe(TOPIC_JOYSTICK);
    mqttClient.subscribe(TOPIC_ROUTE);
  }
}

// ==========================================
// 8. SETUP & MAIN LOOP
// ==========================================
void setup() {
  Serial.begin(115200);
  
  pinMode(PUMP_PIN, OUTPUT);
  digitalWrite(PUMP_PIN, HIGH); // Pompa ON

  pinMode(RPWM_PIN, OUTPUT); pinMode(LPWM_PIN, OUTPUT);
  pinMode(R_EN, OUTPUT); pinMode(L_EN, OUTPUT);
  digitalWrite(R_EN, HIGH); digitalWrite(L_EN, HIGH);
  
  servoKemudi.setPeriodHertz(50);
  servoKemudi.attach(SERVO_PIN, 500, 2400);
  servoKemudi.write(90); 

  pinMode(TRIG_KIRI, OUTPUT); pinMode(ECHO_KIRI, INPUT);
  pinMode(TRIG_KANAN, OUTPUT); pinMode(ECHO_KANAN, INPUT);

  SerialGPS.begin(9600, SERIAL_8N1, RX_GPS, TX_GPS);
  Serial4G.begin(115200, SERIAL_8N1, RX_4G, TX_4G);

  Serial.println("\n🚀 SPEDI V6.0 - AUTO PILOT READY");
  modem.restart();
  connectToInternetAndMQTT();
  lastCommandTime = millis();
}

void loop() {
  while (SerialGPS.available() > 0) {
    gps.encode(SerialGPS.read());
  }

  if (!mqttClient.connected()) {
    connectToInternetAndMQTT();
  }
  mqttClient.loop();

  // Prioritas 1: Insting Menghindar
  cekDanEksekusiSmartMove();

  if (!isSmartMoveActive) {
    // Prioritas 2: Auto-Pilot Jalur Sungai
    if (isAutoNavMode) {
      if (gps.location.isValid()) {
        navigasiJalurSungai();
      } else {
        stopMotors(); // Berhenti kalau sinyal satelit hilang saat auto-pilot
      }
    } 
    // Prioritas 3: Kontrol Manual (Timeout Safety)
    else {
      if (millis() - lastCommandTime > TIMEOUT_MS) {
        stopMotors(); 
      }
    }
  }

  // Kirim Telemetri tiap 2 detik
  static unsigned long lastTelemetri = 0;
  if (millis() - lastTelemetri > 2000) {
    publishStatus();
    lastTelemetri = millis();
  }
}