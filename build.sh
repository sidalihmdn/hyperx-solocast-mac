#!/bin/sh
# Builds SoloCast.app next to this script, then runs the self-check against the mic.
set -e
cd "$(dirname "$0")"
mkdir -p SoloCast.app/Contents/MacOS SoloCast.app/Contents/Resources
cp AppIcon.icns SoloCast.app/Contents/Resources/
# Explicit target: swiftc's default deployment version came out newer than the running OS, so the app refused to launch.
swiftc -O -parse-as-library -target "$(uname -m)-apple-macos13.0" SoloCast.swift -o SoloCast.app/Contents/MacOS/SoloCast
cat > SoloCast.app/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SoloCast</string>
<key>CFBundleIdentifier</key><string>local.solocast</string>
<key>CFBundleName</key><string>SoloCast</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>1.1</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>SoloCast reads the microphone to show levels and apply the gate, EQ and compressor.</string>
</dict></plist>
EOF
# Signed so macOS can remember the microphone permission for this build.
codesign --force --sign - SoloCast.app
SoloCast.app/Contents/MacOS/SoloCast --check
