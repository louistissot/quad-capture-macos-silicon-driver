// qc_midi_driver: CoreMIDI driver (MIDIDriverInterface version 2) for the MIDI IN and MIDI OUT ports
// of the Roland QUAD-CAPTURE (UA-55).
//
// USB interface 2, alternate setting 0: bulk OUT endpoint 0x06 and bulk IN endpoint 0x86. The data
// are USB-MIDI event packets on cable 0 (the Linux snd-usb-audio quirk for 0582:012f uses the same
// format). The driver publishes one MIDI device "QUAD-CAPTURE" with one source and one destination.
// The device is offline while the QUAD-CAPTURE is not connected.
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>
#include <CoreMIDI/CoreMIDI.h>
#include <CoreMIDI/MIDIDriver.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <os/log.h>
#include <notify.h>
#include "qc_usbmidi.h"
#include "engine/qc_ctl.h"

#define QC_VID 0x0582
#define QC_PID 0x012f
#define MIDI_INTERFACE 2
#define EP_OUT 0x06
#define EP_IN 0x86
#define IN_SIZE 512          // wMaxPacketSize of the bulk endpoints (high speed)
#define IN_REQUESTS 2        // bulk reads in flight
#define OUT_CHUNK 512        // bytes in one bulk write (a multiple of 4)
#define PENDING_MAX 65536    // encoded bytes that can wait for the USB queue

static os_log_t gLog;
static ULONG gRefs;
static CFRunLoopRef gMainRunLoop;
static MIDIDeviceRef gDevice;
static MIDIEndpointRef gSource, gDest;
static dispatch_queue_t gQueue;      // all USB work
static IONotificationPortRef gNotify;
static io_iterator_t gIfaceIter, gDevIter;

// USB state (gQueue only).
static IOUSBHostInterface *gIface;
static IOUSBHostPipe *gInPipe, *gOutPipe;
static NSMutableData *gInBuf[IN_REQUESTS];
static bool gOutBusy;
static int gReadErrors;

// Output queue (Send threads write, gQueue reads).
static os_unfair_lock gOutLock = OS_UNFAIR_LOCK_INIT;
static QCMidiEncoder gEnc;
static uint8_t gPending[PENDING_MAX];
static size_t gPendingLen;
static bool gOnline;

#pragma mark Helpers

static void setOffline(bool offline) {
    if (!gDevice || !gMainRunLoop) return;
    CFRunLoopPerformBlock(gMainRunLoop, kCFRunLoopCommonModes, ^{
        MIDIObjectSetIntegerProperty(gDevice, kMIDIPropertyOffline, offline ? 1 : 0);
    });
    CFRunLoopWakeUp(gMainRunLoop);
}

static io_service_t findService(bool interfaceOnly) {
    CFMutableDictionaryRef m;
    if (interfaceOnly)
        m = [IOUSBHostInterface createMatchingDictionaryWithVendorID:@QC_VID productID:@QC_PID bcdDevice:nil
                                                     interfaceNumber:@MIDI_INTERFACE configurationValue:@1
                                                      interfaceClass:nil interfaceSubclass:nil interfaceProtocol:nil
                                                               speed:nil productIDArray:nil];
    else
        m = [IOUSBHostDevice createMatchingDictionaryWithVendorID:@QC_VID productID:@QC_PID bcdDevice:nil
                                                      deviceClass:nil deviceSubclass:nil deviceProtocol:nil
                                                            speed:nil productIDArray:nil];
    return IOServiceGetMatchingService(kIOMainPortDefault, m);
}

#pragma mark USB input

static void readNext(int k);

