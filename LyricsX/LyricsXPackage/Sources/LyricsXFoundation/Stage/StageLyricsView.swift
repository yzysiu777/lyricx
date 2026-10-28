import AppKit
import SwiftUI

// MARK: - 滚动歌词列（歌词模式）

/// 不用 ScrollView，而是自己算每行位置：这样每一行可以有各自的弹簧延迟，
/// 换行时呈现 Apple Music 那种「前一行先走、后面的行依次跟上」的效果。
struct StageLyricsColumn: View {
    @ObservedObject var model: StageModel
    let fontSize: CGFloat
    /// 当前行在视图中的纵向位置（0 = 顶部，1 = 底部）
    var anchorRatio: CGFloat = 0.3

    @State private var heights: [Int: CGFloat] = [:]
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let lines = model.lines
            let current = model.currentIndex
            let ys = positions(for: lines)
            let anchor = geo.size.height * anchorRatio
            let base = anchor - (current.map { ys[$0] } ?? -fontSize * 0.6)
            let blurEnabled = !hovering && !model.isUserScrolling

            ZStack(alignment: .topLeading) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                    let distance = current.map { i - $0 } ?? i + 1
                    StageLyricLine(
                        model: model,
                        line: line,
                        isActive: i == current,
                        distance: distance,
                        fontSize: fontSize,
                        showTranslation: model.showTranslation,
                        blurEnabled: blurEnabled
                    )
                    .frame(width: geo.size.width, alignment: .leading)
                    .background(HeightReader(id: line.id))
                    .offset(y: ys[i] + base)
                    .animation(
                        .spring(response: 0.62, dampingFraction: 0.86).delay(delay(index: i, current: current)),
                        value: current
                    )
                    // 远离可视区的行不参与绘制
                    .opacity(isVisible(y: ys[i] + base + model.userScrollOffset, height: geo.size.height) ? 1 : 0)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .offset(y: model.userScrollOffset)
            .onPreferenceChange(LineHeightKey.self) { new in
                heights.merge(new) { $1 }
            }
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.1),
                    .init(color: .black, location: 0.8),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
        .background(ScrollWheelCatcher { model.userScrolled(by: $0) })
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.4), value: blurKey)
        .onChange(of: model.lines) { _, _ in heights = [:] }
    }

    private var blurKey: Bool { !hovering && !model.isUserScrolling }

    private func estimatedHeight(_ line: StageLine) -> CGFloat {
        switch line.kind {
        case .interlude: return fontSize * 0.9
        case .text:
            var h = fontSize * 1.6
            if model.showTranslation, line.translation != nil { h += fontSize * 0.8 }
            if line.background != nil { h += fontSize * 0.8 }
            return h
        }
    }

    private func positions(for lines: [StageLine]) -> [CGFloat] {
        var ys: [CGFloat] = []
        ys.reserveCapacity(lines.count)
        var y: CGFloat = 0
        let spacing = fontSize * 0.42
        for line in lines {
            ys.append(y)
            y += (heights[line.id] ?? estimatedHeight(line)) + spacing
        }
        return ys
    }

    private func delay(index: Int, current: Int?) -> Double {
        guard let current, index > current else { return 0 }
        return Double(min(index - current, 8)) * 0.042
    }

    private func isVisible(y: CGFloat, height: CGFloat) -> Bool {
        y > -height * 0.8 && y < height * 1.8
    }
}

private struct LineHeightKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct HeightReader: View {
    let id: Int
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: LineHeightKey.self, value: [id: geo.size.height])
        }
    }
}

// MARK: - 单行

struct StageLyricLine: View {
    @ObservedObject var model: StageModel
    let line: StageLine
    let isActive: Bool
    let distance: Int
    let fontSize: CGFloat
    let showTranslation: Bool
    let blurEnabled: Bool

    @State private var hovering = false

