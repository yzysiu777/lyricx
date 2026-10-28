import AppKit
import SwiftUI

// MARK: - 流动的封面背景

/// 把预先模糊过的封面放大成三层，缓慢旋转、漂移、叠加，得到 Apple Music 那种流动色彩。
/// 每层都放大到窗口对角线的两倍以上，边缘永远不会出现在画面里。
struct StageBackdrop: View {
    let image: NSImage?
    let palette: StagePalette
    let animate: Bool

    var body: some View {
        GeometryReader { geo in
            let side = hypot(geo.size.width, geo.size.height) * 2.1
            ZStack {
                Color.black
                if let image {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animate)) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        ZStack {
                            layer(image, side: side, angle: t * 5, dx: sin(t / 13) * 0.18, dy: cos(t / 17) * 0.14, scale: 1.0, geo: geo)
                            layer(image, side: side, angle: -t * 7 + 120, dx: cos(t / 11) * 0.22, dy: sin(t / 9) * 0.2, scale: 0.8, geo: geo)
                                .opacity(0.75)
                                .blendMode(.screen)
                            layer(image, side: side, angle: t * 3 + 240, dx: sin(t / 19 + 2) * 0.25, dy: cos(t / 15 + 1) * 0.22, scale: 0.6, geo: geo)
                                .opacity(0.55)
                        }
                    }
                    .blur(radius: 36)
                    .transition(.opacity)
                } else {
                    LinearGradient(colors: palette.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                        .transition(.opacity)
                }
                // 压暗，保证白字可读；底部再多压一点
                LinearGradient(
                    colors: [.black.opacity(0.22), .black.opacity(0.32), .black.opacity(0.48)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func layer(_ image: NSImage, side: CGFloat, angle: Double, dx: Double, dy: Double, scale: CGFloat, geo: GeometryProxy) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: side * scale, height: side * scale)
            .rotationEffect(.degrees(angle))
            .offset(x: geo.size.width * dx, y: geo.size.height * dy)
            .frame(width: geo.size.width, height: geo.size.height)
    }
}

// MARK: - 自动换行布局（按词换行）

struct WordGap: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

struct FlowLayout: Layout {
    var lineSpacing: CGFloat = 0
    var alignment: HorizontalAlignment = .leading

    struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, sv) in subviews.enumerated() {
            let size = sv.sizeThatFits(.unspecified)
            let gap = sv[WordGap.self]
            var row = rows[rows.count - 1]
            if !row.indices.isEmpty, row.width + size.width > maxWidth {
                rows.append(Row())
                row = Row()
            }
            row.indices.append(i)
            row.width += size.width + gap
            row.height = max(row.height, size.height)
            rows[rows.count - 1] = row
        }
        // 行尾的间距不计入宽度
        for r in rows.indices {
            if let last = rows[r].indices.last {
                rows[r].width -= subviews[last][WordGap.self]
            }
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = rows(for: subviews, maxWidth: maxWidth)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(for: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x: CGFloat
            switch alignment {
            case .center: x = bounds.minX + (bounds.width - row.width) / 2
            case .trailing: x = bounds.maxX - row.width
            default: x = bounds.minX
            }
            for i in row.indices {
                let sv = subviews[i]
                let size = sv.sizeThatFits(.unspecified)
                sv.place(at: CGPoint(x: x, y: y + (row.height - size.height)), proposal: .unspecified)
                x += size.width + sv[WordGap.self]
            }
            y += row.height + lineSpacing
        }
    }
}

// MARK: - 逐字填充

/// 一行逐字歌词。`time` 为 nil 表示这一行不在播放（整体暗色、无动画）。
struct KaraokeWords: View {
    let words: [StageWord]
    let fontSize: CGFloat
    let time: TimeInterval?
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        let font = Font.system(size: fontSize, weight: .bold)
        let spaceWidth = fontSize * 0.28
        FlowLayout(lineSpacing: fontSize * 0.1, alignment: alignment) {
            ForEach(words) { word in
                KaraokeWord(word: word, font: font, fontSize: fontSize, time: time)
                    .layoutValue(key: WordGap.self, value: word.trailingSpace ? spaceWidth : 0)
            }
        }
    }
}

struct KaraokeWord: View {
    let word: StageWord
    let font: Font
    let fontSize: CGFloat
    let time: TimeInterval?

