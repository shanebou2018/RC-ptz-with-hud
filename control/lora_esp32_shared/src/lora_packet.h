// Shared wire formats for the ESP32+LoRa vehicle control architecture:
//   base station ESP32 (PS2 controller + OLED, control/lora_base_esp32)
//     --[E220-900T22D LoRa, "cmd" packet below]-->
//   vehicle ESP32 (servos + motor controllers, control/lora_vehicle_esp32)
//     --[USB serial, "telemetry" frame below]-->
//   Pi (control/vehicle_fpga_bridge.py, UNCHANGED -- see note below)
//
// This header is the single source of truth for both packet layouts and
// their CRC. Install it as an Arduino library (copy this whole
// control/lora_esp32_shared/ folder into your Arduino libraries/
// directory, or symlink it) so both .ino sketches can
// `#include <lora_packet.h>` from one place instead of drifting apart --
// same "single source of truth, keep both ends in sync" philosophy as
// fpga/common/rtl/packet_defs.vh (this fork's earlier FPGA-based attempt
// at the same base<->vehicle link, superseded by this ESP32-based one).
//
// DEMO CODE, UNVERIFIED: written and reasoned through, never compiled
// (no Arduino/ESP32 toolchain in the dev sandbox this was written in) or
// run against real hardware. Treat every byte layout, pin choice, and
// timing constant here as a first draft -- confirm against your actual
// wiring and toolchain before flashing anything.
//
// ---------------------------------------------------------------------
// Command packet (base -> vehicle, over LoRa). Fixed 12 bytes.
// Deliberately plaintext (no XOR keystream, unlike the earlier FPGA
// fork's packet_defs.vh) to keep this first demo easy to sniff/debug
// with a logic analyzer or a second E220+USB-serial dongle while
// bringing the link up -- add an encryption stage as a fast-follow once
// the plaintext link is proven, not before.
//
// | Byte  | Field                                                 |
// |-------|-------------------------------------------------------|
// | 0     | Sync byte (LORA_CMD_SYNC)                              |
// | 1     | Sequence number, wraps 0-255                           |
// | 2     | Pan   (0-180)                                          |
// | 3     | Tilt  (0-180)                                          |
// | 4     | Focus (0-180)                                          |
// | 5     | Zoom  (0-180)                                          |
// | 6     | Flags: bit0=fire trigger, bit1=load trigger,           |
// |       |        bit2=motor L dir, bit3=motor R dir, bits4-7=0   |
// | 7     | Motor L PWM (0-LORA_MAX_MOTOR_PWM)                     |
// | 8     | Motor R PWM (0-LORA_MAX_MOTOR_PWM)                     |
// | 9     | Reserved (0)                                           |
// | 10-11 | CRC16/CCITT-FALSE over bytes 0-9, big-endian           |
//
// Same steady-rate-packet-doubles-as-heartbeat design as the FPGA fork:
// the base sketch sends this at a fixed rate (LORA_CMD_SEND_INTERVAL_MS
// in lora_base_esp32.ino) whether or not the operator touched anything,
// and the vehicle sketch's deadman timer treats *any* valid, non-repeat
// packet as proof of life -- there's no separate lightweight ping.
//
// ---------------------------------------------------------------------
// Telemetry frame (vehicle -> Pi, over USB serial). Fixed 14 bytes.
// BYTE-IDENTICAL to fpga/vehicle/rtl/telemetry_uart_tx.v's frame format,
// which control/vehicle_fpga_bridge.py already decodes -- this was
// deliberate so that script keeps working completely unchanged against
// this new ESP32 vehicle firmware; only its --port needs to point at the
// vehicle ESP32's USB-serial device instead of an FPGA's.
//
// | Byte  | Field                                                 |
// |-------|---------------------------------------------------------|
// | 0     | Sync byte (LORA_TELEM_SYNC)                              |
// | 1-2   | Heading, degrees*10, big-endian uint16 (0 if no compass) |
// | 3-8   | Pan, tilt, focus, zoom, fire, load (0-180 each)          |
// | 9     | Flags: bit0=motor L dir, bit1=motor R dir                |
// | 10    | Motor L PWM                                              |
// | 11    | Motor R PWM                                              |
// | 12-13 | CRC16/CCITT-FALSE over bytes 0-11, big-endian            |

