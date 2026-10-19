// qc_sysex: read (and, on request, change) the control-panel settings of the Roland QUAD-CAPTURE.
//
// The settings of the preamps, the compressors and the monitor mixer are Roland System Exclusive
// messages on USB interface 2 (bulk OUT 0x06, bulk IN 0x86), in USB-MIDI event packets with
// cable number 1 (MIDI IN/OUT use cable 0). See docs/PROTOCOL.md, "Control panel (SysEx)".
//
// Usage:
//   qc_sysex                     send RQ1 for the state block (address 01 00 00 00, 59 bytes),
//                                print the reply and decode it
//   qc_sysex -r                  print the raw reply only
//   qc_sysex -w AAAAAAAA DD...   send DT1: address (8 hex digits), data bytes (hex), then read
//                                the state block again
//   qc_sysex -m SECONDS          watch: read the state block each 300 ms and print each change,
//                                and print each message that the device sends by itself
// CAUTION: -w changes the settings of the device. The device keeps them after a power cycle.
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>
#include <stdlib.h>
#include <string.h>
#include <notify.h>
#include "engine/qc_ctl.h"
#include "midi/qc_usbmidi.h"

#define QC_VID 0x0582
#define QC_PID 0x012f
#define CABLE 1
#define BLOCK_SIZE 59

static IOUSBHostInterface *gIf;
static IOUSBHostPipe *gOut, *gIn;

static const uint8_t kHeader[] = {0xF0, 0x41, 0x10, 0x00, 0x00, 0x56};   // Roland, device 0x10, model 00 00 56

// Roland checksum: the sum of address and data plus the checksum is 0 (modulo 128).
static uint8_t checksum(const uint8_t *p, size_t n) {
    unsigned s = 0;
    for (size_t i = 0; i < n; i++) s += p[i];
    return (uint8_t)((128 - (s & 0x7F)) & 0x7F);
}

static bool sendSysEx(const uint8_t *msg, size_t n) {
    uint8_t pk[512];
    QCMidiEncoder enc;
    qc_midi_encoder_reset(&enc);
    size_t len = qc_midi_encode(&enc, CABLE, msg, n, pk, sizeof(pk));
    NSError *err = nil;
    NSMutableData *d = [gIf ioDataWithCapacity:len error:&err];
    if (!d) { fprintf(stderr, "Cannot allocate the OUT buffer: %s\n", err.localizedDescription.UTF8String); return false; }
    memcpy(d.mutableBytes, pk, len);
    NSUInteger done = 0;
    if (![gOut sendIORequestWithData:d bytesTransferred:&done completionTimeout:1.0 error:&err] || done != len) {
        fprintf(stderr, "Bulk OUT failed: %s\n", err ? err.localizedDescription.UTF8String : "short transfer");
        return false;
    }
    printf("Sent (%zu bytes):", n);
    for (size_t i = 0; i < n; i++) printf(" %02X", msg[i]);
    printf("\n");
    return true;
}

static void printMsg(const char *what, const uint8_t *m, size_t n) {
    printf("%s (%zu bytes):", what, n);
    for (size_t i = 0; i < n; i++) printf(" %02X", m[i]);
    printf("\n");
}

// Read event packets for up to `seconds`. Collect the SysEx bytes of cable 1 until F7.
// Print the packets of other cables. Returns the length of the message, or 0.
static size_t readSysEx(uint8_t *msg, size_t cap, double seconds) {
    NSError *err = nil;
    NSMutableData *d = [gIf ioDataWithCapacity:512 error:&err];
    size_t n = 0;
    bool inside = false;
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([end timeIntervalSinceNow] > 0) {
        NSUInteger got = 0;
        err = nil;
        if (![gIn sendIORequestWithData:d bytesTransferred:&got completionTimeout:0.2 error:&err]) continue;
        const uint8_t *p = d.bytes;
        for (NSUInteger i = 0; i + 4 <= got; i += 4) {
            if (p[i] == 0 && p[i + 1] == 0) continue;   // padding
            uint8_t b[3];
            int k = qc_midi_decode(&p[i], b);
            if ((p[i] >> 4) != CABLE) {
                printf("  cable %d packet: %02X %02X %02X %02X\n", p[i] >> 4, p[i], p[i + 1], p[i + 2], p[i + 3]);
                continue;
            }
            for (int j = 0; j < k; j++) {
                if (b[j] == 0xF0) { inside = true; n = 0; }
                if (!inside) continue;
                if (n < cap) msg[n++] = b[j];
                if (b[j] == 0xF7) return n;
            }
        }
    }
    return 0;
}

