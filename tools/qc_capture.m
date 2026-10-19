// qc_capture: record audio from the Roland QUAD-CAPTURE (0582:012f) to WAV files.
//
// The device has vendor-specific USB audio interfaces (protocol known from the Linux
// snd-usb-audio driver):
//   interface 0: playback, isochronous OUT endpoint 0x05
//   interface 1: capture, isochronous IN endpoint 0x85 (implicit feedback)
// Alternate setting 1/2/3/4 = 44.1/48/96/192 kHz. Samples are 24-bit, left-justified in 4-byte words.
// Only alternate setting 1 (44.1 kHz) operates now. At 48/96 kHz the device sends empty packets:
// a vendor command (not known yet) must change the device clock first.
// Completion callbacks can come tens of milliseconds late, so the queue holds 128 ms by default.
// Device behavior found in tests (19 October 2026):
//   - An abort of the transfers at the end of a run can mute the outputs for the next runs.
//     Thus the tool stops with a clean drain: no new requests, then the queue completes.
//   - In the first run after a power cycle, the device sends empty capture packets (about 0.5 s).
//     A playback request with 0 bytes fails, and a stopped playback stream hangs the device
//     (control requests time out until the next power cycle). Thus empty capture packets give
//     playback packets with the nominal size.
// The capture stream needs the playback stream to run too, so this tool sends silence to
// the outputs. The size of each playback packet follows the size of the capture packets
// (implicit feedback), as in the Linux driver.
// With -T, the tool plays a quiet test tone: 440 Hz on output 1 (left) from 0.3 s to 2.3 s,
// then 660 Hz on output 2 (right) from 2.7 s to 4.7 s. Each tone has 30 ms fades.
//
// Usage: qc_capture [-a alt] [-s seconds] [-o output_dir] [-T] [-g tone_level_dBFS]
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>
#include <mach/mach_time.h>
#include <getopt.h>
#include <math.h>

#define QC_VID 0x0582
#define QC_PID 0x012f
#define MAX_REQ 64  // maximum isochronous requests in flight for each direction
#define MAX_TPR 128 // maximum transactions (microframes) per request
static int NUM_REQ = 16; // -n: requests in flight for each direction
static int TPR = 64;     // -t: transactions (microframes) per request, a multiple of 8 (8 = 1 ms)
#define FIFO_LEN 4096

typedef struct {
    int alt;
    int channels;
    int subframe;     // bytes per sample
    int bits;
    uint32_t rate;
    uint8_t ep;
    uint16_t maxPacket;
} StreamFormat;

static StreamFormat gInFmt, gOutFmt;
static IOUSBHostPipe *gInPipe, *gOutPipe;
static NSMutableData *gInData[MAX_REQ], *gOutData[MAX_REQ];
static IOUSBHostIsochronousTransaction gInTx[MAX_REQ][MAX_TPR], gOutTx[MAX_REQ][MAX_TPR];
static uint64_t gNextInFrame, gNextOutFrame;
static volatile bool gStop;
static bool gAsap;          // -A: firstFrameNumber 0 (xHCI schedules after the previous request)
static uint64_t gStartFrame, gInStartFrame, gStartTime;
// -P: playback starts this number of ms (frames) before capture. The Linux driver starts
// playback first for Roland devices (QUIRK_FLAG_PLAYBACK_FIRST). All passed tests used 0
// (the same frame), so 0 is the default.
static int gPlaybackLeadMs = 0;
static int gInFlightIn, gInFlightOut;   // requests in the queue, for a clean stop
#define LAG_LOG 64
static int64_t gOutLag[LAG_LOG], gInLag[LAG_LOG];   // (current frame - completed frame) samples
static int gOutLagN, gInLagN;

static uint8_t *gCap;
static size_t gCapBytes, gCapMax;
static uint64_t gOutCompletions;
// Playback statistics, from the completed OUT transactions (the data that the controller transmitted).
static uint64_t gOutTxCount, gOutReqBytes, gOutDoneBytes, gOutShort, gOutNominal;
static int32_t gOutPeak[8];
static uint64_t gOutFirstSoundPos = UINT64_MAX, gOutLastSoundPos;
static uint64_t gOutDonePos;
static uint64_t gInTransactions, gInEmpty, gInErrors, gOutErrors, gInFramesTotal;
static uint64_t gFirstTime, gLastTime, gFramesAfterFirst;
static uint64_t gHist[32];
static uint64_t gFirstDataTx = UINT64_MAX;   // IN transaction index of the first capture data
static uint64_t gEmptyAfterData;             // empty IN packets after the first capture data
#define GAP_LOG 32
static uint64_t gGapStart[GAP_LOG], gGapLen[GAP_LOG];   // blocks of empty IN packets (microframe index, length)
static int gGapN;
static bool gInGap;
static IOReturn gLastInErr, gLastOutErr;
static uint32_t gFifo[FIFO_LEN];
static uint32_t gFifoHead, gFifoTail;
static uint32_t gNominalAcc;

