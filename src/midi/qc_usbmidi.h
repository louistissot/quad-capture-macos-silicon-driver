// qc_usbmidi: convert between a MIDI 1.0 byte stream and USB-MIDI event packets (USB Device Class
// Definition for MIDI Devices 1.0, section 4). Each event packet has 4 bytes: cable number and code
// index number (CIN) in byte 0, then up to 3 MIDI bytes.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t running;   // running status of channel messages (0 if none)
    uint8_t msg[3];    // the message that is being collected
    uint8_t len;       // bytes in msg
    uint8_t need;      // total bytes of the message (status included)
    uint8_t sx[3];     // SysEx bytes that are not sent yet
    uint8_t sxn;
    bool sysex;
} QCMidiEncoder;

void qc_midi_encoder_reset(QCMidiEncoder *e);

// Encode n MIDI bytes. Writes complete 4-byte event packets to out (outCap bytes; n * 4 bytes is
// always sufficient). Returns the number of bytes written. Incomplete messages stay in the encoder.
size_t qc_midi_encode(QCMidiEncoder *e, uint8_t cable, const uint8_t *bytes, size_t n, uint8_t *out, size_t outCap);

// Decode one event packet. Writes 0 to 3 MIDI bytes to bytes and returns the count.
int qc_midi_decode(const uint8_t packet[4], uint8_t bytes[3]);

#ifdef __cplusplus
}
#endif