static uint32_t nibbles(const uint8_t *p, int count) {
    uint32_t v = 0;
    for (int i = 0; i < count; i++) v = (v << 4) | (p[i] & 0x0F);
    return v;
}

static const char *kRatio[] = {"1:1.0", "1:1.2", "1:1.5", "1:2.0", "1:2.8", "1:4.0", "1:8.0", "1:16", "1:INF"};
static const char *kAttack[] = {"0.2", "0.5", "1.0", "2.0", "4.0", "6.0", "8.0", "10", "15", "20", "25", "30", "35",
                                "40", "45", "50", "55", "60", "65", "70", "75", "80", "85", "90", "95", "100"};
static const int kRelease[] = {10, 12, 15, 18, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75,
                               80, 85, 90, 95, 100, 110, 120, 130, 140, 150, 160, 170, 180, 190, 200, 220,
                               240, 260, 280, 300, 320, 340, 360, 380, 400, 420, 440, 460, 480, 500};

static void printLevel(const char *name, uint32_t v) {
    if (v == 0) printf("  %-22s -INF dB (0x%06X)\n", name, v);
    else printf("  %-22s %+.1f dB (0x%06X)\n", name, 20.0 * log10((double)v / 0x200000), v);
}

static void decodeBlock(const uint8_t *k) {
    printf("Decoded state block:\n");
    printf("  bytes 0-7  (32-bit)    0x%08X\n", nibbles(k, 8));
    printf("  bytes 8-15 (32-bit)    0x%08X\n", nibbles(k + 8, 8));
    printf("  bytes 16-19            %d %d %d %d (device settings, names not known yet)\n", k[16], k[17], k[18], k[19]);
    printf("  byte 20                %d (probably the AUTO-SENS margin, dB)\n", k[20]);
    printf("  AUTO-SENS state        %d (0 off, 2 measurement, 1 complete)\n", k[21]);
    printf("  output select          %d\n", k[22]);
    printf("  stereo link            %d\n", k[27] & 1);
    for (int ch = 0; ch < 2; ch++) {
        const int g = k[29 + ch], th = k[35 + ch], ra = k[37 + ch], at = k[31 + ch], re = k[33 + ch], ga = k[39 + ch];
        printf("  IN %d: lo-cut %d, phase %d, sens %.1f dB, comp %d\n", ch + 1, (k[23] >> ch) & 1, (k[24] >> ch) & 1,
               k[25 + ch] / 2.0, (k[28] >> ch) & 1);
        printf("        gate %s%s, threshold %d dB, ratio %s, attack %s ms, release %d ms, gain %+d dB\n",
               g == 0 ? "-INF" : "", g == 0 ? "" : [NSString stringWithFormat:@"%d dB", g - 70].UTF8String, th - 50,
               ra <= 8 ? kRatio[ra] : "?", at <= 25 ? kAttack[at] : "?", re <= 45 ? kRelease[re] : -1, ga - 50);
    }
    printLevel("mixer INPUT 1", nibbles(k + 41, 6));
    printLevel("mixer INPUT 2", nibbles(k + 47, 6));
    printLevel("mixer COAX (3/4)", nibbles(k + 53, 6));
}

static const char *kNames[BLOCK_SIZE] = {
    [16] = "byte 16", [17] = "byte 17", [18] = "byte 18", [19] = "byte 19", [20] = "AUTO-SENS margin?", [21] = "AUTO-SENS state",
    [22] = "output select", [23] = "lo-cut bits", [24] = "phase bits", [25] = "IN 1 sens", [26] = "IN 2 sens",
    [27] = "link", [28] = "comp bits", [29] = "IN 1 gate", [30] = "IN 2 gate", [31] = "IN 1 attack",
    [32] = "IN 2 attack", [33] = "IN 1 release", [34] = "IN 2 release", [35] = "IN 1 threshold",
    [36] = "IN 2 threshold", [37] = "IN 1 ratio", [38] = "IN 2 ratio", [39] = "IN 1 gain", [40] = "IN 2 gain"};