static void onRead(int k, IOReturn status, NSUInteger n) {
    if (!gIface || status == kIOReturnAborted || status == kIOReturnNotOpen || status == kIOReturnOffline) return;
    if (status != kIOReturnSuccess) {
        if (++gReadErrors > 50) { os_log_error(gLog, "MIDI IN: too many errors (0x%08x)", status); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), gQueue, ^{ readNext(k); });
        return;
    }
    gReadErrors = 0;
    const uint8_t *data = gInBuf[k].bytes;
    Byte listBuf[1024];
    MIDIPacketList *list = (MIDIPacketList *)listBuf;
    MIDIPacket *pkt = MIDIPacketListInit(list);
    const MIDITimeStamp now = mach_absolute_time();
    for (NSUInteger i = 0; i + 4 <= n; i += 4) {
        // Cable 1 carries the Roland control messages (SENS knobs, AUTO-SENS): not MIDI for the apps.
        if ((data[i] >> 4) != 0) continue;
        uint8_t bytes[3];
        int count = qc_midi_decode(data + i, bytes);
        if (count == 0) continue;
        MIDIPacket *next = MIDIPacketListAdd(list, sizeof(listBuf), pkt, now, (ByteCount)count, bytes);
        if (!next) {
            MIDIReceived(gSource, list);
            pkt = MIDIPacketListInit(list);
            next = MIDIPacketListAdd(list, sizeof(listBuf), pkt, now, (ByteCount)count, bytes);
        }
        pkt = next;
    }
    if (list->numPackets > 0 && gSource) MIDIReceived(gSource, list);
    readNext(k);
}

static void readNext(int k) {
    if (!gIface || !gInPipe) return;
    NSError *err = nil;
    if (![gInPipe enqueueIORequestWithData:gInBuf[k] completionTimeout:0 error:&err
                         completionHandler:^(IOReturn status, NSUInteger n) { onRead(k, status, n); }])
        os_log_error(gLog, "MIDI IN: cannot queue a read: %{public}s", err.localizedDescription.UTF8String);
}

#pragma mark USB output

static void flushOut(void) {
    if (!gIface || !gOutPipe || gOutBusy) return;
    uint8_t chunk[OUT_CHUNK];
    size_t len;
    os_unfair_lock_lock(&gOutLock);
    len = gPendingLen < OUT_CHUNK ? gPendingLen : OUT_CHUNK;
    memcpy(chunk, gPending, len);
    memmove(gPending, gPending + len, gPendingLen - len);
    gPendingLen -= len;
    os_unfair_lock_unlock(&gOutLock);
    if (len == 0) return;
    NSError *err = nil;
    NSMutableData *d = [gIface ioDataWithCapacity:len error:&err];   // its length is its capacity
    if (!d) { os_log_error(gLog, "MIDI OUT: no buffer"); return; }
    memcpy(d.mutableBytes, chunk, len);
    gOutBusy = true;
    if (![gOutPipe enqueueIORequestWithData:d completionTimeout:1.0 error:&err
                          completionHandler:^(IOReturn status, NSUInteger n) {
                              (void)n;
                              gOutBusy = false;
                              if (status != kIOReturnSuccess && status != kIOReturnAborted)
                                  os_log_error(gLog, "MIDI OUT: write failed (0x%08x)", status);
                              if (status != kIOReturnAborted) flushOut();
                          }]) {
        gOutBusy = false;
        os_log_error(gLog, "MIDI OUT: cannot queue a write: %{public}s", err.localizedDescription.UTF8String);
    }
}

#pragma mark USB open and close

