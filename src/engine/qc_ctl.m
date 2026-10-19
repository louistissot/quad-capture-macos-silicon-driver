// qc_ctl: see qc_ctl.h.
#import "qc_ctl.h"
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>
#include <notify.h>
#include <os/log.h>

#define QC_VID 0x0582
#define QC_PID 0x012f
#define CTL_INTERFACE 2
#define EP_IN 0x86
#define IN_SIZE 512
#define IN_REQUESTS 2
#define STATUS_INTERFACE 3
#define EP_STATUS 0x82

static os_log_t gLog;
static dispatch_queue_t gQueue;   // all state below
static IOUSBHostInterface *gIface;
static IOUSBHostPipe *gInPipe;
static NSMutableData *gBuf[IN_REQUESTS];
static uint64_t gGeneration;      // changes at each close, so old completions do nothing
static dispatch_time_t gReleasedUntil;
static uint64_t gMessages;
static dispatch_source_t gTimer;  // must stay referenced: ARC frees an unreferenced source
static int gTick;
static dispatch_time_t gStatusReleasedUntil;

// Status (interface 3).
static IOUSBHostInterface *gStIface;
static IOUSBHostPipe *gStPipe;
static NSMutableData *gStBuf;
static uint64_t gStGeneration;
static bool gStBusy;              // a status read is in flight
static int gStReads;              // reads in the current poll
static QCStatusCallback gStCallback;
static bool gStKnown;
static uint32_t gStRate;
static bool gStExternal, gStLocked;

static io_service_t findInterface(int number) {
    CFMutableDictionaryRef m =
        [IOUSBHostInterface createMatchingDictionaryWithVendorID:@QC_VID productID:@QC_PID bcdDevice:nil
                                                 interfaceNumber:@(number) configurationValue:@1
                                                  interfaceClass:nil interfaceSubclass:nil
                                               interfaceProtocol:nil speed:nil productIDArray:nil];
    return IOServiceGetMatchingService(kIOMainPortDefault, m);
}

static void closeStatus(const char *why) {
    if (!gStIface) return;
    gStGeneration++;
    gStBusy = false;
    [gStIface selectAlternateSetting:0 error:nil];
    [gStIface destroy];
    gStIface = nil;
    gStPipe = nil;
    gStBuf = nil;
    gStKnown = false;
    os_log(gLog, "interface 3 released (%{public}s)", why);
}

static void closeIface(const char *why) {
    if (!gIface) return;
    gGeneration++;
    [gIface destroy];   // aborts the queued reads
    gIface = nil;
    gInPipe = nil;
    for (int k = 0; k < IN_REQUESTS; k++) gBuf[k] = nil;
    os_log(gLog, "interface 2 released (%{public}s); %llu control packets read", why, gMessages);
}

static void readNext(int k);

static void onRead(int k, uint64_t gen, IOReturn status, NSUInteger n) {
    if (gen != gGeneration || !gIface) return;
    if (status != kIOReturnSuccess) {
        closeIface("read error");
        return;
    }
    // Count the packets of cable 1 (SENS knobs, AUTO-SENS). Nothing else is necessary: the device
    // only needs a reader.
    const uint8_t *p = gBuf[k].bytes;
    for (NSUInteger i = 0; i + 4 <= n; i += 4)
        if ((p[i] >> 4) == 1 && (p[i] & 0x0F) != 0) gMessages++;
    readNext(k);
}

static void readNext(int k) {
    if (!gIface) return;
    const uint64_t gen = gGeneration;
    NSError *err = nil;
    if (![gInPipe enqueueIORequestWithData:gBuf[k] completionTimeout:0 error:&err
                         completionHandler:^(IOReturn status, NSUInteger n) {
                             dispatch_async(gQueue, ^{ onRead(k, gen, status, n); });
                         }])
        closeIface("cannot queue a read");
}

static void tryOpen(void) {
    if (gIface || dispatch_time(DISPATCH_TIME_NOW, 0) < gReleasedUntil) return;
    io_service_t svc = findInterface(CTL_INTERFACE);
    if (!svc) return;   // not connected, or not configured yet
    NSError *err = nil;
    IOUSBHostInterface *iface = [[IOUSBHostInterface alloc]
        initWithIOService:svc options:IOUSBHostObjectInitOptionsNone queue:gQueue error:&err
          interestHandler:^(IOUSBHostObject *obj, uint32_t type, void *arg) {
              (void)obj; (void)arg;
              if (type == kIOMessageServiceIsTerminated) closeIface("device disconnected");
          }];
    IOObjectRelease(svc);
    if (!iface) {   // another process (the MIDI driver, qc_sysex) uses it: try again later
        static bool logged;
        if (!logged) os_log(gLog, "interface 2 not available: %{public}s", err.localizedDescription.UTF8String);
        logged = true;
        return;
    }
    IOUSBHostPipe *pipe = [iface copyPipeWithAddress:EP_IN error:&err];
    if (!pipe) { [iface destroy]; return; }
    for (int k = 0; k < IN_REQUESTS; k++) {
        gBuf[k] = [iface ioDataWithCapacity:IN_SIZE error:&err];
        if (!gBuf[k]) { [iface destroy]; return; }
    }
    gIface = iface;
    gInPipe = pipe;
    gGeneration++;
    for (int k = 0; k < IN_REQUESTS; k++) readNext(k);
    os_log(gLog, "interface 2 opened: the control channel is read");
}

