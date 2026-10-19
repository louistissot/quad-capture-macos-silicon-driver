// qc_engine: USB audio engine for the Roland QUAD-CAPTURE. See qc_engine.h.
//
// USB protocol (from the descriptors and the Linux snd-usb-audio driver):
//   interface 0: playback, isochronous OUT endpoint 0x05, 4 ch
//   interface 1: capture, isochronous IN endpoint 0x85, 6 ch (implicit feedback)
//   alternate setting 1/2/3/4 = 44.1/48/96/192 kHz (2 ch at 192 kHz)
//   24-bit samples left-justified in 32-bit words.
// The device clock changes with a vendor request on endpoint 0 (docs/PROTOCOL.md, "Sample rate"),
// only while the streams are stopped.
// Device behavior found in tests (see README.md):
//   - An abort of the transfers can mute the outputs, so the engine stops with a clean drain.
//   - After a power cycle the device sends empty capture packets for about 0.5 s, and a playback
//     request with 0 bytes fails. Empty capture packets give playback packets with the nominal size.
//   - Sample time 0 starts after STABLE_MICROFRAMES non-empty capture packets.
// Latency: the playback data of a request is read from the ring when the request is queued, so the
// output lead is the queue depth (requests x microframes) plus a margin for late callbacks. A request
// that is too late (kIOReturnIsoTooOld) moves to a later frame (resync): capture puts in silence for
// the skipped microframes, and playback skips the same number of samples, so both stay on time.
#import "qc_engine.h"
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>
#include <mach/mach.h>
#include <mach/thread_policy.h>
#include <mach/mach_time.h>
#include <math.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>

#ifndef __MAC_26_0
// The microframe API is in the macOS 26 SDK. Declare it for older SDKs; the engine calls it only
// if the object responds to it (macOS 26 or later).
@interface IOUSBHostObject (QCMicroframe)
- (uint64_t)currentMicroframeWithTime:(nullable IOUSBHostTime *)time error:(NSError *_Nullable *)error;
@end
#endif

#define QC_VID 0x0582
#define QC_PID 0x012f
#define FIFO_LEN 4096
#define STABLE_MICROFRAMES 800  // 100 ms of non-empty capture packets
#define RESYNC_ATTEMPTS 4       // a late request tries again with a lead of 2, 4, 8 and 16 ms (frames)
#define RING_MASK (QC_RING_FRAMES - 1)

typedef struct {
    int channels;
    int subframe;
    uint32_t rate;
    uint8_t ep;
    uint16_t maxPacket;
} Fmt;

static os_log_t gLog;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;   // serializes configure, start and stop
static dispatch_queue_t gQueue;
static _Atomic int gCbPriority, gCbPolicy;

// Configuration (changed only while the engine does not run).
static int gNumReq = 8, gTpr = 128;              // 128 ms queue of 16 ms requests (fewer kernel calls:
                                                  // 4.5 % of one core instead of 9.4 % with 4 ms requests)
static uint32_t gOutMargin = 44, gInMargin = 44;   // 1 ms each (frames at 44.1 kHz); 0.5 ms passed a
                                                  // full-CPU-load test too
static uint32_t gRate = 44100;                     // Hz

const uint32_t qc_engine_rates[QC_NUM_RATES] = {44100, 48000, 96000, 192000};
static bool gDirectWrite = true;                   // the client writes playback into the queued requests
static bool gDirectRead = true;                    // a real-time thread reads capture from the queued requests
#define GUARD_MICROFRAMES 8                        // direct writes stop 1 ms before the transfer
#define SCAN_DELAY_MICROFRAMES 2                   // the scanner reads a microframe 250 us after its end
#define SCAN_PERIOD_US 1000                        // the scanner wakes each 1 ms
#define SENTINEL 0x5AA5C33Cu                       // marks a capture frame slot that the device did not fill

// Direct read: a map of each queued capture request, for the scanner thread.
typedef struct {
    _Atomic uint32_t seq;
    bool valid;
    uint64_t reqIndex;
    uint64_t firstMicro;
    const uint8_t *base;
} InMap;
static InMap gInMap[QC_MAX_REQUESTS];
static uint64_t gInReqIndex;                       // USB queue: index of the next capture request
static uint64_t gInSlotReq[QC_MAX_REQUESTS];       // USB queue: request index in each slot
static _Atomic uint64_t gScanDoneReq;              // the scanner read all requests below this index
static _Atomic uint64_t gStableReq, gStableMicro;  // first request and microframe of sample time 0
static pthread_t gScanThread;
static bool gScanThreadRunning;
static atomic_bool gScanStop;
static _Atomic int gScanPriority;

// Direct write: a map of each queued playback request, for the client (real-time) thread.
// The sequence number is odd while the USB queue changes the map.
typedef struct {
    _Atomic uint32_t seq;
    bool valid;
    int64_t firstT;                                // sample time of the first frame
    uint32_t frames;
    uint64_t firstMicro;                           // microframe of transaction 0
    uint16_t cum[QC_MAX_MICROFRAMES + 1];          // frames before transaction i
    uint8_t *base;                                 // the I/O buffer of the request
} OutMap;
static OutMap gOutMap[QC_MAX_REQUESTS];
static _Atomic uint32_t gRefSeq;                   // seqlock for gRefMicro / gRefHost (read by the client)
static _Atomic uint64_t gRefMicroA, gRefHostA;

static IOUSBHostDevice *gDev;
static IOUSBHostInterface *gIfOut, *gIfIn;
static IOUSBHostPipe *gOutPipe, *gInPipe;
static NSMutableData *gInData[QC_MAX_REQUESTS], *gOutData[QC_MAX_REQUESTS];
static IOUSBHostIsochronousTransaction gInTx[QC_MAX_REQUESTS][QC_MAX_MICROFRAMES];
static IOUSBHostIsochronousTransaction gOutTx[QC_MAX_REQUESTS][QC_MAX_MICROFRAMES];
static uint64_t gInSlotMicro[QC_MAX_REQUESTS], gOutSlotMicro[QC_MAX_REQUESTS];
static Fmt gInFmt, gOutFmt;

// Queue state (only the USB queue changes these while the engine runs).
static uint64_t gNextInFrame, gNextOutFrame, gInExpectMicro;
static int gInFlightIn, gInFlightOut;
static bool gStop;
static uint32_t gFifo[FIFO_LEN], gFifoHead, gFifoTail, gNominalAcc, gGapAcc;
static uint32_t gConsec;
static int64_t gS, gNextZero;
static uint64_t gRefMicro, gRefHost, gZeroHost0;
static bool gHasMicroAPI;             // currentMicroframeWithTime (macOS 26 or later)
static double gFrameBoundaryEst;      // fallback clock: smoothed host time of frame 0
static bool gFrameEstValid;
static int gFrameEstOutliers;
static double gTicksPerMicro, gNsPerTick;
static int64_t gOutPos, gOutOffset;
static bool gOutMapped;
static uint64_t gOutFillEndMicro;
static double gInLagMax, gOutLagMax;
static uint64_t gInLagHist[QC_LAG_BUCKETS], gOutLagHist[QC_LAG_BUCKETS];

// Shared with the client threads.
static atomic_bool gRunning, gStable, gDead;
static _Atomic int64_t gInWritePos, gOutReadPos;
static _Atomic uint32_t gZSeq;
static _Atomic int64_t gZSample;
static _Atomic uint64_t gZHost, gZSeed = 1;
static _Atomic uint64_t gStInputMissing, gStOutputLate, gStEmpty, gStInErr, gStOutErr, gStZero, gStResync, gStGap;
static _Atomic uint64_t gStDirect, gStRing, gStRace;

static float gInRing[QC_RING_FRAMES * QC_IN_CHANNELS];
static float gOutRing[QC_RING_FRAMES * QC_OUT_CHANNELS];

