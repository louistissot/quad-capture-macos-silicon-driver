# Change log

## Unreleased

- Sample rates 48, 96 and 192 kHz (was 44.1 kHz only). Select the rate in Audio MIDI Setup or in
  an app. The driver sets the clock of the QUAD-CAPTURE with a vendor request when the stream
  starts (the change takes about 1 s). The driver keeps the selected rate after a restart.
- At 192 kHz the device has 2 inputs and 2 outputs; the DIGITAL channels are silent.
- The safety margins scale with the sample rate.
- New tool `build/qc_rate` reads and changes the device rate. `qc_hal_test -r` and
  `qc_engine_test -r` test a rate.

## 0.3.0 (beta)

- Much lower latency. Safety offsets: output 3 ms (was 42 ms), input 3.4 ms (was 12 ms).
  - Direct write: the Core Audio IO thread writes the playback samples directly into the queued
    USB requests, until 1 ms before the transfer.
  - Direct read: a real-time thread reads the capture data directly from the queued USB requests,
    250 us after each microframe, and publishes the clock.
  - So the latency does not depend on the time of the USB callbacks. The USB queue is now 128 ms
    deep: a callback can be up to 128 ms late with no dropout (a 126 ms delay occurred in tests
    during heavy system activity).
- The start waits until all queued playback requests can take direct writes (no silent start).
- The driver sets the USB configuration as soon as the QUAD-CAPTURE connects (and when the audio
  service starts), as the Roland driver does. The lights of the device show that it is ready.
- A log line for each USB callback delay longer than 20 ms.
- Removed the experimental scheduling modes (one of them could block the audio service for 60 s).
- The stored tuning values of older versions are ignored.

## 0.2.0 (beta)

- 4 inputs (IN 1, IN 2, DIGITAL IN L/R) and 4 outputs (OUT 1L, OUT 2R, DIGITAL OUT L/R), with
  channel names.
- Output volume and mute controls (macOS volume keys). The settings stay after a restart.
- Hot-plug: the device shows when the QUAD-CAPTURE connects and goes away when it disconnects.
- Lower latency: output safety offset 42 ms (was 139 ms), input safety offset 12 ms (was 35 ms).
- A late USB request moves to a later frame and does not stop the stream.
- Clock fallback for macOS 12 to 15 (the microframe API exists only on macOS 26 or later).
- Universal build (Apple Silicon and Intel), macOS 12 or later.
- Installer and uninstaller packages.
- Custom properties `qcfg` (USB queue) and `qsta` (statistics) for tests and tuning.

## 0.1.0

- First version: 2 inputs and 2 outputs at 44.1 kHz, Core Audio plug-in with the USB engine inside.
