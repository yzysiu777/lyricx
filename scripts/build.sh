#!/bin/zsh
# 本地构建 LyricsX（Release，ad-hoc 签名），产物放在 lyricx/dist/LyricsX.app
set -e
ROOT="${0:A:h:h}"
cd "$ROOT/LyricsX"
export LYRICSX_SKIP_BUILD_BUMP=1
mkdir -p "$ROOT/build"
# UNIVERSAL=1 时同时编译 Apple 芯片和 Intel（发布用）；默认只编译本机架构，更快
if [ "${UNIVERSAL:-0}" = "1" ]; then
  ARCH_FLAGS=(ONLY_ACTIVE_ARCH=NO "ARCHS=arm64 x86_64")
else
  ARCH_FLAGS=(ONLY_ACTIVE_ARCH=YES)
fi
xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration "${CONFIG:-Release}" \
  -derivedDataPath "$ROOT/build" -skipMacroValidation -skipPackagePluginValidation \
  "${ARCH_FLAGS[@]}" build "$@" | tee "$ROOT/build/last-build.log" | grep -E "error:|warning: .*LyricsX/|BUILD (SUCCEEDED|FAILED)" || true
APP="$ROOT/build/Build/Products/${CONFIG:-Release}/LyricsX.app"
grep -q "BUILD SUCCEEDED" "$ROOT/build/last-build.log" || { echo "构建失败，看 build/last-build.log"; exit 1; }
rm -rf "$ROOT/dist" && mkdir -p "$ROOT/dist" && cp -R "$APP" "$ROOT/dist/"
# 统一用 ad-hoc 重新签名：Sparkle 等预编译框架自带上游开发者签名，与本地签名不一致会被系统拒绝加载
OUT="$ROOT/dist/LyricsX.app"
# 逐个签名（不用 xargs -I：它对路径长度有 255 字节限制，路径长时会静默跳过）
find "$OUT/Contents" \( -name "*.framework" -o -name "*.dylib" -o -name "*.xpc" -o -name "*.app" \) -prune -print0 \
  | while IFS= read -r -d '' item; do codesign --force --deep --sign - "$item" >/dev/null 2>&1; done
codesign --force --sign - --entitlements "$ROOT/LyricsX/LyricsX/Supporting Files/LyricsX.local.entitlements" "$OUT"
codesign --verify --deep --strict "$OUT" || { echo "签名校验失败"; exit 1; }
echo "签名校验通过"
echo "产物: $ROOT/dist/LyricsX.app"
