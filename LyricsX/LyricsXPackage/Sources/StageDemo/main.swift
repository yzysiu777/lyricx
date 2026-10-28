// README 配图用的演示程序：用自编歌词和程序生成的封面展示真实的歌词窗口界面，
// 不涉及任何受版权保护的歌词或专辑封面。
//
// 用法：swift run StageDemo <lyrics|cover> <宽> <高> [hover]
import AppKit
import SwiftUI
import LyricsXFoundation

let args = CommandLine.arguments
let mode: StageMode = args.count > 1 && args[1] == "cover" ? .cover : .lyrics
let width = args.count > 2 ? Double(args[2]) ?? 340 : 340
let height = args.count > 3 ? Double(args[3]) ?? 280 : 280
let hover = args.contains("hover")

// 自编示例歌词（原创，无版权问题）
let demo: [(TimeInterval, TimeInterval, String, String)] = [
    (0, 4, "Morning light upon the page", "晨光落在书页上"),
    (4, 8, "Every theorem finds its place", "每条定理各得其所"),
    (8, 12, "Humming softly while I read", "一边读书，一边轻轻哼唱"),
    (12, 16, "Quiet music, all I need", "一点安静的音乐，便已足够"),
    (16, 20, "Turn the chapter, take a breath", "翻过一章，深吸一口气"),
    (28, 32, "Write the proof and let it rest", "写下证明，让它安放"),
]

func makeLines() -> [StageLine] {
    var lines: [StageLine] = []
    var id = 0
    for (k, (start, end, text, tr)) in demo.enumerated() {
        if k > 0, start - demo[k - 1].1 >= 6 {
            lines.append(StageLine(id: id, kind: .interlude, start: demo[k - 1].1, end: start - 0.25, text: ""))
            id += 1
        }
        let parts = text.split(separator: " ").map(String.init)
        let step = (end - start - 0.4) / Double(parts.count)
        let words = parts.enumerated().map { i, w in
            StageWord(id: i, syllables: [StageSyllable(text: w, start: start + Double(i) * step, end: start + Double(i + 1) * step)],
                      trailingSpace: i < parts.count - 1)
        }
        lines.append(StageLine(id: id, kind: .text, start: start, end: end, text: text, words: words, translation: tr, background: nil))
        id += 1
    }
    return lines
}

/// 程序生成的抽象封面
func makeArtwork() -> NSImage {
    NSImage(size: NSSize(width: 600, height: 600), flipped: false) { rect in
        NSGradient(colors: [
            NSColor(srgbRed: 0.10, green: 0.16, blue: 0.40, alpha: 1),
            NSColor(srgbRed: 0.55, green: 0.22, blue: 0.52, alpha: 1),
            NSColor(srgbRed: 0.98, green: 0.55, blue: 0.42, alpha: 1),
        ])!.draw(in: rect, angle: -50)
        let circles: [(CGFloat, CGFloat, CGFloat, NSColor)] = [
            (420, 420, 170, NSColor(srgbRed: 1, green: 0.82, blue: 0.45, alpha: 0.85)),
            (170, 190, 120, NSColor(srgbRed: 0.35, green: 0.75, blue: 0.95, alpha: 0.55)),
            (330, 150, 60, NSColor.white.withAlphaComponent(0.35)),
        ]
        for (x, y, r, c) in circles {
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)).fill()
        }
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let wave = NSBezierPath()
        wave.lineWidth = 6
        wave.move(to: NSPoint(x: 40, y: 300))
        for x in stride(from: 40.0, through: 560.0, by: 8) {
            wave.line(to: NSPoint(x: x, y: 300 + 40 * sin(x / 38)))
        }
        wave.stroke()
        return true
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let model = StageModel()
    model.mode = mode
    model.title = "Quiet Study"
    model.artist = "lyricx demo"
    model.hasTrack = true
    model.duration = 200
    model.isPlaying = true
    model.showTranslation = true
    model.timeProvider = { 9.7 } // 第 3 句唱到一半
    model.lines = makeLines()
    model.setArtwork(makeArtwork())
    model.isHoveringWindow = hover

    let window = NSWindow(
        contentRect: NSRect(x: 200, y: 200, width: width, height: height),
        styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
        backing: .buffered, defer: false
    )
    window.title = "lyricx-demo"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.backgroundColor = .black
    window.appearance = NSAppearance(named: .darkAqua)
    let hosting = NSHostingView(rootView: StageRootView(model: model))
    hosting.sizingOptions = []
    window.contentView = hosting
    if !hover {
        for t in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(t)?.alphaValue = 0
        }
    }
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    print("demo window ready")
    app.run()
}
