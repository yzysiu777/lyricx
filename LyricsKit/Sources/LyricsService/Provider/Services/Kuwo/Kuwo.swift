import Foundation
import LyricsCore

// 酷我音乐：歌曲库全、华语覆盖好；歌词为逐行 LRC。
// 搜索接口返回的是单引号「伪 JSON」，先把结构性的单引号换成双引号再解析
//（歌名里的撇号已被转义成 &apos;，不会被误伤）。

extension LyricsProviders {
    final class Kuwo {
        let httpClient: HTTPClient
        private var performer: NetworkPerformer { NetworkPerformer(httpClient: httpClient) }

        init(httpClient: HTTPClient = .shared) {
            self.httpClient = httpClient
        }
    }
}

extension LyricsProviders.Kuwo: _LyricsProvider {
    struct LyricsToken {
        let id: String
        let title: String
        let artist: String
        let album: String
        let duration: Double
        let artworkURL: URL?
    }

    static let service: String = "Kuwo"

    var isAuthorized: Bool { get async { true } }

    func search(for request: LyricsSearchRequest) async throws -> [LyricsToken] {
        let endpoint = Endpoint(
            scheme: "http",
            host: "search.kuwo.cn",
            path: "/r.s",
            queryItems: [
                URLQueryItem(name: "all", value: request.searchTerm.description),
                URLQueryItem(name: "ft", value: "music"),
                URLQueryItem(name: "itemset", value: "web_2013"),
                URLQueryItem(name: "client", value: "kt"),
                URLQueryItem(name: "pn", value: "0"),
                URLQueryItem(name: "rn", value: "10"),
                URLQueryItem(name: "rformat", value: "json"),
                URLQueryItem(name: "encoding", value: "utf8"),
                URLQueryItem(name: "vipver", value: "1"),
            ]
        )
        let data = try await performer.performData(endpoint)
        guard var text = String(data: data, encoding: .utf8) else {
            throw LyricsProviderError.processingFailed(reason: "Kuwo: non-UTF8 search response")
        }
        text = text.replacingOccurrences(of: #"(?<=[{\[,:])'|'(?=[}\],:])"#, with: "\"", options: .regularExpression)
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let list = json["abslist"] as? [[String: Any]] else {
            throw LyricsProviderError.processingFailed(reason: "Kuwo: unexpected search response")
        }
        return list.compactMap { item -> LyricsToken? in
            let rid = (item["MUSICRID"] as? String) ?? ""
            let id = rid.replacingOccurrences(of: "MUSIC_", with: "")
            guard !id.isEmpty, let name = item["SONGNAME"] as? String else { return nil }
            let artURL = (item["web_albumpic_short"] as? String).flatMap { path -> URL? in
                guard !path.isEmpty else { return nil }
                return URL(string: "https://img2.kuwo.cn/star/albumcover/500" + path.drop(while: { $0 != "/" }))
            }
            return LyricsToken(
                id: id,
                title: name.htmlEntityDecoded,
                artist: ((item["ARTIST"] as? String) ?? "").htmlEntityDecoded,
                album: ((item["ALBUM"] as? String) ?? "").htmlEntityDecoded,
                duration: Double((item["DURATION"] as? String) ?? "") ?? 0,
                artworkURL: artURL
            )
        }
    }

    func fetch(with token: LyricsToken) async throws -> Lyrics {
        let endpoint = Endpoint(
            host: "kuwo.cn",
            path: "/openapi/v1/www/lyric/getlyric",
            queryItems: [URLQueryItem(name: "musicId", value: token.id)]
        )
        let response: KuwoLyricsResponse = try await performer.performJSON(endpoint)
        guard let lines = response.data?.lrclist, !lines.isEmpty else {
            throw LyricsProviderError.processingFailed(reason: "Kuwo: no lyrics")
        }
        // 酷我把翻译行放在同一时间戳的下一行：转成 LRC 后交给 Lyrics 的合并逻辑处理。
        let lrc = lines.map { line -> String in
            let t = Double(line.time) ?? 0
            let m = Int(t) / 60
            let s = t - Double(m * 60)
            return String(format: "[%02d:%05.2f]%@", m, s, line.lineLyric.htmlEntityDecoded)
        }.joined(separator: "\n")
        guard let lyrics = Lyrics(lrc) else {
            throw LyricsProviderError.processingFailed(reason: "Kuwo: unparsable lyrics")
        }
        lyrics.applyMetadata(
            title: token.title,
            artist: token.artist,
            album: token.album.isEmpty ? nil : token.album,
            length: token.duration > 0 ? token.duration : nil,
            artworkURL: token.artworkURL,
            serviceToken: token.id
        )
        return lyrics
    }
}

struct KuwoLyricsResponse: Decodable {
    struct Payload: Decodable {
        struct Line: Decodable {
            let lineLyric: String
            let time: String
        }
        let lrclist: [Line]?
    }
    let data: Payload?
}

extension String {
    /// 解码搜索接口常见的 HTML 实体（&nbsp; &amp; &apos; &quot; &#39; …）。
    var htmlEntityDecoded: String {
        guard contains("&") else { return self }
        var result = self
        let table: [(String, String)] = [
            ("&nbsp;", " "), ("&apos;", "'"), ("&#39;", "'"), ("&quot;", "\""),
            ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&"),
        ]
        for (entity, value) in table {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result
    }
}
