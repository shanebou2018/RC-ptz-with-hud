// Base-station ESP32 firmware for the ESP32+LoRa control architecture --
// reads a PlayStation 2 controller, shows status on an OLED, and
// transmits a command packet to the vehicle ESP32
// (control/lora_vehicle_esp32) over a dedicated E220-900T22D LoRa link at
// a steady rate. This is a separate physical box: no Pi, no USB
// connection to anything -- just this ESP32, its E220 module, the PS2
// controller, and the OLED. See CLAUDE.md's fork section for how this
// replaces the earlier FPGA-based base station (fpga/base/).
//
// DEMO CODE, UNVERIFIED: written and reasoned through, never compiled (no
// Arduino/ESP32 toolchain in the dev sandbox this was written in) or run
// against real hardware. In particular, the PS2X_lib API calls below
// (config_gamepad/read_gamepad/Analog/Button/ButtonPressed) are written
// from general knowledge of that library, not verified against an actual
// installed copy -- confirm method names/signatures against whatever
// version the Arduino Library Manager installs before compiling. Stick
// axis directions (which way is "forward", which way is "pan right") are
// first guesses -- flip signs below once you can see it actually move.
//
// Libraries required (Arduino Library Manager):
//   - PS2X_lib          (search "PS2X", by Bill Porter / madsci1016)
//   - Adafruit SSD1306 + Adafruit GFX + Adafruit BusIO
//   - lora_packet (control/lora_esp32_shared/ -- copy/symlink that whole
//     folder into your Arduino libraries/ directory first)
//
// ---- Pinout (first guess, confirm against your actual wiring) ---------
//   PS2 controller: DAT=32  CMD=33  ATT(SEL)=25  CLK=26
//   OLED (I2C SSD1306, 128x64 assumed -- swap Adafruit_SSD1306's
//         constructor args if yours differs): SDA=21  SCL=22
//   E220: M0=5  M1=18  AUX=19  (ESP32 UART2) RX2=23 <- E220 TXD
//                                             TX2=27 -> E220 RXD
//
// Same E220 config-mode caveat as lora_vehicle_esp32.ino: both modules
// must already be configured (matching channel/address/air-rate) via
// EBYTE's RF_Setting tool or AT commands before this sketch's normal-mode
// transparent transmission will reach the vehicle at all.
//
// ---- Control mapping (first guess -- easy to retune, see below) -------
//   Left stick:  Y = throttle (forward/back), X = turn -- tank-mixed into
//                left/right motor PWM+dir, same mix esp32_firmware.ino's
//                WASD keyboard driving used on the main branch.
//   Right stick: X = pan rate, Y = tilt rate -- continuous-while-deflected,
//                like the main branch web HUD's arrow-key pan/tilt, since
//                a PS2 stick springs back to center and can't hold an
//                absolute position the way a potentiometer could (see the
//                earlier FPGA fork's base station, which used pots for
//                exactly this reason -- a stick needs rate control instead).
//   D-pad up/down:    zoom out/in, continuous while held
//   D-pad left/right: focus -/+, continuous while held
//   Triangle: fire trigger (momentary, one packet's worth of "fire" flag)
//   Cross:    load trigger (same)
//   Select:   center pan/tilt to 90/90 -- the "planned enhancement" the
//             main branch's CLAUDE.md flagged as not-yet-built for its
//             web HUD (a "C key" idea), built here instead.

#include <PS2X_lib.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <lora_packet.h>

// ---- PS2 controller pins -------------------------------------------------
const int PIN_PS2_DAT = 32;
const int PIN_PS2_CMD = 33;
const int PIN_PS2_ATT = 25;
const int PIN_PS2_CLK = 26;

// ---- OLED (I2C SSD1306) ---------------------------------------------------
const int PIN_OLED_SDA = 21;
const int PIN_OLED_SCL = 22;
#define OLED_WIDTH 128
#define OLED_HEIGHT 64
#define OLED_I2C_ADDR 0x3C
Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);

// ---- E220-900T22D pins -----------------------------------------------------
const int PIN_E220_M0 = 5;
const int PIN_E220_M1 = 18;
const int PIN_E220_AUX = 19;
const int PIN_E220_RX2 = 23;  // ESP32 RX  <- E220 TXD
const int PIN_E220_TX2 = 27;  // ESP32 TX  -> E220 RXD
const long E220_UART_BAUD = 9600;

HardwareSerial LoraSerial(2);
PS2X ps2x;
bool ps2Connected = false;

