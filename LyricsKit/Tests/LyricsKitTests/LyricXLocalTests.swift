import Testing
import Foundation
import LyricsCore
@testable import LyricsService

struct AMLLTTMLParsingTests {
    private let sample = """
    <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:itunes="http://music.apple.com/lyric-ttml-internal"><body dur="04:25.541"><div begin="00:29.231" end="04:25.541">\
    <p begin="00:29.231" end="00:32.723" itunes:key="L1"><span begin="00:29.231" end="00:29.692">Hello</span> <span begin="00:29.692" end="00:30.057">world</span><span ttm:role="x-translation" xml:lang="zh-CN">你好 世界</span><span ttm:role="x-bg"><span begin="00:31.000" end="00:31.500">(ooh)</span></span></p>\
    <p begin="00:01:32.000" end="00:01:33.000"><span begin="00:01:32.000" end="00:01:33.000">Bye</span></p>\
    </div></body></tt>
    """

    @Test func parsesInlineRoles() throws {
        let lyrics = try #require(Lyrics(ttmlContent: sample))
        #expect(lyrics.lines.count == 2)
        let line = lyrics.lines[0]
        #expect(line.content == "Hello world")
        #expect(line.attachments[.translation(languageCode: "zh-CN")] == "你好 世界")
        #expect(line.attachments[.backgroundVocals] == "(ooh)")
        #expect(line.attachments.timetag != nil)
        #expect(lyrics.metadata.attachmentTags.contains(.translation(languageCode: "zh-CN")))
        #expect(abs(lyrics.lines[1].position - 92) < 0.001)
    }
}

struct SearchNormalizerTests {
    @Test func coreTitle() {
        #expect(LyricsSearchNormalizer.coreTitle("Don't Stop Me Now (Remastered 2011)") == "Don't Stop Me Now")
        #expect(LyricsSearchNormalizer.coreTitle("Song - Live at Wembley") == "Song")
        #expect(LyricsSearchNormalizer.coreTitle("Song feat. Someone") == "Song")
        #expect(LyricsSearchNormalizer.coreTitle("晴天（Live）") == "晴天")
        #expect(LyricsSearchNormalizer.coreTitle("(Intro)") == "(Intro)")
    }

    @Test func comparableFoldsScriptAndWidth() {
        #expect(LyricsSearchNormalizer.comparable("後來") == LyricsSearchNormalizer.comparable("后来"))
        #expect(LyricsSearchNormalizer.comparable("ＡＢＣ！") == "abc")
    }

    @Test func artistSplit() {
        #expect(LyricsSearchNormalizer.artists("A, B & C feat. D") == ["A", "B", "C", "D"])
        #expect(LyricsSearchNormalizer.artists("周杰伦/费玉清") == ["周杰伦", "费玉清"])
    }

    @Test func qualityPrefersExactCoreTitle() {
        func make(_ title: String, _ len: Double) -> Lyrics {
            let l = Lyrics("[00:00.00]a\n[00:05.00]b")!
            l.idTags[.title] = title
            l.idTags[.artist] = "周杰倫"
            l.length = len
            l.metadata.request = LyricsSearchRequest(searchTerm: .info(title: "晴天", artist: "周杰伦"), duration: 269)
            return l
        }
        let exact = make("晴天", 270)
        let medley = make("晴天+告白气球 (Live)", 506)
        #expect(exact.quality > medley.quality + 0.2)
    }
}

/// 真实网络冒烟测试：LYRICX_NETWORK_TESTS=1 swift test --filter NewSourcesNetworkTests
struct NewSourcesNetworkTests {
    static let enabled = ProcessInfo.processInfo.environment["LYRICX_NETWORK_TESTS"] == "1"
    let request = LyricsSearchRequest(searchTerm: .info(title: "晴天", artist: "周杰伦"), duration: 269, limit: 2)

    private func first(_ provider: LyricsProvider, _ req: LyricsSearchRequest? = nil) async throws -> Lyrics? {
        for try await lyrics in provider.lyrics(for: req ?? request) { return lyrics }
        return nil
    }

    @Test(.enabled(if: enabled)) func kuwo() async throws {
        let l = try #require(try await first(LyricsProviders.Kuwo()))
        print("Kuwo:", l.idTags[.title] ?? "", l.lines.count, l.quality)
        #expect(l.lines.count > 10)
    }

    @Test(.enabled(if: enabled)) func migu() async throws {
        let l = try #require(try await first(LyricsProviders.Migu()))
        print("Migu:", l.idTags[.title] ?? "", l.lines.count, l.quality)
        #expect(l.lines.count > 10)
    }

    @Test(.enabled(if: enabled)) func amll() async throws {
        let idol = LyricsSearchRequest(searchTerm: .info(title: "アイドル (Idol)", artist: "YOASOBI"), duration: 213, limit: 2)
        let l = try #require(try await first(LyricsProviders.AMLLTTMLDB(), idol))
        print("AMLL:", l.idTags[.title] ?? "", l.lines.count, l.quality, l.metadata.attachmentTags)
        #expect(l.lines.count > 10)
        #expect(l.lines.contains { $0.attachments.timetag != nil })
    }
}


struct PlausibleMatchTests {
    private func make(title: String, artist: String, length: Double, searchTitle: String, searchArtist: String, duration: Double) -> Lyrics {
        let l = Lyrics("[00:00.00]a\n[00:05.00]b")!
        l.idTags[.title] = title
        l.idTags[.artist] = artist
        l.length = length
        l.metadata.request = LyricsSearchRequest(searchTerm: .info(title: searchTitle, artist: searchArtist), duration: duration)
        return l
    }

    @Test func rejectsSameTitleDifferentArtist() {
        // 实际遇到的错例：Babehoven 的 You're a Liar 被配上 Alfie Templeman 的同名歌
        let l = make(title: "You're a Liar", artist: "Alfie Templeman", length: 165.7, searchTitle: "You're a Liar", searchArtist: "Babehoven", duration: 160.3)
        #expect(!l.isPlausibleMatch)
    }

    @Test func acceptsTransliteratedArtistWithSameDuration() {
        let l = make(title: "晴天", artist: "周杰伦", length: 269.5, searchTitle: "晴天", searchArtist: "Jay Chou", duration: 269)
        #expect(l.isPlausibleMatch)
    }

    @Test func acceptsNormalMatch() {
        let l = make(title: "if I could I would", artist: "Tove Lo", length: 127.6, searchTitle: "if I could I would", searchArtist: "Tove Lo", duration: 128)
        #expect(l.isPlausibleMatch)
    }

    @Test func rejectsDifferentSong() {
        let l = make(title: "晴天+告白气球 (Live)", artist: "周杰伦", length: 506, searchTitle: "晴天", searchArtist: "周杰伦", duration: 269)
        #expect(!l.isPlausibleMatch)
    }
}
