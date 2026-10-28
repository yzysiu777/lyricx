#!/bin/zsh
# 本地构建 LyricsX（Release，ad-hoc 签名），产物放在 lyricx/dist/LyricsX.app
set -e
ROOT="${0:A:h:h}"
cd "$ROOT/LyricsX"
export LYRICSX_SKIP_BUILD_BUMP=1
xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration "${CONFIG:-Release}" \
  -derivedDataPath "$ROOT/build" -skipMacroValidation -skipPackagePluginValidation \
  ONLY_ACTIVE_ARCH=YES build "$@" | tee "$ROOT/build/last-build.log" | grep -E "error:|warning: .*LyricsX/|BUILD (SUCCEEDED|FAILED)" || true
APP="$ROOT/build/Build/Products/${CONFIG:-Release}/LyricsX.app"
grep -q "BUILD SUCCEEDED" "$ROOT/build/last-build.log" || { echo "构建失败，看 build/last-build.log"; exit 1; }
rm -rf "$ROOT/dist" && mkdir -p "$ROOT/dist" && cp -R "$APP" "$ROOT/dist/"
# 统一用 ad-hoc 重新签名：Sparkle 等预编译框架自带上游开发者签名，与本地签名不一致会被系统拒绝加载
OUT="$ROOT/dist/LyricsX.app"
find "$OUT/Contents" \( -name "*.framework" -o -name "*.dylib" -o -name "*.xpc" -o -name "*.app" \) -prune -print0 2>/dev/null \
  | xargs -0 -I{} codesign --force --deep --sign - {} >/dev/null 2>&1 || true
codesign --force --sign - --entitlements "$ROOT/LyricsX/LyricsX/Supporting Files/LyricsX.local.entitlements" "$OUT"
codesign --verify --deep --strict "$OUT" && echo "签名校验通过"
echo "产物: $ROOT/dist/LyricsX.app"
