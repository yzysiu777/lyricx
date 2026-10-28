import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 歌词窗口的根视图：背景 + 歌词模式 / 欣赏模式 + 悬停控件 + 提示。
public struct StageRootView: View {
    @ObservedObject var model: StageModel
    @FocusState private var focused: Bool

    public init(model: StageModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            StageBackdrop(image: model.backdropImage, palette: model.palette, animate: model.isPlaying)

            Group {
                switch model.mode {
                case .lyrics: LyricsModeView(model: model)
                case .cover: CoverModeView(model: model)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))

            if let toast = model.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 28)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.4), value: model.mode)
        // 鼠标进出由窗口控制器在整个窗口框架（含标题栏按钮）上判断，
        // 不能用 .onHover：鼠标移到红绿灯上时 SwiftUI 会误判为「离开窗口」
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.space) { model.actions.playPause(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "tTmM")) { press in
            switch press.characters.lowercased() {
            case "t": model.showTranslation.toggle()
            case "m": model.actions.setMode(model.mode == .lyrics ? .cover : .lyrics)
            default: return .ignored
            }
            return .handled
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSURL.self) { url, _ in
            guard let url = url as? URL,
                  let content = try? String(contentsOf: url, encoding: .utf8) else { return }
            DispatchQueue.main.async { model.actions.importLyrics(content) }
        }
        return true
    }
}

// MARK: - 歌词模式

private struct LyricsModeView: View {
    @ObservedObject var model: StageModel

    var body: some View {
        GeometryReader { geo in
            let fontSize = Self.fontSize(size: geo.size) * model.fontScale
            let compact = geo.size.height < 380 || geo.size.width < 380
            let showChrome = model.isHoveringWindow

            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    // 标题贴近顶部；鼠标移入、红绿灯出现时才向右让位
                    StageHeader(model: model, compact: compact)
                        .padding(.top, 10)
                        .padding(.leading, model.isHoveringWindow ? 76 : 14)
                        .padding(.trailing, 12)
                        .padding(.bottom, 2)
                        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.isHoveringWindow)

                    if model.lines.isEmpty {
                        EmptyLyricsView(model: model, compact: compact)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        StageLyricsColumn(model: model, fontSize: fontSize, anchorRatio: compact ? 0.36 : 0.3)
                            .padding(.horizontal, 6)
                    }
                }

                // 底部：悬停时出现的进度条和播放控制
                VStack {
                    Spacer()
                    VStack(spacing: 4) {
                        StageProgressBar(model: model)
                        TransportControls(model: model, size: 12)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 30)
                    .padding(.bottom, 10)
                    .background(
                        LinearGradient(colors: [.clear, .black.opacity(0.55), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                            .allowsHitTesting(false)
                    )
                    .opacity(showChrome ? 1 : 0)
                    .offset(y: showChrome ? 0 : 12)
                    .animation(.easeOut(duration: 0.25), value: showChrome)
                }
            }
        }
    }

    static func fontSize(size: CGSize) -> CGFloat {
        // 小窗口里同时受宽、高约束，保证能看到 3～4 行
        min(36, max(13, min(size.width * 0.056, size.height * 0.066)))
    }
}

private struct StageHeader: View {
    @ObservedObject var model: StageModel
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 9 : 12) {
            ArtworkThumb(image: model.artwork, size: compact ? 28 : 44, cornerRadius: compact ? 5 : 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.hasTrack ? model.title : "未在播放")
                    .font(.system(size: compact ? 12.5 : 14, weight: .bold))
                    .foregroundStyle(.white)
                Text(model.artist)
                    .font(.system(size: compact ? 11 : 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            StageControls(model: model)
                .opacity(model.isHoveringWindow ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: model.isHoveringWindow)
        }
    }
}

