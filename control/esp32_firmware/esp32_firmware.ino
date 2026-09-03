// ESP32 firmware for the RC PTZ rig: drives two Cytron-style 2-pin
// (DIR + PWM) motor controllers, six hobby servos (pan/tilt/focus/zoom/
// fire/load), and reads a compass over I2C — then talks to the Pi 5 over
// USB serial using the line-delimited JSON protocol documented in
// control/esp32_bridge.py.
//
// pan/tilt/focus/zoom are plain absolute-position servos (pos: 0-180).
// fire/load are not: they idle at 0 deg and any {"type":"servo",
// "name":"fire"|"load"} command (pos is ignored) triggers a one-shot,
// non-blocking swing-out-and-return — see startPulse()/updatePulse().
//
// NOT YET COMPILED OR RUN ON HARDWARE. Written against arduino-esp32 core
// 3.x (for the analogWrite()-based PWM API) and assumed library choices
// below — verify both against your actual toolchain/board before flashing.
//
// Libraries required (Arduino Library Manager):
//   - ESP32Servo         (github: madhephaestus/ESP32Servo)
//   - ArduinoJson        (v7)
//   - Adafruit BNO055 + Adafruit Unified Sensor
//     (placeholder compass choice from CLAUDE.md — swap this section for
//     whatever compass part actually gets wired up)
//
// Pinout below is a first guess, not a wiring decision — confirm against
// your actual board/wiring before trusting it.

#include <Wire.h>
#include <ESP32Servo.h>
#include <ArduinoJson.h>
#include <Adafruit_Sensor.h>
#include <Adafruit_BNO055.h>

// =========================================================================
// SAFETY LIMITS — tune these for your hardware. Keep MAX_MOTOR_PWM in sync
// with MAX_MOTOR_PWM in web/static/index.html and control/esp32_bridge.py.
// =========================================================================

// Hard ceiling on drive motor PWM (out of 255), regardless of what a
// command asks for. Start low and raise it once you've confirmed
// direction/wiring are correct.
const int MAX_MOTOR_PWM = 200;

// Deadman switch: if no command line (including the HUD page's heartbeat
// ping) has been received in this long, both drive motors are forced to
// stop. Protects against a closed browser tab, dropped websocket, or dead
// Pi/USB link leaving the motors running. Does not affect servos, which
// just hold their last commanded position.
const unsigned long COMMAND_TIMEOUT_MS = 500;

// ---- Fire/load pulse — tune these --------------------------------------
// Fire and load aren't plain position servos: they idle at 0 deg and, on
// any command, swing to a fixed angle, hold, then spring back to 0 —
// entirely on the ESP32 so the sequence completes reliably even if the
// Pi/browser link drops mid-pulse. A command while already mid-pulse is
// ignored (button, not toggle).
const int FIRE_PULSE_ANGLE = 40;
const int LOAD_PULSE_ANGLE = 120;
const unsigned long PULSE_HOLD_MS = 500;

// ---- Servo pins --------------------------------------------------------
const int PIN_SERVO_PAN = 13;
const int PIN_SERVO_TILT = 14;
const int PIN_SERVO_FOCUS = 27;
const int PIN_SERVO_ZOOM = 26;
const int PIN_SERVO_FIRE = 25;
const int PIN_SERVO_LOAD = 33;

// ---- Motor pins (Cytron 2-pin: DIR digital, PWM analog) ----------------
const int PIN_MOTOR_L_DIR = 32;
const int PIN_MOTOR_L_PWM = 4;
const int PIN_MOTOR_R_DIR = 16;
const int PIN_MOTOR_R_PWM = 17;

// ---- Compass (I2C, default ESP32 pins) ----------------------------------
const int PIN_I2C_SDA = 21;
const int PIN_I2C_SCL = 22;

Adafruit_BNO055 compass = Adafruit_BNO055(55, 0x28, &Wire);

Servo servoPan, servoTilt, servoFocus, servoZoom, servoFire, servoLoad;

struct ServoState {
  int pan = 90, tilt = 90, focus = 0, zoom = 0, fire = 0, load = 0;
} servoState;

struct MotorState {
  int dir = 1, pwm = 0;
} motorL, motorR;

String serialBuffer;

void applyServo(const String &name, int pos) {
  pos = constrain(pos, 0, 180);
  if (name == "pan") { servoState.pan = pos; servoPan.write(pos); }
  else if (name == "tilt") { servoState.tilt = pos; servoTilt.write(pos); }
  else if (name == "focus") { servoState.focus = pos; servoFocus.write(pos); }
  else if (name == "zoom") { servoState.zoom = pos; servoZoom.write(pos); }
  else if (name == "fire") { servoState.fire = pos; servoFire.write(pos); }
  else if (name == "load") { servoState.load = pos; servoLoad.write(pos); }
}

