// qc_engine: USB audio engine for the Roland QUAD-CAPTURE. See qc_engine.h.
//
// USB protocol (from the descriptors and the Linux snd-usb-audio driver):
//   interface 0, alternate setting 1: playback, isochronous OUT endpoint 0x05, 4 ch
//   interface 1, alternate setting 1: capture, isochronous IN endpoint 0x85, 6 ch (implicit feedback)
//   44.1 kHz, 24-bit samples left-justified in 32-bit words.
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
#include <AudioToolbox/AudioWorkInterval.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
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
#define QC_ALT 1
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
static int gSchedMode = 0, gQueueMode = -1;
static os_workgroup_interval_t gWorkgroup;
static _Atomic int gCbPriority, gCbPolicy;

// Configuration (changed only while the engine does not run).
static int gNumReq = 16, gTpr = 16;               // 32 ms queue
static uint32_t gOutMargin = 441, gInMargin = 441;  // 10 ms margins

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
static void refreshRef(IOUSBHostInterface *iface) {
    IOUSBHostTime t = 0;
    if (gHasMicroAPI) {
        uint64_t cur = [iface currentMicroframeWithTime:&t error:nil];
        if (cur && t) { gRefMicro = cur; gRefHost = t; }
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
    static const double edges[QC_LAG_BUCKETS - 1] = {0.5, 1, 2, 4, 8, 16, 32};
    int b = 0;
    while (b < QC_LAG_BUCKETS - 1 && ms >= edges[b]) b++;
    hist[b]++;
}

// Append capture frames (or silence if src is NULL) that span `micros` microframes from microStart.
// Publish the zero timestamps that fall inside, with the host time interpolated over the span.
static void appendCapture(const int32_t *src, uint32_t frames, uint64_t microStart, uint32_t micros) {
    if (frames == 0) return;
    for (uint32_t f = 0; f < frames; f++) {
        float *dst = &gInRing[((gS + f) & RING_MASK) * QC_IN_CHANNELS];
        for (int c = 0; c < QC_IN_CHANNELS; c++)
            dst[c] = src ? (float)src[f * gInFmt.channels + c] * (1.0f / 2147483648.0f) : 0.0f;
    }
    while (gNextZero < gS + frames) {
        double frac = (double)(gNextZero - gS) / frames;
        uint64_t h = hostOfMicro(microStart) + (uint64_t)(frac * micros * gTicksPerMicro);
        publishZero(gNextZero, h);
        gNextZero += QC_ZERO_PERIOD;
    }
    gS += frames;
    atomic_store_explicit(&gInWritePos, gS, memory_order_release);
}

static void enqueueIn(int slot);
static void enqueueOut(int slot);

// Mode 2: give the callback thread a real-time (time-constraint) policy, once for each thread.
static void promoteThread(void) {
    static __thread bool done;
    if (gSchedMode < 2 || done) return;
    done = true;
    double ticksPerUs = 1000.0 / gNsPerTick;
    thread_time_constraint_policy_data_t pol;
    pol.period = (uint32_t)(gTpr * 125 * ticksPerUs);
    pol.computation = (uint32_t)(200 * ticksPerUs);
    pol.constraint = (uint32_t)(gTpr * 125 * ticksPerUs);
    pol.preemptible = 1;
    kern_return_t kr = thread_policy_set(mach_thread_self(), THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&pol,
                                         THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    if (kr != KERN_SUCCESS) os_log_error(gLog, "thread_policy_set failed: %d", kr);
}

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

static void onInDone(int slot, IOReturn status, IOUSBHostIsochronousTransaction *list) {
    gInFlightIn--;
    if (gStop || status == kIOReturnAborted) return;
    promoteThread();
    sampleThread();

    refreshRef(gIfIn);
    const uint64_t slotMicro = gInSlotMicro[slot];
    recordLag(slotMicro + gTpr, &gInLagMax, gInLagHist);

    bool stable = atomic_load_explicit(&gStable, memory_order_relaxed);
    // Microframes skipped by a resync: put in silence, so sample time stays on the device clock.
    if (stable && slotMicro > gInExpectMicro) {
        uint32_t gap = (uint32_t)(slotMicro - gInExpectMicro);
        uint32_t frames = nominalFrames(&gGapAcc, gap);
        appendCapture(NULL, frames, gInExpectMicro, gap);
        atomic_fetch_add_explicit(&gStGap, frames, memory_order_relaxed);
    }
    gInExpectMicro = slotMicro + gTpr;

    const uint32_t fb = gInFmt.channels * gInFmt.subframe;
    const uint8_t *base = gInData[slot].bytes;
    for (int i = 0; i < gTpr; i++) {
        uint64_t m = slotMicro + i;
        IOReturn st = list[i].status;
        uint32_t frames = 0;
        bool ok = (st == kIOReturnSuccess || st == kIOReturnUnderrun);
        if (ok) frames = list[i].completeCount / fb;
        else atomic_fetch_add_explicit(&gStInErr, 1, memory_order_relaxed);

        // Implicit feedback: the size of each playback packet follows the size of a capture packet.
        if (((gFifoHead + 1) % FIFO_LEN) != gFifoTail) {
            gFifo[gFifoHead] = frames;
            gFifoHead = (gFifoHead + 1) % FIFO_LEN;
        }

        if (!stable) {
            gConsec = frames ? gConsec + 1 : 0;
            if (gConsec >= STABLE_MICROFRAMES) {
                // Sample time 0 is the first frame of the next microframe.
                uint64_t m0 = m + 1;
                gS = 0;
                gNextZero = QC_ZERO_PERIOD;
                gZeroHost0 = hostOfMicro(m0);
                atomic_store_explicit(&gInWritePos, 0, memory_order_release);
                publishZero(0, gZeroHost0);
                // Map the playback stream position to sample time: the next playback frame goes out at
                // microframe gOutFillEndMicro, when the device is at about this sample time.
                double expected = (double)((int64_t)gOutFillEndMicro - (int64_t)m0) * gOutFmt.rate / 8000.0;
                gOutOffset = (int64_t)llround(expected) - gOutPos;
                gOutMapped = true;
                atomic_store_explicit(&gOutReadPos, gOutPos + gOutOffset, memory_order_release);
                atomic_store_explicit(&gStable, true, memory_order_release);
                stable = true;
                os_log(gLog, "stream stable at microframe %llu; output offset %lld", m0, gOutOffset);
            }
            continue;
        }
        if (!ok) {
            // A lost capture packet: put in silence with the nominal size.
            appendCapture(NULL, nominalFrames(&gGapAcc, 1), m, 1);
            continue;
        }
        if (frames == 0) {
            atomic_fetch_add_explicit(&gStEmpty, 1, memory_order_relaxed);
            continue;
        }
        appendCapture((const int32_t *)(base + list[i].offset), frames, m, 1);
    }
    enqueueIn(slot);
}

static void onOutDone(int slot, IOReturn status, IOUSBHostIsochronousTransaction *list) {
    gInFlightOut--;
    if (gStop || status == kIOReturnAborted) return;
    promoteThread();
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

static void enqueueIn(int slot) {
    IOUSBHostIsochronousTransaction *tx = gInTx[slot];
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
                o[c] = floatToSample(r[c]);
                r[c] = 0.0f;   // a frame that the client does not write again plays as silence
            }
        }
        gOutPos += frames;
        off += frames * fb;
    }
}