static void closeUSB(void) {
    if (!gIface) return;
    [gInPipe abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
    [gOutPipe abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
    [gIface destroy];
    gIface = nil;
    gInPipe = gOutPipe = nil;
    for (int k = 0; k < IN_REQUESTS; k++) gInBuf[k] = nil;
    gOutBusy = false;
    os_unfair_lock_lock(&gOutLock);
    gOnline = false;
    gPendingLen = 0;
    os_unfair_lock_unlock(&gOutLock);
    setOffline(true);
    os_log(gLog, "MIDI: QUAD-CAPTURE offline");
}

static void openUSB(io_service_t svc);

// Interface 2 is busy: the audio driver reads the control channel there while no MIDI client runs
// (see qc_ctl.h). Ask it to release the interface, and try again each 250 ms for 3 s.
static int gOpenAttempts;
static void retryOpen(void) {
    if (gIface) return;
    if (gOpenAttempts == 0) notify_post(QC_CTL_WANT_NOTIFICATION);
    if (++gOpenAttempts > 12) {
        os_log_error(gLog, "MIDI: interface 2 stays busy");
        gOpenAttempts = 0;
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), gQueue, ^{
        io_service_t s = findService(true);
        if (s) { openUSB(s); IOObjectRelease(s); }
    });
}

static void openUSB(io_service_t svc) {
    if (gIface) return;
    NSError *err = nil;
    IOUSBHostInterface *iface = [[IOUSBHostInterface alloc]
        initWithIOService:svc options:IOUSBHostObjectInitOptionsNone queue:gQueue error:&err
          interestHandler:^(IOUSBHostObject *obj, uint32_t type, void *arg) {
              (void)obj; (void)arg;
              if (type == kIOMessageServiceIsTerminated) closeUSB();
          }];
    if (!iface) {
        if (gOpenAttempts == 0)
            os_log(gLog, "MIDI: interface 2 is busy (%{public}s); asking the audio driver to release it",
                   err.localizedDescription.UTF8String);
        retryOpen();
        return;
    }
    gOpenAttempts = 0;
    IOUSBHostPipe *outPipe = [iface copyPipeWithAddress:EP_OUT error:&err];
    IOUSBHostPipe *inPipe = [iface copyPipeWithAddress:EP_IN error:&err];
    if (!outPipe || !inPipe) {
        os_log_error(gLog, "MIDI: cannot open the pipes");
        [iface destroy];
        return;
    }
    gIface = iface;
    gOutPipe = outPipe;
    gInPipe = inPipe;
    gReadErrors = 0;
    for (int k = 0; k < IN_REQUESTS; k++) gInBuf[k] = [iface ioDataWithCapacity:IN_SIZE error:&err];
    os_unfair_lock_lock(&gOutLock);
    qc_midi_encoder_reset(&gEnc);
    gPendingLen = 0;
    gOnline = true;
    os_unfair_lock_unlock(&gOutLock);
    for (int k = 0; k < IN_REQUESTS; k++) readNext(k);
    setOffline(false);
    os_log(gLog, "MIDI: QUAD-CAPTURE online");
}

static void interfaceArrived(void *refcon, io_iterator_t it) {
    (void)refcon;
    io_service_t s;
    while ((s = IOIteratorNext(it))) {
        openUSB(s);
        IOObjectRelease(s);
    }
}

// The device connected. Normally the audio driver sets its configuration; if interface 2 does not
// exist after 1 s (for example without the audio driver), set the configuration here.
static void deviceArrived(void *refcon, io_iterator_t it) {
    (void)refcon;
    io_service_t s;
    while ((s = IOIteratorNext(it))) IOObjectRelease(s);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), gQueue, ^{
        if (gIface) return;
        io_service_t iface = findService(true);
        if (iface) { openUSB(iface); IOObjectRelease(iface); return; }
        io_service_t dev = findService(false);
        if (!dev) return;
        NSError *err = nil;
        IOUSBHostDevice *d = [[IOUSBHostDevice alloc] initWithIOService:dev options:IOUSBHostObjectInitOptionsNone
                                                                  queue:nil error:&err interestHandler:nil];
        IOObjectRelease(dev);
        if (!d) return;
        if (!d.configurationDescriptor && [d configureWithValue:1 matchInterfaces:YES error:&err])
            os_log(gLog, "MIDI: device configured");
        [d destroy];
    });
}

#pragma mark Driver interface