#ifndef LORA_PACKET_H
#define LORA_PACKET_H

#include <Arduino.h>

// ---- CRC16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflect, xorout 0) -
// Must match control/vehicle_fpga_bridge.py's crc16_ccitt_false() and the
// earlier FPGA fork's fpga/common/rtl/crc16.v exactly -- this is the same
// algorithm, just a third independent implementation of it. Defined
// before the encode/decode functions below since they call it.
inline uint16_t crc16CcittFalse(const uint8_t *data, size_t len) {
  uint16_t crc = 0xFFFF;
  for (size_t i = 0; i < len; i++) {
    crc ^= (uint16_t)data[i] << 8;
    for (int b = 0; b < 8; b++) {
      crc = (crc & 0x8000) ? ((crc << 1) ^ 0x1021) : (crc << 1);
    }
  }
  return crc;
}

// ---- Command packet (base -> vehicle) ----------------------------------
#define LORA_CMD_SYNC         0xA5
#define LORA_CMD_LEN          12
#define LORA_CMD_PAYLOAD_LEN  10  // bytes 0-9, i.e. LORA_CMD_LEN - 2 (CRC)

#define LORA_CMD_IDX_SYNC     0
#define LORA_CMD_IDX_SEQ      1
#define LORA_CMD_IDX_PAN      2
#define LORA_CMD_IDX_TILT     3
#define LORA_CMD_IDX_FOCUS    4
#define LORA_CMD_IDX_ZOOM     5
#define LORA_CMD_IDX_FLAGS    6
#define LORA_CMD_IDX_MOTOR_L  7
#define LORA_CMD_IDX_MOTOR_R  8
#define LORA_CMD_IDX_RESERVED 9
#define LORA_CMD_IDX_CRC_HI   10
#define LORA_CMD_IDX_CRC_LO   11

#define LORA_FLAG_FIRE         0x01
#define LORA_FLAG_LOAD         0x02
#define LORA_FLAG_MOTOR_L_DIR  0x04
#define LORA_FLAG_MOTOR_R_DIR  0x08

// Keep in sync with esp32_firmware.ino's MAX_MOTOR_PWM (main branch) and
// the earlier FPGA fork's packet_defs.vh `MAX_MOTOR_PWM -- same 200/255
// starting ceiling, same "start low, raise once wiring's confirmed safe"
// reasoning.
#define LORA_MAX_MOTOR_PWM  200

struct LoraCmdPacket {
  uint8_t seq = 0;
  uint8_t pan = 90, tilt = 90, focus = 0, zoom = 0;
  bool fire = false, load = false;
  uint8_t motorLDir = 1, motorRDir = 1;  // 0/1, meaning is wiring-dependent
  uint8_t motorLPwm = 0, motorRPwm = 0;
};

// Serializes `pkt` into `out[LORA_CMD_LEN]`, computing the CRC itself.
inline void loraCmdEncode(const LoraCmdPacket &pkt, uint8_t out[LORA_CMD_LEN]) {
  out[LORA_CMD_IDX_SYNC] = LORA_CMD_SYNC;
  out[LORA_CMD_IDX_SEQ] = pkt.seq;
  out[LORA_CMD_IDX_PAN] = pkt.pan;
  out[LORA_CMD_IDX_TILT] = pkt.tilt;
  out[LORA_CMD_IDX_FOCUS] = pkt.focus;
  out[LORA_CMD_IDX_ZOOM] = pkt.zoom;
  uint8_t flags = 0;
  if (pkt.fire) flags |= LORA_FLAG_FIRE;
  if (pkt.load) flags |= LORA_FLAG_LOAD;
  if (pkt.motorLDir) flags |= LORA_FLAG_MOTOR_L_DIR;
  if (pkt.motorRDir) flags |= LORA_FLAG_MOTOR_R_DIR;
  out[LORA_CMD_IDX_FLAGS] = flags;
  out[LORA_CMD_IDX_MOTOR_L] = pkt.motorLPwm;
  out[LORA_CMD_IDX_MOTOR_R] = pkt.motorRPwm;
  out[LORA_CMD_IDX_RESERVED] = 0;
  uint16_t crc = crc16CcittFalse(out, LORA_CMD_PAYLOAD_LEN);
  out[LORA_CMD_IDX_CRC_HI] = (crc >> 8) & 0xFF;
  out[LORA_CMD_IDX_CRC_LO] = crc & 0xFF;
}

