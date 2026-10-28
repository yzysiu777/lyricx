import AppKit
import SwiftUI
import LyricsCore

// 歌词窗口（「舞台」）的数据模型。
// App 负责把当前歌曲、歌词、播放状态喂进来；界面只读这个模型。

public enum StageMode: String, CaseIterable {
    /// 歌词模式：大字号、左对齐、滚动歌词（类 Apple Music 全屏歌词）
    case lyrics
    /// 欣赏模式：上方大封面，下方两行歌词，窗口接近正方形
    case cover
}

/// 窗口尺寸档位。窗口不能拖边缘改大小（避免误触），只能在这里选。
public enum StageSizePreset: String, CaseIterable {
    case small, medium, large, custom

    public var title: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        case .custom: return "自定义…"
        }
    }

    /// 预设尺寸（点）；自定义返回 nil
    public var size: CGSize? {
        switch self {
        case .small: return CGSize(width: 280, height: 200)
        case .medium: return CGSize(width: 340, height: 280)
        case .large: return CGSize(width: 440, height: 360)
        case .custom: return nil
        }
    }
}

// MARK: - 显示用的歌词结构

public struct StageSyllable: Hashable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// 一个「不可断开」的单位：英文是一个单词，中日韩是一个字。
public struct StageWord: Hashable, Identifiable {
    public let id: Int
    public var syllables: [StageSyllable]
    /// 词后面是否有空格（布局时用间距表示，避免尾随空格宽度不稳定）
    public var trailingSpace: Bool

    public init(id: Int, syllables: [StageSyllable], trailingSpace: Bool) {
        self.id = id
        self.syllables = syllables
        self.trailingSpace = trailingSpace
    }

    public var text: String { syllables.map(\.text).joined() }
    public var start: TimeInterval { syllables.first?.start ?? 0 }
    public var end: TimeInterval { syllables.last?.end ?? 0 }

    /// 0...1，按字符数加权的演唱进度。
    public func progress(at time: TimeInterval) -> Double {
        guard time > start else { return 0 }
        guard time < end else { return 1 }
        let total = max(1, syllables.reduce(0) { $0 + $1.text.count })
        var done = 0.0
        for s in syllables {
            let n = Double(s.text.count)
            if time >= s.end {
                done += n
            } else if time > s.start {
                let span = max(0.001, s.end - s.start)
                done += n * (time - s.start) / span
                break
            } else {
                break
            }
        }
        return min(1, done / Double(total))
    }
}

public struct StageLine: Identifiable, Hashable {
    public enum Kind: Hashable { case text, interlude }

    public let id: Int
    public var kind: Kind
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// 逐字时间；为 nil 表示只有逐行时间
    public var words: [StageWord]?
    public var translation: String?
    public var background: String?

    public var isWordSynced: Bool { words != nil }

    public init(id: Int, kind: Kind, start: TimeInterval, end: TimeInterval, text: String,
                words: [StageWord]? = nil, translation: String? = nil, background: String? = nil) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.text = text
        self.words = words
        self.translation = translation
        self.background = background
    }
}

public struct StagePalette: Equatable {
    public var colors: [Color]
    public var accent: Color
    public static let `default` = StagePalette(
        colors: [Color(red: 0.20, green: 0.16, blue: 0.32), Color(red: 0.42, green: 0.16, blue: 0.30), Color(red: 0.10, green: 0.22, blue: 0.36)],
        accent: Color(red: 0.98, green: 0.36, blue: 0.45)
    )
}

