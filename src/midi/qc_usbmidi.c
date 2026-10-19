// qc_usbmidi: see qc_usbmidi.h.
#include "qc_usbmidi.h"
#include <string.h>

// Number of MIDI bytes for each code index number (CIN 0 and 1 are reserved).
static const uint8_t kCinBytes[16] = {0, 0, 2, 3, 3, 1, 2, 3, 3, 3, 3, 3, 2, 2, 3, 1};

void qc_midi_encoder_reset(QCMidiEncoder *e) { memset(e, 0, sizeof(*e)); }

static size_t put(uint8_t *out, size_t outCap, size_t pos, uint8_t cable, uint8_t cin, const uint8_t *b, int n) {
    if (pos + 4 > outCap) return pos;
    out[pos] = (uint8_t)((cable << 4) | (cin & 0x0F));
    for (int i = 0; i < 3; i++) out[pos + 1 + i] = i < n ? b[i] : 0;
    return pos + 4;
}

size_t qc_midi_encode(QCMidiEncoder *e, uint8_t cable, const uint8_t *bytes, size_t n, uint8_t *out, size_t outCap) {
    size_t pos = 0;
    for (size_t i = 0; i < n; i++) {
        const uint8_t b = bytes[i];
        if (b >= 0xF8) {
            // Real-time byte: send at once; it does not change the state (also inside SysEx).
            pos = put(out, outCap, pos, cable, 0x0F, &b, 1);
            continue;
        }
        if (b == 0xF0) {
            e->sysex = true;
            e->sx[0] = b;
            e->sxn = 1;
            e->len = 0;
            e->running = 0;
            continue;
        }
        if (b == 0xF7) {
            if (e->sysex) {
                e->sx[e->sxn++] = b;
                pos = put(out, outCap, pos, cable, (uint8_t)(0x04 + e->sxn), e->sx, e->sxn);   // CIN 5, 6 or 7
                e->sysex = false;
                e->sxn = 0;
            }
            continue;
        }
        if (b & 0x80) {
            // A status byte ends an unfinished SysEx (the bytes of that SysEx are dropped).
            e->sysex = false;
            e->sxn = 0;
            if (b >= 0xF0) {
                e->running = 0;
                if (b == 0xF6) {   // tune request: a single byte
                    pos = put(out, outCap, pos, cable, 0x05, &b, 1);
                    e->len = 0;
                } else if (b == 0xF1 || b == 0xF3 || b == 0xF2) {
                    e->msg[0] = b;
                    e->len = 1;
                    e->need = b == 0xF2 ? 3 : 2;
                } else {
                    e->len = 0;   // 0xF4, 0xF5: undefined
                }
            } else {
                e->running = b;
                e->msg[0] = b;
                e->len = 1;
                e->need = ((b & 0xF0) == 0xC0 || (b & 0xF0) == 0xD0) ? 2 : 3;
            }
            continue;
        }
        // Data byte.
        if (e->sysex) {
            e->sx[e->sxn++] = b;
            if (e->sxn == 3) {
                pos = put(out, outCap, pos, cable, 0x04, e->sx, 3);
                e->sxn = 0;
            }
            continue;
        }
        if (e->len == 0) {
            if (!e->running) continue;   // a data byte with no status: ignore it
            e->msg[0] = e->running;
            e->len = 1;
            e->need = ((e->running & 0xF0) == 0xC0 || (e->running & 0xF0) == 0xD0) ? 2 : 3;
        }
        e->msg[e->len++] = b;
        if (e->len == e->need) {
            uint8_t cin;
            if (e->msg[0] >= 0xF0) cin = e->need == 3 ? 0x03 : 0x02;   // system common
            else cin = e->msg[0] >> 4;                                 // channel message
            pos = put(out, outCap, pos, cable, cin, e->msg, e->need);
            e->len = 0;
        }
    }
    return pos;
}

int qc_midi_decode(const uint8_t packet[4], uint8_t bytes[3]) {
    const int n = kCinBytes[packet[0] & 0x0F];
    for (int i = 0; i < n; i++) bytes[i] = packet[1 + i];
    return n;
}
