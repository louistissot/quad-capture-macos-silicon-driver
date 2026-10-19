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

static os_log_t gLog;
static dispatch_queue_t gQueue;   // all state below
static IOUSBHostInterface *gIface;
static IOUSBHostPipe *gInPipe;
static NSMutableData *gBuf[IN_REQUESTS];
static uint64_t gGeneration;      // changes at each close, so old completions do nothing
static dispatch_time_t gReleasedUntil;
static uint64_t gMessages;
static dispatch_source_t gTimer;  // must stay referenced: ARC frees an unreferenced source

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
    CFMutableDictionaryRef m =
        [IOUSBHostInterface createMatchingDictionaryWithVendorID:@QC_VID productID:@QC_PID bcdDevice:nil
                                                 interfaceNumber:@CTL_INTERFACE configurationValue:@1
                                                  interfaceClass:nil interfaceSubclass:nil
                                               interfaceProtocol:nil speed:nil productIDArray:nil];
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, m);
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
        if (r != NOTIFY_STATUS_OK) os_log_error(gLog, "cannot register for %{public}s (%u)", QC_CTL_WANT_NOTIFICATION, r);
        gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
        dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                                  (uint64_t)QC_CTL_RETRY_SECONDS * NSEC_PER_SEC, NSEC_PER_SEC / 4);
        dispatch_source_set_event_handler(gTimer, ^{ tryOpen(); });
        dispatch_resume(gTimer);
        os_log(gLog, "control channel reader started");
    });
}
