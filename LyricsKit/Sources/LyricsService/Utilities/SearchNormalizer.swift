import Foundation

/// 歌名 / 歌手的归一化工具，用于两件事：
/// 1. 生成更「干净」的搜索词（去掉 feat.、Remastered、Live 等后缀，只保留主唱）；
/// 2. 给搜索结果打分时做宽松比较（全角/半角、繁/简、大小写、标点都不影响）。
public enum LyricsSearchNormalizer {
    /// 用于比较的规范形式：全角转半角、繁体转简体、去音调符号、小写、去掉标点和空白。
    public static func comparable(_ string: String) -> String {
        var s = string
        s = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        s = s.applyingTransform(StringTransform(rawValue: "Hant-Hans"), reverse: false) ?? s
        s = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        s = s.unicodeScalars.filter { !CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines).contains($0) }
            .map(String.init).joined()
        return s
    }

    private static let bracketPattern = #"\s*[\(\[（【〔［{<《][^\)\]）】〕］}>》]*[\)\]）】〕］}>》]"#
    private static let featPattern = #"(?i)\s+(feat\.?|ft\.?|featuring|with)\s+.*$"#
    private static let dashSuffixPattern = #"\s+[-–—~～]\s+.*$"#

    /// 去掉版本信息后的「核心歌名」。
    /// "Song (feat. X) [Remastered 2011] - Live at Wembley" → "Song"
    public static func coreTitle(_ title: String) -> String {
        var s = title
        s = s.replacingOccurrences(of: bracketPattern, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: featPattern, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: dashSuffixPattern, with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? title.trimmingCharacters(in: .whitespacesAndNewlines) : s
    }

    /// 把「A, B & C feat. D」拆成各个歌手。
    public static func artists(_ artist: String) -> [String] {
        let separators = #"(?i)\s*(,|，|&|＆|/|／|、|;|；|\+|\s+x\s+|\s+×\s+|\s+vs\.?\s+|\s+feat\.?\s+|\s+ft\.?\s+|\s+featuring\s+|\s+with\s+|\s+and\s+)\s*"#
        return artist
            .replacingOccurrences(of: separators, with: "\u{1F}", options: .regularExpression)
            .split(separator: "\u{1F}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 歌手集合的相似度：有任何一位歌手完全对上就给高分。
    static func artistSimilarity(_ a: String, _ b: String, similarity: (String, String) -> Double) -> Double {
        let lhs = artists(a).map(comparable).filter { !$0.isEmpty }
        let rhs = artists(b).map(comparable).filter { !$0.isEmpty }
        guard !lhs.isEmpty, !rhs.isEmpty else { return similarity(comparable(a), comparable(b)) }
        if Set(lhs) == Set(rhs) { return 1 }
        if !Set(lhs).isDisjoint(with: rhs) { return 0.95 }
        var best = similarity(comparable(a), comparable(b))
        for l in lhs {
            for r in rhs {
                best = max(best, similarity(l, r))
            }
        }
        return best
    }
}

/// 搜索插件：在原始搜索之外，再用「核心歌名 + 主唱」搜一遍。
/// 解决 "Song (Remastered 2011)"、"A, B & C" 这类在国内平台搜不到的情况。
public struct LyricsSearchVariantsPlugin: LyricsSearchRequestPlugin {
    public init() {}

    public func additionalRequests(for request: LyricsSearchRequest) async -> [LyricsSearchRequest] {
        guard case .info(let title, let artist) = request.searchTerm else { return [] }
        let core = LyricsSearchNormalizer.coreTitle(title)
        let primary = LyricsSearchNormalizer.artists(artist).first ?? artist
        var result: [LyricsSearchRequest] = []
        if core != title || primary != artist {
            result.append(request.derived(searchTerm: .info(title: core, artist: primary)))
        }
        return result
    }
}
