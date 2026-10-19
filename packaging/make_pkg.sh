#!/bin/zsh
# Build the installer packages in dist/:
#   QuadCapture-Driver-<version>.pkg              installs the Core Audio plug-in
#   QuadCapture-Driver-Uninstaller-<version>.pkg  removes it
#   SHA256SUMS.txt
# Optional signing and notarization (Apple Developer ID):
#   SIGN_IDENTITY="Developer ID Application: ..."    signs the plug-in (hardened runtime)
#   INSTALLER_IDENTITY="Developer ID Installer: ..." signs the packages
#   NOTARY_PROFILE=<notarytool keychain profile>     notarizes and staples the packages
set -euo pipefail
cd "${0:a:h}/.."
VERSION=$(cat VERSION)
./build.sh

WORK=build/pkg
rm -rf $WORK
mkdir -p $WORK/root/Library/Audio/Plug-Ins/HAL "$WORK/root/Library/Audio/MIDI Drivers" $WORK/resources dist
ditto build/QuadCapture.driver $WORK/root/Library/Audio/Plug-Ins/HAL/QuadCapture.driver
ditto build/QuadCaptureMIDI.plugin "$WORK/root/Library/Audio/MIDI Drivers/QuadCaptureMIDI.plugin"
cp packaging/resources/*.html $WORK/resources/
cp LICENSE $WORK/resources/LICENSE.txt

# The bundles must go to their system folders, also if another copy of a bundle exists.
pkgbuild --analyze --root $WORK/root $WORK/component.plist >/dev/null
i=0
while /usr/libexec/PlistBuddy -c "Print :$i:RootRelativeBundlePath" $WORK/component.plist >/dev/null 2>&1; do
    /usr/libexec/PlistBuddy -c "Delete :$i:BundleIsRelocatable" $WORK/component.plist >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :$i:BundleIsRelocatable bool false" $WORK/component.plist
    i=$((i + 1))
done

pkgbuild --root $WORK/root --component-plist $WORK/component.plist \
    --identifier com.louistissot.quadcapture.driver --version $VERSION \
    --scripts packaging/scripts --install-location / $WORK/driver.pkg >/dev/null
pkgbuild --nopayload --scripts packaging/uninstall-scripts \
    --identifier com.louistissot.quadcapture.uninstall --version $VERSION $WORK/uninstall.pkg >/dev/null

sed "s/@VERSION@/$VERSION/g" packaging/distribution.xml > $WORK/distribution.xml
sed "s/@VERSION@/$VERSION/g" packaging/uninstall-distribution.xml > $WORK/uninstall-distribution.xml

SIGN=()
[[ -n "${INSTALLER_IDENTITY:-}" ]] && SIGN=(--sign "$INSTALLER_IDENTITY")
PKG=dist/QuadCapture-Driver-$VERSION.pkg
UNPKG=dist/QuadCapture-Driver-Uninstaller-$VERSION.pkg
productbuild --distribution $WORK/distribution.xml --resources $WORK/resources --package-path $WORK $SIGN $PKG >/dev/null
productbuild --distribution $WORK/uninstall-distribution.xml --resources $WORK/resources --package-path $WORK $SIGN $UNPKG >/dev/null

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    for p in $PKG $UNPKG; do
        xcrun notarytool submit $p --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple $p
    done
fi

(cd dist && shasum -a 256 QuadCapture-Driver-$VERSION.pkg QuadCapture-Driver-Uninstaller-$VERSION.pkg > SHA256SUMS.txt)
echo "Built $PKG and $UNPKG"
