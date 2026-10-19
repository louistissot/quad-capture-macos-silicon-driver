# QuadCaptureMac: a macOS driver for the Roland QUAD-CAPTURE

QuadCaptureMac is an open-source driver for the **Roland QUAD-CAPTURE (UA-55)** USB audio
interface. Roland stopped the development of its driver: the last Roland driver supports only Intel
Macs with macOS 12 or earlier. With this driver, the QUAD-CAPTURE operates on Apple Silicon Macs
(M1 and later) and on Intel Macs with macOS 12 or later.

> This project is not made, approved or supported by Roland Corporation. "Roland" and
> "QUAD-CAPTURE" are trademarks of Roland Corporation. The project uses these names only to
> identify the hardware that it supports.

## Features

- A Core Audio device with the name **QUAD-CAPTURE** in all apps (Logic Pro, Ableton Live,
  GarageBand, Reaper, System Settings, and others).
- 4 inputs: IN 1, IN 2, DIGITAL IN L, DIGITAL IN R.
- 4 outputs: OUT 1L, OUT 2R (also PHONES), DIGITAL OUT L, DIGITAL OUT R.
- MIDI IN and MIDI OUT: a CoreMIDI driver gives the MIDI ports of the QUAD-CAPTURE to all MIDI apps.
- A control panel app for the settings of the preamps, the compressors and the monitor mixer
  (see [Control panel](#control-panel)).
- 44.1, 48, 96 and 192 kHz, 24-bit. Select the rate in Audio MIDI Setup or in your music app.
  At 192 kHz the QUAD-CAPTURE has only 2 inputs and 2 outputs: DIGITAL IN and DIGITAL OUT are silent.
- With a digital source at COAXIAL IN, the QUAD-CAPTURE runs on the clock of that source. The
  driver then uses the rate of the source, and other rates are not available.
- The audio clock comes from the QUAD-CAPTURE itself, so there is no drift.
- Output volume and mute: the macOS volume keys operate.
- Hot-plug: the device shows when you connect the QUAD-CAPTURE and goes away when you disconnect it.
- No kernel extension and no change to the macOS security settings. The driver is a standard
  Core Audio plug-in that runs in user space.

## Status

Version 1.0.0. See [CHANGELOG.md](CHANGELOG.md).

| Configuration | Status |
|---|---|
| MacBook Pro M4 Pro, macOS 26.6 | Tested by the author |
| Other Apple Silicon Macs (M1, M2, M3, M5), macOS 12 to 26 | Expected to operate, not tested yet |
| Intel Macs, macOS 12 or later | The build is universal, not tested yet |

If you use a Mac that is not in the table, please send a
[compatibility report](../../issues/new?template=compatibility_report.yml). It helps all users.

### Known limits

- **The control panel app is not in the packages yet.** To use it, build it from source (see
  [Control panel](#control-panel)). Some settings of the Roland control panel (output select,
  DIGITAL IN setting, AUTO-SENS margin) are not in the app, because their values are not known yet.
- **The control panel app and MIDI apps cannot run at the same time.** They use the same USB
  interface of the QUAD-CAPTURE (interface 2).
- **Unsigned packages.** The packages do not have an Apple Developer ID signature, so macOS shows
  a warning when you open them. See [Install](#install).

## Install

1. Download `QuadCapture-Driver-<version>.pkg` from the [Releases](../../releases) page.
2. Open the package.
3. If macOS shows "Apple could not verify ...", click **Done**. Then open System Settings >
   Privacy & Security, scroll down, and click **Open Anyway** next to the package name.
4. Follow the steps of the installer. You must type your Mac password.

   CAUTION: At the end of the installation, the macOS audio service restarts. All audio on the
   Mac stops for a few seconds.

5. Connect the QUAD-CAPTURE with its USB cable. If macOS asks you to allow the accessory, click
   **Allow**.
6. In System Settings > Sound, or in your music app, select **QUAD-CAPTURE**.

To hear your inputs with no delay, use the DIRECT MONITOR control on the QUAD-CAPTURE.

If the recorded level is low, turn the SENS knob of the input up, or press AUTO-SENS and play
at your loudest level. With the SENS knobs at minimum, the preamp gain is 0 dB.

## Control panel

`QuadCapture Panel.app` replaces the Roland control panel app, which does not operate on Apple
Silicon Macs. It shows and changes these settings of IN 1 and IN 2:

- SENS (input gain), LO-CUT and PHASE.
- The compressor: on/off, threshold, ratio, attack, release, gate and gain.
- The stereo link of IN 1 and IN 2.
- The monitor mixer levels in OUTPUT 1-2: INPUT 1, INPUT 2 and COAX.

To get the app, build it from source (see [Build from source](#build-from-source)), then open
`build/QuadCapture Panel.app`.

CAUTION: The app sends each change to the QUAD-CAPTURE at once. The device keeps the settings
after a power cycle.

- The app follows the SENS knobs and AUTO-SENS on the QUAD-CAPTURE. The other knobs and buttons
  (DIRECT MONITOR, MIX, OUTPUT, PHONES) operate in the device and do not show in the app.
- If a MIDI app runs (for example a music app that uses MIDI), the app shows "Another process uses
  the control channel". Quit the MIDI apps. The app connects again automatically.
- If the app shows "The QUAD-CAPTURE does not answer", disconnect the USB cable for 5 seconds, then
  connect it again.

## Uninstall

Open `QuadCapture-Driver-Uninstaller-<version>.pkg` from the [Releases](../../releases) page.
You can also use this command in Terminal:

```bash
sudo rm -rf /Library/Audio/Plug-Ins/HAL/QuadCapture.driver && sudo killall coreaudiod
```

## Troubleshooting

| Problem | What to do |
|---|---|
| The QUAD-CAPTURE device is not in the list | Disconnect the USB cable, wait 5 seconds, and connect it again. Make sure that the driver is installed: `ls /Library/Audio/Plug-Ins/HAL/`. |
| No sound | Turn the OUTPUT and PHONES knobs up. Make sure that the macOS volume of the device is not at 0 and not muted. |
| The device does not operate after it stopped abruptly | Disconnect the USB cable for 5 seconds, then connect it again. The firmware of the QUAD-CAPTURE can stop when its stream stops abruptly. |
| After the installation, no app can use audio, and `coreaudiod` uses 100 % CPU | The installation restarts the macOS audio service. Some apps that use audio (seen with Unity apps) can then keep the audio service busy. Quit these apps, or restart the Mac. If possible, quit audio apps before you install. |

To send a useful bug report, attach the driver log:

```bash
/usr/bin/log show --last 30m --predicate 'subsystem == "com.louistissot.quadcapture"'
```

## How it works

```
App ─> Core Audio (HAL) ─> QuadCapture.driver (AudioServerPlugIn)
                              └─ qc_engine: IOUSBHost isochronous streams ─> USB ─> QUAD-CAPTURE
```

- The QUAD-CAPTURE is not "class compliant": its USB audio interfaces are vendor-specific, so
  macOS does not recognize it. The format of its audio streams is close to USB Audio Class 1.
  The Linux `snd-usb-audio` driver supports the device and documents its endpoints.
- The plug-in (`src/driver/qc_driver.c`) publishes the Core Audio device. The USB engine
  (`src/engine/qc_engine.m`) runs inside the plug-in. It sends and receives the isochronous USB
  packets through the Apple IOUSBHost framework. It needs no kernel extension and no special
  entitlement.
- The size of each playback packet follows the size of a capture packet (implicit feedback).
- The Core Audio clock (zero timestamps) comes from the capture packets, so it follows the clock
  of the QUAD-CAPTURE.

[docs/PROTOCOL.md](docs/PROTOCOL.md) gives the USB protocol, the behavior of the device firmware,
and the design of the engine.

## Build from source

You need the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh
```

This builds `build/QuadCapture.driver` (universal: arm64 and x86_64, macOS 12 or later) and the
test tools. To build the installer packages in `dist/`:

```bash
./packaging/make_pkg.sh
```

To install a local build without a package, remove the installed plug-in first. If `cp` writes
over the old binary, macOS keeps the old code signature for that file and stops the driver
helper ("Code Signature Invalid"):

```bash
sudo rm -rf /Library/Audio/Plug-Ins/HAL/QuadCapture.driver && sudo cp -R build/QuadCapture.driver /Library/Audio/Plug-Ins/HAL/ && sudo killall coreaudiod
```

### Test tools

| Tool | Use |
|---|---|
| `build/qc_hal_test [-T] [-q] [-c ...]` | Uses the installed device through Core Audio, as an app does. `-T` plays a test tone, `-q` prints the driver configuration and statistics, `-c` changes the USB queue. |
| `build/qc_engine_test [-T]` | Uses the USB engine directly, with no installed driver. |
| `build/qc_capture [-T]` | Low-level USB recorder and tone test. |
| `build/qc_descriptors` | Prints the USB descriptors. |
| `build/qc_sysex [-m seconds]` | Reads the control-panel settings of the device (SENS, compressor, mixer), or watches their changes. `-w` changes a setting. |
| `build/QuadCapture Panel.app` | The control panel app: SENS, LO-CUT, PHASE, compressor, stereo link and monitor mixer of IN 1 and IN 2. It replaces the Roland control panel. Changes go to the device at once, and the device keeps them after a power cycle. |
| `build/qc_rate [hz]` | Reads the sample rate of the device, or changes it (44100, 48000, 96000, 192000). Use it only while no app uses the QUAD-CAPTURE. |

CAUTION: Before you use `-T`, set the volume of your speakers and headphones low.

The test tools and an app cannot use the QUAD-CAPTURE at the same time.

## Help wanted

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). These items need help:

- **Compatibility reports** from other Macs and macOS versions.
- **The control panel protocol**: the values of output select, DIGITAL IN setting and AUTO-SENS
  margin (see [docs/PROTOCOL.md](docs/PROTOCOL.md)), also from a USB capture.
- **An Apple Developer ID**, to sign and notarize the packages.

## License

MIT. See [LICENSE](LICENSE).

## Acknowledgments

- The developers of the Linux `snd-usb-audio` driver, whose quirk table documents the endpoints
  of the QUAD-CAPTURE.
- The Apple "NullAudio" sample driver, which shows the object model of an AudioServerPlugIn.