// Send RQ1 for the state block. Return true and the 59 data bytes if the reply is correct.
// Other messages from the device (cable 1) that arrive first are printed.
static bool requestBlock(uint8_t *block, bool quiet);

// Watch mode: poll the state block and print the changes.
static int watch(double seconds) {
    uint8_t prev[BLOCK_SIZE], cur[BLOCK_SIZE];
    if (!requestBlock(prev, false)) return 1;
    decodeBlock(prev);
    printf("Watching for %.0f s. Turn the knobs and press the buttons now.\n", seconds);
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    NSDate *t0 = [NSDate date];
    while ([end timeIntervalSinceNow] > 0) {
        usleep(300000);
        if (!requestBlock(cur, true)) continue;
        for (int i = 0; i < BLOCK_SIZE; i++) {
            if (cur[i] == prev[i]) continue;
            if (i >= 41) {
                int base = 41 + ((i - 41) / 6) * 6;
                printf("%6.1f s  mixer %s: 0x%06X -> 0x%06X\n", -[t0 timeIntervalSinceNow],
                       base == 41 ? "INPUT 1" : base == 47 ? "INPUT 2" : "COAX", nibbles(prev + base, 6), nibbles(cur + base, 6));
                i = base + 5;
                continue;
            }
            printf("%6.1f s  byte %2d (%s): %d -> %d\n", -[t0 timeIntervalSinceNow], i, kNames[i] ? kNames[i] : "?",
                   prev[i], cur[i]);
        }
        memcpy(prev, cur, sizeof(prev));
    }
    decodeBlock(prev);
    return 0;
}

static bool requestBlock(uint8_t *block, bool quiet) {
    uint8_t rq[17];
    memcpy(rq, kHeader, 6);
    rq[6] = 0x11;
    const uint8_t body[8] = {0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, BLOCK_SIZE};
    memcpy(rq + 7, body, 8);
    rq[15] = checksum(body, 8);
    rq[16] = 0xF7;
    if (quiet) {
        QCMidiEncoder enc;
        uint8_t pk[64];
        qc_midi_encoder_reset(&enc);
        size_t len = qc_midi_encode(&enc, CABLE, rq, sizeof(rq), pk, sizeof(pk));
        NSError *err = nil;
        NSMutableData *d = [gIf ioDataWithCapacity:len error:&err];
        memcpy(d.mutableBytes, pk, len);
        NSUInteger done = 0;
        if (![gOut sendIORequestWithData:d bytesTransferred:&done completionTimeout:1.0 error:&err]) return false;
    } else if (!sendSysEx(rq, sizeof(rq))) {
        return false;
    }
    for (int tries = 0; tries < 8; tries++) {
        uint8_t msg[256];
        size_t n = readSysEx(msg, sizeof(msg), 1.0);
        if (n == 0) return false;
        if (n == 7 + 4 + BLOCK_SIZE + 2 && memcmp(msg, kHeader, 6) == 0 && msg[6] == 0x12 && msg[7] == 0x01) {
            if (checksum(msg + 7, 4 + BLOCK_SIZE) != msg[7 + 4 + BLOCK_SIZE]) printf("WARNING: checksum error\n");
            memcpy(block, msg + 11, BLOCK_SIZE);
            return true;
        }
        printMsg("Message from the device", msg, n);
    }
    return false;
}

static int readBlock(bool raw) {
    uint8_t rq[17];
    memcpy(rq, kHeader, 6);
    rq[6] = 0x11;   // RQ1
    const uint8_t body[8] = {0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, BLOCK_SIZE};
    memcpy(rq + 7, body, 8);
    rq[15] = checksum(body, 8);
    rq[16] = 0xF7;
    if (!sendSysEx(rq, sizeof(rq))) return 1;
    uint8_t msg[256];
    size_t n = readSysEx(msg, sizeof(msg), 2.0);
    if (n == 0) { printf("No SysEx reply on cable %d in 2 s.\n", CABLE); return 1; }
    printf("Reply (%zu bytes):", n);
    for (size_t i = 0; i < n; i++) printf(" %02X", msg[i]);
    printf("\n");
    if (raw) return 0;
    if (n != 7 + 4 + BLOCK_SIZE + 2 || memcmp(msg, kHeader, 6) != 0 || msg[6] != 0x12 || msg[7] != 0x01) {
        printf("The reply is not a DT1 of the state block.\n");
        return 1;
    }
    if (checksum(msg + 7, 4 + BLOCK_SIZE) != msg[7 + 4 + BLOCK_SIZE]) printf("WARNING: checksum error\n");
    decodeBlock(msg + 11);
    return 0;
}

