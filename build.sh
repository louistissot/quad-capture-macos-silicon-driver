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
clang $COMMON $OBJC -o build/qc_engine_test tools/qc_engine_test.m src/engine/qc_engine.m $FW
clang $COMMON -o build/qc_hal_test tools/qc_hal_test.c -framework CoreAudio -framework CoreFoundation

DRV=build/QuadCapture.driver
rm -rf $DRV
mkdir -p $DRV/Contents/MacOS
sed "s/@VERSION@/$VERSION/g" src/driver/Info.plist > $DRV/Contents/Info.plist
clang $COMMON -x c -c -o build/qc_driver.o src/driver/qc_driver.c
clang $COMMON $OBJC -c -o build/qc_engine.o src/engine/qc_engine.m
clang $COMMON -bundle -o $DRV/Contents/MacOS/QuadCapture build/qc_driver.o build/qc_engine.o \
    $FW -framework CoreAudio -framework CoreFoundation
rm -f build/qc_driver.o build/qc_engine.o
if [[ -n "${SIGN_IDENTITY:-}" && "$SIGN_IDENTITY" != "-" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp $DRV   # for notarization
else
    codesign --force --sign - --timestamp=none $DRV                               # ad-hoc signature
fi
echo "Built $DRV $VERSION ($(lipo -archs $DRV/Contents/MacOS/QuadCapture), macOS $MINOS+, SDK $(basename $SDKPATH))"