// Test tone (-T). The level is in dBFS; the tool refuses levels above TONE_MAX_DB.
#define TONE_MAX_DB -12.0
#define TONE_FADE 0.03
static bool gTone;
static double gToneDb = -30.0;
static double gToneAmp;
static uint64_t gOutPos;   // frames sent to the playback endpoint

typedef struct { double start, end, freq; int channel; } ToneSegment;
static const ToneSegment kTones[] = {
    {0.3, 2.3, 440.0, 0},
    {2.7, 4.7, 660.0, 1},
};
#define NUM_TONES (sizeof(kTones) / sizeof(kTones[0]))

// Fill one playback frame (all output channels) for frame position `pos`.
static void toneFrame(uint64_t pos, int32_t *frame, int channels) {
    for (int c = 0; c < channels; c++) frame[c] = 0;
    double t = (double)pos / gOutFmt.rate;
    for (size_t k = 0; k < NUM_TONES; k++) {
        const ToneSegment *g = &kTones[k];
        if (t < g->start || t >= g->end || g->channel >= channels) continue;
        double env = 1.0, a = t - g->start, b = g->end - t;
        if (a < TONE_FADE) env = 0.5 - 0.5 * cos(M_PI * a / TONE_FADE);
        if (b < TONE_FADE) env = 0.5 - 0.5 * cos(M_PI * b / TONE_FADE);
        frame[g->channel] = (int32_t)lrint(gToneAmp * env * sin(2.0 * M_PI * g->freq * a));
    }
}

// Amplitude of frequency `freq` in one capture channel (Goertzel), in dBFS.
static double toneLevel(const int32_t *smp, int channels, int ch, size_t from, size_t to, double freq, double rate) {
    double w = 2.0 * M_PI * freq / rate, coeff = 2.0 * cos(w), s1 = 0, s2 = 0;
    for (size_t i = from; i < to; i++) {
        double s0 = (double)smp[i * channels + ch] + coeff * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    double re = s1 - s2 * cos(w), im = s2 * sin(w);
    double amp = 2.0 * sqrt(re * re + im * im) / (double)(to - from);
    return amp > 0 ? 20.0 * log10(amp / 2147483648.0) : -INFINITY;
}

// Parse the configuration descriptor and get the format of interface `iface`, alternate setting `alt`.
static bool parseFormat(const IOUSBConfigurationDescriptor *cd, int iface, int alt, StreamFormat *f) {
    const uint8_t *p = (const uint8_t *)cd, *end = p + cd->wTotalLength;
    bool inside = false, gotFmt = false, gotEp = false;
    memset(f, 0, sizeof(*f));
    f->alt = alt;
    p += cd->bLength;
    while (p + 2 <= end && p[0] >= 2 && p + p[0] <= end) {
        uint8_t len = p[0], type = p[1];
        if (type == 4) {
            inside = (p[2] == iface && p[3] == alt);
        } else if (inside && type == 0x24 && len >= 11 && p[2] == 0x02 && p[3] == 0x01) {
            f->channels = p[4];
            f->subframe = p[5];
            f->bits = p[6];
            f->rate = p[8] | (p[9] << 8) | (p[10] << 16);
            gotFmt = true;
        } else if (inside && type == 5) {
            f->ep = p[2];
            f->maxPacket = (p[4] | (p[5] << 8)) & 0x7ff;
            gotEp = true;
        }
        p += len;
    }
    return gotFmt && gotEp;
}

static io_service_t waitForInterface(int num) {
    for (int i = 0; i < 60; i++) {
        CFMutableDictionaryRef m =
            [IOUSBHostInterface createMatchingDictionaryWithVendorID:@QC_VID
                                                           productID:@QC_PID
                                                           bcdDevice:nil
                                                     interfaceNumber:@(num)
                                                  configurationValue:@1
                                                      interfaceClass:nil
                                                   interfaceSubclass:nil
                                                   interfaceProtocol:nil
                                                               speed:nil
                                                      productIDArray:nil];
        io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, m);
        if (s) return s;
        usleep(50000);
    }
    return 0;
}

