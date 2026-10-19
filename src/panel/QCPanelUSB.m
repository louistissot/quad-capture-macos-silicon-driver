// QCPanelUSB: see QCPanelUSB.h.
#import "QCPanelUSB.h"
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>
#include <notify.h>
#include "engine/qc_ctl.h"
#include "midi/qc_usbmidi.h"

#define QC_VID 0x0582
#define QC_PID 0x012f
#define CTL_INTERFACE 2
#define EP_OUT 0x06
#define EP_IN 0x86
#define CABLE 1
#define IN_SIZE 512
#define IN_REQUESTS 2
#define OPEN_ATTEMPTS 12            // 12 x 250 ms = 3 s
#define BUSY_WAIT_SECONDS 5         // after a failed open, wait this time before the next try
#define RELEASED_WAIT_SECONDS 6     // after a release, give the other process time to open the interface
#define MAX_SYSEX 512

@implementation QCPanelUSB {
    dispatch_queue_t _q;            // all state below
    dispatch_queue_t _writeQ;       // synchronous bulk OUT writes, in order
    dispatch_source_t _timer;
    int _notifyToken;
    IOUSBHostInterface *_iface;
    IOUSBHostPipe *_inPipe, *_outPipe;
    NSMutableData *_inBuf[IN_REQUESTS];
    uint64_t _generation;           // changes at each close, so old completions do nothing
    int _attempt;                   // 0 = no open sequence in progress
    dispatch_time_t _nextTry;
    dispatch_time_t _ignoreNotifyUntil;   // our own notification comes back to us
    QCLinkState _state;
    bool _stopped;
    uint8_t _sx[MAX_SYSEX];
    size_t _sxLen;
    bool _inSysEx;
}

- (instancetype)init {
    if ((self = [super init])) {
        _q = dispatch_queue_create("com.louistissot.quadcapture.panel.usb", DISPATCH_QUEUE_SERIAL);
        _writeQ = dispatch_queue_create("com.louistissot.quadcapture.panel.write", DISPATCH_QUEUE_SERIAL);
        _state = QCLinkStateNoDevice;
        _notifyToken = NOTIFY_TOKEN_INVALID;
    }
    return self;
}

- (void)setState:(QCLinkState)state detail:(NSString *)detail {
    _state = state;
    void (^cb)(QCLinkState, NSString *) = self.onState;
    if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(state, detail); });
}

static io_service_t findInterface(void) {
    CFMutableDictionaryRef m =
        [IOUSBHostInterface createMatchingDictionaryWithVendorID:@QC_VID productID:@QC_PID bcdDevice:nil
                                                 interfaceNumber:@CTL_INTERFACE configurationValue:@1
                                                  interfaceClass:nil interfaceSubclass:nil
                                               interfaceProtocol:nil speed:nil productIDArray:nil];
    return IOServiceGetMatchingService(kIOMainPortDefault, m);
}

#pragma mark Open and close

- (void)start {
    dispatch_async(_q, ^{
        if (self->_timer || self->_stopped) return;
        __weak QCPanelUSB *weakSelf = self;
        uint32_t r = notify_register_dispatch(QC_CTL_WANT_NOTIFICATION, &self->_notifyToken, self->_q, ^(int t) {
            (void)t;
            [weakSelf otherProcessWantsInterface];
        });
        if (r != NOTIFY_STATUS_OK) NSLog(@"QuadCapture Panel: cannot register for %s (%u)", QC_CTL_WANT_NOTIFICATION, r);
        self->_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_q);
        dispatch_source_set_timer(self->_timer, dispatch_time(DISPATCH_TIME_NOW, 0), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
        dispatch_source_set_event_handler(self->_timer, ^{ [weakSelf tick]; });
        dispatch_resume(self->_timer);
    });
}

- (void)retryNow {
    dispatch_async(_q, ^{
        self->_nextTry = 0;
        if (!self->_iface && self->_attempt == 0) [self beginOpen];
    });
}

- (void)tick {
    if (_stopped || _iface || _attempt != 0) return;
    if (dispatch_time(DISPATCH_TIME_NOW, 0) < _nextTry) return;
    [self beginOpen];
}

- (void)beginOpen {
    io_service_t svc = findInterface();
    if (!svc) {
        if (_state != QCLinkStateNoDevice) [self setState:QCLinkStateNoDevice detail:@"QUAD-CAPTURE not connected"];
        return;
    }
    IOObjectRelease(svc);
    _attempt = 1;
    [self setState:QCLinkStateOpening detail:@"opening interface 2"];
    [self tryOpen];
}