// ---- Tunables -------------------------------------------------------------
// How often a command packet goes out over LoRa. This doubles as the
// heartbeat (see lora_packet.h) -- the vehicle's COMMAND_TIMEOUT_MS
// (1000ms in lora_vehicle_esp32.ino) must stay comfortably above this.
// 10Hz is a bench-test starting point for SHORT range/high air rate --
// real long-range LoRa settings (high spreading factor) will need this
// slowed down a lot; bench-tune both ends together once real radios and
// range are involved, per the same open item the earlier FPGA fork never
// got to resolve.
const unsigned long LORA_CMD_SEND_INTERVAL_MS = 100;
const unsigned long CONTROL_TICK_MS = 20;  // PS2 poll / pan-tilt-zoom-focus rate
const unsigned long OLED_REFRESH_MS = 200;  // don't redraw every tick -- I2C isn't free

const int STICK_DEADZONE = 15;  // +/- counts around center (128) that count as "centered"
const uint8_t PAN_TILT_STEP_DEG = 1;    // degrees per CONTROL_TICK_MS while right stick deflected
const uint8_t ZOOM_FOCUS_STEP_DEG = 1;  // degrees per CONTROL_TICK_MS while d-pad held

LoraCmdPacket cmd;  // current commanded state, persists between sends

void centerPanTilt() {
  cmd.pan = 90;
  cmd.tilt = 90;
}

// Maps a 0-255 stick axis (128=center) to a signed -amplitude..+amplitude
// value, deadzone applied, 0 inside the deadzone.
int stickToSigned(int raw, int amplitude) {
  int centered = raw - 128;
  if (abs(centered) < STICK_DEADZONE) return 0;
  return constrain(map(centered, -128, 127, -amplitude, amplitude), -amplitude, amplitude);
}

void updateDriveFromSticks() {
  int forward = stickToSigned(255 - ps2x.Analog(PSS_LY), LORA_MAX_MOTOR_PWM);  // stick convention: verify, invert if backwards
  int turn = stickToSigned(ps2x.Analog(PSS_LX), LORA_MAX_MOTOR_PWM);

  int left = constrain(forward + turn, -LORA_MAX_MOTOR_PWM, LORA_MAX_MOTOR_PWM);
  int right = constrain(forward - turn, -LORA_MAX_MOTOR_PWM, LORA_MAX_MOTOR_PWM);

  cmd.motorLDir = (left >= 0) ? 1 : 0;
  cmd.motorLPwm = (uint8_t)abs(left);
  cmd.motorRDir = (right >= 0) ? 1 : 0;
  cmd.motorRPwm = (uint8_t)abs(right);
}

// Sign of a stickToSigned() result: -1, 0, or +1. Used to collapse
// proportional stick deflection down to a simple +/-1-per-tick step --
// deliberately crude for a first demo (matches the main branch web HUD's
// fixed-step arrow-key behavior) rather than true analog-rate control
// (which would scale PAN_TILT_STEP_DEG by how far the stick is pushed,
// not just its direction). Worth revisiting once this is on real
// hardware and the fixed step feels too coarse or too slow.
int stepSign(int signedVal) {
  return (signedVal > 0) - (signedVal < 0);
}

void updatePanTiltFromStick() {
  int panStep = stepSign(stickToSigned(ps2x.Analog(PSS_RX), 100));
  int tiltStep = stepSign(stickToSigned(ps2x.Analog(PSS_RY), 100));
  if (panStep != 0) cmd.pan = constrain(cmd.pan + panStep * PAN_TILT_STEP_DEG, 0, 180);
  if (tiltStep != 0) cmd.tilt = constrain(cmd.tilt + tiltStep * PAN_TILT_STEP_DEG, 0, 180);
}

void updateZoomFocusFromDpad() {
  if (ps2x.Button(PSB_PAD_UP)) cmd.zoom = constrain(cmd.zoom + ZOOM_FOCUS_STEP_DEG, 0, 180);
  if (ps2x.Button(PSB_PAD_DOWN)) cmd.zoom = constrain(cmd.zoom - ZOOM_FOCUS_STEP_DEG, 0, 180);
  if (ps2x.Button(PSB_PAD_RIGHT)) cmd.focus = constrain(cmd.focus + ZOOM_FOCUS_STEP_DEG, 0, 180);
  if (ps2x.Button(PSB_PAD_LEFT)) cmd.focus = constrain(cmd.focus - ZOOM_FOCUS_STEP_DEG, 0, 180);
}

// Fire/load are momentary triggers, not held state -- the *vehicle* owns
// the actual pulse timing (startPulse()/updatePulse() in
// lora_vehicle_esp32.ino, ported from esp32_firmware.ino), so this just
// needs to set the flag true for ONE outgoing packet per button press,
// not for the whole time the button happens to be held.
bool fireTriggerPending = false, loadTriggerPending = false;