static uint32_t nominalFrames(void) {
    gNominalAcc += gOutFmt.rate;
    uint32_t n = gNominalAcc / 8000;
    gNominalAcc %= 8000;
    return n;
}

static void enqueueIn(int slot);
static void enqueueOut(int slot);

static void onInDone(int slot, IOReturn status, IOUSBHostIsochronousTransaction *list) {
    gInFlightIn--;
    if (gStop || status == kIOReturnAborted) return;
    uint64_t now = mach_absolute_time();
    const uint32_t fb = gInFmt.channels * gInFmt.subframe;
    static uint64_t inCompletions;
    inCompletions++;
    if (inCompletions % (400 / TPR) == 1 && gInLagN < LAG_LOG)
        gInLag[gInLagN++] = (int64_t)[gInPipe.hostInterface frameNumberWithTime:NULL] -
                            (int64_t)(gInStartFrame + inCompletions * (TPR / 8));
    const uint8_t *base = gInData[slot].bytes;
    for (int i = 0; i < TPR; i++) {
        gInTransactions++;
        IOReturn st = list[i].status;
        if (st != kIOReturnSuccess && st != kIOReturnUnderrun) {
            gInErrors++;
            gLastInErr = st;
            continue;
        }
        uint32_t n = list[i].completeCount;
        uint32_t frames = n / fb;
        if (frames == 0) gInEmpty++;
        if (frames > 0 && gFirstDataTx == UINT64_MAX) gFirstDataTx = gInTransactions - 1;
        if (frames == 0 && gFirstDataTx != UINT64_MAX) gEmptyAfterData++;
        if (frames == 0) {
            if (!gInGap && gGapN < GAP_LOG) { gGapStart[gGapN] = gInTransactions - 1; gGapLen[gGapN] = 0; gGapN++; }
            gInGap = true;
            if (gGapN > 0 && gGapN <= GAP_LOG) gGapLen[gGapN - 1]++;
        } else {
            gInGap = false;
        }
        gHist[frames < 31 ? frames : 31]++;
        if (gFirstTime == 0 && frames > 0) {
            gFirstTime = now;
        } else if (gFirstTime) {
            gFramesAfterFirst += frames;
            gLastTime = now;
        }
        gInFramesTotal += frames;
        if (gCapBytes + frames * fb <= gCapMax) {
            memcpy(gCap + gCapBytes, base + list[i].offset, frames * fb);
            gCapBytes += frames * fb;
        }
        if (((gFifoHead + 1) % FIFO_LEN) != gFifoTail) {
            gFifo[gFifoHead] = frames;
            gFifoHead = (gFifoHead + 1) % FIFO_LEN;
        }
    }
    enqueueIn(slot);
}

static void onOutDone(int slot, IOReturn status, IOUSBHostIsochronousTransaction *list) {
    gInFlightOut--;
    if (gStop || status == kIOReturnAborted) return;
    gOutCompletions++;
    if (gOutCompletions % (400 / TPR) == 1 && gOutLagN < LAG_LOG)
        gOutLag[gOutLagN++] = (int64_t)[gOutPipe.hostInterface frameNumberWithTime:NULL] -
                              (int64_t)(gStartFrame + gOutCompletions * (TPR / 8));
    if (status != kIOReturnSuccess) {
        gOutErrors++;
        gLastOutErr = status;
    }
    const uint32_t fb = gOutFmt.channels * gOutFmt.subframe;
    const uint8_t *base = gOutData[slot].bytes;
    for (int i = 0; i < TPR; i++) {
        if (list[i].status != kIOReturnSuccess) {
            gOutErrors++;
            gLastOutErr = list[i].status;
        }
        gOutTxCount++;
        gOutReqBytes += list[i].requestCount;
        gOutDoneBytes += list[i].completeCount;
        if (list[i].completeCount != list[i].requestCount) gOutShort++;
        const int32_t *smp = (const int32_t *)(base + list[i].offset);
        uint32_t frames = list[i].completeCount / fb;
        for (uint32_t f = 0; f < frames; f++) {
            bool sound = false;
            for (int c = 0; c < gOutFmt.channels && c < 8; c++) {
                int32_t v = smp[f * gOutFmt.channels + c];
                int32_t a = v < 0 ? -v : v;
                if (a > gOutPeak[c]) gOutPeak[c] = a;
                if (a > 0) sound = true;
            }
            if (sound) {
                if (gOutFirstSoundPos == UINT64_MAX) gOutFirstSoundPos = gOutDonePos + f;
                gOutLastSoundPos = gOutDonePos + f;
            }
        }
        gOutDonePos += list[i].requestCount / fb;
    }
    enqueueOut(slot);
}

