# Change log

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
