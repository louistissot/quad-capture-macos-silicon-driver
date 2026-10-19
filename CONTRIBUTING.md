# Contributing to QuadCaptureMac

Thank you for your help. Bug reports, compatibility reports, documentation, and code are all
welcome.

## Reports

- **Compatibility report:** use the "Compatibility report" issue form. Give your Mac model, your
  macOS version, and what operated.
- **Bug report:** use the "Bug report" issue form, and attach the driver log:

  ```bash
  /usr/bin/log show --last 30m --predicate 'subsystem == "com.louistissot.quadcapture"'
  ```

- **USB captures** of the official Roland driver (Windows with Wireshark and USBPcap, or an Intel
  Mac with macOS 12 or earlier) are very useful for the sample-rate command and the control panel
  protocol. Attach the `.pcapng` file and write down what you did at which time.

## Build and test

```bash
./build.sh                       # driver and test tools
./packaging/make_pkg.sh          # installer packages in dist/
SDK=macosx15.4 ./build.sh        # optional: build with an older SDK to find APIs that are too new
```

The build fails on an API that is newer than the deployment target (macOS 12). If you must use a
newer API, call it only after a run-time check (see `refreshRef` in `src/engine/qc_engine.m`).

Tests with the hardware:

1. `build/qc_engine_test -s 30` uses the USB engine directly. It must report 0 missing frames,
   0 late frames and 0 USB errors.
2. Install your build. Remove the installed plug-in first, so that the copy is a new file:
   `sudo rm -rf /Library/Audio/Plug-Ins/HAL/QuadCapture.driver && sudo cp -R build/QuadCapture.driver
   /Library/Audio/Plug-Ins/HAL/ && sudo killall coreaudiod`.
3. `build/qc_hal_test -s 60` uses the device through Core Audio. It must report 0 sample-time
   breaks. `build/qc_hal_test -q` prints the driver statistics.
4. CAUTION: Set the volume of your speakers and headphones low before the next step.
   `build/qc_hal_test -T` plays a tone: 440 Hz on the left, then 660 Hz on the right.

Give the results of these tests in your pull request.

## Rules for the engine

The firmware of the QUAD-CAPTURE is fragile (see [docs/PROTOCOL.md](docs/PROTOCOL.md)). Obey these
rules:

- Never send an isochronous request with 0 bytes.
- Never stop the playback stream while the capture stream continues.
- Stop the streams with a clean drain (no new requests, then wait). Use an abort only if the drain
  times out.
- In the real-time functions (`qc_engine_read_input`, `qc_engine_write_output`,
  `qc_engine_zero_timestamp`, and the IO functions of the driver), use no locks, no allocation,
  no Objective-C messages, and no logs.

## Code style

- C11 and Objective-C with ARC. 4 spaces, lines of 120 characters or less.
- Comments explain why, not what.
- One change in one pull request. Give the reason and the test results in the description.

## License of contributions

The project uses the MIT license. When you send a contribution, you agree that it uses the same
license.
