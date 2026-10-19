#!/bin/zsh
# Build build/QuadCapture Panel.app: the control panel app for the QUAD-CAPTURE (SwiftUI, no Xcode
# project). Universal binary (arm64 + x86_64), macOS 12 or later. build.sh calls this script.
#   src/panel/build_panel.sh            build with the default SDK
#   SDK=macosx15.4 src/panel/build_panel.sh
set -euo pipefail
cd "${0:a:h}/../.."
mkdir -p build

VERSION=$(cat VERSION)
SDKPATH=$(xcrun --sdk "${SDK:-macosx}" --show-sdk-path)
MINOS=12.0
APP="build/QuadCapture Panel.app"
TMP=build/panel.tmp
rm -rf "$APP" $TMP
mkdir -p "$APP/Contents/MacOS" $TMP

for A in arm64 x86_64; do
    C=(-isysroot "$SDKPATH" -arch $A -mmacosx-version-min=$MINOS -O2 -Wall -Wextra -Wno-unused-parameter
       -Werror=unguarded-availability-new -Werror=partial-availability -Isrc)
    clang $C -fobjc-arc -c -o $TMP/QCPanelUSB-$A.o src/panel/QCPanelUSB.m
    clang $C -c -o $TMP/qc_usbmidi-$A.o src/midi/qc_usbmidi.c
    swiftc -target $A-apple-macos$MINOS -sdk "$SDKPATH" -swift-version 5 -O -Isrc \
        -import-objc-header src/panel/QCPanel-Bridging.h -module-name QuadCapturePanel \
        -o $TMP/QuadCapturePanel-$A src/panel/PanelModel.swift src/panel/PanelApp.swift src/panel/AudioDevice.swift \
        src/panel/Controls.swift src/panel/WebPanel.swift \
        $TMP/QCPanelUSB-$A.o $TMP/qc_usbmidi-$A.o \
        -framework AppKit -framework SwiftUI -framework IOKit -framework IOUSBHost -framework CoreAudio \
        -framework Network -framework CoreImage
done
lipo -create -output "$APP/Contents/MacOS/QuadCapturePanel" $TMP/QuadCapturePanel-arm64 $TMP/QuadCapturePanel-x86_64
sed "s/@VERSION@/$VERSION/g" src/panel/Info.plist > "$APP/Contents/Info.plist"
rm -rf $TMP

if [[ -n "${SIGN_IDENTITY:-}" && "$SIGN_IDENTITY" != "-" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP"   # for notarization
else
    codesign --force --sign - --timestamp=none "$APP"   # ad-hoc signature
fi
echo "Built $APP $VERSION ($(lipo -archs "$APP/Contents/MacOS/QuadCapturePanel"), macOS $MINOS+)"