// One attempt of the open sequence. The first attempt does not post the notification: the interface
// can be free. Then the audio plug-in must release it.
- (void)tryOpen {
    if (_stopped || _iface) { _attempt = 0; return; }
    io_service_t svc = findInterface();
    if (!svc) {
        _attempt = 0;
        [self setState:QCLinkStateNoDevice detail:@"QUAD-CAPTURE not connected"];
        return;
    }
    NSError *err = nil;
    __weak QCPanelUSB *weakSelf = self;
    IOUSBHostInterface *iface = [[IOUSBHostInterface alloc]
        initWithIOService:svc options:IOUSBHostObjectInitOptionsNone queue:_q error:&err
          interestHandler:^(IOUSBHostObject *obj, uint32_t type, void *arg) {
              (void)obj; (void)arg;
              if (type == kIOMessageServiceIsTerminated) [weakSelf closeWithState:QCLinkStateNoDevice detail:@"QUAD-CAPTURE disconnected"];
          }];
    IOObjectRelease(svc);
    if (!iface) {
        if (_attempt == 1) {
            _ignoreNotifyUntil = dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC);
            notify_post(QC_CTL_WANT_NOTIFICATION);
        }
        if (++_attempt > OPEN_ATTEMPTS) {
            _attempt = 0;
            _nextTry = dispatch_time(DISPATCH_TIME_NOW, (int64_t)BUSY_WAIT_SECONDS * NSEC_PER_SEC);
            [self setState:QCLinkStateBusy detail:[NSString stringWithFormat:@"interface 2 stays busy (%@)", err.localizedDescription]];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), _q, ^{ [weakSelf tryOpen]; });
        return;
    }
    _attempt = 0;
    IOUSBHostPipe *outPipe = [iface copyPipeWithAddress:EP_OUT error:&err];
    IOUSBHostPipe *inPipe = [iface copyPipeWithAddress:EP_IN error:&err];
    for (int k = 0; k < IN_REQUESTS; k++) _inBuf[k] = inPipe ? [iface ioDataWithCapacity:IN_SIZE error:&err] : nil;
    if (!outPipe || !inPipe || !_inBuf[0] || !_inBuf[IN_REQUESTS - 1]) {
        [iface destroy];
        _nextTry = dispatch_time(DISPATCH_TIME_NOW, (int64_t)BUSY_WAIT_SECONDS * NSEC_PER_SEC);
        [self setState:QCLinkStateBusy detail:@"cannot open the pipes of interface 2"];
        return;
    }
    _iface = iface;
    _outPipe = outPipe;
    _inPipe = inPipe;
    _generation++;
    _inSysEx = false;
    _sxLen = 0;
    for (int k = 0; k < IN_REQUESTS; k++) [self readNext:k];
    [self setState:QCLinkStateOpen detail:@"interface 2 open"];
}