static bool parseHex(const char *s, uint8_t *out, size_t want) {
    if (strlen(s) != want * 2) return false;
    for (size_t i = 0; i < want; i++) {
        char t[3] = {s[2 * i], s[2 * i + 1], 0};
        char *e;
        long v = strtol(t, &e, 16);
        if (*e || v < 0 || v > 0x7F) return false;
        out[i] = (uint8_t)v;
    }
    return true;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        bool raw = false, write = false;
        double watchSeconds = 0;
        uint8_t addr[4], data[64];
        size_t dataLen = 0;
        if (argc == 2 && !strcmp(argv[1], "-r")) raw = true;
        else if (argc == 3 && !strcmp(argv[1], "-m")) watchSeconds = atof(argv[2]);
        else if (argc >= 4 && !strcmp(argv[1], "-w")) {
            write = true;
            if (!parseHex(argv[2], addr, 4)) { fprintf(stderr, "bad address\n"); return 2; }
            for (int i = 3; i < argc && dataLen < sizeof(data); i++)
                if (!parseHex(argv[i], &data[dataLen++], 1)) { fprintf(stderr, "bad data byte %s\n", argv[i]); return 2; }
        } else if (argc != 1) {
            fprintf(stderr, "usage: qc_sysex [-r] | qc_sysex -m seconds | qc_sysex -w AAAAAAAA DD [DD...]\n");
            return 2;
        }

        CFMutableDictionaryRef m =
            [IOUSBHostInterface createMatchingDictionaryWithVendorID:@QC_VID productID:@QC_PID bcdDevice:nil
                                                     interfaceNumber:@2 configurationValue:@1
                                                      interfaceClass:nil interfaceSubclass:nil
                                                   interfaceProtocol:nil speed:nil productIDArray:nil];
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, m);
        if (!svc) { fprintf(stderr, "Interface 2 of the QUAD-CAPTURE not found.\n"); return 1; }
        NSError *err = nil;
        // The audio driver (or the MIDI driver) can use interface 2. Ask the audio driver to release
        // it (qc_ctl.h), and try again for 3 s.
        for (int i = 0; i < 12 && !gIf; i++) {
            if (i == 1) notify_post(QC_CTL_WANT_NOTIFICATION);
            if (i > 0) usleep(250000);
            gIf = [[IOUSBHostInterface alloc] initWithIOService:svc options:IOUSBHostObjectInitOptionsNone queue:nil
                                                          error:&err interestHandler:nil];
        }
        IOObjectRelease(svc);
        if (!gIf) { fprintf(stderr, "Cannot open interface 2: %s\n", err.localizedDescription.UTF8String); return 1; }
        gOut = [gIf copyPipeWithAddress:0x06 error:&err];
        gIn = [gIf copyPipeWithAddress:0x86 error:&err];
        if (!gOut || !gIn) { fprintf(stderr, "Cannot open the MIDI pipes.\n"); [gIf destroy]; return 1; }

        int rc = 0;
        if (write) {
            uint8_t msg[96];
            memcpy(msg, kHeader, 6);
            msg[6] = 0x12;   // DT1
            memcpy(msg + 7, addr, 4);
            memcpy(msg + 11, data, dataLen);
            msg[11 + dataLen] = checksum(msg + 7, 4 + dataLen);
            msg[12 + dataLen] = 0xF7;
            if (!sendSysEx(msg, 13 + dataLen)) rc = 1;
            usleep(100000);
        }
        if (rc == 0) rc = watchSeconds > 0 ? watch(watchSeconds) : readBlock(raw);
        [gIf destroy];
        return rc;
    }
}