static void enqueueIn(int slot) {
    IOUSBHostIsochronousTransaction *tx = gInTx[slot];
    for (int i = 0; i < TPR; i++) {
        tx[i] = (IOUSBHostIsochronousTransaction){0};
        tx[i].requestCount = gInFmt.maxPacket;
        tx[i].offset = i * gInFmt.maxPacket;
    }
    uint64_t frame = gAsap ? 0 : gNextInFrame;
    gNextInFrame += TPR / 8;
    NSError *e = nil;
    BOOL ok = [gInPipe enqueueIORequestWithData:gInData[slot]
                                transactionList:tx
                           transactionListCount:TPR
                               firstFrameNumber:frame
                                        options:IOUSBHostIsochronousTransferOptionsNone
                                          error:&e
                              completionHandler:^(IOReturn st, IOUSBHostIsochronousTransaction *list) {
                                  onInDone(slot, st, list);
                              }];
    if (ok) gInFlightIn++;
    if (!ok) {
        fprintf(stderr, "IN enqueue failed (frame %llu, now %llu, code 0x%08lx): %s\n", frame,
                [gInPipe.hostInterface frameNumberWithTime:NULL], (long)e.code, e.localizedDescription.UTF8String);
        gStop = true;
    }
}

static void enqueueOut(int slot) {
    IOUSBHostIsochronousTransaction *tx = gOutTx[slot];
    const uint32_t fb = gOutFmt.channels * gOutFmt.subframe;
    uint32_t off = 0;
    for (int i = 0; i < TPR; i++) {
        uint32_t frames;
        if (gFifoTail != gFifoHead) {
            frames = gFifo[gFifoTail];
            gFifoTail = (gFifoTail + 1) % FIFO_LEN;
        } else {
            frames = 0;
        }
        // An empty capture packet gives no size. Use the nominal size, so that the playback
        // stream continues (a request with 0 bytes fails with kIOReturnNotReady).
        if (frames == 0) {
            frames = nominalFrames();
            gOutNominal++;
        }
        if (frames * fb > gOutFmt.maxPacket) frames = gOutFmt.maxPacket / fb;
        tx[i] = (IOUSBHostIsochronousTransaction){0};
        tx[i].requestCount = frames * fb;
        tx[i].offset = off;
        if (gTone) {
            int32_t *dst = (int32_t *)((uint8_t *)gOutData[slot].mutableBytes + off);
            for (uint32_t f = 0; f < frames; f++) toneFrame(gOutPos + f, dst + f * gOutFmt.channels, gOutFmt.channels);
        }
        gOutPos += frames;
        off += frames * fb;
    }
    uint64_t frame = gAsap ? 0 : gNextOutFrame;
    gNextOutFrame += TPR / 8;
    NSError *e = nil;
    BOOL ok = [gOutPipe enqueueIORequestWithData:gOutData[slot]
                                 transactionList:tx
                            transactionListCount:TPR
                                firstFrameNumber:frame
                                         options:IOUSBHostIsochronousTransferOptionsNone
                                           error:&e
                               completionHandler:^(IOReturn st, IOUSBHostIsochronousTransaction *list) {
                                   onOutDone(slot, st, list);
                               }];
    if (ok) gInFlightOut++;
    if (!ok) {
        uint32_t total = 0;
        for (int i = 0; i < TPR; i++) total += tx[i].requestCount;
        fprintf(stderr, "OUT enqueue failed (frame %llu, now %llu, bytes %u, completions %llu, code 0x%08lx): %s\n", frame,
                [gOutPipe.hostInterface frameNumberWithTime:NULL], total, gOutCompletions, (long)e.code,
                e.localizedDescription.UTF8String);
        gStop = true;
    }
}

static void put16(FILE *f, uint16_t v) { fwrite(&v, 2, 1, f); }
static void put32(FILE *f, uint32_t v) { fwrite(&v, 4, 1, f); }