    var body: some View {
        switch line.kind {
        case .interlude:
            ZStack(alignment: .leading) {
                if isActive {
                    InterludeDots(line: line, fontSize: fontSize, model: model)
                        .transition(.scale(scale: 0.3, anchor: .leading).combined(with: .opacity))
                }
            }
            .frame(height: fontSize * 0.9, alignment: .leading)
            .padding(.horizontal, fontSize * 0.4)
            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: isActive)
        case .text:
            textLine
        }
    }

    private var textLine: some View {
        VStack(alignment: .leading, spacing: fontSize * 0.16) {
            mainText
            if let bg = line.background {
                Text(bg)
                    .font(.system(size: fontSize * 0.58, weight: .semibold))
                    .foregroundStyle(.white.opacity(isActive ? 0.7 : 1))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showTranslation, let tr = line.translation {
                Text(tr)
                    .font(.system(size: fontSize * 0.58, weight: .semibold))
                    .foregroundStyle(.white.opacity(isActive ? 0.68 : 1))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, fontSize * 0.22)
        .padding(.horizontal, fontSize * 0.4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: fontSize * 0.4, style: .continuous)
                .fill(.white.opacity(hovering ? 0.09 : 0))
        )
        .opacity(isActive ? 1 : (distance < 0 ? 0.3 : 0.36))
        .scaleEffect(isActive ? 1 : 0.955, anchor: .leading)
        .blur(radius: blurEnabled && !isActive ? min(CGFloat(abs(distance)), 5) * 0.75 : 0)
        .contentShape(Rectangle())
        .onTapGesture { model.actions.seek(line.start + 0.01) }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: isActive)
        .help("单击跳到这一句")
    }

    @ViewBuilder
    private var mainText: some View {
        if let words = line.words {
            if isActive {
                TimelineView(.animation) { _ in
                    KaraokeWords(words: words, fontSize: fontSize, time: model.now())
                }
            } else {
                KaraokeWords(words: words, fontSize: fontSize, time: nil)
            }
        } else {
            Text(line.text)
                .font(.system(size: fontSize, weight: .bold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(fontSize * 0.08)
        }
    }
}

// MARK: - 欣赏模式下的两行歌词

struct CoverLyrics: View {
    @ObservedObject var model: StageModel
    let fontSize: CGFloat
    var alignment: HorizontalAlignment = .center

    private var textAlignment: TextAlignment { alignment == .leading ? .leading : .center }
    private var frameAlignment: Alignment { alignment == .leading ? .leading : .center }

    var body: some View {
        let lines = model.lines
        let idx = model.currentIndex
        let current = idx.flatMap { lines.indices.contains($0) ? lines[$0] : nil }
        let next = nextTextLine(after: idx, in: lines)

        VStack(alignment: alignment, spacing: fontSize * 0.45) {
            ZStack(alignment: frameAlignment) {
                if let current {
                    currentView(current)
                        .id(current.id)
                        .transition(.asymmetric(
                            insertion: .offset(y: fontSize * 1.2).combined(with: .opacity),
                            removal: .offset(y: -fontSize * 1.2).combined(with: .opacity)
                        ))
                } else if let next {
                    // 第一句之前：先预告第一句
                    Text(next.text)
                        .font(.system(size: fontSize, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(textAlignment)
                }
            }
            .frame(maxWidth: .infinity, alignment: frameAlignment)

            if let next, current != nil {
                Text(next.text)
                    .font(.system(size: fontSize * 0.72, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.38))
                    .multilineTextAlignment(textAlignment)
                    .lineLimit(1)
                    .id(next.id)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.86), value: idx)
    }

    @ViewBuilder
    private func currentView(_ line: StageLine) -> some View {
        switch line.kind {
        case .interlude:
            InterludeDots(line: line, fontSize: fontSize, model: model)
        case .text:
            VStack(alignment: alignment, spacing: fontSize * 0.25) {
                if let words = line.words {
                    TimelineView(.animation) { _ in
                        KaraokeWords(words: words, fontSize: fontSize, time: model.now(), alignment: alignment)
                    }
                } else {
                    Text(line.text)
                        .font(.system(size: fontSize, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(textAlignment)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.showTranslation, let tr = line.translation {
                    Text(tr)
                        .font(.system(size: fontSize * 0.62, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.66))
                        .multilineTextAlignment(textAlignment)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func nextTextLine(after idx: Int?, in lines: [StageLine]) -> StageLine? {
        let start = (idx ?? -1) + 1
        guard start < lines.count else { return nil }
        return lines[start...].first { $0.kind == .text }
    }
}
