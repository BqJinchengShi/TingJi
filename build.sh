#!/bin/bash
# 编译 CLI（tingji-cli）+ GUI App（TingJi.app）。
# 裸 swiftc，绕过 SPM 链接问题。
set -e
cd "$(dirname "$0")"
mkdir -p .build

COMMON="-swift-version 5 -target arm64-apple-macosx14 -O"
FW="-framework AVFoundation -framework ScreenCaptureKit -framework CoreMedia -framework CryptoKit -framework Carbon -framework Foundation"

# CLI
CLI_SRCS=$(find Sources/DoubaoRecorder -name '*.swift' | sort)
swiftc $COMMON $CLI_SRCS Sources/doubao-recorder/App.swift $FW -o .build/tingji-cli
echo "built: .build/tingji-cli"

# GUI 可执行
GUI_SRCS=$(find Sources/DoubaoRecorder Sources/DoubaoRecorderApp -name '*.swift' | sort)
swiftc $COMMON $GUI_SRCS $FW -framework SwiftUI -framework AppKit -o .build/TingJi
echo "built: .build/TingJi"

# 生成 App 图标
swiftc -framework AppKit -framework Foundation gen_icon.swift -o .build/gen_icon 2>/dev/null
./.build/gen_icon 2>/dev/null || true

# 打 .app bundle
APP=.build/TingJi.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/TingJi "$APP/Contents/MacOS/TingJi"
cp Info.plist "$APP/Contents/"
[ -f AppIcon.png ] && cp AppIcon.png "$APP/Contents/Resources/AppIcon.png"
codesign -s TingJiSign --force "$APP" 2>/dev/null || codesign -s - "$APP" 2>/dev/null || true
echo "built: $APP"

# 打 DMG 安装包（含 .app + Applications 链接，拖拽安装）
DMG=.build/听记.dmg
rm -rf /tmp/tingji_dmg && mkdir -p /tmp/tingji_dmg
cp -R "$APP" /tmp/tingji_dmg/
ln -s /Applications /tmp/tingji_dmg/Applications
hdiutil create -volname "听记" -srcfolder /tmp/tingji_dmg -ov -format UDZO "$DMG" 2>/dev/null
rm -rf /tmp/tingji_dmg
echo "built: $DMG"