// Write a WAVE_FORMAT_EXTENSIBLE file. `samples` are left-justified 32-bit integers.
static bool writeWav(const char *path, const int32_t *samples, size_t frames, int srcChannels,
                     const int *chanMap, int channels, uint32_t rate, int bytesPerSample) {
    FILE *f = fopen(path, "wb");
    if (!f) return false;
    uint32_t dataBytes = (uint32_t)(frames * channels * bytesPerSample);
    static const uint8_t pcmGuid[16] = {0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
                                        0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71};
    fwrite("RIFF", 1, 4, f);
    put32(f, 4 + (8 + 40) + (8 + dataBytes));
    fwrite("WAVEfmt ", 1, 8, f);
    put32(f, 40);
    put16(f, 0xFFFE);
    put16(f, channels);
    put32(f, rate);
    put32(f, rate * channels * bytesPerSample);
    put16(f, channels * bytesPerSample);
    put16(f, bytesPerSample * 8);
    put16(f, 22);
    put16(f, 24);   // valid bits
    put32(f, 0);    // no speaker positions
    fwrite(pcmGuid, 1, 16, f);
    fwrite("data", 1, 4, f);
    put32(f, dataBytes);
    for (size_t i = 0; i < frames; i++) {
        for (int c = 0; c < channels; c++) {
            int32_t s = samples[i * srcChannels + chanMap[c]];
            if (bytesPerSample == 4) {
                fwrite(&s, 4, 1, f);
            } else {
                uint8_t b[3] = {(uint8_t)(s >> 8), (uint8_t)(s >> 16), (uint8_t)(s >> 24)};
                fwrite(b, 1, 3, f);
            }
        }
    }
    fclose(f);
    return true;
}

static double dbfs(double v) { return v > 0 ? 20.0 * log10(v / 2147483648.0) : -INFINITY; }