public struct StageActions {
    public var seek: (TimeInterval) -> Void = { _ in }
    public var playPause: () -> Void = {}
    public var next: () -> Void = {}
    public var previous: () -> Void = {}
    /// 调整歌词偏移，单位秒；正数表示歌词提前出现
    public var adjustOffset: (Double) -> Void = { _ in }
    public var resetOffset: () -> Void = {}
    public var searchLyrics: () -> Void = {}
    public var wrongLyrics: () -> Void = {}
    public var showInFinder: () -> Void = {}
    public var openPreferences: () -> Void = {}
    public var setPinned: (Bool) -> Void = { _ in }
    public var setMode: (StageMode) -> Void = { _ in }
    /// 选择尺寸档位；选「自定义」时弹出输入框
    public var setSizePreset: (StageSizePreset) -> Void = { _ in }
    public var importLyrics: (String) -> Void = { _ in }
    public init() {}
}

// MARK: - Model

@MainActor
public final class StageModel: ObservableObject {
    @Published public var lines: [StageLine] = [] {
        didSet { tick(force: true) }
    }
    @Published public private(set) var currentIndex: Int?

    @Published public var title = ""
    @Published public var artist = ""
    @Published public var album = ""
    @Published public var hasTrack = false
    @Published public var duration: TimeInterval = 0
    @Published public var isPlaying = false

    @Published public private(set) var artwork: NSImage?
    @Published public private(set) var backdropImage: NSImage?
    @Published public private(set) var palette: StagePalette = .default

    @Published public var mode: StageMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "LyricsStageMode") }
    }
    @Published public var showTranslation: Bool {
        didSet { UserDefaults.standard.set(showTranslation, forKey: "LyricsStageShowTranslation") }
    }
    /// 字号倍率（0.85 / 1 / 1.15）
    @Published public var fontScale: Double {
        didSet { UserDefaults.standard.set(fontScale, forKey: "LyricsStageFontScale") }
    }
    @Published public var isPinned = false
    @Published public var sizePreset: StageSizePreset = .medium
    @Published public var isSearching = false
    @Published public var sourceDescription: String?
    @Published public var offsetDescription: String?
    @Published public var toast: String?

    /// 鼠标是否在窗口内（控制按钮的显隐）
    @Published public var isHoveringWindow = false
    /// 用户手动滚动的偏移，停手 3 秒后自动回到当前行
    @Published public var userScrollOffset: CGFloat = 0
    @Published public private(set) var isUserScrolling = false

    public var hasTranslation: Bool { lines.contains { $0.translation != nil } }

    /// 当前播放时间（已含歌词偏移）。由 App 提供。
    public var timeProvider: () -> TimeInterval = { 0 }
    public var actions = StageActions()

    private var timer: Timer?
    private var scrollResumeWork: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?

    public init() {
        let d = UserDefaults.standard
        mode = StageMode(rawValue: d.string(forKey: "LyricsStageMode") ?? "") ?? .lyrics
        showTranslation = d.object(forKey: "LyricsStageShowTranslation") as? Bool ?? true
        let scale = d.double(forKey: "LyricsStageFontScale")
        fontScale = scale > 0 ? scale : 1
        let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func now() -> TimeInterval { timeProvider() }

    public func tick(force: Bool = false) {
        let idx = Self.index(in: lines, at: timeProvider())
        if force || idx != currentIndex {
            currentIndex = idx
        }
    }

    public func setArtwork(_ image: NSImage?) {
        guard image !== artwork else { return }
        artwork = image
        if let image {
            let blurred = StageImageProcessing.backdrop(from: image)
            let palette = StageImageProcessing.palette(from: image)
            withAnimation(.easeInOut(duration: 0.8)) {
                self.backdropImage = blurred
                self.palette = palette
            }
        } else {
            withAnimation(.easeInOut(duration: 0.8)) {
                backdropImage = nil
                palette = .default
            }
        }
    }

    public func showToast(_ text: String) {
        toastWork?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { toast = text }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.3)) { self?.toast = nil }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    // MARK: 手动滚动

    public func userScrolled(by delta: CGFloat) {
        isUserScrolling = true
        userScrollOffset += delta
        scrollResumeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.resumeTracking() }
        scrollResumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    public func resumeTracking() {
        scrollResumeWork?.cancel()
        withAnimation(.spring(response: 0.7, dampingFraction: 0.86)) {
            userScrollOffset = 0
            isUserScrolling = false
        }
    }

    // MARK: 行定位

    static func index(in lines: [StageLine], at time: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        var lo = 0, hi = lines.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].start <= time {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        // 间奏点只在它的时间段内显示，结束后让位给下一行（前面的文字行不重新点亮）
        if let f = found, lines[f].kind == .interlude, time >= lines[f].end {
            return f + 1 < lines.count ? f + 1 : f
        }
        return found
    }
}