void applyMotor(const String &side, int dir, int pwm) {
  pwm = constrain(pwm, 0, MAX_MOTOR_PWM);
  dir = dir ? 1 : 0;
  if (side == "l") {
    motorL.dir = dir;
    motorL.pwm = pwm;
    digitalWrite(PIN_MOTOR_L_DIR, dir);
    analogWrite(PIN_MOTOR_L_PWM, pwm);
  } else if (side == "r") {
    motorR.dir = dir;
    motorR.pwm = pwm;
    digitalWrite(PIN_MOTOR_R_DIR, dir);
    analogWrite(PIN_MOTOR_R_PWM, pwm);
  }
}

unsigned long lastCommandMs = 0;

struct PulseState {
  bool active = false;
  unsigned long startMs = 0;
};
PulseState firePulse, loadPulse;

// Starts the swing-out leg immediately; updatePulse() below brings it back
// to 0 after PULSE_HOLD_MS without ever calling delay().
void startPulse(PulseState &state, const String &name, int angle) {
  if (state.active) return;  // mid-pulse: ignore, button not toggle
  state.active = true;
  state.startMs = millis();
  applyServo(name, angle);
}

void updatePulse(PulseState &state, const String &name, unsigned long now) {
  if (state.active && now - state.startMs >= PULSE_HOLD_MS) {
    applyServo(name, 0);
    state.active = false;
  }
}

void handleCommandLine(const String &line) {
  JsonDocument doc;
  if (deserializeJson(doc, line) != DeserializationError::Ok) return;

  // Any well-formed line — including a plain {"type":"ping"} heartbeat —
  // counts as proof the link is alive and resets the deadman timer.
  lastCommandMs = millis();

  const char *type = doc["type"] | "";
  if (strcmp(type, "servo") == 0) {
    String name = String((const char *)(doc["name"] | ""));
    if (name == "fire") {
      startPulse(firePulse, "fire", FIRE_PULSE_ANGLE);
    } else if (name == "load") {
      startPulse(loadPulse, "load", LOAD_PULSE_ANGLE);
    } else {
      applyServo(name, doc["pos"] | 0);
    }
  } else if (strcmp(type, "motor") == 0) {
    applyMotor(String((const char *)(doc["side"] | "")), doc["dir"] | 1, doc["pwm"] | 0);
  }
}

void publishTelemetry(float heading) {
  JsonDocument doc;
  doc["hdg"] = heading;
  JsonObject servo = doc["servo"].to<JsonObject>();
  servo["pan"] = servoState.pan;
  servo["tilt"] = servoState.tilt;
  servo["focus"] = servoState.focus;
  servo["zoom"] = servoState.zoom;
  servo["fire"] = servoState.fire;
  servo["load"] = servoState.load;
  JsonObject motor = doc["motor"].to<JsonObject>();
  JsonObject l = motor["l"].to<JsonObject>();
  l["dir"] = motorL.dir;
  l["pwm"] = motorL.pwm;
  JsonObject r = motor["r"].to<JsonObject>();
  r["dir"] = motorR.dir;
  r["pwm"] = motorR.pwm;
  serializeJson(doc, Serial);
  Serial.print('\n');
}

void setup() {
  Serial.begin(115200);

  pinMode(PIN_MOTOR_L_DIR, OUTPUT);
  pinMode(PIN_MOTOR_R_DIR, OUTPUT);

  servoPan.attach(PIN_SERVO_PAN);
  servoTilt.attach(PIN_SERVO_TILT);
  servoFocus.attach(PIN_SERVO_FOCUS);
  servoZoom.attach(PIN_SERVO_ZOOM);
  servoFire.attach(PIN_SERVO_FIRE);
  servoLoad.attach(PIN_SERVO_LOAD);
  applyServo("pan", servoState.pan);
  applyServo("tilt", servoState.tilt);
  applyServo("focus", servoState.focus);
  applyServo("zoom", servoState.zoom);
  applyServo("fire", servoState.fire);
  applyServo("load", servoState.load);

  Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL);
  compass.begin();

  lastCommandMs = millis();
}

unsigned long lastTelemetryMs = 0;
const unsigned long TELEMETRY_INTERVAL_MS = 100;

void loop() {
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n') {
      handleCommandLine(serialBuffer);
      serialBuffer = "";
    } else if (c != '\r') {
      serialBuffer += c;
    }
  }

  unsigned long now = millis();

  updatePulse(firePulse, "fire", now);
  updatePulse(loadPulse, "load", now);

  if (now - lastCommandMs > COMMAND_TIMEOUT_MS) {
    // Deadman: link's gone quiet, force the drive motors off. Re-asserted
    // every loop while the timeout stays exceeded — cheap and idempotent.
    applyMotor("l", 1, 0);
    applyMotor("r", 1, 0);
  }

  if (now - lastTelemetryMs >= TELEMETRY_INTERVAL_MS) {
    lastTelemetryMs = now;
    sensors_event_t event;
    compass.getEvent(&event);
    publishTelemetry(event.orientation.x);  // heading, degrees
  }
}
