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

The settings of the preamps, the compressors and the monitor mixer are Roland System Exclusive
messages. They use the MIDI bulk endpoints of interface 2 (`0x06` OUT, `0x86` IN), in USB-MIDI
event packets with **cable number 1**. MIDI IN and MIDI OUT use cable 0.

Source: a study of the Roland control panel app and of `RDUSB012FDev.kext` (version 1.5.6), for
interoperability only. The app does not make SysEx: it sends a small command (command number,
channel, value) to the kext, and the kext makes the SysEx message. The project contains no Roland
code. Items marked "not tested" come only from that study.

#### Message format

| Message | Bytes |
|---|---|
| Header | `F0 41 10 00 00 56`: Roland, device ID `10`, model ID `00 00 56` |
| DT1 (data set) | header, `12`, address (4 bytes), data, checksum, `F7` |
| RQ1 (data request) | header, `11`, address (4 bytes), size (4 bytes), checksum, `F7` |

The checksum makes the sum of the address, the data (or the size) and the checksum a multiple
of 128: `checksum = (128 - (sum & 0x7F)) & 0x7F`. All data bytes are 7-bit values.

#### Parameters (DT1, 1 data byte)

`c` is the input channel: 0 = IN 1, 1 = IN 2.

| Address | Parameter | Values |
|---|---|---|
| `00 05 0c 01` | LO-CUT | 0 off, 1 on |
| `00 05 0c 02` | PHASE (polarity) | 0 normal, 1 inverted |
| `00 05 0c 04` | SENS (input gain) | 0 to 108 = 0 to 54 dB in 0.5 dB steps |
| `00 05 00 05` | Stereo link of IN 1 and IN 2 | 0 off, 1 on |
| `00 05 0c 06` | Compressor on | 0 off (BYPASS), 1 on |
| `00 05 0c 07` | Gate | 0 = -INF (off), 1 to 50 = -69 to -20 dB |
| `00 05 0c 08` | Attack | 0 to 25: 0.2, 0.5, 1, 2, 4, 6, 8, 10, 15 ... 100 ms (steps of 5 ms above 10 ms) |
| `00 05 0c 09` | Release | 0 to 45: 10, 12, 15, 18, 20, 25 ... 100 (steps of 5), 110 ... 200 (steps of 10), 220 ... 500 ms (steps of 20) |
| `00 05 0c 0a` | Threshold | 0 to 50 = -50 to 0 dB |
| `00 05 0c 0b` | Ratio | 0 to 8 = 1:1.0, 1:1.2, 1:1.5, 1:2.0, 1:2.8, 1:4.0, 1:8.0, 1:16, 1:INF |
| `00 05 0c 0c` | Gain (make-up) | 0 to 74 = -50 to +24 dB (text table of the app; only 0 and +1 dB tested) |
| `00 03 00 00` | Output select | value from the app (meaning not known yet) |
| `00 02 00 04` | DIGITAL IN setting | value from the app (meaning not known yet) |
| `00 02 01 00` | AUTO-SENS mode | value from the app |
| `00 02 01 01` | AUTO-SENS margin | value from the app ("Margin [dB]") |
| `00 02 01 02` | AUTO-SENS start/stop | value from the app |
| `00 0a 00 00` | Level meter on/off | value from the app |
| `00 00 00 02` | Initialize (the app sends 0 after "OK to initialize the current settings?") | not tested: it resets all settings |

#### Monitor mixer (DT1, 6 data bytes)

The MIXER section of the panel sets the level of each input in OUTPUT 1-2 (direct monitor).

| Address | Level |
|---|---|
| `00 06 00 08` | INPUT 1 |
| `00 06 01 08` | INPUT 2 |
| `00 06 02 08` | COAX (DIGITAL IN 3/4) |

The data is a 24-bit linear gain in 6 bytes of 4 bits each, high nibble first.
`0x200000` = 0 dB, `0x7FFFFF` = +12 dB, 0 = -INF. Example: 0 dB = `02 00 00 00 00 00`.

#### State block (RQ1 and DT1 at `01 00 00 00`, 59 bytes)

The app reads all settings with RQ1, address `01 00 00 00`, size `00 00 00 3B` (59 bytes):
`F0 41 10 00 00 56 11 01 00 00 00 00 00 00 3B 44 F7`. The device answers with a DT1 of 59 data
bytes to the same address. The kext can also write the full block with one DT1 to that address.