    var body: some View {
        let p = time.map { word.progress(at: $0) } ?? 0
        let isActive = time != nil
        // 长音（≥1 秒）在演唱时轻微放大并发光
        let isLong = word.end - word.start >= 1.0 && word.text.count <= 6
        let sing = isActive && isLong ? sin(Double.pi * p) : 0
        // 唱过的字向上浮起一点点
        let lift = isActive ? -fontSize * 0.045 * easeOut(p) : 0

        Text(word.text)
            .font(font)
            .foregroundStyle(.white.opacity(isActive ? 0.36 : 1))
            .overlay(alignment: .leading) {
                if isActive {
                    Text(word.text)
                        .font(font)
                        .foregroundStyle(.white)
                        .mask(fillMask(p))
                }
            }
            .fixedSize()
            .scaleEffect(1 + 0.05 * sing, anchor: .bottom)
            .shadow(color: .white.opacity(0.55 * sing), radius: fontSize * 0.25 * sing)
            .offset(y: lift)
    }

    private func fillMask(_ p: Double) -> some View {
        let edge = 0.12
        let a = p * (1 + edge) - edge
        return LinearGradient(
            stops: [
                .init(color: .black, location: max(0, a)),
                .init(color: .clear, location: min(1, max(0, a + edge))),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
}

// MARK: - 间奏圆点

struct InterludeDots: View {
    let line: StageLine
    let fontSize: CGFloat
    let model: StageModel

    var body: some View {
        TimelineView(.animation) { _ in
            let t = model.now()
            let duration = max(0.1, line.end - line.start)
            let p = min(1, max(0, (t - line.start) / duration))
            // 结尾 0.5 秒收拢消失
            let tail = min(1, max(0, (line.end - t) / 0.5))
            let breathe = 1 + 0.07 * sin(t * 3.2)
            HStack(spacing: fontSize * 0.28) {
                ForEach(0 ..< 3) { i in
                    let local = min(1, max(0, p * 3 - Double(i)))
                    Circle()
                        .fill(.white.opacity(0.28 + 0.72 * local))
                        .frame(width: fontSize * 0.34, height: fontSize * 0.34)
                }
            }
            .scaleEffect(breathe * tail, anchor: .leading)
            .opacity(tail)
            .padding(.vertical, fontSize * 0.2)
        }
    }
}

// MARK: - 小部件

/// 毛玻璃圆形图标按钮
struct GlassIconButton: View {
    let systemName: String
    var isOn = false
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isOn ? Color.black.opacity(0.85) : .white.opacity(hovering ? 1 : 0.85))
                .frame(width: 24, height: 24)
                .background {
                    Circle().fill(isOn ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.white.opacity(hovering ? 0.22 : 0.12)))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

struct TransportButton: View {
    let systemName: String
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.88))
                .frame(width: size * 2, height: size * 1.8)
                .contentShape(Rectangle())
                .scaleEffect(pressed ? 0.86 : 1)
        }
        .buttonStyle(PressReportingStyle(pressed: $pressed))
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: pressed)
    }
}

private struct PressReportingStyle: ButtonStyle {
    @Binding var pressed: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, new in pressed = new }
    }
}

/// 细进度条，可拖动跳转
struct StageProgressBar: View {
    @ObservedObject var model: StageModel
    @State private var dragValue: Double?
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let duration = max(1, model.duration)
            let raw = model.now()
            let current = dragValue ?? min(1, max(0, raw / duration))
            VStack(spacing: 5) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.22))
                        Capsule().fill(.white.opacity(hovering || dragValue != nil ? 0.95 : 0.75))
                            .frame(width: max(0, geo.size.width * current))
                    }
                    .frame(height: hovering || dragValue != nil ? 7 : 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    // 只响应单击跳转；拖动交给窗口移动，避免误触
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { v in
                                let f = min(1, max(0, v.location.x / geo.size.width))
                                model.actions.seek(f * duration)
                            }
                    )
                }
                .frame(height: 12)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: hovering)

                HStack {
                    Text(format(current * duration))
                    Spacer()
                    Text("-" + format(max(0, duration - current * duration)))
                }
                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// 捕获滚轮：手动翻看歌词
struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
                if dy != 0 { self.onScroll?(dy) }
                return event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
