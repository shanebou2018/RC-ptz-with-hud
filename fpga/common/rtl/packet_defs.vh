// Shared command-packet layout for the base<->vehicle LoRa link. Single
// source of truth for both packet_encoder.v (base) and packet_decoder.v
// (vehicle) -- keep both in sync by only editing this file.
//
// Fixed 12-byte packet, sized to fit comfortably in LoRa's airtime budget
// (see fpga/README.md for the throughput/latency numbers this was sized
// against). Bytes 2-9 (the payload) are XOR'd with a keystream (see
// keystream.v) before transmission; the CRC is computed over the
// already-encoded bytes 0-9.
//
// Security note, stated plainly so this isn't oversold: the CRC is NOT
// keyed. It catches accidental RF corruption (a bit-flipped byte fails
// the check regardless of key), but it does NOT prove the sender knew
// the shared secret -- anyone can compute a valid CRC over arbitrary
// bytes without knowing the key. A receiver with the wrong key still
// accepts a structurally-valid packet (right sync, right CRC over
// whatever bytes it got, a seq number that isn't an exact repeat); it
// just decrypts the payload to garbage-but-in-range-ish values rather
// than being rejected outright. This scheme (XOR keystream + unkeyed
// CRC + exact-duplicate rejection) defeats passive sniffing and naive
// replay-of-a-captured-packet, per the project's "slightly secure, not
// cryptographically hardened" design choice -- it does NOT defend
// against active forgery/injection by an attacker who doesn't know the
// key. A keyed MAC (or a real AEAD cipher) would be needed for that; see
// the fork's open question on XOR-keystream vs. a stronger cipher.
//
// | Byte  | Field                                            |
// |-------|---------------------------------------------------|
// | 0     | Sync/magic byte (PKT_SYNC)                         |
// | 1     | Sequence number, wraps 0-255                       |
// | 2     | Pan     (0-180)                                    |
// | 3     | Tilt    (0-180)                                    |
// | 4     | Focus   (0-180)                                    |
// | 5     | Zoom    (0-180)                                    |
// | 6     | Flags: bit0=fire, bit1=load, bit2=motorL dir,      |
// |       |        bit3=motorR dir, bits4-7 reserved (0)       |
// | 7     | Motor L PWM (0-MAX_MOTOR_PWM)                      |
// | 8     | Motor R PWM (0-MAX_MOTOR_PWM)                      |
// | 9     | Reserved (0)                                       |
// | 10-11 | CRC16 over bytes 0-9 (post-encoding)               |

`ifndef PACKET_DEFS_VH
`define PACKET_DEFS_VH

`define PKT_SYNC        8'hA5
`define PKT_LEN         12      // total bytes, including CRC16
`define PKT_PAYLOAD_LEN 10      // bytes 0-9, i.e. PKT_LEN - 2 (CRC bytes)

`define PKT_IDX_SYNC    0
`define PKT_IDX_SEQ     1
`define PKT_IDX_PAN     2
`define PKT_IDX_TILT    3
`define PKT_IDX_FOCUS   4
`define PKT_IDX_ZOOM    5
`define PKT_IDX_FLAGS   6
`define PKT_IDX_MOTOR_L 7
`define PKT_IDX_MOTOR_R 8
`define PKT_IDX_RESERVED 9
`define PKT_IDX_CRC_HI  10
`define PKT_IDX_CRC_LO  11

`define FLAG_FIRE       0
`define FLAG_LOAD       1
`define FLAG_MOTOR_L_DIR 2
`define FLAG_MOTOR_R_DIR 3

// Safety ceiling on drive-motor PWM, same philosophy/value as
// esp32_firmware.ino's MAX_MOTOR_PWM -- keep in sync with that constant's
// spirit (200 out of a notional 0-255 range) if it's ever retuned.
`define MAX_MOTOR_PWM   8'd200

`endif
