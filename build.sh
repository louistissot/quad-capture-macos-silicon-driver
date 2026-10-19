#!/bin/zsh
# Build the QuadCaptureMac test tools and the Core Audio plug-in (build/QuadCapture.driver).
# Universal binaries (arm64 + x86_64), macOS 12 or later.
#   ./build.sh            build with the default SDK
#   SDK=macosx15.4 ./build.sh   build with another installed SDK (to find APIs that are too new)
set -euo pipefail
cd "${0:a:h}"
mkdir -p build

VERSION=$(cat VERSION)
SDKPATH=$(xcrun --sdk "${SDK:-macosx}" --show-sdk-path)
ARCH=(-arch arm64 -arch x86_64)
MINOS=12.0
COMMON=(-isysroot "$SDKPATH" $ARCH -mmacosx-version-min=$MINOS -O2 -Wall -Wextra -Wno-unused-parameter
        -Werror=unguarded-availability-new -Werror=partial-availability -Isrc)
OBJC=(-fobjc-arc)
FW=(-framework Foundation -framework IOKit -framework IOUSBHost)

clang $COMMON $OBJC -o build/qc_descriptors tools/qc_descriptors.m $FW
clang $COMMON $OBJC -o build/qc_capture tools/qc_capture.m $FW
clang $COMMON $OBJC -o build/qc_rate tools/qc_rate.m $FW
clang $COMMON $OBJC -o build/qc_engine_test tools/qc_engine_test.m src/engine/qc_engine.m $FW
clang $COMMON -o build/qc_hal_test tools/qc_hal_test.c -framework CoreAudio -framework CoreFoundation
clang $COMMON -o build/qc_midi_codec_test tools/qc_midi_codec_test.c src/midi/qc_usbmidi.c
clang $COMMON -o build/qc_midi_test tools/qc_midi_test.c -framework CoreMIDI -framework CoreFoundation

DRV=build/QuadCapture.driver
rm -rf $DRV
mkdir -p $DRV/Contents/MacOS
sed "s/@VERSION@/$VERSION/g" src/driver/Info.plist > $DRV/Contents/Info.plist
clang $COMMON -x c -c -o build/qc_driver.o src/driver/qc_driver.c
clang $COMMON $OBJC -c -o build/qc_engine.o src/engine/qc_engine.m
clang $COMMON -bundle -o $DRV/Contents/MacOS/QuadCapture build/qc_driver.o build/qc_engine.o \
    $FW -framework CoreAudio -framework CoreFoundation
rm -f build/qc_driver.o build/qc_engine.o

# CoreMIDI driver (MIDI IN / MIDI OUT).
MID=build/QuadCaptureMIDI.plugin
rm -rf $MID
mkdir -p $MID/Contents/MacOS
sed "s/@VERSION@/$VERSION/g" src/midi/Info.plist > $MID/Contents/Info.plist
clang $COMMON -c -o build/qc_usbmidi.o src/midi/qc_usbmidi.c
clang $COMMON $OBJC -c -o build/qc_midi_driver.o src/midi/qc_midi_driver.m
clang $COMMON -bundle -o $MID/Contents/MacOS/QuadCaptureMIDI build/qc_midi_driver.o build/qc_usbmidi.o \
    $FW -framework CoreMIDI -framework CoreFoundation
rm -f build/qc_usbmidi.o build/qc_midi_driver.o

for B in $DRV $MID; do
    if [[ -n "${SIGN_IDENTITY:-}" && "$SIGN_IDENTITY" != "-" ]]; then
        codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp $B   # for notarization
    else
        codesign --force --sign - --timestamp=none $B                               # ad-hoc signature
    fi
done
echo "Built $DRV $VERSION ($(lipo -archs $DRV/Contents/MacOS/QuadCapture), macOS $MINOS+, SDK $(basename $SDKPATH))"
echo "Built $MID $VERSION ($(lipo -archs $MID/Contents/MacOS/QuadCaptureMIDI))"