int main(int argc, char **argv) {
    @autoreleasepool {
        int alt = 1;
        double seconds = 5.0;
        bool dryRun = false;   // -D: check the tone signal without the device
        NSString *outDir = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:@"recordings"];
        int ch;
        while ((ch = getopt(argc, argv, "a:s:o:An:t:Tg:DP:")) != -1) {
            if (ch == 'a') alt = atoi(optarg);
            else if (ch == 's') seconds = atof(optarg);
            else if (ch == 'o') outDir = @(optarg);
            else if (ch == 'A') gAsap = true;
            else if (ch == 'n') NUM_REQ = atoi(optarg);
            else if (ch == 't') TPR = atoi(optarg);
            else if (ch == 'T') gTone = true;
            else if (ch == 'g') gToneDb = atof(optarg);
            else if (ch == 'D') dryRun = true;
            else if (ch == 'P') gPlaybackLeadMs = atoi(optarg);
            else { fprintf(stderr, "usage: qc_capture [-a alt 1-4] [-s seconds] [-o dir] [-A] [-n requests] [-t microframes] [-T] [-g dBFS]\n"); return 2; }
        }
        if (NUM_REQ < 2 || NUM_REQ > MAX_REQ || TPR < 8 || TPR > MAX_TPR || TPR % 8) {
            fprintf(stderr, "-n must be 2..%d; -t must be a multiple of 8, 8..%d\n", MAX_REQ, MAX_TPR);
            return 2;
        }
        if (gTone) {
            if (gToneDb > TONE_MAX_DB) {
                fprintf(stderr, "Tone level %.1f dBFS is too high (maximum %.1f dBFS).\n", gToneDb, TONE_MAX_DB);
                return 2;
            }
            if (seconds < kTones[NUM_TONES - 1].end + 0.3) seconds = kTones[NUM_TONES - 1].end + 0.3;
            gToneAmp = pow(10.0, gToneDb / 20.0) * 2147483647.0;
            printf("Test tone: %.1f dBFS; 440 Hz on output 1 (0.3-2.3 s), 660 Hz on output 2 (2.7-4.7 s)\n", gToneDb);
        }
        if (dryRun) {
            // Generate the full tone at 44.1 kHz, 4 channels, and print the peak and the first samples.
            gOutFmt.rate = 44100;
            gOutFmt.channels = 4;
            int32_t fr[4];
            double peak[4] = {0}, prevAbs = 0, maxStep = 0;
            uint64_t total = (uint64_t)(seconds * gOutFmt.rate);
            for (uint64_t pos = 0; pos < total; pos++) {
                toneFrame(pos, fr, 4);
                for (int c = 0; c < 4; c++) if (fabs((double)fr[c]) > peak[c]) peak[c] = fabs((double)fr[c]);
                double a = (double)fr[0] + (double)fr[1];
                if (pos && fabs(a - prevAbs) > maxStep) maxStep = fabs(a - prevAbs);
                prevAbs = a;
            }
            for (int c = 0; c < 4; c++) printf("dry run: output %d peak %.1f dBFS\n", c + 1, dbfs(peak[c]));
            printf("dry run: largest step between samples %.1f dBFS (a 660 Hz sine at the level gives %.1f)\n",
                   dbfs(maxStep), dbfs(gToneAmp * 2.0 * M_PI * 660.0 / 44100.0));
            printf("dry run: samples at 0.30 s:");
            for (int i = 0; i < 6; i++) { toneFrame((uint64_t)(0.3 * 44100) + 1000 + i, fr, 4); printf(" %d", fr[0]); }
            printf("\n");
            return 0;
        }
        printf("Queue: %d requests x %d microframes = %d ms; %s frame numbers; playback starts %d ms before capture\n",
               NUM_REQ, TPR, NUM_REQ * TPR / 8, gAsap ? "ASAP" : "explicit", gPlaybackLeadMs);

        CFMutableDictionaryRef match =
            [IOUSBHostDevice createMatchingDictionaryWithVendorID:@QC_VID productID:@QC_PID bcdDevice:nil
                                                      deviceClass:nil deviceSubclass:nil deviceProtocol:nil
                                                            speed:nil productIDArray:nil];
        io_service_t devSvc = IOServiceGetMatchingService(kIOMainPortDefault, match);
        if (!devSvc) { fprintf(stderr, "QUAD-CAPTURE (0582:012f) not found.\n"); return 1; }

        NSError *err = nil;
        IOUSBHostDevice *dev = [[IOUSBHostDevice alloc] initWithIOService:devSvc options:IOUSBHostObjectInitOptionsNone
                                                                    queue:nil error:&err interestHandler:nil];
        IOObjectRelease(devSvc);
        if (!dev) { fprintf(stderr, "Cannot open the device: %s\n", err.localizedDescription.UTF8String); return 1; }

        const IOUSBConfigurationDescriptor *cd = [dev configurationDescriptorWithIndex:0 error:&err];
        if (!cd || !parseFormat(cd, 1, alt, &gInFmt) || !parseFormat(cd, 0, alt, &gOutFmt)) {
            fprintf(stderr, "No audio format for alternate setting %d.\n", alt);
            return 1;
        }
        printf("Format: alt %d, %u Hz, capture %d ch, playback %d ch, %d-bit in %d bytes\n", alt, gInFmt.rate,
               gInFmt.channels, gOutFmt.channels, gInFmt.bits, gInFmt.subframe);

        if (!dev.configurationDescriptor) {
            if (![dev configureWithValue:1 matchInterfaces:YES error:&err]) {
                fprintf(stderr, "Cannot set configuration 1: %s\n", err.localizedDescription.UTF8String);
                return 1;
            }
            printf("Configuration 1 set.\n");
        }

        dispatch_queue_t q = dispatch_queue_create("qc.usb", dispatch_queue_attr_make_with_qos_class(
                                                                  DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        io_service_t s0 = waitForInterface(0), s1 = waitForInterface(1);
        if (!s0 || !s1) { fprintf(stderr, "Audio interfaces did not appear.\n"); return 1; }
        IOUSBHostInterface *ifOut = [[IOUSBHostInterface alloc] initWithIOService:s0 options:IOUSBHostObjectInitOptionsNone
                                                                            queue:q error:&err interestHandler:nil];
        if (!ifOut) { fprintf(stderr, "Cannot open interface 0: %s\n", err.localizedDescription.UTF8String); return 1; }
        IOUSBHostInterface *ifIn = [[IOUSBHostInterface alloc] initWithIOService:s1 options:IOUSBHostObjectInitOptionsNone
                                                                           queue:q error:&err interestHandler:nil];
        if (!ifIn) { fprintf(stderr, "Cannot open interface 1: %s\n", err.localizedDescription.UTF8String); return 1; }
        IOObjectRelease(s0);
        IOObjectRelease(s1);

        if (![ifOut selectAlternateSetting:alt error:&err] || ![ifIn selectAlternateSetting:alt error:&err]) {
            fprintf(stderr, "Cannot select alternate setting %d: %s\n", alt, err.localizedDescription.UTF8String);
            return 1;
        }
        gOutPipe = [ifOut copyPipeWithAddress:gOutFmt.ep error:&err];
        gInPipe = [ifIn copyPipeWithAddress:gInFmt.ep error:&err];
        if (!gOutPipe || !gInPipe) { fprintf(stderr, "Cannot open the pipes: %s\n", err.localizedDescription.UTF8String); return 1; }

        for (int i = 0; i < NUM_REQ; i++) {
            gInData[i] = [ifIn ioDataWithCapacity:TPR * gInFmt.maxPacket error:&err];
            gOutData[i] = [ifOut ioDataWithCapacity:TPR * gOutFmt.maxPacket error:&err];
            if (!gInData[i] || !gOutData[i]) { fprintf(stderr, "Cannot allocate I/O buffers.\n"); return 1; }
            // ioData buffers have a fixed length (the length cannot be set).
            memset(gOutData[i].mutableBytes, 0, TPR * gOutFmt.maxPacket);   // silence only
        }

        gCapMax = (size_t)((seconds + 1.0) * gInFmt.rate) * gInFmt.channels * gInFmt.subframe;
        gCap = calloc(1, gCapMax);

        dispatch_sync(q, ^{
            uint64_t now = [ifIn frameNumberWithTime:NULL];
            uint64_t base = now + 8;
            gStartFrame = base + (gPlaybackLeadMs < 0 ? -gPlaybackLeadMs : 0);
            gInStartFrame = base + (gPlaybackLeadMs > 0 ? gPlaybackLeadMs : 0);
            gNextOutFrame = gStartFrame;
            gNextInFrame = gInStartFrame;
            gStartTime = mach_absolute_time();
            for (int i = 0; i < NUM_REQ; i++) enqueueOut(i);
            for (int i = 0; i < NUM_REQ; i++) enqueueIn(i);
        });
        printf("%s %.1f s ...\n", gTone ? "Playing the tone and recording" : "Recording", seconds);
        uint64_t t0 = mach_absolute_time();
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        while (!gStop) {
            usleep(20000);
            double el = (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 1e9;
            if (el >= seconds) break;
        }
        // Clean stop: send no new requests, and let the queued requests complete.
        dispatch_sync(q, ^{ gStop = true; });
        __block int inFlight = 0;
        for (int i = 0; i < 100; i++) {
            dispatch_sync(q, ^{ inFlight = gInFlightIn + gInFlightOut; });
            if (inFlight == 0) break;
            usleep(10000);
        }
        if (inFlight == 0) {
            printf("Clean stop: all queued requests completed.\n");
        } else {
            printf("Stop: %d requests did not complete, abort.\n", inFlight);
            [gInPipe abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
            [gOutPipe abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
        }
        [ifIn selectAlternateSetting:0 error:nil];
        [ifOut selectAlternateSetting:0 error:nil];
        [ifIn destroy];
        [ifOut destroy];
        [dev destroy];

        // Statistics
        __block uint64_t inTx, inEmpty, inErr, outErr, framesAfter, tFirst, tLast;
        dispatch_sync(q, ^{
            inTx = gInTransactions; inEmpty = gInEmpty; inErr = gInErrors; outErr = gOutErrors;
            framesAfter = gFramesAfterFirst; tFirst = gFirstTime; tLast = gLastTime;
        });
        printf("IN transactions: %llu, empty: %llu, errors: %llu (last 0x%08x); OUT errors: %llu (last 0x%08x)\n",
               inTx, inEmpty, inErr, gLastInErr, outErr, gLastOutErr);
        printf("Lag (current frame - expected frame), every 50 ms:\n  OUT:");
        for (int i = 0; i < gOutLagN; i++) printf(" %lld", gOutLag[i]);
        printf("\n  IN: ");
        for (int i = 0; i < gInLagN; i++) printf(" %lld", gInLag[i]);
        printf("\n");
        if (gFirstDataTx != UINT64_MAX)
            printf("First capture data after %.1f ms (microframe %llu); empty packets after that: %llu\n",
                   gFirstDataTx / 8.0, gFirstDataTx, gEmptyAfterData);
        else
            printf("No capture data.\n");
        if (gGapN > 0) {
            printf("Empty blocks (start ms + length ms):");
            for (int i = 0; i < gGapN; i++) printf("  %.1f+%.1f", gGapStart[i] / 8.0, gGapLen[i] / 8.0);
            printf("%s\n", gGapN == GAP_LOG ? " ..." : "");
        }
        printf("OUT transactions: %llu, bytes requested %llu, transmitted %llu, short %llu, nominal size %llu\n",
               gOutTxCount, gOutReqBytes, gOutDoneBytes, gOutShort, gOutNominal);
        printf("OUT transmitted peak per channel (dBFS):");
        for (int c = 0; c < gOutFmt.channels && c < 8; c++) printf("  out %d %6.1f", c + 1, dbfs(gOutPeak[c]));
        printf("\n");
        if (gOutFirstSoundPos != UINT64_MAX)
            printf("OUT non-zero samples from %.3f s to %.3f s (stream position)\n",
                   (double)gOutFirstSoundPos / gOutFmt.rate, (double)gOutLastSoundPos / gOutFmt.rate);
        printf("Frames per microframe:");
        for (int i = 0; i < 32; i++) if (gHist[i]) printf("  %d:%llu", i, gHist[i]);
        printf("\n");
        if (tLast > tFirst) {
            double dt = (double)(tLast - tFirst) * tb.numer / tb.denom / 1e9;
            printf("Measured device sample rate: %.1f Hz (over %.2f s)\n", framesAfter / dt, dt);
        }

        size_t frames = gCapBytes / (gInFmt.channels * gInFmt.subframe);
        printf("Captured %zu frames (%.2f s at %u Hz)\n", frames, (double)frames / gInFmt.rate, gInFmt.rate);
        if (frames == 0 || gInFmt.subframe != 4) {
            fprintf(stderr, "No audio data to write.\n");
            return 1;
        }

        // The samples are left-justified 32-bit words (S32_LE in the Linux driver).
        int32_t *smp = (int32_t *)gCap;
        size_t n = frames * gInFmt.channels;
        size_t lowNonZero = 0;
        for (size_t i = 0; i < n; i++) if (smp[i] & 0xff) lowNonZero++;
        printf("Samples with a low byte that is not 0: %zu of %zu\n", lowNonZero, n);

        printf("Per-channel levels (dBFS):\n");
        for (int c = 0; c < gInFmt.channels; c++) {
            double peak = 0, sum = 0, mean = 0;
            for (size_t i = 0; i < frames; i++) mean += smp[i * gInFmt.channels + c];
            mean /= frames;
            for (size_t i = 0; i < frames; i++) {
                double v = smp[i * gInFmt.channels + c] - mean;
                if (fabs(v) > peak) peak = fabs(v);
                sum += v * v;
            }
            printf("  ch %d: peak %7.1f  rms %7.1f  dc %.0f\n", c + 1, dbfs(peak), dbfs(sqrt(sum / frames)), mean);
        }

        if (gTone) {
            // Measure each tone in each capture channel, 0.1 s inside the tone segment.
            printf("Tone levels in the capture channels (dBFS):\n");
            for (size_t k = 0; k < NUM_TONES; k++) {
                const ToneSegment *g = &kTones[k];
                size_t from = (size_t)((g->start + 0.1) * gInFmt.rate), to = (size_t)((g->end - 0.1) * gInFmt.rate);
                if (to > frames) to = frames;
                if (from >= to) continue;
                printf("  %.0f Hz (output %d):", g->freq, g->channel + 1);
                for (int c = 0; c < gInFmt.channels; c++)
                    printf("  ch %d %6.1f", c + 1, toneLevel(smp, gInFmt.channels, c, from, to, g->freq, gInFmt.rate));
                printf("\n");
            }
        }

        [NSFileManager.defaultManager createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *base = [NSString stringWithFormat:@"%@/capture-%uHz", outDir, gInFmt.rate];
        int all[8] = {0, 1, 2, 3, 4, 5, 6, 7};
        NSString *pAll = [base stringByAppendingFormat:@"-%dch.wav", gInFmt.channels];
        NSString *pStereo = [base stringByAppendingString:@"-ch1-2.wav"];
        writeWav(pAll.UTF8String, smp, frames, gInFmt.channels, all, gInFmt.channels, gInFmt.rate, 4);
        writeWav(pStereo.UTF8String, smp, frames, gInFmt.channels, all, 2, gInFmt.rate, 3);
        printf("Wrote %s\nWrote %s\n", pAll.UTF8String, pStereo.UTF8String);
    }
    return 0;
}
