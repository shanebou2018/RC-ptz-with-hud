// Vehicle-side ESP32 firmware for the ESP32+LoRa control architecture
// (this branch's second attempt at long-range control, after an earlier
// FPGA-based one in fpga/ -- see CLAUDE.md's fork section for the full
// history/decision). Drives six hobby servos and two Cytron-style 2-pin
// drive motor controllers, exactly like the main branch's
// control/esp32_firmware/esp32_firmware.ino -- but instead of taking
// commands from the Pi over USB serial, it receives them from a base
// station ESP32 (control/lora_base_esp32) over a dedicated E220-900T22D
// LoRa link, with the Pi completely out of the control loop. Telemetry
// still goes to the Pi over USB serial, in the SAME 14-byte binary frame
// format fpga/vehicle/rtl/telemetry_uart_tx.v used -- so
// control/vehicle_fpga_bridge.py keeps working unchanged, just pointed
// at this ESP32's serial port instead of an FPGA's.
//
// DEMO CODE, UNVERIFIED: written and reasoned through, never compiled (no
// Arduino/ESP32 toolchain in the dev sandbox this was written in) or run
// against real hardware -- no FPGA, ESP32, E220 module, servo, or motor
// controller in this architecture has been touched. Confirm every pin
// assignment, library API call, and timing constant below before
// flashing. Servo/motor/pulse/deadman logic is a straight port of
// esp32_firmware.ino's already-more-carefully-reasoned-through version of
// the same thing -- see that file if something here looks unexplained.
//
// No compass/IMU in this demo -- the base/vehicle hardware list this was
// built from didn't include one, unlike the main branch's ESP32 firmware
// or the earlier FPGA fork's spi_compass_driver.v. `headingDeg` in the
// telemetry frame is a static 0 placeholder; wire one up (I2C or SPI) and
// fill it in the same way esp32_firmware.ino does with its BNO055 if/when
// heading data is wanted on the HUD.
//
// Libraries required (Arduino Library Manager):
//   - ESP32Servo (github: madhephaestus/ESP32Servo)
//   - lora_packet (control/lora_esp32_shared/ -- copy/symlink that whole
//     folder into your Arduino libraries/ directory first)
//
// ---- Pinout (first guess, confirm against your actual wiring) ---------
// Servo/motor pins are the SAME as esp32_firmware.ino's, for continuity
// if you're wiring against the same harness. E220 pins are new for this
// sketch -- picked to avoid every servo/motor pin below, nothing more.
//
//   Servos:  pan=13  tilt=14  focus=27  zoom=26  fire=25  load=33
//   Motors:  L_DIR=32  L_PWM=4   R_DIR=16  R_PWM=17
//   E220:    M0=5  M1=18  AUX=19  (ESP32 UART2) RX2=23 <- E220 TXD
//                                                TX2=22 -> E220 RXD
//   Pi telemetry: hardware Serial (UART0 / USB), unchanged from
//                 esp32_firmware.ino -- no extra GPIO needed.
//
// The E220 must be pre-configured (matching channel/address/air-rate as
// the base station's module, via EBYTE's RF_Setting config tool or AT
// commands sent in config mode, M0=1/M1=1) BEFORE this sketch's normal-
// mode (M0=0/M1=0) transparent-transmission behavior will talk to
// anything -- that one-time config step isn't done by this sketch.

#include <ESP32Servo.h>
#include <lora_packet.h>
#include <string.h>  // strcmp() below

// =========================================================================
// SAFETY LIMITS -- same philosophy as esp32_firmware.ino. Keep
// MAX_MOTOR_PWM in sync with LORA_MAX_MOTOR_PWM in lora_packet.h (the
// base station clamps to that ceiling before sending, but the vehicle
// re-clamps here too -- never trust the link alone).
// =========================================================================
const int MAX_MOTOR_PWM = LORA_MAX_MOTOR_PWM;

// Deadman switch: if no valid, non-duplicate command packet has arrived
// this long, force both drive motors to 0. LoRa's lower packet rate and
// longer expected exposure to link loss (vs. USB-serial) argue for a
// longer timeout than esp32_firmware.ino's 500ms -- this is a starting
// guess, needs bench-tuning against the base station's actual
// LORA_CMD_SEND_INTERVAL_MS once real radios are on hand (see
// lora_base_esp32.ino).
const unsigned long COMMAND_TIMEOUT_MS = 1000;

// ---- Fire/load pulse -- identical constants/behavior to esp32_firmware.ino
const int FIRE_PULSE_ANGLE = 40;
const int LOAD_PULSE_ANGLE = 120;
const unsigned long PULSE_HOLD_MS = 500;

