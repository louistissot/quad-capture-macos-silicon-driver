// QCPanelUSB: the USB part of the QuadCapture Panel app.
//
// The panel sends and receives Roland SysEx messages on USB interface 2 of the QUAD-CAPTURE (bulk OUT
// 0x06, bulk IN 0x86, USB-MIDI cable 1). See docs/PROTOCOL.md, "Control panel (SysEx)".
//
// Interface 2 hand-over (see src/engine/qc_ctl.h):
// - Only one process can open interface 2. The audio plug-in reads it while no other process uses it.
// - To open it, the panel posts QC_CTL_WANT_NOTIFICATION, then tries again each 250 ms for 3 s.
// - While the panel holds the interface, it reads the bulk IN endpoint at all times. If nobody reads
//   it, the front panel of the device stops.
// - If another process posts the notification (the CoreMIDI driver when a MIDI app starts, or
//   qc_sysex), the panel releases the interface, and tries to open it again later.
// - -stop closes the interface, so the audio plug-in takes it again.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, QCLinkState) {
    QCLinkStateNoDevice,   // the QUAD-CAPTURE is not connected (or interface 2 does not exist yet)
    QCLinkStateOpening,    // the panel asked for interface 2 and tries to open it
    QCLinkStateBusy,       // another process holds interface 2 (usually the CoreMIDI driver)
    QCLinkStateReleased,   // another process asked for interface 2; the panel released it
    QCLinkStateOpen,       // the panel holds interface 2 and reads it
};

@interface QCPanelUSB : NSObject

// Called on the main queue when the state changes. detail is a short text for the log.
@property (nonatomic, copy, nullable) void (^onState)(QCLinkState state, NSString *detail);
// Called on the main queue for each complete SysEx message on cable 1 (F0 ... F7).
@property (nonatomic, copy, nullable) void (^onSysEx)(NSData *message);
// Called on the main queue when a write fails.
@property (nonatomic, copy, nullable) void (^onError)(NSString *text);

// Start: try to open interface 2 now, and again each 2 s while it is not open.
- (void)start;
// Try to open interface 2 now (the user clicked Retry).
- (void)retryNow;
// Send one SysEx message (F0 ... F7) on cable 1. The messages go out in order. The panel never
// sends a DT1 to the "Initialize" address 00 00 00 02.
- (void)sendSysEx:(NSData *)message;
// Close interface 2 and stop. Synchronous: call it before the app quits.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