// MARK: - 由 Lyrics 构造显示行

extension StageModel {
    /// - Parameters:
    ///   - translationCode: 优先使用的翻译语言
    ///   - convert: 简繁转换等文本变换（逐音节调用，保证不破坏逐字时间）
    public static func makeLines(
        from lyrics: Lyrics,
        translationCode: String?,
        convert: (String) -> String = { $0 }
    ) -> [StageLine] {
        let all = lyrics.lines.filter(\.enabled)
        var result: [StageLine] = []
        var nextID = 0
        func appendInterlude(_ start: TimeInterval, _ end: TimeInterval) {
            guard end - start >= 6 else { return }
            result.append(StageLine(id: nextID, kind: .interlude, start: start, end: end - 0.25, text: ""))
            nextID += 1
        }

        var previousEnd: TimeInterval = 0
        for (i, line) in all.enumerated() {
            let content = line.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            // 开头的署名行（作词/作曲/Lyrics by…）和「歌名 - 歌手」标题行不显示
            if line.position < 40, isCreditLine(content, title: lyrics.idTags[.title], artist: lyrics.idTags[.artist]) { continue }
            let start = line.position
            let nextAny = i + 1 < all.count ? all[i + 1].position : nil
            let words = makeWords(for: line, lineStart: start, nextStart: nextAny, convert: convert)

            var end: TimeInterval
            if let w = words, let last = w.last {
                end = max(last.end, start + 0.2)
            } else if let duration = line.attachments.timetag?.duration, duration > 0 {
                end = start + duration
            } else {
                end = nextAny ?? (start + 6)
            }
            if let nextAny, nextAny > start { end = min(end, max(nextAny, start + 0.2)) }

            appendInterlude(result.isEmpty ? 0 : previousEnd, start)

            var translation = line.attachments[.translation(languageCode: translationCode)]
                ?? line.attachments.translation()
            translation = translation?.trimmingCharacters(in: .whitespacesAndNewlines)
            if translation?.isEmpty == true || translation == content { translation = nil }
            if let t = translation, t.contains("翻译由") || t.contains("歌词翻译") || t.contains("译者") { translation = nil }
            let background = line.attachments[.backgroundVocals]

            result.append(StageLine(
                id: nextID,
                kind: .text,
                start: start,
                end: end,
                text: convert(content),
                words: words,
                translation: translation.map(convert),
                background: background.map(convert)
            ))
            nextID += 1
            previousEnd = end
        }
        return result
    }

    private static let creditPattern = try! NSRegularExpression(
        pattern: #"^\s*[^\s]{0,8}?\s*(作词|作曲|编曲|制作人|制作|监制|混音|录音|和声|吉他|贝斯|鼓|母带|出品|发行|词|曲|OP|SP|Lyrics?( by)?|Lyricist|Written by|Composed by|Composer|Arranged by|Arranger|Produced by|Producer|Mixed by|Mastered by|Vocals?)\s*[:：]"#,
        options: [.caseInsensitive]
    )