private struct EmptyLyricsView: View {
    @ObservedObject var model: StageModel
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 7 : 14) {
            if !model.hasTrack {
                Image(systemName: "music.note")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.white.opacity(0.5))
                Text("播放音乐后，歌词会显示在这里")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            } else if model.isSearching {
                ProgressView().controlSize(.small).tint(.white)
                Text("正在搜索歌词…")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
            } else {
                Text("没有找到歌词")
                    .font(.system(size: compact ? 14 : 18, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                if !compact {
                    Text("可以手动搜索，或把 .lrc 文件拖进窗口")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Button {
                    model.actions.searchLyrics()
                } label: {
                    Text("搜索歌词…")
                        .font(.system(size: compact ? 11.5 : 13, weight: .semibold))
                        .padding(.horizontal, compact ? 12 : 16)
                        .padding(.vertical, compact ? 5 : 7)
                        .background(.white.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.bottom, compact ? 24 : 60)
    }
}

// MARK: - 欣赏模式

private struct CoverModeView: View {
    @ObservedObject var model: StageModel
    @State private var hoveringArtwork = false

    var body: some View {
        GeometryReader { geo in
            if geo.size.width > geo.size.height * 1.05 {
                landscape(geo.size)
            } else {
                portrait(geo)
            }
        }
    }

    /// 横向小窗：左边封面，右边歌名 + 两行歌词
    private func landscape(_ size: CGSize) -> some View {
        let h = size.height, w = size.width
        let art = max(80, min(h - 64, w * 0.46))
        let lyricFont = min(20, max(12.5, min(w * 0.042, h * 0.06))) * model.fontScale
        return HStack(alignment: .center, spacing: 16) {
            ArtworkThumb(image: model.artwork, size: art, cornerRadius: art * 0.05)
                .shadow(color: .black.opacity(0.4), radius: model.isPlaying ? 16 : 8, y: 6)
                .scaleEffect(model.isPlaying ? 1 : 0.9)
                .animation(.spring(response: 0.55, dampingFraction: 0.68), value: model.isPlaying)
                .overlay {
                    TransportControls(model: model, size: max(11, art * 0.07))
                        .padding(.horizontal, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .opacity(hoveringArtwork ? 1 : 0)
                        .animation(.easeOut(duration: 0.2), value: hoveringArtwork)
                }
                .onHover { hoveringArtwork = $0 }
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.hasTrack ? model.title : "未在播放")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    Text(model.artist)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .lineLimit(1)
                Group {
                    if model.lines.isEmpty {
                        Text(model.isSearching ? "正在搜索歌词…" : (model.hasTrack ? "暂无歌词" : ""))
                            .font(.system(size: lyricFont * 0.85, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                    } else {
                        CoverLyrics(model: model, fontSize: lyricFont, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: lyricFont * 3.2, alignment: .leading)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 28)
        .padding(.bottom, 12)
        .frame(width: w, height: h)
        .overlay(alignment: .topTrailing) {
            StageControls(model: model)
                .padding(.top, 8)
                .padding(.trailing, 10)
                .opacity(model.isHoveringWindow ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: model.isHoveringWindow)
        }
    }

    private func portrait(_ geo: GeometryProxy) -> some View {
        Group {
            let w = geo.size.width, h = geo.size.height
            let art = max(100, min(w - 56, h * 0.55))
            let lyricFont = min(22, max(13, w * 0.05)) * model.fontScale
            let titleSize = min(17, max(12.5, w * 0.045))

            VStack(spacing: 0) {
                Spacer(minLength: 30)

                ArtworkThumb(image: model.artwork, size: art, cornerRadius: art * 0.035)
                    .shadow(color: .black.opacity(model.isPlaying ? 0.45 : 0.3), radius: model.isPlaying ? 28 : 14, y: model.isPlaying ? 14 : 6)
                    .scaleEffect(model.isPlaying ? 1 : 0.86)
                    .animation(.spring(response: 0.55, dampingFraction: 0.68), value: model.isPlaying)
                    .overlay {
                        // 悬停封面时出现播放控制
                        TransportControls(model: model, size: max(13, art * 0.06))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .opacity(hoveringArtwork ? 1 : 0)
                            .scaleEffect(hoveringArtwork ? 1 : 0.92)
                            .animation(.easeOut(duration: 0.2), value: hoveringArtwork)
                    }
                    .onHover { hoveringArtwork = $0 }

                Spacer().frame(height: max(14, h * 0.03))

                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.hasTrack ? model.title : "未在播放")
                            .font(.system(size: titleSize, weight: .bold))
                            .foregroundStyle(.white)
                        Text(model.artist)
                            .font(.system(size: titleSize * 0.82, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(width: art)

                StageProgressBar(model: model)
                    .frame(width: art)
                    .padding(.top, 10)
                    .opacity(model.isHoveringWindow ? 1 : 0.0)
                    .animation(.easeOut(duration: 0.25), value: model.isHoveringWindow)

                Spacer(minLength: 6)

                Group {
                    if model.lines.isEmpty {
                        Text(model.isSearching ? "正在搜索歌词…" : (model.hasTrack ? "暂无歌词" : ""))
                            .font(.system(size: lyricFont * 0.8, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                    } else {
                        CoverLyrics(model: model, fontSize: lyricFont)
                    }
                }
                .frame(width: w - 32)
                .frame(minHeight: lyricFont * 3.4)

                Spacer(minLength: 12)
            }
            .frame(width: w, height: h)
            .overlay(alignment: .topTrailing) {
                StageControls(model: model)
                    .padding(.top, 10)
                    .padding(.trailing, 14)
                    .opacity(model.isHoveringWindow ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: model.isHoveringWindow)
            }
        }
    }
}

// MARK: - 共用部件

struct ArtworkThumb: View {
    let image: NSImage?
    let size: CGFloat
    var cornerRadius: CGFloat = 7

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.36, weight: .regular))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
    }
}

struct TransportControls: View {
    @ObservedObject var model: StageModel
    let size: CGFloat

    var body: some View {
        HStack(spacing: size * 0.9) {
            TransportButton(systemName: "backward.fill", size: size) { model.actions.previous() }
            TransportButton(systemName: model.isPlaying ? "pause.fill" : "play.fill", size: size * 1.25) { model.actions.playPause() }
                .contentTransition(.symbolEffect(.replace))
            TransportButton(systemName: "forward.fill", size: size) { model.actions.next() }
        }
    }
}

struct StageControls: View {
    @ObservedObject var model: StageModel

    var body: some View {
        HStack(spacing: 5) {
            if model.hasTranslation {
                GlassIconButton(systemName: "character.bubble", isOn: model.showTranslation, help: "显示翻译（T）") {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { model.showTranslation.toggle() }
                }
            }
            GlassIconButton(
                systemName: model.mode == .lyrics ? "square.on.square" : "text.quote",
                help: model.mode == .lyrics ? "切换到欣赏模式（M）" : "切换到歌词模式（M）"
            ) {
                model.actions.setMode(model.mode == .lyrics ? .cover : .lyrics)
            }
            GlassIconButton(systemName: model.isPinned ? "pin.fill" : "pin", isOn: model.isPinned, help: "窗口置顶") {
                model.actions.setPinned(!model.isPinned)
            }
            StageMoreMenu(model: model)
        }
    }
}

private struct StageMoreMenu: View {
    @ObservedObject var model: StageModel

    var body: some View {
        Menu {
            if let source = model.sourceDescription {
                Text(source)
            }
            if let offset = model.offsetDescription {
                Text(offset)
            }
            Button("搜索歌词…") { model.actions.searchLyrics() }
            Divider()
            Button("歌词提前 0.1 秒") { model.actions.adjustOffset(0.1) }
            Button("歌词延后 0.1 秒") { model.actions.adjustOffset(-0.1) }
            Button("重置时间偏移") { model.actions.resetOffset() }
            Divider()
            Menu("窗口大小") {
                ForEach(StageSizePreset.allCases, id: \.self) { preset in
                    Toggle(preset.title, isOn: Binding(
                        get: { model.sizePreset == preset },
                        set: { _ in model.actions.setSizePreset(preset) }
                    ))
                }
            }
            Picker("字号", selection: $model.fontScale) {
                Text("小").tag(0.85)
                Text("中").tag(1.0)
                Text("大").tag(1.18)
            }
            Divider()
            Button("在 Finder 中显示歌词文件") { model.actions.showInFinder() }
            Button("歌词不对，不再为这首歌搜索") { model.actions.wrongLyrics() }
            Divider()
            Button("偏好设置…") { model.actions.openPreferences() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多")
    }
}
