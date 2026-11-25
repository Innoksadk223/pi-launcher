#!/bin/bash
# 构建 PI 项目启动器.app
# 用法：./build.sh
set -euo pipefail

cd "$(dirname "$0")"

APP="PI 项目启动器.app"
BIN="$APP/Contents/MacOS/PI 项目启动器"
RES="$APP/Contents/Resources"

echo "==> 清理旧产物"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES"

echo "==> 运行自检"
SELFTEST_DIR="$(mktemp -d)"
swiftc -o "$SELFTEST_DIR/selftest" src/selftest.swift src/Store.swift src/SessionHistory.swift src/Launcher.swift src/Terminal.swift src/ProcessProbe.swift
"$SELFTEST_DIR/selftest" || { echo "自检未通过，已中止构建"; exit 1; }
rm -rf "$SELFTEST_DIR"

echo "==> 编译原生外壳"
swiftc -O -o "$BIN" src/Store.swift src/SessionHistory.swift src/Launcher.swift src/Terminal.swift src/ProcessProbe.swift src/main.swift

echo "==> 拷贝界面资源"
cp -R ui "$RES/ui"

# 资源带版本戳：WKWebView 对 file:// 子资源有缓存，不换 URL 的话
# 换过 css/js 之后重开还会拿旧的那份，看起来像「没更新」。
STAMP="$(date +%Y%m%d%H%M%S)"
for f in tokens.css glass.css app.css app.js; do
  /usr/bin/sed -i '' "s|$f\"|$f?v=${STAMP}\"|g" "$RES/ui/index.html"
done

echo "==> 应用图标"
if [ -f assets/icon/AppIcon-white.icns ]; then
  cp assets/icon/AppIcon-white.icns "$RES/AppIcon.icns"
else
  echo "   未找到图标（assets/icon/AppIcon-white.icns），将使用系统默认图标"
fi

echo "==> 写入 Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>PI 项目启动器</string>
  <key>CFBundleDisplayName</key>       <string>PI 项目启动器</string>
  <key>CFBundleExecutable</key>        <string>PI 项目启动器</string>
  <key>CFBundleIdentifier</key>        <string>local.pi.project-launcher</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>3.2</string>
  <key>CFBundleVersion</key>           <string>6</string>
  <key>CFBundleIconFile</key>          <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>    <string>12.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>用于在终端（Ghostty 或系统 Terminal）中打开新窗口并启动 PI。</string>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 临时签名（本机运行足够）"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   （签名跳过，不影响本机运行）"

echo
echo "构建完成：$APP"
echo "双击即可运行；首次控制 Ghostty 时系统会询问是否允许。"