    static func isCreditLine(_ text: String, title: String?, artist: String?) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        if creditPattern.firstMatch(in: text, range: range) != nil { return true }
        if let title, !title.isEmpty, text.hasPrefix(title), text.contains(" - ") { return true }
        return false
    }

    private static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { s in
            switch s.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3000...0x303F, 0xFF00...0xFFEF:
                return true
            default:
                return false
            }
        }
    }

    /// 把逐字时间转成「词」列表。优先用 TTML 的精确时间，其次用通用的 InlineTimeTag。
    static func makeWords(
        for line: LyricsLine,
        lineStart: TimeInterval,
        nextStart: TimeInterval?,
        convert: (String) -> String
    ) -> [StageWord]? {
        let chars = Array(line.content)
        guard !chars.isEmpty else { return nil }
        var segments: [StageSyllable] = []

        if let sync = line.attachments.synchronizedTextTiming, sync.isValid(forCharacterCount: chars.count) {
            var cursor = 0
            let syllables = sync.words.flatMap { word in
                word.syllables.isEmpty
                    ? [LyricsLine.Attachments.SynchronizedTextTiming.Syllable(characterRange: word.characterRange, timeRange: word.timeRange)]
                    : word.syllables
            }.sorted { $0.characterRange.lowerBound < $1.characterRange.lowerBound }
            for syl in syllables {
                let r = syl.characterRange.clamped(to: 0 ..< chars.count)
                guard !r.isEmpty, r.lowerBound >= cursor else { continue }
                // 两个音节之间的字符（通常是空格）并入前一个音节
                if r.lowerBound > cursor {
                    let gap = String(chars[cursor ..< r.lowerBound])
                    if segments.isEmpty {
                        segments.append(StageSyllable(text: gap, start: lineStart + syl.timeRange.lowerBound, end: lineStart + syl.timeRange.lowerBound))
                    } else {
                        segments[segments.count - 1].text += gap
                    }
                }
                segments.append(StageSyllable(
                    text: String(chars[r]),
                    start: lineStart + syl.timeRange.lowerBound,
                    end: lineStart + syl.timeRange.upperBound
                ))
                cursor = r.upperBound
            }
            if cursor < chars.count, !segments.isEmpty {
                segments[segments.count - 1].text += String(chars[cursor...])
            }
        } else if let tt = line.attachments.timetag, tt.tags.count >= 2 || (tt.tags.count == 1 && tt.duration != nil) {
            let tags = tt.tags.sorted { $0.index < $1.index }
            let lineDuration = tt.duration ?? ((nextStart ?? lineStart + 5) - lineStart)
            // 第一个时间标签前的字符
            if let first = tags.first, first.index > 0 {
                segments.append(StageSyllable(text: String(chars[0 ..< min(first.index, chars.count)]),
                                              start: lineStart, end: lineStart + first.time))
            }
            for (k, tag) in tags.enumerated() {
                let from = min(max(0, tag.index), chars.count)
                let to = k + 1 < tags.count ? min(max(from, tags[k + 1].index), chars.count) : chars.count
                guard to > from else { continue }
                let t0 = tag.time
                let t1 = k + 1 < tags.count ? tags[k + 1].time : max(t0, lineDuration)
                segments.append(StageSyllable(text: String(chars[from ..< to]),
                                              start: lineStart + t0, end: lineStart + max(t0, t1)))
            }
        } else {
            return nil
        }

        guard !segments.isEmpty else { return nil }

        // 合并成「词」：遇到空格或中日韩字符就断开
        var words: [StageWord] = []
        var current: [StageSyllable] = []
        func flush(trailingSpace: Bool) {
            guard !current.isEmpty else { return }
            words.append(StageWord(id: words.count, syllables: current, trailingSpace: trailingSpace))
            current = []
        }
        for seg in segments {
            // 一个音节里可能含多个以空格分开的词（例如逐行转来的数据），拆开
            var pieceStart = seg.text.startIndex
            let text = seg.text
            let count = max(1, text.count)
            var charOffset = 0
            func timeAt(_ offset: Int) -> TimeInterval {
                seg.start + (seg.end - seg.start) * Double(offset) / Double(count)
            }
            var idx = text.startIndex
            while idx < text.endIndex {
                let c = text[idx]
                let nextIdx = text.index(after: idx)
                if c.isWhitespace {
                    let piece = String(text[pieceStart ..< idx])
                    let pieceOffset = text.distance(from: text.startIndex, to: pieceStart)
                    if !piece.isEmpty {
                        current.append(StageSyllable(text: convert(piece), start: timeAt(pieceOffset), end: timeAt(charOffset)))
                    }
                    flush(trailingSpace: true)
                    pieceStart = nextIdx
                } else if isCJK(c) {
                    let before = String(text[pieceStart ..< idx])
                    let pieceOffset = text.distance(from: text.startIndex, to: pieceStart)
                    if !before.isEmpty {
                        current.append(StageSyllable(text: convert(before), start: timeAt(pieceOffset), end: timeAt(charOffset)))
                    }
                    flush(trailingSpace: false)
                    current.append(StageSyllable(text: convert(String(c)), start: timeAt(charOffset), end: timeAt(charOffset + 1)))
                    flush(trailingSpace: false)
                    pieceStart = nextIdx
                }
                charOffset += 1
                idx = nextIdx
            }
            let rest = String(text[pieceStart...])
            if !rest.isEmpty {
                let pieceOffset = text.distance(from: text.startIndex, to: pieceStart)
                current.append(StageSyllable(text: convert(rest), start: timeAt(pieceOffset), end: seg.end))
            }
        }
        flush(trailingSpace: false)
        return words.isEmpty ? nil : words
    }
}