// ---- Servo pins ---------------------------------------------------------
const int PIN_SERVO_PAN = 13;
const int PIN_SERVO_TILT = 14;
const int PIN_SERVO_FOCUS = 27;
const int PIN_SERVO_ZOOM = 26;
const int PIN_SERVO_FIRE = 25;
const int PIN_SERVO_LOAD = 33;

// ---- Motor pins (Cytron 2-pin: DIR digital, PWM analog) -----------------
const int PIN_MOTOR_L_DIR = 32;
const int PIN_MOTOR_L_PWM = 4;
const int PIN_MOTOR_R_DIR = 16;
const int PIN_MOTOR_R_PWM = 17;

// ---- E220-900T22D pins ---------------------------------------------------
const int PIN_E220_M0 = 5;
const int PIN_E220_M1 = 18;
const int PIN_E220_AUX = 19;
const int PIN_E220_RX2 = 23;  // ESP32 RX  <- E220 TXD
const int PIN_E220_TX2 = 22;  // ESP32 TX  -> E220 RXD
const long E220_UART_BAUD = 9600;  // factory default UART baud -- the
                                    // module's *air* data rate is a
                                    // separate config-mode setting

HardwareSerial LoraSerial(2);  // ESP32 UART2

Servo servoPan, servoTilt, servoFocus, servoZoom, servoFire, servoLoad;

struct ServoState {
  int pan = 90, tilt = 90, focus = 0, zoom = 0, fire = 0, load = 0;
} servoState;

struct MotorState {
  int dir = 1, pwm = 0;
} motorL, motorR;

void applyServoPos(const char *name, int pos) {
  pos = constrain(pos, 0, 180);
  if (!strcmp(name, "pan")) { servoState.pan = pos; servoPan.write(pos); }
  else if (!strcmp(name, "tilt")) { servoState.tilt = pos; servoTilt.write(pos); }
  else if (!strcmp(name, "focus")) { servoState.focus = pos; servoFocus.write(pos); }
  else if (!strcmp(name, "zoom")) { servoState.zoom = pos; servoZoom.write(pos); }
  else if (!strcmp(name, "fire")) { servoState.fire = pos; servoFire.write(pos); }
  else if (!strcmp(name, "load")) { servoState.load = pos; servoLoad.write(pos); }
}

void applyMotor(const char *side, int dir, int pwm) {
  pwm = constrain(pwm, 0, MAX_MOTOR_PWM);
  dir = dir ? 1 : 0;
  if (!strcmp(side, "l")) {
    motorL.dir = dir; motorL.pwm = pwm;
    digitalWrite(PIN_MOTOR_L_DIR, dir);
    analogWrite(PIN_MOTOR_L_PWM, pwm);
  } else if (!strcmp(side, "r")) {
    motorR.dir = dir; motorR.pwm = pwm;
    digitalWrite(PIN_MOTOR_R_DIR, dir);
    analogWrite(PIN_MOTOR_R_PWM, pwm);
  }
}

// ---- Fire/load one-shot pulse state machine (identical to esp32_firmware.ino) --
struct PulseState {
  bool active = false;
  unsigned long startMs = 0;
};
PulseState firePulse, loadPulse;

void startPulse(PulseState &state, const char *name, int angle) {
  if (state.active) return;  // mid-pulse: ignore, button not toggle
  state.active = true;
  state.startMs = millis();
  applyServoPos(name, angle);
}

void updatePulse(PulseState &state, const char *name, unsigned long now) {
  if (state.active && now - state.startMs >= PULSE_HOLD_MS) {
    applyServoPos(name, 0);
    state.active = false;
  }
}

// ---- E220 receive: byte-at-a-time sync-hunt + fixed-length read ---------
// Simpler than a full ring buffer since LoRa's packet rate is low (tens
// of Hz at most) -- there's no risk of falling behind the incoming byte
// stream the way a fast UART bridge might.
uint8_t rxBuf[LORA_CMD_LEN];
int rxFill = 0;
bool haveSyncedOnce = false;
uint8_t lastSeq = 0;

unsigned long lastCommandMs = 0;

