#!/bin/bash
# Quiet Timer installer
# Compiles the Swift source in ./src/<lang>/ on this Mac and installs the app into ~/Applications.
#
# Usage:  bash install.sh [en|zh]        (default: en)
#
# Installing one language replaces the other one if it is already installed.

set -euo pipefail

LANG_CODE="${1:-en}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/src/$LANG_CODE/main.swift"
DEST_DIR="$HOME/Applications"
EXEC_NAME="QuietTimer"

case "$LANG_CODE" in
  en)
    APP_NAME="Quiet Timer"
    BUNDLE_ID="local.quiettimer.en"
    M_NOT_MAC="This installer only works on macOS."
    M_NO_SRC="Source file not found:"
    M_CHECK="Checking for the Swift compiler (Xcode Command Line Tools)..."
    M_NO_CLT_1="The Xcode Command Line Tools are not installed. A system dialog will open: click Install,"
    M_NO_CLT_2="wait for it to finish (a few minutes), then run this script again."
    M_COMPILE="Compiling (about 20-60 seconds)..."
    M_BUNDLE="Building the app..."
    M_SIGN_WARN="(Note: ad-hoc code signing failed. This is usually harmless.)"
    M_LAUNCH="Launching..."
    M_DONE="Done! Quiet Timer is installed."
    M_TIP_1="  - A small pill ('Click to set') appears in the top-right corner of your screen. Click it to start a countdown."
    M_TIP_2="  - Drag the pill to any corner. Click it (or right-click) for the menu."
    M_TIP_3="  - Hide / show the pill anywhere with Control + Option + T."
    M_TIP_4="  - There is also a small timer icon in the menu bar with the same menu."
    M_WHERE="  - App location:"
    ;;
  zh)
    APP_NAME="静音倒计时"
    BUNDLE_ID="local.quiettimer.app"
    M_NOT_MAC="这个安装脚本只能在 Mac 上运行。"
    M_NO_SRC="找不到源码文件："
    M_CHECK="正在检查 Swift 编译器（Xcode 命令行工具）..."
    M_NO_CLT_1="没有检测到 Xcode 命令行工具。系统会弹出安装窗口，点「安装」，"
    M_NO_CLT_2="装完（几分钟）后再重新运行本脚本即可。"
    M_COMPILE="正在编译（大约 20-60 秒，请稍等）..."
    M_BUNDLE="正在生成 App..."
    M_SIGN_WARN="（提示：本机自签名步骤失败，通常不影响使用。）"
    M_LAUNCH="正在启动..."
    M_DONE="安装完成！"
    M_TIP_1="  - 屏幕右上角会出现一个小胶囊「点击设置」，点它选择时长即可开始倒计时"
    M_TIP_2="  - 胶囊可以拖到任意角落；点击或右键胶囊 = 打开菜单"
    M_TIP_3="  - 在任何软件里按 Control + Option + T 可以隐藏 / 显示胶囊"
    M_TIP_4="  - 菜单栏里还有一个小计时器图标，同样能打开菜单"
    M_WHERE="  - App 位置："
    ;;
  *)
    echo "Usage: bash install.sh [en|zh]"
    exit 1
    ;;
esac

if [ "$(uname)" != "Darwin" ]; then
  echo "$M_NOT_MAC"
  exit 1
fi

if [ ! -f "$SRC" ]; then
  echo "$M_NO_SRC $SRC"
  exit 1
fi

echo "$M_CHECK"
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "$M_NO_CLT_1"
  echo "$M_NO_CLT_2"
  xcode-select --install 2>/dev/null || true
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "$M_COMPILE"
xcrun swiftc -O -swift-version 5 -o "$WORK/$EXEC_NAME" "$SRC"

echo "$M_BUNDLE"
APP_PATH="$DEST_DIR/$APP_NAME.app"
pkill -x "$EXEC_NAME" 2>/dev/null || true
mkdir -p "$DEST_DIR"
# Remove a previous install of either language (only this app's own bundles).
rm -rf "$DEST_DIR/Quiet Timer.app" "$DEST_DIR/静音倒计时.app"
mkdir -p "$APP_PATH/Contents/MacOS"
cp "$WORK/$EXEC_NAME" "$APP_PATH/Contents/MacOS/$EXEC_NAME"

cat > "$APP_PATH/Contents/Info.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST_EOF

# Ad-hoc sign on this machine (no developer account needed) so macOS accepts the locally built app.
codesign --force --deep --sign - "$APP_PATH" >/dev/null 2>&1 || echo "$M_SIGN_WARN"
xattr -cr "$APP_PATH" 2>/dev/null || true

echo "$M_LAUNCH"
open "$APP_PATH"

echo ""
echo "$M_DONE"
echo "$M_TIP_1"
echo "$M_TIP_2"
echo "$M_TIP_3"
echo "$M_TIP_4"
echo "$M_WHERE $APP_PATH"