// MARK: - 图像处理（背景与取色）

enum StageImageProcessing {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// 预先模糊好的小图：背景层只需旋转缩放，不必每帧做高斯模糊。
    static func backdrop(from image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var ci = CIImage(cgImage: cg)
        let target: CGFloat = 160
        let scale = target / max(ci.extent.width, ci.extent.height)
        ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = ci.extent
        ci = ci.clampedToExtent()
            .applyingGaussianBlur(sigma: 14)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.7,
                kCIInputBrightnessKey: -0.04,
                kCIInputContrastKey: 1.05,
            ])
            .cropped(to: extent)
        guard let out = context.createCGImage(ci, from: extent) else { return nil }
        return NSImage(cgImage: out, size: extent.size)
    }

    static func palette(from image: NSImage) -> StagePalette {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .default }
        let side = 10
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .default }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        var candidates: [(h: CGFloat, s: CGFloat, b: CGFloat)] = []
        for i in 0 ..< side * side {
            let r = CGFloat(pixels[i * 4]) / 255, g = CGFloat(pixels[i * 4 + 1]) / 255, b = CGFloat(pixels[i * 4 + 2]) / 255
            var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
            NSColor(srgbRed: r, green: g, blue: b, alpha: 1).getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
            candidates.append((hue, sat, bri))
        }
        // 偏好饱和、亮度适中的颜色；挑出色相差异明显的 3 个
        let sorted = candidates.sorted { ($0.s * (1 - abs($0.b - 0.6))) > ($1.s * (1 - abs($1.b - 0.6))) }
        var picked: [(h: CGFloat, s: CGFloat, b: CGFloat)] = []
        for c in sorted {
            if picked.allSatisfy({ hueDistance($0.h, c.h) > 0.08 || abs($0.b - c.b) > 0.3 }) {
                picked.append(c)
            }
            if picked.count == 3 { break }
        }
        while picked.count < 3 { picked.append(picked.last ?? (0.7, 0.3, 0.4)) }
        let colors = picked.map { Color(hue: $0.h, saturation: min(1, $0.s * 1.1), brightness: min(0.75, max(0.25, $0.b))) }
        let accentSource = picked.first!
        let accent = Color(hue: accentSource.h, saturation: min(1, max(0.45, accentSource.s)), brightness: 0.95)
        return StagePalette(colors: colors, accent: accent)
    }

    private static func hueDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let d = abs(a - b)
        return min(d, 1 - d)
    }
}