void handleCommandPacket(const LoraCmdPacket &pkt) {
  // Exact-duplicate rejection, same spirit as the FPGA fork's
  // packet_decoder.v -- a repeated sequence number means we already
  // processed this packet (or, on the very first packet after boot,
  // there's nothing to compare against yet).
  if (haveSyncedOnce && pkt.seq == lastSeq) return;
  haveSyncedOnce = true;
  lastSeq = pkt.seq;
  lastCommandMs = millis();

  applyServoPos("pan", pkt.pan);
  applyServoPos("tilt", pkt.tilt);
  applyServoPos("focus", pkt.focus);
  applyServoPos("zoom", pkt.zoom);
  if (pkt.fire) startPulse(firePulse, "fire", FIRE_PULSE_ANGLE);
  if (pkt.load) startPulse(loadPulse, "load", LOAD_PULSE_ANGLE);
  applyMotor("l", pkt.motorLDir, pkt.motorLPwm);
  applyMotor("r", pkt.motorRDir, pkt.motorRPwm);
}

void pollLoraSerial() {
  while (LoraSerial.available()) {
    uint8_t b = LoraSerial.read();
    if (rxFill == 0 && b != LORA_CMD_SYNC) continue;  // hunt for sync
    rxBuf[rxFill++] = b;
    if (rxFill == LORA_CMD_LEN) {
      LoraCmdPacket pkt;
      if (loraCmdDecode(rxBuf, pkt)) {
        handleCommandPacket(pkt);
      }
      // Whether or not it decoded cleanly, this window's done -- slide
      // to hunting for the next sync byte rather than assuming
      // alignment survived a bad frame.
      rxFill = 0;
    }
  }
}

// ---- Telemetry to the Pi (unchanged frame format, see lora_packet.h) ----
unsigned long lastTelemetryMs = 0;
const unsigned long TELEMETRY_INTERVAL_MS = 100;

void publishTelemetry() {
  TelemetryFrame t;
  t.headingDeg = 0;  // no compass in this demo -- see header comment
  t.pan = servoState.pan; t.tilt = servoState.tilt;
  t.focus = servoState.focus; t.zoom = servoState.zoom;
  t.fire = servoState.fire; t.load = servoState.load;
  t.motorLDir = motorL.dir; t.motorRDir = motorR.dir;
  t.motorLPwm = motorL.pwm; t.motorRPwm = motorR.pwm;
  uint8_t frame[LORA_TELEM_LEN];
  telemetryEncode(t, frame);
  Serial.write(frame, LORA_TELEM_LEN);
}

void setup() {
  Serial.begin(115200);  // USB, to the Pi (telemetry only, no commands in)

  pinMode(PIN_MOTOR_L_DIR, OUTPUT);
  pinMode(PIN_MOTOR_R_DIR, OUTPUT);

  servoPan.attach(PIN_SERVO_PAN);
  servoTilt.attach(PIN_SERVO_TILT);
  servoFocus.attach(PIN_SERVO_FOCUS);
  servoZoom.attach(PIN_SERVO_ZOOM);
  servoFire.attach(PIN_SERVO_FIRE);
  servoLoad.attach(PIN_SERVO_LOAD);
  applyServoPos("pan", servoState.pan);
  applyServoPos("tilt", servoState.tilt);
  applyServoPos("focus", servoState.focus);
  applyServoPos("zoom", servoState.zoom);
  applyServoPos("fire", servoState.fire);
  applyServoPos("load", servoState.load);

  pinMode(PIN_E220_M0, OUTPUT);
  pinMode(PIN_E220_M1, OUTPUT);
  pinMode(PIN_E220_AUX, INPUT);
  digitalWrite(PIN_E220_M0, LOW);  // M0=0, M1=0 => normal (transparent) mode
  digitalWrite(PIN_E220_M1, LOW);
  LoraSerial.begin(E220_UART_BAUD, SERIAL_8N1, PIN_E220_RX2, PIN_E220_TX2);

  lastCommandMs = millis();
}

void loop() {
  pollLoraSerial();

  unsigned long now = millis();
  updatePulse(firePulse, "fire", now);
  updatePulse(loadPulse, "load", now);

  if (now - lastCommandMs > COMMAND_TIMEOUT_MS) {
    // Deadman: link's gone quiet, force the drive motors off. Servos hold
    // their last position, same choice esp32_firmware.ino made -- see
    // CLAUDE.md's fork section, "Servo behavior on deadman timeout" open
    // item, for why this might want revisiting given LoRa's longer
    // expected time-in-link-loss vs. USB-serial.
    applyMotor("l", 1, 0);
    applyMotor("r", 1, 0);
  }

  if (now - lastTelemetryMs >= TELEMETRY_INTERVAL_MS) {
    lastTelemetryMs = now;
    publishTelemetry();
  }
}