void pollButtons() {
  if (ps2x.ButtonPressed(PSB_TRIANGLE)) fireTriggerPending = true;
  if (ps2x.ButtonPressed(PSB_CROSS)) loadTriggerPending = true;
  if (ps2x.ButtonPressed(PSB_SELECT)) centerPanTilt();
}

// ---- E220 AUX-busy wait ---------------------------------------------------
bool e220WaitIdle(unsigned long timeoutMs) {
  unsigned long start = millis();
  while (digitalRead(PIN_E220_AUX) == LOW) {
    if (millis() - start > timeoutMs) return false;
    delay(1);
  }
  return true;
}

void sendCommandPacket() {
  cmd.fire = fireTriggerPending;
  cmd.load = loadTriggerPending;
  fireTriggerPending = false;
  loadTriggerPending = false;

  uint8_t frame[LORA_CMD_LEN];
  loraCmdEncode(cmd, frame);
  cmd.seq++;  // increments regardless of send success -- a dropped send
              // just becomes a gap the vehicle's duplicate check never
              // sees, not a stall

  if (!e220WaitIdle(50)) return;  // module still busy -- skip this tick
                                   // rather than block; next tick tries again
  LoraSerial.write(frame, LORA_CMD_LEN);
}

// ---- OLED status ------------------------------------------------------
unsigned long linkOkUntilMs = 0;  // cosmetic only -- there's no return
                                   // channel in this demo (see CLAUDE.md's
                                   // fork section open item on that), so
                                   // this just reflects "we attempted a
                                   // send recently", not confirmed receipt

void drawStatus() {
  display.clearDisplay();
  display.setTextSize(1);
  display.setTextColor(SSD1306_WHITE);
  display.setCursor(0, 0);
  display.printf("PS2: %s\n", ps2Connected ? "OK" : "NOT FOUND");
  display.printf("seq: %u\n", cmd.seq);
  display.printf("pan %3d  tilt %3d\n", cmd.pan, cmd.tilt);
  display.printf("zoom %3d focus %3d\n", cmd.zoom, cmd.focus);
  display.printf("L %s%3d  R %s%3d\n",
                  cmd.motorLDir ? "+" : "-", cmd.motorLPwm,
                  cmd.motorRDir ? "+" : "-", cmd.motorRPwm);
  display.println(millis() - linkOkUntilMs < 1000 ? "TX: sending" : "TX: idle");
  display.display();
}

void setup() {
  Serial.begin(115200);  // USB, debug console only -- no Pi on this box

  Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);
  if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDR)) {
    Serial.println("SSD1306 init failed -- check wiring/address");
  }
  display.clearDisplay();
  display.setTextSize(1);
  display.setTextColor(SSD1306_WHITE);
  display.setCursor(0, 0);
  display.println("Starting...");
  display.display();

  // config_gamepad's exact signature/return codes are library-version
  // dependent -- this follows the commonly-documented
  // (clk, cmd, att, dat, pressures, rumble) form. A few retries because
  // real PS2 controllers sometimes need more than one attempt to sync.
  int err = 1;
  for (int attempt = 0; attempt < 5 && err != 0; attempt++) {
    err = ps2x.config_gamepad(PIN_PS2_CLK, PIN_PS2_CMD, PIN_PS2_ATT, PIN_PS2_DAT, true, false);
    if (err != 0) delay(200);
  }
  ps2Connected = (err == 0);
  if (!ps2Connected) {
    Serial.println("PS2 controller not found -- check wiring, will keep polling in loop()");
  }

  pinMode(PIN_E220_M0, OUTPUT);
  pinMode(PIN_E220_M1, OUTPUT);
  pinMode(PIN_E220_AUX, INPUT);
  digitalWrite(PIN_E220_M0, LOW);
  digitalWrite(PIN_E220_M1, LOW);
  LoraSerial.begin(E220_UART_BAUD, SERIAL_8N1, PIN_E220_RX2, PIN_E220_TX2);
}

unsigned long lastControlTickMs = 0, lastSendMs = 0, lastOledMs = 0;

void loop() {
  unsigned long now = millis();

  if (now - lastControlTickMs >= CONTROL_TICK_MS) {
    lastControlTickMs = now;
    ps2x.read_gamepad(false, 0);
    updateDriveFromSticks();
    updatePanTiltFromStick();
    updateZoomFocusFromDpad();
    pollButtons();
  }

  if (now - lastSendMs >= LORA_CMD_SEND_INTERVAL_MS) {
    lastSendMs = now;
    sendCommandPacket();
    linkOkUntilMs = now;
  }

  if (now - lastOledMs >= OLED_REFRESH_MS) {
    lastOledMs = now;
    drawStatus();
  }
}