static HRESULT QM_QueryInterface(void *self, REFIID iid, LPVOID *ppv);
static ULONG QM_AddRef(void *self);
static ULONG QM_Release(void *self);
static OSStatus QM_FindDevices(MIDIDriverRef self, MIDIDeviceListRef devList);
static OSStatus QM_Start(MIDIDriverRef self, MIDIDeviceListRef devList);
static OSStatus QM_Stop(MIDIDriverRef self);
static OSStatus QM_Configure(MIDIDriverRef self, MIDIDeviceRef device);
static OSStatus QM_Send(MIDIDriverRef self, const MIDIPacketList *pktlist, void *ref1, void *ref2);
static OSStatus QM_EnableSource(MIDIDriverRef self, MIDIEndpointRef src, Boolean enabled);
static OSStatus QM_Flush(MIDIDriverRef self, MIDIEndpointRef dest, void *ref1, void *ref2);
static OSStatus QM_Monitor(MIDIDriverRef self, MIDIEndpointRef dest, const MIDIPacketList *pktlist);

static MIDIDriverInterface gInterface = {
    ._reserved = NULL,
    .QueryInterface = QM_QueryInterface,
    .AddRef = QM_AddRef,
    .Release = QM_Release,
    .FindDevices = QM_FindDevices,
    .Start = QM_Start,
    .Stop = QM_Stop,
    .Configure = QM_Configure,
    .Send = QM_Send,
    .EnableSource = QM_EnableSource,
    .Flush = QM_Flush,
    .Monitor = QM_Monitor,
    .SendPackets = NULL,
    .MonitorEvents = NULL,
};
static MIDIDriverInterface *gInterfacePtr = &gInterface;

// Factory function (named in Info.plist, CFPlugInFactories).
__attribute__((visibility("default"))) void *QuadCaptureMIDI_Create(CFAllocatorRef allocator, CFUUIDRef typeID) {
    (void)allocator;
    if (!CFEqual(typeID, kMIDIDriverTypeID)) return NULL;
    if (!gLog) gLog = os_log_create("com.louistissot.quadcapture", "midi");
    gRefs = 1;
    return &gInterfacePtr;
}

static HRESULT QM_QueryInterface(void *self, REFIID iid, LPVOID *ppv) {
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, iid);
    HRESULT r = E_NOINTERFACE;
    if (CFEqual(req, IUnknownUUID) || CFEqual(req, kMIDIDriverInterface2ID)) {
        QM_AddRef(self);
        *ppv = self;
        r = S_OK;
    } else {
        *ppv = NULL;
    }
    CFRelease(req);
    return r;
}

static ULONG QM_AddRef(void *self) { (void)self; return ++gRefs; }
static ULONG QM_Release(void *self) { (void)self; return gRefs ? --gRefs : 0; }

// Version 1 only.
static OSStatus QM_FindDevices(MIDIDriverRef self, MIDIDeviceListRef devList) { (void)self; (void)devList; return noErr; }