- (void)closeWithState:(QCLinkState)state detail:(NSString *)detail {
    if (_iface) {
        _generation++;
        [_inPipe abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
        [_outPipe abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
        [_iface destroy];
        _iface = nil;
        _inPipe = _outPipe = nil;
        for (int k = 0; k < IN_REQUESTS; k++) _inBuf[k] = nil;
    }
    [self setState:state detail:detail];
}

- (void)otherProcessWantsInterface {
    if (!_iface || dispatch_time(DISPATCH_TIME_NOW, 0) < _ignoreNotifyUntil) return;
    _nextTry = dispatch_time(DISPATCH_TIME_NOW, (int64_t)RELEASED_WAIT_SECONDS * NSEC_PER_SEC);
    [self sendCloseMessage];
    [self closeWithState:QCLinkStateReleased detail:@"another process asked for interface 2"];
}

// Send closeMessage synchronously (timeout 0.5 s), on _q, while the interface is open.
- (void)sendCloseMessage {
    NSData *msg = self.closeMessage;
    if (!_iface || msg.length == 0 || msg.length > MAX_SYSEX) return;
    uint8_t pk[MAX_SYSEX * 2];
    QCMidiEncoder enc;
    qc_midi_encoder_reset(&enc);
    const size_t len = qc_midi_encode(&enc, CABLE, msg.bytes, msg.length, pk, sizeof(pk));
    NSError *err = nil;
    NSMutableData *d = [_iface ioDataWithCapacity:len error:&err];
    if (!d) return;
    memcpy(d.mutableBytes, pk, len);
    NSUInteger done = 0;
    [_outPipe sendIORequestWithData:d bytesTransferred:&done completionTimeout:0.5 error:&err];
}

- (void)stop {
    // First let the queued writes go out (each has a timeout of 1 s), then send closeMessage, then close.
    dispatch_sync(_q, ^{});
    dispatch_sync(_writeQ, ^{});
    dispatch_sync(_q, ^{
        self->_stopped = true;
        if (self->_timer) { dispatch_source_cancel(self->_timer); self->_timer = nil; }
        if (self->_notifyToken != NOTIFY_TOKEN_INVALID) { notify_cancel(self->_notifyToken); self->_notifyToken = NOTIFY_TOKEN_INVALID; }
        [self sendCloseMessage];
        [self closeWithState:QCLinkStateNoDevice detail:@"stopped"];
    });
}

#pragma mark Read

- (void)readNext:(int)k {
    if (!_iface) return;
    const uint64_t gen = _generation;
    NSError *err = nil;
    __weak QCPanelUSB *weakSelf = self;
    dispatch_queue_t q = _q;
    if (![_inPipe enqueueIORequestWithData:_inBuf[k] completionTimeout:0 error:&err
                         completionHandler:^(IOReturn status, NSUInteger n) {
                             dispatch_async(q, ^{ [weakSelf onRead:k generation:gen status:status length:n]; });
                         }]) {
        _nextTry = 0;
        [self closeWithState:QCLinkStateNoDevice detail:[NSString stringWithFormat:@"cannot queue a read (%@)", err.localizedDescription]];
    }
}

- (void)onRead:(int)k generation:(uint64_t)gen status:(IOReturn)status length:(NSUInteger)n {
    if (gen != _generation || !_iface) return;
    if (status != kIOReturnSuccess) {
        _nextTry = 0;
        [self closeWithState:QCLinkStateNoDevice detail:[NSString stringWithFormat:@"read error 0x%08x", status]];
        return;
    }
    const uint8_t *p = _inBuf[k].bytes;
    for (NSUInteger i = 0; i + 4 <= n; i += 4) {
        if (p[i] == 0 && p[i + 1] == 0) continue;   // padding
        if ((p[i] >> 4) != CABLE) continue;          // MIDI IN (cable 0) is not for the panel
        uint8_t b[3];
        int count = qc_midi_decode(&p[i], b);
        for (int j = 0; j < count; j++) [self collect:b[j]];
    }
    [self readNext:k];
}

- (void)collect:(uint8_t)b {
    if (b == 0xF0) { _inSysEx = true; _sxLen = 0; }
    if (!_inSysEx) return;
    if (_sxLen < MAX_SYSEX) _sx[_sxLen++] = b;
    if (b != 0xF7) return;
    _inSysEx = false;
    NSData *msg = [NSData dataWithBytes:_sx length:_sxLen];
    void (^cb)(NSData *) = self.onSysEx;
    if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(msg); });
}

#pragma mark Write

- (void)sendSysEx:(NSData *)message {
    const uint8_t *m = message.bytes;
    const size_t n = message.length;
    if (n < 2 || m[0] != 0xF0 || m[n - 1] != 0xF7 || n > MAX_SYSEX) {
        [self reportError:@"not a SysEx message; not sent"];
        return;
    }
    // Never send the "Initialize" address: it resets all the settings of the device.
    static const uint8_t kInit[] = {0xF0, 0x41, 0x10, 0x00, 0x00, 0x56, 0x12, 0x00, 0x00, 0x00, 0x02};
    if (n >= sizeof(kInit) && memcmp(m, kInit, sizeof(kInit)) == 0) {
        [self reportError:@"DT1 to 00 00 00 02 (Initialize) is not allowed; not sent"];
        return;
    }
    NSData *msg = [message copy];
    dispatch_async(_q, ^{
        if (!self->_iface) { [self reportError:@"interface 2 is not open; not sent"]; return; }
        IOUSBHostInterface *iface = self->_iface;
        IOUSBHostPipe *pipe = self->_outPipe;
        const uint64_t gen = self->_generation;
        uint8_t pk[MAX_SYSEX * 2];
        QCMidiEncoder enc;
        qc_midi_encoder_reset(&enc);
        const size_t len = qc_midi_encode(&enc, CABLE, msg.bytes, msg.length, pk, sizeof(pk));
        NSError *err = nil;
        NSMutableData *d = [iface ioDataWithCapacity:len error:&err];
        if (!d) { [self reportError:[NSString stringWithFormat:@"cannot allocate the OUT buffer (%@)", err.localizedDescription]]; return; }
        memcpy(d.mutableBytes, pk, len);
        dispatch_async(self->_writeQ, ^{
            NSError *werr = nil;
            NSUInteger done = 0;
            if (![pipe sendIORequestWithData:d bytesTransferred:&done completionTimeout:1.0 error:&werr] || done != len) {
                dispatch_async(self->_q, ^{
                    if (gen == self->_generation)
                        [self reportError:[NSString stringWithFormat:@"bulk OUT failed (%@)", werr ? werr.localizedDescription : @"short transfer"]];
                });
            }
        });
    });
}

- (void)reportError:(NSString *)text {
    void (^cb)(NSString *) = self.onError;
    if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(text); });
}

@end
