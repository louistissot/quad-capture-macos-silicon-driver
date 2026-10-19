# USB protocol, device behavior and engine design

This document records what the project knows about the Roland QUAD-CAPTURE (UA-55) on USB, how
the firmware behaves, and why the engine is designed as it is. Read it before you change
`src/engine/qc_engine.m`.

## USB identity

| Item | Value |
|---|---|
| Vendor ID / product ID | `0582:012f` |
| Speed | High speed (USB 2.0, 480 Mbit/s), 125 µs microframes |
| Device class | `ff/00/ff` (vendor-specific), so macOS does not configure the device |
| Configuration | 1 configuration, 5 interfaces, maximum power 450 mA |

Sources: the descriptors (`build/qc_descriptors`) and the Linux `snd-usb-audio` quirk table
(`sound/usb/quirks-table.h`, entry `USB_DEVICE(0x0582, 0x012f)`).

## Interfaces

| Interface | Function | Endpoint | Format at alternate setting 1 |
|---|---|---|---|
| 0 | Playback | `0x05` isochronous OUT, asynchronous | 4 ch, 24-bit in 32-bit words, 44.1 kHz |
| 1 | Capture | `0x85` isochronous IN, asynchronous, implicit feedback | 6 ch, 24-bit in 32-bit words, 44.1 kHz |
| 2 | MIDI | `0x06` OUT / `0x86` IN, bulk (alternate setting 0) | USB-MIDI event packets, 1 cable |
| 3 | Unknown (status) | `0x82` interrupt IN, 8 bytes | - |
| 4 | Unknown (status) | `0x81` interrupt IN, 8 bytes | - |

- The class-specific descriptors are USB Audio Class 1 descriptors on vendor-specific interfaces
  (class `ff`, subclass `01`/`02`).
- Alternate settings 1, 2, 3 and 4 of interfaces 0 and 1 are 44.1, 48, 96 and 192 kHz. At 192 kHz
  the streams have 2 channels.