static bool parseFormat(const IOUSBConfigurationDescriptor *cd, int iface, int alt, Fmt *f) {
    const uint8_t *p = (const uint8_t *)cd, *end = p + cd->wTotalLength;
    bool inside = false, gotFmt = false, gotEp = false;
    memset(f, 0, sizeof(*f));
    p += cd->bLength;
    while (p + 2 <= end && p[0] >= 2 && p + p[0] <= end) {
        uint8_t len = p[0], type = p[1];
        if (type == 4) {
            inside = (p[2] == iface && p[3] == alt);
        } else if (inside && type == 0x24 && len >= 11 && p[2] == 0x02 && p[3] == 0x01) {
            f->channels = p[4];
            f->subframe = p[5];
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

static io_service_t findDevice(void) {
    CFMutableDictionaryRef m =
        [IOUSBHostDevice createMatchingDictionaryWithVendorID:@QC_VID productID:@QC_PID bcdDevice:nil
                                                  deviceClass:nil deviceSubclass:nil deviceProtocol:nil
                                                        speed:nil productIDArray:nil];
    return IOServiceGetMatchingService(kIOMainPortDefault, m);
}

static io_service_t waitForInterface(int num) {
    for (int i = 0; i < 60; i++) {
        CFMutableDictionaryRef m =
            [IOUSBHostInterface createMatchingDictionaryWithVendorID:@QC_VID productID:@QC_PID bcdDevice:nil
                                                     interfaceNumber:@(num) configurationValue:@1
                                                      interfaceClass:nil interfaceSubclass:nil
                                                   interfaceProtocol:nil speed:nil productIDArray:nil];
        io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, m);
        if (s) return s;
        usleep(50000);
    }
    return 0;
}

static void publishZero(int64_t sample, uint64_t host) {
    uint32_t q = atomic_load_explicit(&gZSeq, memory_order_relaxed);
    atomic_store_explicit(&gZSeq, q + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    atomic_store_explicit(&gZSample, sample, memory_order_relaxed);
    atomic_store_explicit(&gZHost, host, memory_order_relaxed);
    atomic_store_explicit(&gZSeq, q + 2, memory_order_release);
    atomic_fetch_add_explicit(&gStZero, 1, memory_order_relaxed);
}

// Host time of the start of microframe m, from the most recent (microframe, host time) pair.
static inline uint64_t hostOfMicro(uint64_t m) {
    double d = (double)((int64_t)m - (int64_t)gRefMicro) * gTicksPerMicro;
    return (uint64_t)((double)gRefHost + d);
}

// Update the (microframe, host time) pair. macOS 26: exact microframe time. Older macOS: the host time
// of a frame-number read is inside that frame, so the frame start is smoothed over many reads; the
// constant offset that stays (about 0.5 ms) does not change the clock rate.
static void publishRef(void) {
    uint32_t q = atomic_load_explicit(&gRefSeq, memory_order_relaxed);
    atomic_store_explicit(&gRefSeq, q + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    atomic_store_explicit(&gRefMicroA, gRefMicro, memory_order_relaxed);
    atomic_store_explicit(&gRefHostA, gRefHost, memory_order_relaxed);
    atomic_store_explicit(&gRefSeq, q + 2, memory_order_release);
}

static void refreshRef(IOUSBHostInterface *iface) {
    IOUSBHostTime t = 0;
    if (gHasMicroAPI) {
        uint64_t cur = [iface currentMicroframeWithTime:&t error:nil];
        if (cur && t) { gRefMicro = cur; gRefHost = t; publishRef(); }
        return;
    }
    uint64_t f = [iface frameNumberWithTime:&t];
    if (!f || !t) return;
    const double ticksPerFrame = gTicksPerMicro * 8.0;
    double b = (double)t - (double)f * ticksPerFrame;
    if (!gFrameEstValid) {
        gFrameBoundaryEst = b;
        gFrameEstValid = true;
    } else if (fabs(b - gFrameBoundaryEst) > 2.0 * ticksPerFrame) {
        // A read that took long (thread preempted): ignore it, unless this continues.
        if (++gFrameEstOutliers > 20) { gFrameBoundaryEst = b; gFrameEstOutliers = 0; }
        else return;
    } else {
        gFrameEstOutliers = 0;
        gFrameBoundaryEst += 0.02 * (b - gFrameBoundaryEst);
    }
    gRefMicro = f * 8;
    gRefHost = (uint64_t)(gFrameBoundaryEst + (double)f * ticksPerFrame);
    publishRef();
}

static void loadRef(uint64_t *micro, uint64_t *host) {
    for (;;) {
        uint32_t a = atomic_load_explicit(&gRefSeq, memory_order_acquire);
        if (a & 1) continue;
        *micro = atomic_load_explicit(&gRefMicroA, memory_order_relaxed);
        *host = atomic_load_explicit(&gRefHostA, memory_order_relaxed);
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit(&gRefSeq, memory_order_relaxed) == a) return;
    }
}

static uint64_t hostOfMicroShared(uint64_t m) {
    uint64_t rm, rh;
    loadRef(&rm, &rh);
    return (uint64_t)((double)rh + (double)((int64_t)m - (int64_t)rm) * gTicksPerMicro);
}

static uint32_t nominalFrames(uint32_t *acc, uint32_t microframes) {
    *acc += gOutFmt.rate * microframes;
    uint32_t n = *acc / 8000;
    *acc %= 8000;
    return n;
}

static inline int32_t floatToSample(float v) {
    if (v >= 1.0f) return INT32_MAX;
    if (v <= -1.0f) return INT32_MIN;
    return (int32_t)lrintf(v * 2147483647.0f);
}

static void recordLag(uint64_t endMicro, double *maxMs, uint64_t *hist) {
    double ms = ((double)mach_absolute_time() - (double)hostOfMicro(endMicro)) * gNsPerTick * 1e-6;
    if (ms > *maxMs) *maxMs = ms;
    // Log the start of each stall (callback later than 20 ms), at most one line per 100 ms.
    static uint64_t lastLog;
    uint64_t now = mach_absolute_time();
    if (ms > 20.0 && (double)(now - lastLog) * gNsPerTick > 100e6) {
        lastLog = now;
        os_log(gLog, "stall: callback %.1f ms after the end of its request", ms);
    }
    static const double edges[QC_LAG_BUCKETS - 1] = {0.5, 1, 2, 4, 8, 16, 32};
    int b = 0;
    while (b < QC_LAG_BUCKETS - 1 && ms >= edges[b]) b++;
    hist[b]++;
}

// Append capture frames (or silence if src is NULL) that span `micros` microframes from microStart.
// Publish the zero timestamps that fall inside, with the host time interpolated over the span.
static void appendCapture(const int32_t *src, uint32_t frames, uint64_t microStart, uint32_t micros, bool shared) {
    if (frames == 0) return;
    const int used = gInFmt.channels < QC_IN_CHANNELS ? gInFmt.channels : QC_IN_CHANNELS;   // 2 at 192 kHz
    for (uint32_t f = 0; f < frames; f++) {
        float *dst = &gInRing[((gS + f) & RING_MASK) * QC_IN_CHANNELS];
        for (int c = 0; c < QC_IN_CHANNELS; c++)
            dst[c] = src && c < used ? (float)src[f * gInFmt.channels + c] * (1.0f / 2147483648.0f) : 0.0f;
    }
    while (gNextZero < gS + frames) {
        double frac = (double)(gNextZero - gS) / frames;
        uint64_t h = (shared ? hostOfMicroShared(microStart) : hostOfMicro(microStart)) +
                     (uint64_t)(frac * micros * gTicksPerMicro);
        publishZero(gNextZero, h);
        gNextZero += QC_ZERO_PERIOD;
    }
    gS += frames;
    atomic_store_explicit(&gInWritePos, gS, memory_order_release);
}

static void enqueueIn(int slot);
static void enqueueOut(int slot);

static void sampleThread(void) {
    static uint32_t n;
    if (n++ % 1000) return;
    thread_extended_info_data_t info;
    mach_msg_type_number_t count = THREAD_EXTENDED_INFO_COUNT;
    mach_port_t th = mach_thread_self();
    if (thread_info(th, THREAD_EXTENDED_INFO, (thread_info_t)&info, &count) == KERN_SUCCESS) {
        atomic_store_explicit(&gCbPriority, info.pth_curpri, memory_order_relaxed);
        atomic_store_explicit(&gCbPolicy, info.pth_policy, memory_order_relaxed);
    }
    mach_port_deallocate(mach_task_self(), th);
}

static void reuseInSlot(int slot);

static void onInDone(int slot, IOReturn status, IOUSBHostIsochronousTransaction *list) {
    gInFlightIn--;
    if (gStop || status == kIOReturnAborted) return;
    sampleThread();

    refreshRef(gIfIn);
    const uint64_t slotMicro = gInSlotMicro[slot];
    recordLag(slotMicro + gTpr, &gInLagMax, gInLagHist);

    const bool stable = atomic_load_explicit(&gStable, memory_order_relaxed);
    const uint32_t fb = gInFmt.channels * gInFmt.subframe;
    bool becameStable = false;
    for (int i = 0; i < gTpr; i++) {
        IOReturn st = list[i].status;
        uint32_t frames = 0;
        if (st == kIOReturnSuccess || st == kIOReturnUnderrun) frames = list[i].completeCount / fb;
        else atomic_fetch_add_explicit(&gStInErr, 1, memory_order_relaxed);
        // Implicit feedback: the size of each playback packet follows the size of a capture packet.
        if (((gFifoHead + 1) % FIFO_LEN) != gFifoTail) {
            gFifo[gFifoHead] = frames;
            gFifoHead = (gFifoHead + 1) % FIFO_LEN;
        }
        if (!stable && !becameStable) {
            gConsec = frames ? gConsec + 1 : 0;
            if (gConsec >= STABLE_MICROFRAMES) becameStable = true;
        }
    }

    if (becameStable) {
        // Sample time 0 is the first frame of the next request (its data is still in its buffer).
        const uint64_t m0 = slotMicro + gTpr;
        gS = 0;
        gNextZero = QC_ZERO_PERIOD;
        gInExpectMicro = m0;
        atomic_store_explicit(&gInWritePos, 0, memory_order_release);
        atomic_store_explicit(&gStableReq, gInSlotReq[slot] + 1, memory_order_relaxed);
        atomic_store_explicit(&gStableMicro, m0, memory_order_relaxed);
        if (!gDirectRead) {
            gZeroHost0 = hostOfMicro(m0);
            publishZero(0, gZeroHost0);
        }
        // Map the playback stream position to sample time: the next playback frame goes out at
        // microframe gOutFillEndMicro, when the device is at about this sample time.
        double expected = (double)((int64_t)gOutFillEndMicro - (int64_t)m0) * gOutFmt.rate / 8000.0;
        gOutOffset = (int64_t)llround(expected) - gOutPos;
        gOutMapped = true;
        atomic_store_explicit(&gOutReadPos, gOutPos + gOutOffset, memory_order_release);
        atomic_store_explicit(&gStable, true, memory_order_release);
        os_log(gLog, "stream stable at microframe %llu; output offset %lld", m0, gOutOffset);
    } else if (stable && !gDirectRead) {
        // Callback path: the data of this request goes to the ring now.
        if (slotMicro > gInExpectMicro) {
            // Microframes skipped by a resync: put in silence, so sample time stays on the device clock.
            uint32_t gap = (uint32_t)(slotMicro - gInExpectMicro);
            uint32_t frames = nominalFrames(&gGapAcc, gap);
            appendCapture(NULL, frames, gInExpectMicro, gap, false);
            atomic_fetch_add_explicit(&gStGap, frames, memory_order_relaxed);
        }
        gInExpectMicro = slotMicro + gTpr;
        const uint8_t *base = gInData[slot].bytes;
        for (int i = 0; i < gTpr; i++) {
            const uint64_t m = slotMicro + i;
            IOReturn st = list[i].status;
            if (st != kIOReturnSuccess && st != kIOReturnUnderrun) {
                appendCapture(NULL, nominalFrames(&gGapAcc, 1), m, 1, false);   // lost packet: silence
                continue;
            }
            uint32_t frames = list[i].completeCount / fb;
            if (frames == 0) {
                atomic_fetch_add_explicit(&gStEmpty, 1, memory_order_relaxed);
                continue;
            }
            appendCapture((const int32_t *)(base + list[i].offset), frames, m, 1, false);
        }
    }
    reuseInSlot(slot);
}

// Direct read: queue the slot again only after the scanner read it. Normally the scanner is far ahead.
static void reuseInSlot(int slot) {
    if (gStop) return;
    if (gDirectRead && atomic_load_explicit(&gStable, memory_order_acquire) &&
        gInSlotReq[slot] >= atomic_load_explicit(&gScanDoneReq, memory_order_acquire) &&
        gInSlotReq[slot] >= atomic_load_explicit(&gStableReq, memory_order_relaxed)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500000), gQueue, ^{ reuseInSlot(slot); });
        return;
    }
    enqueueIn(slot);
}

static void onOutDone(int slot, IOReturn status, IOUSBHostIsochronousTransaction *list) {
    gInFlightOut--;
    if (gStop || status == kIOReturnAborted) return;
    recordLag(gOutSlotMicro[slot] + gTpr, &gOutLagMax, gOutLagHist);
    for (int i = 0; i < gTpr; i++)
        if (list[i].status != kIOReturnSuccess) atomic_fetch_add_explicit(&gStOutErr, 1, memory_order_relaxed);
    enqueueOut(slot);
}

// Frame number for a request that was too late: 2, 4, 8 or 16 ms after now (attempt 0..3).
static uint64_t resyncFrame(IOUSBHostInterface *iface, int attempt) {
    return [iface frameNumberWithTime:NULL] + (2u << attempt);
}

// All attempts failed: try again 1 ms later, so the slot does not go out of the queue.
static void retryLater(bool capture, int slot) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1000000), gQueue, ^{
        if (gStop) return;
        if (capture) enqueueIn(slot);
        else enqueueOut(slot);
    });
}