#pragma mark Status (interface 3)

static void statusRead(void);

static void onStatus(uint64_t gen, IOReturn status, NSUInteger n) {
    if (gen != gStGeneration || !gStIface) return;
    gStBusy = false;
    if (status != kIOReturnSuccess) {
        if (status == kUSBHostReturnPipeStalled) [gStPipe clearStallWithError:nil];
        else if (status != kIOReturnAborted) closeStatus("read error");
        return;
    }
    const uint8_t *b = gStBuf.bytes;
    if (n < 8 || b[0] != 1) {
        // The device sends two messages in turn; the one with byte 0 = 1 has the clock data.
        if (++gStReads < 4) statusRead();
        return;
    }
    const uint32_t rate = b[3] | (b[4] << 8) | (b[5] << 16);
    const bool external = b[6] == 1, locked = b[7] != 0;
    if (gStKnown && rate == gStRate && external == gStExternal && locked == gStLocked) return;
    os_log(gLog, "device clock: %u Hz, %{public}s%{public}s", rate, external ? "external (COAXIAL IN)" : "internal",
           external && !locked ? ", not locked" : "");
    gStKnown = true;
    gStRate = rate;
    gStExternal = external;
    gStLocked = locked;
    if (gStCallback) gStCallback(rate, external, locked);
}

static void statusRead(void) {
    if (!gStIface || gStBusy) return;
    const uint64_t gen = gStGeneration;
    NSError *err = nil;
    // An interrupt endpoint accepts no completion timeout (kIOReturnBadArgument): use 0.
    if (![gStPipe enqueueIORequestWithData:gStBuf completionTimeout:0 error:&err
                         completionHandler:^(IOReturn status, NSUInteger n) {
                             dispatch_async(gQueue, ^{ onStatus(gen, status, n); });
                         }]) {
        closeStatus("cannot queue a read");
        return;
    }
    gStBusy = true;
}

static void statusPoll(void) {
    if (dispatch_time(DISPATCH_TIME_NOW, 0) < gStatusReleasedUntil) return;
    if (!gStIface) {
        io_service_t svc = findInterface(STATUS_INTERFACE);
        if (!svc) return;
        NSError *err = nil;
        IOUSBHostInterface *iface = [[IOUSBHostInterface alloc]
            initWithIOService:svc options:IOUSBHostObjectInitOptionsNone queue:gQueue error:&err
              interestHandler:^(IOUSBHostObject *obj, uint32_t type, void *arg) {
                  (void)obj; (void)arg;
                  if (type == kIOMessageServiceIsTerminated) closeStatus("device disconnected");
              }];
        IOObjectRelease(svc);
        if (!iface) return;   // qc_rate uses it: try again later
        IOUSBHostPipe *pipe = nil;
        NSMutableData *buf = nil;
        if (![iface selectAlternateSetting:1 error:&err] || !(pipe = [iface copyPipeWithAddress:EP_STATUS error:&err]) ||
            !(buf = [iface ioDataWithCapacity:8 error:&err])) {
            os_log_error(gLog, "cannot open the status endpoint: %{public}s", err.localizedDescription.UTF8String);
            [iface destroy];
            return;
        }
        gStIface = iface;
        gStPipe = pipe;
        gStBuf = buf;
        gStGeneration++;
        os_log(gLog, "interface 3 opened: the clock status is read each second");
    }
    if (gStBusy) {   // the device did not answer in 1 s: abort, and try again at the next tick
        [gStPipe abortWithOption:IOUSBHostAbortOptionAsynchronous error:nil];
        return;
    }
    gStReads = 0;
    statusRead();
}

void qc_ctl_set_status_callback(QCStatusCallback callback) {
    qc_ctl_start();
    dispatch_async(gQueue, ^{
        gStCallback = callback;
        gStKnown = false;   // report the current status again
    });
}

void qc_ctl_start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLog = os_log_create("com.louistissot.quadcapture", "control");
        gQueue = dispatch_queue_create("com.louistissot.quadcapture.control", DISPATCH_QUEUE_SERIAL);
        int token;
        uint32_t r = notify_register_dispatch(QC_CTL_WANT_NOTIFICATION, &token, gQueue, ^(int t) {
            (void)t;
            gReleasedUntil = dispatch_time(DISPATCH_TIME_NOW, (int64_t)QC_CTL_RELEASE_SECONDS * NSEC_PER_SEC);
            closeIface("another process wants it");
        });
        int token3;
        notify_register_dispatch(QC_CTL_STATUS_WANT_NOTIFICATION, &token3, gQueue, ^(int t) {
            (void)t;
            gStatusReleasedUntil = dispatch_time(DISPATCH_TIME_NOW, (int64_t)QC_CTL_RELEASE_SECONDS * NSEC_PER_SEC);
            closeStatus("another process wants it");
        });
        if (r != NOTIFY_STATUS_OK) os_log_error(gLog, "cannot register for %{public}s (%u)", QC_CTL_WANT_NOTIFICATION, r);
        gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
        dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(gTimer, ^{
            if (gTick++ % QC_CTL_RETRY_SECONDS == 0) tryOpen();
            statusPoll();
        });
        dispatch_resume(gTimer);
        os_log(gLog, "control channel reader started");
    });
}
