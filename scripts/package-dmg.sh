#!/bin/zsh
# 打包发布用的 DMG：通用版（Apple 芯片 + Intel），产物在 dist/lyricx-<版本>.dmg
set -e
ROOT="${0:A:h:h}"
UNIVERSAL=1 "$ROOT/scripts/build.sh"

APP="$ROOT/dist/LyricsX.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
NAME="lyricx-$VERSION"
DMG="$ROOT/dist/$NAME.dmg"
STAGE="$ROOT/build/dmg-stage"
RW="$ROOT/build/$NAME-rw.dmg"

echo "架构: $(lipo -archs "$APP/Contents/MacOS/LyricsX")"

rm -rf "$STAGE" "$RW" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/首次打开必读.txt" <<'TXT'
lyricx 没有经过 Apple 公证（需要付费开发者账号），第一次打开会被系统拦下。

安装步骤：
1. 把 LyricsX 拖到右边的 Applications 文件夹。
2. 打开「系统设置 → 隐私与安全性」，在页面底部找到 LyricsX 被阻止的提示，点「仍要打开」。
   （或者在终端运行：xattr -dr com.apple.quarantine /Applications/LyricsX.app）
3. 第一次运行时，系统会询问是否允许 LyricsX 控制「音乐」，请选择允许。

LyricsX 运行后只在菜单栏显示一个图标，歌词窗口可以从菜单栏图标里打开。
项目主页：https://github.com/yzysiu777/lyricx
TXT

# 先做可写镜像，用 Finder 摆好图标位置，再压缩成只读镜像
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
MOUNT=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')
sleep 1
osascript <<OSA || echo "（Finder 排版跳过，不影响使用）"
tell application "Finder"
  tell disk "$NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 760, 480}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 96
    set text size of opts to 13
    set position of item "LyricsX.app" of container window to {140, 150}
    set position of item "Applications" of container window to {420, 150}
    set position of item "首次打开必读.txt" of container window to {280, 290}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
sync
hdiutil detach -quiet "$MOUNT" || hdiutil detach -force -quiet "$MOUNT"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f "$RW"
rm -rf "$STAGE"
echo "DMG: $DMG ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG"