- The endpoints have no sampling-frequency control. The Linux driver says that only 44.1 kHz
  operates, because "some unknown vendor-specific mechanism" changes the sample rate. That
  mechanism is now known: see [Sample rate](#sample-rate).
- The interval of the audio endpoints is 1 (every microframe). At 44.1 kHz a packet has 5 or 6
  frames (5.5125 on average).

### Sample rate

The audio endpoints have no sampling-frequency control. The device clock changes with a vendor
request on endpoint 0. The alternate setting of the streams must then agree with the new rate.

Source: a study of the binary of the last Roland driver for macOS (`RDUSB012FDev.kext`, version
1.5.6, x86_64), for interoperability only. The project contains no Roland code. This section
describes the behavior in our own words.

| Step | Request | Data |
|---|---|---|
| Set the rate | `bmRequestType 0x40`, `bRequest 0x03`, `wValue 0x0008`, `wIndex 0`, 4 bytes OUT | `0x40`, then the rate in Hz, 24-bit little-endian (44100 Hz: `40 44 ac 00`) |
| Read the rate | `bmRequestType 0xc0`, `bRequest 0x03`, `wValue 0x0001`, `wIndex 0`, 4 bytes IN | The rate in Hz, 24-bit little-endian, then a flag byte |

- Flag byte: bit 0 is set while the change is not complete; bit 1 is set if an error occurred.
- The Roland driver sends "set", then reads the rate each 200 ms (40 times at most, 8 s). It
  stops when the rate is correct and bits 0 and 1 are clear.
- The Roland driver changes the rate only while its streams are stopped. Before and after the
  change, it reads a status message from the interrupt endpoint `0x82` (interface 3).
- Status messages on `0x82` have 8 bytes. A message with byte 0 = `1` contains the current
  rate in bytes 3 to 5 (24-bit little-endian). The other bytes are not known yet.
- At 192 kHz the streams have 2 channels (alternate setting 4). At 96 kHz or less they have 4
  playback and 6 capture channels.

`build/qc_rate` reads the rate, and `build/qc_rate <hz>` changes it.

### Control panel (SysEx)

The Roland control panel (input mixer, compressor, AUTO-SENS) sends Roland System Exclusive
messages. The Roland driver puts them in USB-MIDI event packets on the MIDI bulk endpoints of
interface 2 with **cable number 1** (normal MIDI uses cable 0). The content of these messages
(addresses and values) is not known yet.

### Channels

| Capture channel | Signal |
|---|---|
| 1, 2 | IN 1, IN 2 (analog) |
| 3, 4 | DIGITAL IN L, DIGITAL IN R (coaxial S/PDIF) |
| 5, 6 | Identical; about the sum of IN 1 and IN 2. Not in the Roland specification. The driver does not show them. |

| Playback channel | Signal |
|---|---|
| 1, 2 | OUTPUT 1L, OUTPUT 2R, and PHONES |
| 3, 4 | DIGITAL OUT L, DIGITAL OUT R (coaxial S/PDIF) |

### Sample format

Samples are signed 24-bit values, left-justified in 32-bit little-endian words (`S32_LE` in the
Linux driver). The low byte of a capture sample is not always 0.

### Implicit feedback

The capture endpoint is the clock source. The size (in frames) of each playback packet must
follow the size of a capture packet. The capture stream needs the playback stream: the device
sends capture data only while playback packets arrive. The engine sends silence when no client
plays audio.

## Device behavior found in tests

These results come from tests on a MacBook Pro M4 Pro with macOS 26.6 (19 October 2026).

- **An abort of the transfers mutes the outputs.** The first test version aborted the isochronous
  transfers at the end of each run. The first tone test was audible; the next tests were silent,
  although the device received the full tone. With a clean drain (no new requests, then the queued
  requests complete), consecutive tone tests are audible. The engine always stops with a clean
  drain.
- **Warm-up after a power cycle.** In the first stream after a power cycle, about 17 % of the
  capture packets are empty (about 0.5 s of audio). The next streams have no empty packets. The
  engine starts sample time 0 only after 100 ms of non-empty capture packets.
- **A stopped playback stream hangs the device.** A playback request with 0 bytes fails
  (`0xe00002d8`). When the playback stream stopped and the capture stream continued, the device
  stopped to answer control requests (timeouts on endpoint 0). A USB port reset from software
  failed. Only a power cycle (disconnect the USB cable for 5 seconds) made the device operate again.
  The engine never sends a request with 0 bytes: an empty capture packet gives a playback packet
  with the nominal size.
- **48 and 96 kHz before the rate command was known.** At alternate settings 2 and 3, with the
  device clock at 44.1 kHz, the device sent empty capture packets. The device clock must agree
  with the alternate setting.
- **Rate change.** The device needs about 1 s (5 polls of 200 ms) to change its clock. The
  first status read after the "set" request can still show the old rate (seen at 48 to 96 kHz).
  The interrupt endpoint `0x82` sent no status message while the device was idle.
- **192 kHz noise.** The input noise floor at 192 kHz is about -81 dBFS RMS (about -95 to
  -100 dBFS at the other rates), probably because of the wider bandwidth.

## Engine design

### Streams

- `NUM_REQ` isochronous requests are in flight for each direction. Each request has `TPR`
  microframes (`qc_engine_configure`). The default is 16 requests of 16 microframes (32 ms).
- Requests use explicit frame numbers. Capture and playback start in the same frame.
- The data of a playback request comes from the output ring when the request is queued. Thus the
  output safety offset is the queue depth plus a margin for late callbacks.
- A request that is too late (`kIOReturnIsoTooOld`) moves to a later frame (2, 4, 8 or 16 ms after
  now). Capture puts in silence for the skipped microframes, and playback skips the same number of
  samples, so both stay on the device clock. If all attempts fail, the engine tries again 1 ms
  later. It never drops a request slot.

### Clock

- Sample time 0 is the first capture frame after the stream is stable.
- For each capture packet the engine knows its microframe number. It converts the microframe to
  host time and publishes a zero timestamp each `QC_ZERO_PERIOD` (16384) frames, with the host
  time interpolated inside the packet. Thus the Core Audio clock follows the QUAD-CAPTURE clock
  (measured: 44099.5 Hz against the host clock of the test Mac).
- macOS 26 or later: `currentMicroframeWithTime:` gives the exact microframe start time.
- macOS 12 to 15: that method does not exist. The engine reads `frameNumberWithTime:`, whose time
  is a time inside the frame, and smooths the frame start over many reads. The constant offset that
  stays (about 0.5 ms) does not change the clock rate.

### Real-time behavior

- The client functions (`qc_engine_read_input`, `qc_engine_write_output`,
  `qc_engine_zero_timestamp`) use no locks and do no allocation.
- The USB callbacks run on a serial dispatch queue at user-interactive QoS. A test process that
  was a child of another app ran at priority 31 and could not get a real-time policy; its callbacks
  sometimes came up to 90 ms late. The `qsta` custom property of the driver reports the callback
  lag inside the Core Audio driver service.

### Custom properties of the driver

| Selector | Type | Use |
|---|---|---|
| `qcfg` | CFDictionary, settable | USB queue: `requests`, `microframes`, `outputMargin`, `inputMargin` (frames), `scheduling` (0, 1, 2). The driver applies it with a device configuration change and keeps it. |
| `qsta` | CFDictionary, read only | Statistics: frames, missing and late frames, resyncs, callback lag histograms, callback thread priority. |

`build/qc_hal_test -q` prints both; `build/qc_hal_test -c 16,16,441,441,0` sets `qcfg`.

## Test history

| Test | Result |
|---|---|
| Capture, 44.1 kHz, 5 s (`qc_capture`) | 40064 microframes, 0 USB errors, 0 empty packets |
| Input noise floor, no signal | IN 1-2 about -98 to -102 dBFS RMS |
| Tone on OUT 1L / OUT 2R, -30 dBFS | Audible on the correct sides; no capture channel contains it (below -136 dBFS) |
| Core Audio device, 5 s (`qc_hal_test`) | 431 IO cycles of 512 frames, 0 sample-time breaks, rate scalar 1.000000 to 1.000018 |
| Callback lag, test process (`qc_engine_test`) | 95 % below 0.5 ms; some up to 90 ms |
| Rate command, 44.1 -> 48 -> 96 -> 192 -> 44.1 kHz (`qc_rate`) | Each change complete in about 1 s |
| Capture at each rate, 3 s (`qc_capture -a 2/3/4`) | 0 empty packets, 0 USB errors; 6, 12 and 24 frames per microframe |
| Engine at each rate, 4 s (`qc_engine_test -r`) | 0 missing frames, 0 USB errors; measured 47999.08, 95998.41, 191997.05, 44099.64 Hz |
| Core Audio at each rate, 3 s, and tone 5 s (`qc_hal_test -r`) | 0 sample-time breaks, 0 late or missing frames, 0 USB errors |
