#!/bin/sh
# Build the release assets into dist/, for Apple Silicon and Intel in one binary:
#   dist/img2text          the command (what install.sh downloads)
#   dist/img2text.app.zip  the app, unsigned
#
#   ./release.sh 0.1.0
set -eu

version=${1:?usage: ./release.sh VERSION   e.g. ./release.sh 0.1.0}
cd "$(dirname "$0")"

swift build -c release --arch arm64 --arch x86_64
bin="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/img2text"

rm -rf dist
mkdir -p dist/img2text.app/Contents/MacOS
cp "$bin" dist/img2text
cp "$bin" dist/img2text.app/Contents/MacOS/img2text
cat > dist/img2text.app/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>img2text</string>
    <key>CFBundleExecutable</key><string>img2text</string>
    <key>CFBundleIdentifier</key><string>com.jam-sw.img2text</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Image</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>public.image</string></array>
        </dict>
    </array>
</dict>
</plist>
EOF

codesign --force --sign - dist/img2text
codesign --force --sign - dist/img2text.app
ditto -c -k --keepParent dist/img2text.app dist/img2text.app.zip

echo "Built dist/img2text and dist/img2text.app.zip ($version)"