static void enqueueOut(int slot) {
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

// Interest handler of the interfaces: the device disconnected (or the system reset it).
static IOUSBHostInterestHandler gInterest = ^(IOUSBHostObject *object, uint32_t messageType, void *argument) {
    (void)object; (void)argument;
    if (messageType == kIOMessageServiceIsTerminated && !atomic_exchange(&gDead, true)) {
        gStop = true;   // the handler runs on the USB queue
        os_log(gLog, "device disconnected while streaming");
    }
};

static void closeAll(void) {
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

void qc_engine_set_scheduling(int mode) {
    pthread_mutex_lock(&gLock);
    if (!atomic_load(&gRunning) && mode >= 0 && mode <= 2) gSchedMode = mode;
    pthread_mutex_unlock(&gLock);
}

void qc_engine_get_config(int *requests, int *microframes, uint32_t *outputMarginFrames, uint32_t *inputMarginFrames,
                          int *schedulingMode) {
    pthread_mutex_lock(&gLock);
    *requests = gNumReq;
    *microframes = gTpr;
    *outputMarginFrames = gOutMargin;
    *inputMarginFrames = gInMargin;
    *schedulingMode = gSchedMode;
    pthread_mutex_unlock(&gLock);
}

uint32_t qc_engine_output_lead_frames(void) {
    return (uint32_t)ceil(gNumReq * gTpr * QC_SAMPLE_RATE / 8000.0) + gOutMargin;
}

uint32_t qc_engine_input_delay_frames(void) {
    return (uint32_t)ceil(gTpr * QC_SAMPLE_RATE / 8000.0) + gInMargin;
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
        if (!gQueue || gQueueMode != (gSchedMode > 0)) {
            if (gSchedMode > 0) {
                // A workloop in an audio workgroup: its thread uses the scheduling of the workgroup.
                dispatch_workloop_t wl = dispatch_workloop_create_inactive("com.louistissot.quadcapture.usb");
                if (!gWorkgroup) gWorkgroup = AudioWorkIntervalCreate("QuadCapture USB", OS_CLOCK_MACH_ABSOLUTE_TIME, NULL);
                if (gWorkgroup) dispatch_workloop_set_os_workgroup(wl, gWorkgroup);
                dispatch_activate(wl);
                gQueue = wl;
            } else {
                gQueue = dispatch_queue_create("com.louistissot.quadcapture.usb",
                                               dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                                       QOS_CLASS_USER_INTERACTIVE, 0));
            }
            gQueueMode = gSchedMode > 0;
        }
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
        const IOUSBConfigurationDescriptor *cd = [gDev configurationDescriptorWithIndex:0 error:&err];
        if (!cd || !parseFormat(cd, 1, QC_ALT, &gInFmt) || !parseFormat(cd, 0, QC_ALT, &gOutFmt) ||
            gInFmt.subframe != 4 || gOutFmt.subframe != 4 ||
            gInFmt.channels < QC_IN_CHANNELS || gOutFmt.channels < QC_OUT_CHANNELS) {
            os_log_error(gLog, "unexpected descriptors");
            rc = -3; goto fail;
        }
        if (!gDev.configurationDescriptor && ![gDev configureWithValue:1 matchInterfaces:YES error:&err]) {
            os_log_error(gLog, "cannot set configuration 1: %{public}s", err.localizedDescription.UTF8String);
            rc = -3; goto fail;
        }
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
        if (![gIfOut selectAlternateSetting:QC_ALT error:&err] || ![gIfIn selectAlternateSetting:QC_ALT error:&err]) {
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
        if (!atomic_load(&gStable)) {
            os_log_error(gLog, "capture data did not become stable in 3 s");
            drain();
            atomic_store(&gRunning, false);
            rc = -8; goto fail;
        }
        os_log(gLog, "engine started: %d requests x %d microframes; output lead %u, input delay %u frames; %{public}s clock",
               gNumReq, gTpr, qc_engine_output_lead_frames(), qc_engine_input_delay_frames(),
               gHasMicroAPI ? "microframe" : "frame (smoothed)");
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

void qc_engine_write_output(int64_t sampleTime, uint32_t frames, const float *src) {
    int64_t r = atomic_load_explicit(&gOutReadPos, memory_order_acquire);
    uint64_t late = 0;
    for (uint32_t i = 0; i < frames; i++) {
        int64_t pos = sampleTime + i;
        if (pos < r || pos < 0) { late++; continue; }
        if (r != INT64_MAX && pos >= r + QC_RING_FRAMES) continue;
        float *d = &gOutRing[(pos & RING_MASK) * QC_OUT_CHANNELS];
        const float *s = src + (size_t)i * QC_OUT_CHANNELS;
        for (int c = 0; c < QC_OUT_CHANNELS; c++) d[c] = s[c];
    }
    if (late) atomic_fetch_add_explicit(&gStOutputLate, late, memory_order_relaxed);
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

static void presenceChanged(void *refcon, io_iterator_t it) {
    (void)refcon;
    drainIterator(it);
    bool present = qc_engine_device_present();
    if (present == gLastPresent) return;
    gLastPresent = present;
    if (gLog) os_log(gLog, "QUAD-CAPTURE %{public}s", present ? "connected" : "disconnected");
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
        if (gPresenceCallback) gPresenceCallback(gLastPresent);
    });
}