static OSStatus QM_Start(MIDIDriverRef self, MIDIDeviceListRef devList) {
    gMainRunLoop = CFRunLoopGetCurrent();
    // The device list holds the devices of this driver in the current MIDI setup: use the first one.
    ItemCount n = MIDIDeviceListGetNumberOfDevices(devList);
    if (n > 0) gDevice = MIDIDeviceListGetDevice(devList, 0);
    if (!gDevice) {
        MIDIEntityRef entity;
        if (MIDIDeviceCreate(self, CFSTR("QUAD-CAPTURE"), CFSTR("Roland"), CFSTR("QUAD-CAPTURE"), &gDevice) != noErr ||
            MIDIDeviceNewEntity(gDevice, CFSTR("QUAD-CAPTURE"), kMIDIProtocol_1_0, false, 1, 1, &entity) != noErr ||
            MIDISetupAddDevice(gDevice) != noErr) {
            os_log_error(gLog, "MIDI: cannot create the MIDI device");
            return kMIDIUnknownError;
        }
    }
    MIDIEntityRef entity = MIDIDeviceGetEntity(gDevice, 0);
    gSource = MIDIEntityGetSource(entity, 0);
    gDest = MIDIEntityGetDestination(entity, 0);
    MIDIEndpointSetRefCons(gDest, (void *)1, NULL);
    MIDIObjectSetIntegerProperty(gDevice, kMIDIPropertyOffline, 1);

    gQueue = dispatch_queue_create("com.louistissot.quadcapture.midi",
                                   dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                           QOS_CLASS_USER_INTERACTIVE, 0));
    gNotify = IONotificationPortCreate(kIOMainPortDefault);
    IONotificationPortSetDispatchQueue(gNotify, gQueue);
    dispatch_sync(gQueue, ^{
        CFMutableDictionaryRef mi =
            [IOUSBHostInterface createMatchingDictionaryWithVendorID:@QC_VID productID:@QC_PID bcdDevice:nil
                                                     interfaceNumber:@MIDI_INTERFACE configurationValue:@1
                                                      interfaceClass:nil interfaceSubclass:nil interfaceProtocol:nil
                                                               speed:nil productIDArray:nil];
        CFMutableDictionaryRef md =
            [IOUSBHostDevice createMatchingDictionaryWithVendorID:@QC_VID productID:@QC_PID bcdDevice:nil
                                                      deviceClass:nil deviceSubclass:nil deviceProtocol:nil
                                                            speed:nil productIDArray:nil];
        IOServiceAddMatchingNotification(gNotify, kIOFirstMatchNotification, mi, interfaceArrived, NULL, &gIfaceIter);
        IOServiceAddMatchingNotification(gNotify, kIOFirstMatchNotification, md, deviceArrived, NULL, &gDevIter);
        interfaceArrived(NULL, gIfaceIter);
        deviceArrived(NULL, gDevIter);
    });
    os_log(gLog, "MIDI driver started");
    return noErr;
}

static OSStatus QM_Stop(MIDIDriverRef self) {
    (void)self;
    if (gQueue) dispatch_sync(gQueue, ^{ closeUSB(); });
    if (gIfaceIter) { IOObjectRelease(gIfaceIter); gIfaceIter = 0; }
    if (gDevIter) { IOObjectRelease(gDevIter); gDevIter = 0; }
    if (gNotify) { IONotificationPortDestroy(gNotify); gNotify = NULL; }
    os_log(gLog, "MIDI driver stopped");
    return noErr;
}

static OSStatus QM_Configure(MIDIDriverRef self, MIDIDeviceRef device) { (void)self; (void)device; return noErr; }

static OSStatus QM_Send(MIDIDriverRef self, const MIDIPacketList *pktlist, void *ref1, void *ref2) {
    (void)self; (void)ref1; (void)ref2;
    uint8_t enc[4 * 256];
    const MIDIPacket *p = &pktlist->packet[0];
    bool added = false;
    os_unfair_lock_lock(&gOutLock);
    if (gOnline) {
        for (UInt32 i = 0; i < pktlist->numPackets; i++) {
            for (UInt16 off = 0; off < p->length; off += 256) {
                size_t n = p->length - off < 256 ? p->length - off : 256;
                size_t len = qc_midi_encode(&gEnc, 0, p->data + off, n, enc, sizeof(enc));
                if (gPendingLen + len <= PENDING_MAX) {
                    memcpy(gPending + gPendingLen, enc, len);
                    gPendingLen += len;
                    added = added || len > 0;
                }
            }
            p = MIDIPacketNext(p);
        }
    }
    os_unfair_lock_unlock(&gOutLock);
    if (added) dispatch_async(gQueue, ^{ flushOut(); });
    return noErr;
}

static OSStatus QM_EnableSource(MIDIDriverRef self, MIDIEndpointRef src, Boolean enabled) {
    (void)self; (void)src; (void)enabled;
    return noErr;
}

static OSStatus QM_Flush(MIDIDriverRef self, MIDIEndpointRef dest, void *ref1, void *ref2) {
    (void)self; (void)dest; (void)ref1; (void)ref2;
    return noErr;
}

static OSStatus QM_Monitor(MIDIDriverRef self, MIDIEndpointRef dest, const MIDIPacketList *pktlist) {
    (void)self; (void)dest; (void)pktlist;
    return noErr;
}
