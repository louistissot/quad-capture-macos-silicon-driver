// qc_ctl: keep the control channel of the Roland QUAD-CAPTURE empty.
//
// The device sends a Roland SysEx message on USB interface 2 (bulk IN 0x86, USB-MIDI cable 1) for
// each step of a SENS knob and for AUTO-SENS. If no host reads interface 2, the queue of the device
// fills, and its front panel stops: the SENS rings go dark, and AUTO-SENS and DIRECT MONITOR do not
// operate. The Roland driver always reads interface 2. See docs/PROTOCOL.md.
//
// The audio plug-in always runs, so it reads (and discards) interface 2 while no other process
// uses it. Only one process can open the interface. A process that wants interface 2 (the CoreMIDI
// driver, qc_sysex) posts QC_CTL_WANT_NOTIFICATION; the plug-in then releases the interface for
// QC_CTL_RELEASE_SECONDS and takes it again later when it is free.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define QC_CTL_WANT_NOTIFICATION "com.louistissot.quadcapture.interface2.want"
// The same for interface 3 (clock status), for tools such as qc_rate.
#define QC_CTL_STATUS_WANT_NOTIFICATION "com.louistissot.quadcapture.interface3.want"
#define QC_CTL_RELEASE_SECONDS 5
#define QC_CTL_RETRY_SECONDS 2

// Start the reader (audio plug-in only). It runs until the process ends.
void qc_ctl_start(void);

// Clock status. The plug-in also reads the status of the device from interface 3 (interrupt IN
// 0x82, alternate setting 1) each second, as the Roland driver does. Each status message has 8
// bytes; the message with byte 0 = 1 has the device rate in bytes 3-5 (24-bit little-endian),
// byte 6 = 1 if the device runs on the clock of COAXIAL IN, and byte 7 (probably 1 = clock locked).
// With DIGITAL IN at AUTO, the device follows the rate of the coaxial input by itself.
// The callback runs on a private queue when a value changes (and once after the first read).
typedef void (*QCStatusCallback)(uint32_t rate, bool external, bool locked);
void qc_ctl_set_status_callback(QCStatusCallback callback);

#ifdef __cplusplus
}
#endif