static void setInMapValid(InMap *m, bool valid) {
    uint32_t q = atomic_load_explicit(&m->seq, memory_order_relaxed);
    atomic_store_explicit(&m->seq, q + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    m->valid = valid;
    atomic_store_explicit(&m->seq, q + 2, memory_order_release);
}

static void enqueueIn(int slot) {
    IOUSBHostIsochronousTransaction *tx = gInTx[slot];
    InMap *map = &gInMap[slot];
    setInMapValid(map, false);
    if (gDirectRead) {
        // Mark all frame slots: the scanner counts the frames that the device wrote.
        uint32_t *w = (uint32_t *)gInData[slot].mutableBytes;
        const size_t words = (size_t)gTpr * gInFmt.maxPacket / 4;
        for (size_t i = 0; i < words; i++) w[i] = SENTINEL;
    }
    uint64_t frame = gNextInFrame;
    NSError *e = nil;
    BOOL ok = NO;
    for (int attempt = 0; attempt <= RESYNC_ATTEMPTS && !ok; attempt++) {
        for (int i = 0; i < gTpr; i++) {
            tx[i] = (IOUSBHostIsochronousTransaction){0};
            tx[i].requestCount = gInFmt.maxPacket;
            tx[i].offset = i * gInFmt.maxPacket;
        }
        gInSlotMicro[slot] = frame * 8;
        e = nil;
        ok = [gInPipe enqueueIORequestWithData:gInData[slot]
                               transactionList:tx
                          transactionListCount:gTpr
                              firstFrameNumber:frame
                                       options:IOUSBHostIsochronousTransferOptionsNone
                                         error:&e
                             completionHandler:^(IOReturn st, IOUSBHostIsochronousTransaction *l) {
                                 onInDone(slot, st, l);
                             }];
        if (!ok && e.code == kIOReturnIsoTooOld && attempt < RESYNC_ATTEMPTS) {
            frame = resyncFrame(gIfIn, attempt);
            atomic_fetch_add_explicit(&gStResync, 1, memory_order_relaxed);
        } else if (!ok) {
            break;
        }
    }
    if (ok) {
        gNextInFrame = frame + gTpr / 8;
        gInFlightIn++;
        gInSlotReq[slot] = gInReqIndex;
        uint32_t q = atomic_load_explicit(&map->seq, memory_order_relaxed);
        atomic_store_explicit(&map->seq, q + 1, memory_order_relaxed);
        atomic_thread_fence(memory_order_release);
        map->reqIndex = gInReqIndex++;
        map->firstMicro = frame * 8;
        map->base = gInData[slot].bytes;
        map->valid = true;
        atomic_store_explicit(&map->seq, q + 2, memory_order_release);
    } else {
        os_log_error(gLog, "capture enqueue failed (frame %llu): 0x%08lx; try again later", frame, (long)e.code);
        atomic_fetch_add_explicit(&gStInErr, 1, memory_order_relaxed);
        retryLater(true, slot);
    }
}

// Fill one playback request: packet sizes from the capture sizes, data from the output ring.
static void fillOut(int slot) {
    IOUSBHostIsochronousTransaction *tx = gOutTx[slot];
    const uint32_t fb = gOutFmt.channels * gOutFmt.subframe;
    uint8_t *base = gOutData[slot].mutableBytes;
    uint32_t off = 0;
    for (int i = 0; i < gTpr; i++) {
        uint32_t frames = 0;
        if (gFifoTail != gFifoHead) {
            frames = gFifo[gFifoTail];
            gFifoTail = (gFifoTail + 1) % FIFO_LEN;
        }
        if (frames == 0) frames = nominalFrames(&gNominalAcc, 1);
        if (frames * fb > gOutFmt.maxPacket) frames = gOutFmt.maxPacket / fb;
        tx[i] = (IOUSBHostIsochronousTransaction){0};
        tx[i].requestCount = frames * fb;
        tx[i].offset = off;
        int32_t *dst = (int32_t *)(base + off);
        for (uint32_t f = 0; f < frames; f++) {
            int32_t *o = dst + f * gOutFmt.channels;
            for (int c = 0; c < gOutFmt.channels; c++) o[c] = 0;
            if (!gOutMapped) continue;
            int64_t T = gOutPos + f + gOutOffset;
            if (T < 0) continue;
            float *r = &gOutRing[(T & RING_MASK) * QC_OUT_CHANNELS];
            for (int c = 0; c < QC_OUT_CHANNELS; c++) {
                if (c < gOutFmt.channels) o[c] = floatToSample(r[c]);
                r[c] = 0.0f;   // a frame that the client does not write again plays as silence
            }
        }
        gOutPos += frames;
        off += frames * fb;
    }
}

static void setMapValid(OutMap *m, bool valid) {
    uint32_t q = atomic_load_explicit(&m->seq, memory_order_relaxed);
    atomic_store_explicit(&m->seq, q + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    m->valid = valid;
    atomic_store_explicit(&m->seq, q + 2, memory_order_release);
}

static void enqueueOut(int slot) {
    OutMap *map = &gOutMap[slot];
    setMapValid(map, false);
    uint64_t frame = gNextOutFrame;
    // State before the fill, to fill again after a resync.
    const int64_t pos0 = gOutPos;
    const uint32_t tail0 = gFifoTail, acc0 = gNominalAcc;
    NSError *e = nil;
    BOOL ok = NO;
    for (int attempt = 0; attempt <= RESYNC_ATTEMPTS && !ok; attempt++) {
        gOutPos = pos0;
        gFifoTail = tail0;
        gNominalAcc = acc0;
        fillOut(slot);
        gOutSlotMicro[slot] = frame * 8;
        e = nil;
        ok = [gOutPipe enqueueIORequestWithData:gOutData[slot]
                                transactionList:gOutTx[slot]
                           transactionListCount:gTpr
                               firstFrameNumber:frame
                                        options:IOUSBHostIsochronousTransferOptionsNone
                                          error:&e
                              completionHandler:^(IOReturn st, IOUSBHostIsochronousTransaction *l) {
                                  onOutDone(slot, st, l);
                              }];
        if (!ok && e.code == kIOReturnIsoTooOld && attempt < RESYNC_ATTEMPTS) {
            uint64_t newFrame = resyncFrame(gIfOut, attempt);
            // Skip the samples of the skipped microframes, so playback stays on the device clock.
            if (newFrame > frame && gOutMapped)
                gOutOffset += (int64_t)llround((double)(newFrame - frame) * 8.0 * gOutFmt.rate / 8000.0);
            frame = newFrame;
            atomic_fetch_add_explicit(&gStResync, 1, memory_order_relaxed);
        } else if (!ok) {
            break;
        }
    }
    if (gOutMapped) atomic_store_explicit(&gOutReadPos, gOutPos + gOutOffset, memory_order_release);
    if (ok) {
        gNextOutFrame = frame + gTpr / 8;
        gOutFillEndMicro = gNextOutFrame * 8;
        gInFlightOut++;
        if (gOutMapped) {
            // Publish the map, so the client can write into this request until shortly before the transfer.
            const uint32_t fb = gOutFmt.channels * gOutFmt.subframe;
            uint32_t q = atomic_load_explicit(&map->seq, memory_order_relaxed);
            atomic_store_explicit(&map->seq, q + 1, memory_order_relaxed);
            atomic_thread_fence(memory_order_release);
            map->firstT = pos0 + gOutOffset;
            map->firstMicro = frame * 8;
            map->base = gOutData[slot].mutableBytes;
            uint32_t total = 0;
            for (int i = 0; i < gTpr; i++) {
                map->cum[i] = (uint16_t)total;
                total += gOutTx[slot][i].requestCount / fb;
            }
            map->cum[gTpr] = (uint16_t)total;
            map->frames = total;
            map->valid = true;
            atomic_store_explicit(&map->seq, q + 2, memory_order_release);
        }
    } else {
        os_log_error(gLog, "playback enqueue failed (frame %llu): 0x%08lx; try again later", frame, (long)e.code);
        atomic_fetch_add_explicit(&gStOutErr, 1, memory_order_relaxed);
        // The fill moved the ring read position; go back, so the next fill reads the same samples.
        gOutPos = pos0;
        gFifoTail = tail0;
        gNominalAcc = acc0;
        retryLater(false, slot);
    }
}

// Scanner (direct read): a real-time thread that reads the capture data from the queued requests
// 250 us after each microframe, writes it to the input ring, and publishes the zero timestamps.
// So capture and the clock do not depend on the time of the USB callbacks.
static bool findInRequest(uint64_t req, uint64_t *firstMicro, const uint8_t **base) {
    for (int s = 0; s < gNumReq; s++) {
        InMap *m = &gInMap[s];
        uint32_t q = atomic_load_explicit(&m->seq, memory_order_acquire);
        if (q & 1) continue;
        bool valid = m->valid;
        uint64_t idx = m->reqIndex, fm = m->firstMicro;
        const uint8_t *b = m->base;
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit(&m->seq, memory_order_relaxed) != q) continue;
        if (valid && idx == req) { *firstMicro = fm; *base = b; return true; }
    }
    return false;
}

static void *scanThread(void *arg) {
    (void)arg;
    pthread_setname_np("QuadCapture capture scanner");
    const double ticksPerUs = 1000.0 / gNsPerTick;
    thread_time_constraint_policy_data_t pol;
    pol.period = (uint32_t)(SCAN_PERIOD_US * ticksPerUs);
    pol.computation = (uint32_t)(150 * ticksPerUs);
    pol.constraint = (uint32_t)(500 * ticksPerUs);
    pol.preemptible = 1;
    kern_return_t kr = thread_policy_set(mach_thread_self(), THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&pol,
                                         THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    if (kr != KERN_SUCCESS) os_log_error(gLog, "scanner: real-time policy refused (%d)", kr);
    const uint64_t period = (uint64_t)(SCAN_PERIOD_US * ticksPerUs);
    uint64_t next = mach_absolute_time();
    while (!atomic_load(&gScanStop) && !atomic_load_explicit(&gStable, memory_order_acquire)) {
        next += period;
        mach_wait_until(next);
    }
    if (atomic_load(&gScanStop)) return NULL;

    uint64_t req = atomic_load(&gStableReq), expect = atomic_load(&gStableMicro);
    gZeroHost0 = hostOfMicroShared(expect);
    publishZero(0, gZeroHost0);
    const uint32_t fb = gInFmt.channels * gInFmt.subframe;
    const uint32_t slotFrames = gInFmt.maxPacket / fb;
    const uint32_t wordsPerFrame = fb / 4;
    uint64_t firstMicro = 0;
    const uint8_t *base = NULL;
    bool haveReq = false;
    int j = 0;
    uint32_t gapAcc = 0;
    bool sampled = false;
    next = mach_absolute_time();
    while (!atomic_load(&gScanStop)) {
        next += period;
        uint64_t now = mach_absolute_time();
        if (next < now) next = now + period;   // late (should not occur): do not run several times
        mach_wait_until(next);
        if (!sampled) {
            thread_extended_info_data_t info;
            mach_msg_type_number_t count = THREAD_EXTENDED_INFO_COUNT;
            mach_port_t th = mach_thread_self();
            if (thread_info(th, THREAD_EXTENDED_INFO, (thread_info_t)&info, &count) == KERN_SUCCESS)
                atomic_store(&gScanPriority, info.pth_curpri);
            mach_port_deallocate(mach_task_self(), th);
            sampled = true;
        }
        uint64_t rm, rh;
        loadRef(&rm, &rh);
        const double nowMicro = (double)rm + ((double)mach_absolute_time() - (double)rh) / gTicksPerMicro;
        for (;;) {
            if (!haveReq) {
                if (!findInRequest(req, &firstMicro, &base)) break;   // not queued yet
                haveReq = true;
                j = 0;
                if (firstMicro > expect) {
                    // Microframes skipped by a resync: put in silence, so sample time stays on the device clock.
                    uint32_t gap = (uint32_t)(firstMicro - expect);
                    uint32_t frames = nominalFrames(&gapAcc, gap);
                    appendCapture(NULL, frames, expect, gap, true);
                    atomic_fetch_add_explicit(&gStGap, frames, memory_order_relaxed);
                }
                expect = firstMicro;
            }
            const uint64_t m = firstMicro + (uint64_t)j;
            if ((double)(m + 1 + SCAN_DELAY_MICROFRAMES) > nowMicro) break;   // not old enough yet
            const uint32_t *pkt = (const uint32_t *)(base + (size_t)j * gInFmt.maxPacket);
            uint32_t frames = 0;
            while (frames < slotFrames) {
                const uint32_t *w = pkt + (size_t)frames * wordsPerFrame;
                bool marked = true;
                for (uint32_t k = 0; k < wordsPerFrame; k++)
                    if (w[k] != SENTINEL) { marked = false; break; }
                if (marked) break;
                frames++;
            }
            if (frames) appendCapture((const int32_t *)pkt, frames, m, 1, true);
            else atomic_fetch_add_explicit(&gStEmpty, 1, memory_order_relaxed);
            expect = m + 1;
            if (++j == gTpr) {
                atomic_store_explicit(&gScanDoneReq, req + 1, memory_order_release);
                req++;
                haveReq = false;
            }
        }
    }
    return NULL;
}

static void stopScanner(void) {
    if (!gScanThreadRunning) return;
    atomic_store(&gScanStop, true);
    pthread_join(gScanThread, NULL);
    gScanThreadRunning = false;
}

// Interest handler of the interfaces: the device disconnected (or the system reset it).
static IOUSBHostInterestHandler gInterest = ^(IOUSBHostObject *object, uint32_t messageType, void *argument) {
    (void)object; (void)argument;
    if (messageType == kIOMessageServiceIsTerminated && !atomic_exchange(&gDead, true)) {
        gStop = true;   // the handler runs on the USB queue
        os_log(gLog, "device disconnected while streaming");
    }
};

static void closeAll(void) {
    stopScanner();
    if (gIfIn) { [gIfIn selectAlternateSetting:0 error:nil]; [gIfIn destroy]; }
    if (gIfOut) { [gIfOut selectAlternateSetting:0 error:nil]; [gIfOut destroy]; }
    if (gDev) [gDev destroy];
    gIfIn = gIfOut = nil;
    gInPipe = gOutPipe = nil;
    gDev = nil;
    for (int i = 0; i < QC_MAX_REQUESTS; i++) gInData[i] = gOutData[i] = nil;
}

// Run a block on the USB queue and wait for it. A workloop does not accept dispatch_sync.
static void runOnQueue(dispatch_block_t block) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(gQueue, ^{
        block();
        dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
}

// Stop: no new requests, then wait until the queued requests complete (clean drain).
static void drain(void) {
    runOnQueue(^{ gStop = true; });
    __block int inFlight = 0;
    for (int i = 0; i < 100; i++) {
        runOnQueue(^{ inFlight = gInFlightIn + gInFlightOut; });
        if (inFlight == 0) break;
        usleep(10000);
    }
    if (inFlight) {
        os_log_error(gLog, "%d requests did not complete; abort", inFlight);
        [gInPipe abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
        [gOutPipe abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
    }
    stopScanner();
}

void qc_engine_configure(int requests, int microframes, uint32_t outputMarginFrames, uint32_t inputMarginFrames) {
    pthread_mutex_lock(&gLock);
    if (!atomic_load(&gRunning) && requests >= 2 && requests <= QC_MAX_REQUESTS && microframes >= 8 &&
        microframes <= QC_MAX_MICROFRAMES && microframes % 8 == 0) {
        gNumReq = requests;
        gTpr = microframes;
        gOutMargin = outputMarginFrames;
        gInMargin = inputMarginFrames;
    }
    pthread_mutex_unlock(&gLock);
}

void qc_engine_set_direct(int mask) {
    pthread_mutex_lock(&gLock);
    if (!atomic_load(&gRunning)) {
        gDirectWrite = (mask & QC_DIRECT_WRITE) != 0;
        gDirectRead = (mask & QC_DIRECT_READ) != 0;
    }
    pthread_mutex_unlock(&gLock);
}

void qc_engine_get_config(int *requests, int *microframes, uint32_t *outputMarginFrames, uint32_t *inputMarginFrames,
                          int *direct) {
    pthread_mutex_lock(&gLock);
    *requests = gNumReq;
    *microframes = gTpr;
    *outputMarginFrames = gOutMargin;
    *inputMarginFrames = gInMargin;
    *direct = (gDirectWrite ? QC_DIRECT_WRITE : 0) | (gDirectRead ? QC_DIRECT_READ : 0);
    pthread_mutex_unlock(&gLock);
}

bool qc_engine_rate_supported(uint32_t rate) {
    for (int i = 0; i < QC_NUM_RATES; i++)
        if (qc_engine_rates[i] == rate) return true;
    return false;
}

bool qc_engine_set_rate(uint32_t rate) {
    if (!qc_engine_rate_supported(rate)) return false;
    pthread_mutex_lock(&gLock);
    bool ok = !atomic_load(&gRunning);
    if (ok) gRate = rate;
    pthread_mutex_unlock(&gLock);
    return ok;
}

uint32_t qc_engine_get_rate(void) { return gRate; }

// Alternate setting of the audio interfaces for a rate.
static int altForRate(uint32_t rate) {
    for (int i = 0; i < QC_NUM_RATES; i++)
        if (qc_engine_rates[i] == rate) return i + 1;
    return 1;
}

// A margin of the configuration (frames at 44.1 kHz) at the current rate.
static uint32_t scaledMargin(uint32_t margin) { return (uint32_t)ceil((double)margin * gRate / 44100.0); }

uint32_t qc_engine_output_lead_frames(void) {
    if (gDirectWrite) return (uint32_t)ceil(GUARD_MICROFRAMES * (double)gRate / 8000.0) + scaledMargin(gOutMargin);
    return (uint32_t)ceil(gNumReq * gTpr * (double)gRate / 8000.0) + scaledMargin(gOutMargin);
}

uint32_t qc_engine_input_delay_frames(void) {
    if (gDirectRead) {
        const double micros = SCAN_DELAY_MICROFRAMES + 1 + SCAN_PERIOD_US / 125.0;
        return (uint32_t)ceil(micros * (double)gRate / 8000.0) + scaledMargin(gInMargin);
    }
    return (uint32_t)ceil(gTpr * (double)gRate / 8000.0) + scaledMargin(gInMargin);
}

// Read the clock of the device: the rate (Hz) and the flags (bit 0: change not complete, bit 1: error).
static bool readDeviceRate(IOUSBHostDevice *dev, uint32_t *rate, uint8_t *flags) {
    IOUSBDeviceRequest req = {.bmRequestType = 0xc0, .bRequest = 0x03, .wValue = 0x0001, .wIndex = 0, .wLength = 4};
    NSMutableData *data = [NSMutableData dataWithLength:4];
    NSUInteger done = 0;
    NSError *err = nil;
    if (![dev sendDeviceRequest:req data:data bytesTransferred:&done completionTimeout:1.0 error:&err] || done != 4) {
        os_log_error(gLog, "cannot read the device rate: %{public}s", err ? err.localizedDescription.UTF8String : "short reply");
        return false;
    }
    const uint8_t *b = data.bytes;
    *rate = b[0] | (b[1] << 8) | (b[2] << 16);
    *flags = b[3];
    return true;
}

// Set the clock of the device, if it is not at `rate`. The streams must be stopped.
// The device needs about 1 s; wait 8 s at most.
static bool setDeviceRate(IOUSBHostDevice *dev, uint32_t rate) {
    uint32_t cur;
    uint8_t flags;
    if (!readDeviceRate(dev, &cur, &flags)) return false;
    if (cur == rate && !(flags & 0x03)) return true;
    IOUSBDeviceRequest req = {.bmRequestType = 0x40, .bRequest = 0x03, .wValue = 0x0008, .wIndex = 0, .wLength = 4};
    uint8_t b[4] = {0x40, rate & 0xff, (rate >> 8) & 0xff, (rate >> 16) & 0xff};
    NSMutableData *data = [NSMutableData dataWithBytes:b length:4];
    NSUInteger done = 0;
    NSError *err = nil;
    if (![dev sendDeviceRequest:req data:data bytesTransferred:&done completionTimeout:1.0 error:&err]) {
        os_log_error(gLog, "cannot set the device rate: %{public}s", err.localizedDescription.UTF8String);
        return false;
    }
    // The first status after the request can still show the old rate.
    for (int i = 0; i < 40; i++) {
        usleep(200000);
        if (!readDeviceRate(dev, &cur, &flags)) return false;
        if (flags & 0x02) { os_log_error(gLog, "the device reports an error for %u Hz", rate); return false; }
        if (cur == rate && !(flags & 0x01)) {
            os_log(gLog, "device clock changed to %u Hz in %d ms", rate, (i + 1) * 200);
            return true;
        }
    }
    os_log_error(gLog, "the device clock did not change to %u Hz in 8 s", rate);
    return false;
}

bool qc_engine_device_present(void) {
    io_service_t s = findDevice();
    if (!s) return false;
    IOObjectRelease(s);
    return true;
}

bool qc_engine_is_running(void) { return atomic_load(&gRunning); }

int qc_engine_start(void) {
    @autoreleasepool {
        pthread_mutex_lock(&gLock);
        if (!gLog) gLog = os_log_create("com.louistissot.quadcapture", "engine");
        if (atomic_load(&gRunning)) { pthread_mutex_unlock(&gLock); return 0; }
        if (!gQueue)
            gQueue = dispatch_queue_create("com.louistissot.quadcapture.usb",
                                           dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                                   QOS_CLASS_USER_INTERACTIVE, 0));
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        gNsPerTick = (double)tb.numer / tb.denom;
        gTicksPerMicro = 125000.0 / gNsPerTick;

        int rc = 0;
        NSError *err = nil;
        io_service_t devSvc = findDevice();
        if (!devSvc) { os_log_error(gLog, "QUAD-CAPTURE not found"); rc = -1; goto fail; }
        gDev = [[IOUSBHostDevice alloc] initWithIOService:devSvc options:IOUSBHostObjectInitOptionsNone
                                                    queue:nil error:&err interestHandler:nil];
        IOObjectRelease(devSvc);
        if (!gDev) {
            os_log_error(gLog, "cannot open the device: %{public}s", err.localizedDescription.UTF8String);
            rc = -2; goto fail;
        }
        const int alt = altForRate(gRate);
        const IOUSBConfigurationDescriptor *cd = [gDev configurationDescriptorWithIndex:0 error:&err];
        if (!cd || !parseFormat(cd, 1, alt, &gInFmt) || !parseFormat(cd, 0, alt, &gOutFmt) ||
            gInFmt.subframe != 4 || gOutFmt.subframe != 4 || gInFmt.channels < 2 || gOutFmt.channels < 2 ||
            gInFmt.rate != gRate || gOutFmt.rate != gRate) {
            os_log_error(gLog, "unexpected descriptors for %u Hz", gRate);
            rc = -3; goto fail;
        }
        if (!gDev.configurationDescriptor && ![gDev configureWithValue:1 matchInterfaces:YES error:&err]) {
            os_log_error(gLog, "cannot set configuration 1: %{public}s", err.localizedDescription.UTF8String);
            rc = -3; goto fail;
        }
        // The audio interfaces are at alternate setting 0 (no stream) here: set the device clock.
        if (!setDeviceRate(gDev, gRate)) { rc = -10; goto fail; }
        io_service_t s0 = waitForInterface(0), s1 = waitForInterface(1);
        if (!s0 || !s1) { os_log_error(gLog, "audio interfaces did not appear"); rc = -4; goto fail; }
        // The device object is necessary only for the configuration: close it, so that other
        // components (for example a MIDI driver on interface 2) can open the device.
        [gDev destroy];
        gDev = nil;
        gIfOut = [[IOUSBHostInterface alloc] initWithIOService:s0 options:IOUSBHostObjectInitOptionsNone
                                                         queue:gQueue error:&err interestHandler:gInterest];
        gIfIn = [[IOUSBHostInterface alloc] initWithIOService:s1 options:IOUSBHostObjectInitOptionsNone
                                                        queue:gQueue error:&err interestHandler:gInterest];
        IOObjectRelease(s0);
        IOObjectRelease(s1);
        if (!gIfOut || !gIfIn) {
            os_log_error(gLog, "cannot open the interfaces: %{public}s", err.localizedDescription.UTF8String);
            rc = -4; goto fail;
        }
        // Capture first, then playback, each through alternate setting 0, as the Roland driver does.
        if (![gIfIn selectAlternateSetting:0 error:&err] || ![gIfIn selectAlternateSetting:alt error:&err] ||
            ![gIfOut selectAlternateSetting:0 error:&err] || ![gIfOut selectAlternateSetting:alt error:&err]) {
            os_log_error(gLog, "cannot select alternate setting: %{public}s", err.localizedDescription.UTF8String);
            rc = -5; goto fail;
        }
        gOutPipe = [gIfOut copyPipeWithAddress:gOutFmt.ep error:&err];
        gInPipe = [gIfIn copyPipeWithAddress:gInFmt.ep error:&err];
        if (!gOutPipe || !gInPipe) { os_log_error(gLog, "cannot open the pipes"); rc = -6; goto fail; }
        gHasMicroAPI = [gIfIn respondsToSelector:@selector(currentMicroframeWithTime:error:)] &&
                       getenv("QC_FORCE_FRAME_CLOCK") == NULL;
        for (int i = 0; i < gNumReq; i++) {
            gInData[i] = [gIfIn ioDataWithCapacity:gTpr * gInFmt.maxPacket error:&err];
            gOutData[i] = [gIfOut ioDataWithCapacity:gTpr * gOutFmt.maxPacket error:&err];
            if (!gInData[i] || !gOutData[i]) { os_log_error(gLog, "cannot allocate I/O buffers"); rc = -7; goto fail; }
        }

        memset(gInRing, 0, sizeof(gInRing));
        memset(gOutRing, 0, sizeof(gOutRing));
        atomic_store(&gStable, false);
        atomic_store(&gDead, false);
        atomic_store(&gInWritePos, 0);
        atomic_store(&gOutReadPos, INT64_MAX);
        atomic_fetch_add(&gZSeed, 1);
        atomic_store(&gStInputMissing, 0); atomic_store(&gStOutputLate, 0); atomic_store(&gStEmpty, 0);
        atomic_store(&gStInErr, 0); atomic_store(&gStOutErr, 0); atomic_store(&gStZero, 0);
        atomic_store(&gStResync, 0); atomic_store(&gStGap, 0);
        atomic_store(&gStDirect, 0); atomic_store(&gStRing, 0); atomic_store(&gStRace, 0);
        atomic_store(&gScanDoneReq, 0);
        atomic_store(&gStableReq, 0);
        atomic_store(&gScanPriority, 0);
        if (gDirectRead) {
            atomic_store(&gScanStop, false);
            pthread_attr_t attr;
            pthread_attr_init(&attr);
            pthread_attr_setstacksize(&attr, 256 * 1024);
            if (pthread_create(&gScanThread, &attr, scanThread, NULL) == 0) gScanThreadRunning = true;
            pthread_attr_destroy(&attr);
            if (!gScanThreadRunning) { os_log_error(gLog, "cannot create the scanner thread"); rc = -9; goto fail; }
        }
        runOnQueue(^{
            gStop = false;
            gInFlightIn = gInFlightOut = 0;
            gFifoHead = gFifoTail = gNominalAcc = gGapAcc = 0;
            gConsec = 0;
            gS = 0;
            gOutPos = 0;
            gOutOffset = 0;
            gOutMapped = false;
            gInLagMax = gOutLagMax = 0;
            for (int i = 0; i < QC_MAX_REQUESTS; i++) {
                setMapValid(&gOutMap[i], false);
                setInMapValid(&gInMap[i], false);
            }
            gInReqIndex = 0;
            memset(gInLagHist, 0, sizeof(gInLagHist));
            memset(gOutLagHist, 0, sizeof(gOutLagHist));
            gFrameEstValid = false;
            gFrameEstOutliers = 0;
            for (int i = 0; i < 16; i++) refreshRef(gIfIn);   // fallback clock: a first estimate
            uint64_t now = [gIfIn frameNumberWithTime:NULL];
            gNextOutFrame = gNextInFrame = now + 8;   // playback and capture start in the same frame
            gInExpectMicro = gNextInFrame * 8;
            for (int i = 0; i < gNumReq; i++) enqueueOut(i);
            for (int i = 0; i < gNumReq; i++) enqueueIn(i);
        });
        atomic_store(&gRunning, true);

        for (int i = 0; i < 300 && !atomic_load(&gStable); i++) usleep(10000);
        // Wait until all queued playback requests were queued after the start of sample time, so
        // each has a map for direct writes (the queue depth, at most 300 ms).
        if (atomic_load(&gStable)) {
            const useconds_t depthUs = (useconds_t)gNumReq * (useconds_t)gTpr * 125;
            usleep(depthUs + 2000);
        }
        if (!atomic_load(&gStable)) {
            os_log_error(gLog, "capture data did not become stable in 3 s");
            drain();
            atomic_store(&gRunning, false);
            rc = -8; goto fail;
        }
        os_log(gLog, "engine started: %u Hz; %d requests x %d microframes; output lead %u, input delay %u frames; "
                     "%{public}s clock; direct write %{public}s, direct read %{public}s",
               gRate, gNumReq, gTpr, qc_engine_output_lead_frames(), qc_engine_input_delay_frames(),
               gHasMicroAPI ? "microframe" : "frame (smoothed)", gDirectWrite ? "on" : "off", gDirectRead ? "on" : "off");
        pthread_mutex_unlock(&gLock);
        return 0;

    fail:
        closeAll();
        pthread_mutex_unlock(&gLock);
        return rc;
    }
}

void qc_engine_stop(void) {
    @autoreleasepool {
        pthread_mutex_lock(&gLock);
        if (atomic_load(&gRunning)) {
            atomic_store(&gStable, false);
            drain();
            atomic_store(&gRunning, false);
            closeAll();
            os_log(gLog, "engine stopped");
        }
        pthread_mutex_unlock(&gLock);
    }
}

bool qc_engine_zero_timestamp(double *sampleTime, uint64_t *hostTime, uint64_t *seed) {
    if (!atomic_load_explicit(&gRunning, memory_order_acquire) || !atomic_load_explicit(&gStable, memory_order_acquire) ||
        atomic_load_explicit(&gDead, memory_order_relaxed))
        return false;
    for (;;) {
        uint32_t a = atomic_load_explicit(&gZSeq, memory_order_acquire);
        if (a & 1) continue;
        int64_t s = atomic_load_explicit(&gZSample, memory_order_relaxed);
        uint64_t h = atomic_load_explicit(&gZHost, memory_order_relaxed);
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit(&gZSeq, memory_order_relaxed) == a) {
            *sampleTime = (double)s;
            *hostTime = h;
            *seed = atomic_load_explicit(&gZSeed, memory_order_relaxed);
            return true;
        }
    }
}

void qc_engine_read_input(int64_t sampleTime, uint32_t frames, float *dst) {
    int64_t w = atomic_load_explicit(&gInWritePos, memory_order_acquire);
    uint64_t missing = 0;
    for (uint32_t i = 0; i < frames; i++) {
        int64_t pos = sampleTime + i;
        float *d = dst + (size_t)i * QC_IN_CHANNELS;
        if (pos < 0 || pos >= w || pos < w - QC_RING_FRAMES) {
            if (pos >= w) missing++;
            for (int c = 0; c < QC_IN_CHANNELS; c++) d[c] = 0.0f;
            continue;
        }
        const float *s = &gInRing[(pos & RING_MASK) * QC_IN_CHANNELS];
        for (int c = 0; c < QC_IN_CHANNELS; c++) d[c] = s[c];
    }
    if (missing) atomic_fetch_add_explicit(&gStInputMissing, missing, memory_order_relaxed);
}

static void writeRing(int64_t pos, const float *s) {
    float *d = &gOutRing[(pos & RING_MASK) * QC_OUT_CHANNELS];
    for (int c = 0; c < QC_OUT_CHANNELS; c++) d[c] = s[c];
}

void qc_engine_write_output(int64_t sampleTime, uint32_t frames, const float *src) {
    const int64_t r = atomic_load_explicit(&gOutReadPos, memory_order_acquire);
    uint64_t late = 0, direct = 0, ring = 0, race = 0;
    if (!gDirectWrite || !atomic_load_explicit(&gStable, memory_order_acquire)) {
        for (uint32_t i = 0; i < frames; i++) {
            int64_t pos = sampleTime + i;
            if (pos < r || pos < 0) { late++; continue; }
            if (r != INT64_MAX && pos >= r + QC_RING_FRAMES) continue;
            writeRing(pos, src + (size_t)i * QC_OUT_CHANNELS);
        }
        if (late) atomic_fetch_add_explicit(&gStOutputLate, late, memory_order_relaxed);
        return;
    }

    // Current microframe, from the clock reference of the USB queue.
    uint64_t refMicro, refHost;
    for (;;) {
        uint32_t a = atomic_load_explicit(&gRefSeq, memory_order_acquire);
        if (a & 1) continue;
        refMicro = atomic_load_explicit(&gRefMicroA, memory_order_relaxed);
        refHost = atomic_load_explicit(&gRefHostA, memory_order_relaxed);
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit(&gRefSeq, memory_order_relaxed) == a) break;
    }
    const double nowMicro = (double)refMicro + ((double)mach_absolute_time() - (double)refHost) / gTicksPerMicro;
    const double limitMicro = nowMicro + GUARD_MICROFRAMES;
    const uint32_t ch = (uint32_t)gOutFmt.channels;
    const uint32_t used = ch < QC_OUT_CHANNELS ? ch : QC_OUT_CHANNELS;   // 2 at 192 kHz

    // Work in chunks, with a flag for each frame that a queued request received.
    uint32_t done = 0;
    while (done < frames) {
        enum { CHUNK = 512 };
        const uint32_t n = frames - done < CHUNK ? frames - done : CHUNK;
        const int64_t t0 = sampleTime + done;
        bool covered[CHUNK];
        memset(covered, 0, n);
        for (int s = 0; s < gNumReq; s++) {
            OutMap *m = &gOutMap[s];
            uint32_t q1 = atomic_load_explicit(&m->seq, memory_order_acquire);
            if ((q1 & 1) || !m->valid) continue;
            const int64_t a = t0 > m->firstT ? t0 : m->firstT;
            const int64_t endT = m->firstT + (int64_t)m->frames;
            const int64_t b = (t0 + n) < endT ? (t0 + n) : endT;
            if (a >= b) continue;
            int tx = 0;
            for (int64_t t = a; t < b; t++) {
                const uint32_t rel = (uint32_t)(t - m->firstT);
                while (tx < gTpr - 1 && m->cum[tx + 1] <= rel) tx++;
                covered[t - t0] = true;
                if ((double)(m->firstMicro + (uint64_t)tx) < limitMicro) { late++; continue; }
                int32_t *o = (int32_t *)(m->base + (size_t)rel * ch * 4);
                const float *v = src + (size_t)(t - sampleTime) * QC_OUT_CHANNELS;
                for (uint32_t c = 0; c < used; c++) o[c] = floatToSample(v[c]);
                direct++;
            }
            atomic_thread_fence(memory_order_seq_cst);
            if (atomic_load_explicit(&m->seq, memory_order_relaxed) != q1) race++;
        }
        for (uint32_t i = 0; i < n; i++) {
            if (covered[i]) continue;
            const int64_t pos = t0 + i;
            if (pos < r || pos < 0) { late++; continue; }   // already sent
            if (pos >= r + QC_RING_FRAMES) continue;
            writeRing(pos, src + (size_t)(pos - sampleTime) * QC_OUT_CHANNELS);   // a later request reads it
            ring++;
        }
        done += n;
    }
    if (late) atomic_fetch_add_explicit(&gStOutputLate, late, memory_order_relaxed);
    if (direct) atomic_fetch_add_explicit(&gStDirect, direct, memory_order_relaxed);
    if (ring) atomic_fetch_add_explicit(&gStRing, ring, memory_order_relaxed);
    if (race) atomic_fetch_add_explicit(&gStRace, race, memory_order_relaxed);
}

void qc_engine_get_stats(QCEngineStats *st) {
    memset(st, 0, sizeof(*st));
    st->inputFrames = (uint64_t)atomic_load(&gInWritePos);
    st->inputMissing = atomic_load(&gStInputMissing);
    st->outputLate = atomic_load(&gStOutputLate);
    st->emptyPackets = atomic_load(&gStEmpty);
    st->inErrors = atomic_load(&gStInErr);
    st->outErrors = atomic_load(&gStOutErr);
    st->resyncs = atomic_load(&gStResync);
    st->gapFrames = atomic_load(&gStGap);
    st->zeroTimestamps = atomic_load(&gStZero);
    // The lag values change on the USB queue; a copy without a lock is sufficient for statistics.
    st->inLagMaxMs = gInLagMax;
    st->outLagMaxMs = gOutLagMax;
    memcpy(st->inLagHist, gInLagHist, sizeof(gInLagHist));
    memcpy(st->outLagHist, gOutLagHist, sizeof(gOutLagHist));
    st->directFrames = atomic_load(&gStDirect);
    st->ringFrames = atomic_load(&gStRing);
    st->races = atomic_load(&gStRace);
    st->scannerPriority = atomic_load(&gScanPriority);
    st->callbackPriority = atomic_load(&gCbPriority);
    st->callbackPolicy = atomic_load(&gCbPolicy);
    double s;
    uint64_t h, seed;
    if (qc_engine_zero_timestamp(&s, &h, &seed) && s > 0 && h > gZeroHost0)
        st->measuredRate = s / ((double)(h - gZeroHost0) * gNsPerTick * 1e-9);
}

#pragma mark Device presence

static QCPresenceCallback gPresenceCallback;
static IONotificationPortRef gNotifyPort;
static io_iterator_t gArriveIter, gLeaveIter;
static dispatch_queue_t gPresenceQueue;
static bool gLastPresent;

static void drainIterator(io_iterator_t it) {
    io_object_t o;
    while ((o = IOIteratorNext(it))) IOObjectRelease(o);
}

// Set the USB configuration as soon as the device connects, as the Roland driver does: the device
// then shows that it is ready (its lights change), and its interfaces exist for all clients.
static void prepareDevice(void) {
    @autoreleasepool {
        pthread_mutex_lock(&gLock);
        if (!atomic_load(&gRunning)) {
            io_service_t svc = findDevice();
            if (svc) {
                NSError *err = nil;
                IOUSBHostDevice *d = [[IOUSBHostDevice alloc] initWithIOService:svc options:IOUSBHostObjectInitOptionsNone
                                                                          queue:nil error:&err interestHandler:nil];
                IOObjectRelease(svc);
                if (d) {
                    if (!d.configurationDescriptor) {
                        if ([d configureWithValue:1 matchInterfaces:YES error:&err]) os_log(gLog, "device configured");
                        else os_log_error(gLog, "cannot configure the device: %{public}s", err.localizedDescription.UTF8String);
                    }
                    [d destroy];
                }
            }
        }
        pthread_mutex_unlock(&gLock);
    }
}

static void presenceChanged(void *refcon, io_iterator_t it) {
    (void)refcon;
    drainIterator(it);
    bool present = qc_engine_device_present();
    if (present == gLastPresent) return;
    gLastPresent = present;
    if (gLog) os_log(gLog, "QUAD-CAPTURE %{public}s", present ? "connected" : "disconnected");
    if (present) prepareDevice();
    if (gPresenceCallback) gPresenceCallback(present);
}

void qc_engine_watch_device(QCPresenceCallback callback) {
    if (!gLog) gLog = os_log_create("com.louistissot.quadcapture", "engine");
    if (gNotifyPort) return;
    gPresenceCallback = callback;
    gPresenceQueue = dispatch_queue_create("com.louistissot.quadcapture.presence", DISPATCH_QUEUE_SERIAL);
    gNotifyPort = IONotificationPortCreate(kIOMainPortDefault);
    IONotificationPortSetDispatchQueue(gNotifyPort, gPresenceQueue);
    dispatch_sync(gPresenceQueue, ^{
        CFMutableDictionaryRef m1 =
            [IOUSBHostDevice createMatchingDictionaryWithVendorID:@QC_VID productID:@QC_PID bcdDevice:nil deviceClass:nil
                                                   deviceSubclass:nil deviceProtocol:nil speed:nil productIDArray:nil];
        CFMutableDictionaryRef m2 = (CFMutableDictionaryRef)CFRetain(m1);
        IOServiceAddMatchingNotification(gNotifyPort, kIOFirstMatchNotification, m1, presenceChanged, NULL, &gArriveIter);
        IOServiceAddMatchingNotification(gNotifyPort, kIOTerminatedNotification, m2, presenceChanged, NULL, &gLeaveIter);
        drainIterator(gArriveIter);
        drainIterator(gLeaveIter);
        gLastPresent = qc_engine_device_present();
        if (gLastPresent) prepareDevice();
        if (gPresenceCallback) gPresenceCallback(gLastPresent);
    });
}