// Returns true and fills `pkt` if `in` is a structurally valid command
// packet (right sync byte, CRC checks out). Does NOT check the sequence
// number against the last one seen -- that's the caller's job (see
// lora_vehicle_esp32.ino's duplicate/replay handling).
inline bool loraCmdDecode(const uint8_t in[LORA_CMD_LEN], LoraCmdPacket &pkt) {
  if (in[LORA_CMD_IDX_SYNC] != LORA_CMD_SYNC) return false;
  uint16_t crcReceived = (uint16_t(in[LORA_CMD_IDX_CRC_HI]) << 8) | in[LORA_CMD_IDX_CRC_LO];
  if (crc16CcittFalse(in, LORA_CMD_PAYLOAD_LEN) != crcReceived) return false;
  pkt.seq = in[LORA_CMD_IDX_SEQ];
  pkt.pan = in[LORA_CMD_IDX_PAN];
  pkt.tilt = in[LORA_CMD_IDX_TILT];
  pkt.focus = in[LORA_CMD_IDX_FOCUS];
  pkt.zoom = in[LORA_CMD_IDX_ZOOM];
  uint8_t flags = in[LORA_CMD_IDX_FLAGS];
  pkt.fire = flags & LORA_FLAG_FIRE;
  pkt.load = flags & LORA_FLAG_LOAD;
  pkt.motorLDir = (flags & LORA_FLAG_MOTOR_L_DIR) ? 1 : 0;
  pkt.motorRDir = (flags & LORA_FLAG_MOTOR_R_DIR) ? 1 : 0;
  pkt.motorLPwm = in[LORA_CMD_IDX_MOTOR_L];
  pkt.motorRPwm = in[LORA_CMD_IDX_MOTOR_R];
  return true;
}

// ---- Telemetry frame (vehicle -> Pi) -----------------------------------
#define LORA_TELEM_SYNC 0x5A
#define LORA_TELEM_LEN  14

struct TelemetryFrame {
  float headingDeg = 0;  // 0 if no compass wired up -- see lora_vehicle_esp32.ino
  uint8_t pan = 90, tilt = 90, focus = 0, zoom = 0, fire = 0, load = 0;
  uint8_t motorLDir = 1, motorRDir = 1;
  uint8_t motorLPwm = 0, motorRPwm = 0;
};

inline void telemetryEncode(const TelemetryFrame &t, uint8_t out[LORA_TELEM_LEN]) {
  out[0] = LORA_TELEM_SYNC;
  int16_t headingX10 = (int16_t)(t.headingDeg * 10.0f);
  out[1] = (headingX10 >> 8) & 0xFF;
  out[2] = headingX10 & 0xFF;
  out[3] = t.pan;
  out[4] = t.tilt;
  out[5] = t.focus;
  out[6] = t.zoom;
  out[7] = t.fire;
  out[8] = t.load;
  uint8_t flags = 0;
  if (t.motorLDir) flags |= 0x01;
  if (t.motorRDir) flags |= 0x02;
  out[9] = flags;
  out[10] = t.motorLPwm;
  out[11] = t.motorRPwm;
  uint16_t crc = crc16CcittFalse(out, 12);
  out[12] = (crc >> 8) & 0xFF;
  out[13] = crc & 0xFF;
}

#endif  // LORA_PACKET_H