| Data byte | Content |
|---|---|
| 0-7 | 32-bit value in 8 nibbles (not known; the kext only copies it back) |
| 8-15 | 32-bit value in 8 nibbles (not known; the kext only copies it back) |
| 16-19 | Device settings (names not known yet; bytes 17, 18 and 19 are 0 or 1) |
| 20 | 6 in all tests; probably the AUTO-SENS margin in dB (not tested) |
| 21 | AUTO-SENS state: 0 = off, 2 = measurement in progress (SENS shows 0), 1 = measurement complete |
| 22 | Output select |
| 23 | LO-CUT: bit 0 = IN 1, bit 1 = IN 2 |
| 24 | PHASE: bit 0 = IN 1, bit 1 = IN 2 |
| 25, 26 | SENS of IN 1, IN 2 |
| 27 | Stereo link (bit 0) |
| 28 | Compressor on: bit 0 = IN 1, bit 1 = IN 2 |
| 29, 30 | Gate of IN 1, IN 2 |
| 31, 32 | Attack of IN 1, IN 2 |
| 33, 34 | Release of IN 1, IN 2 |
| 35, 36 | Threshold of IN 1, IN 2 |
| 37, 38 | Ratio of IN 1, IN 2 |
| 39, 40 | Gain of IN 1, IN 2 |
| 41-46 | Mixer level INPUT 1 (24-bit, 6 nibbles) |
| 47-52 | Mixer level INPUT 2 |
| 53-58 | Mixer level COAX |

#### Behavior found in tests (19 October 2026)

- The device answers the RQ1 at once, also when no audio stream runs.
- Factory values seen: compressor off, threshold -20 dB, ratio 1:4, attack 2 ms, release
  200 ms, gain 0 dB, gate -INF, mixer levels 0 dB.
- **The SENS knobs operate in the device.** A turn of SENS 1L or SENS 2R changes the gain at
  once, and the device sends a DT1 message for each step on cable 1, for example
  `F0 41 10 00 00 56 12 00 05 00 04 3A 3D F7` (IN 1 SENS = 0x3A = 29 dB). The driver does not
  have to answer these messages. With the SENS knobs at minimum, the gain is 0 dB and the
  recorded level is very low.
- **AUTO-SENS operates in the device.** The device sends `00 02 01 02` = 0 when the measurement
  starts, sets byte 21 of the state block, and sets the SENS values when the measurement ends.
- **The host must read interface 2 at all times.** If no process reads the bulk IN endpoint
  `0x86`, the messages of the SENS knobs and of AUTO-SENS stay in the queue of the device. When
  the queue is full, the front panel stops: the SENS rings go dark, and AUTO-SENS and DIRECT
  MONITOR do not respond. Audio continues. A read of the queue makes the panel operate again
  (the waiting knob and button events are then processed). The Roland driver always reads
  interface 2. In this project, the audio plug-in reads it (`src/engine/qc_ctl.m`) while no
  other process uses it; the MIDI driver and `qc_sysex` post the notification
  `com.louistissot.quadcapture.interface2.want`, and the plug-in releases the interface for 5 s.
- The MIDI driver ignores cable 1, so the control messages do not go to MIDI apps.
- **DIRECT MONITOR, MIX, OUTPUT and PHONES** operate in the device. They do not change the state
  block and the device sends no message for them.
- **The SENS knob of IN 2** sends `00 05 01 04`. Thus `c` is byte 2 of the address (IN 1:
  `00 05 00 04`).
- **The device sends each DT1 back.** After the device applies a DT1 from the host, it sends the
  same message (same address, same data) on cable 1, about 20 to 140 ms later. This was seen for
  the parameters `00 05 0c xx` and the mixer level `00 06 00 08` (INPUT 1). The panel app uses this echo
  as flow control: it sends one DT1 at a time, and it sends the next one after the echo (or after
  300 ms).
- **Stereo link on** (`00 05 00 05` = 1): the device copies the compressor settings of IN 1 to
  IN 2 and sends 7 DT1 messages, `00 05 01 06` to `00 05 01 0c`, with the new values of IN 2.
  Stereo link off sends no copy.
- **Gain** (`00 05 0c 0c`): the values `0x32` (0 dB) and `0x33` (+1 dB) were written, and the
  state block showed them. The full range (0 to 74) is not tested yet.
- **Mixer levels**: DT1 messages to `00 06 00 08` from about -50 dB to 0 dB were written. Each
  echo and the next state block agreed with the values.

`build/qc_sysex` sends the RQ1 and decodes the reply. `build/qc_sysex -m <seconds>` reads the
state block each 300 ms and prints each change and each message from the device. `build/qc_sysex -w <address> <data...>`
sends a DT1.

`build/QuadCapture Panel.app` (`src/panel/`) is a control panel app that uses this protocol. It
reads the state block at start and after each group of writes, follows the DT1 messages from the
device, and never sends the "Initialize" address `00 00 00 02`. It gets interface 2 with the same
notification, reads the interface at all times while it holds it, releases it when another process
posts the notification, and closes it when the app quits.

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
