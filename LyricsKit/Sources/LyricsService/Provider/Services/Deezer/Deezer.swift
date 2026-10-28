import Foundation
import LyricsCore

// Deezer：欧美曲库很全，匿名登录即可取到逐行同步歌词（数据来自 Musixmatch / LyricFind 授权）。
// 流程：匿名换 JWT → 公共搜索接口找歌 → GraphQL 取歌词。

extension LyricsProviders {
    final class Deezer {
        let httpClient: HTTPClient
        private var performer: NetworkPerformer { NetworkPerformer(httpClient: httpClient) }

        init(httpClient: HTTPClient = .shared) {
            self.httpClient = httpClient
        }
    }
}

/// 匿名 JWT 缓存（有效期较短，10 分钟刷新一次）
private actor DeezerTokenCache {
    static let shared = DeezerTokenCache()
    private var token: String?
    private var fetchedAt: Date?

    func token(using performer: NetworkPerformer) async throws -> String {
        if let token, let fetchedAt, Date().timeIntervalSince(fetchedAt) < 600 { return token }
        let request = try Endpoint.absolute("https://auth.deezer.com/login/anonymous?jo=p&rto=c")
        let data = try await performer.executeReturningData(request)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jwt = obj["jwt"] as? String, !jwt.isEmpty else {
            throw LyricsProviderError.processingFailed(reason: "Deezer: anonymous login failed")
        }
        token = jwt
        fetchedAt = Date()
        return jwt
    }
}

extension LyricsProviders.Deezer: _LyricsProvider {
    struct LyricsToken {
        let id: Int
        let title: String
        let artist: String
        let album: String?
        let duration: Double
        let artworkURL: URL?
    }

    static let service: String = "Deezer"

    var isAuthorized: Bool { get async { true } }

    func search(for request: LyricsSearchRequest) async throws -> [LyricsToken] {
        var queries: [String] = []
        switch request.searchTerm {
        case .info(let title, let artist):
            if !artist.isEmpty { queries.append("artist:\"\(artist)\" track:\"\(title)\"") }
            queries.append("\(title) \(artist)")
        case .keyword(let keyword):
            queries.append(keyword)
        }
        for q in queries {
            let endpoint = Endpoint(
                host: "api.deezer.com",
                path: "/search",
                queryItems: [URLQueryItem(name: "q", value: q), URLQueryItem(name: "limit", value: "8")]
            )
            let response: DeezerSearchResponse = try await performer.performJSON(endpoint)
            let tokens = (response.data ?? []).map {
                LyricsToken(
                    id: $0.id,
                    title: $0.title,
                    artist: $0.artist?.name ?? "",
                    album: $0.album?.title,
                    duration: Double($0.duration ?? 0),
                    artworkURL: ($0.album?.cover_xl ?? $0.album?.cover_big).flatMap(URL.init(string:))
                )
            }
            if !tokens.isEmpty { return tokens }
        }
        return []
    }

    func fetch(with token: LyricsToken) async throws -> Lyrics {
        let jwt = try await DeezerTokenCache.shared.token(using: performer)
        let query = "query L($id: String!) { track(trackId: $id) { lyrics { synchronizedLines { lrcTimestamp line } } } }"
        let body = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "variables": ["id": "\(token.id)"],
        ])
        var request = try Endpoint.absolute(
            "https://pipe.deezer.com/api",
            method: .post,
            headers: ["Authorization": "Bearer \(jwt)", "Content-Type": "application/json"],
            body: body
        )
        request.timeoutInterval = 10
        let data = try await performer.executeReturningData(request)
        let response = try performer.decode(data, as: DeezerLyricsResponse.self)
        guard let lines = response.data?.track?.lyrics?.synchronizedLines, !lines.isEmpty else {
            throw LyricsProviderError.processingFailed(reason: "Deezer: no synced lyrics")
        }
        let lrc = lines.map { "\($0.lrcTimestamp ?? "")\($0.line ?? "")" }.joined(separator: "\n")
        guard let lyrics = Lyrics(lrc) else {
            throw LyricsProviderError.processingFailed(reason: "Deezer: unparsable lyrics")
        }
        lyrics.applyMetadata(
            title: token.title,
            artist: token.artist,
            album: token.album,
            length: token.duration > 0 ? token.duration : nil,
            artworkURL: token.artworkURL,
            serviceToken: "\(token.id)"
        )
        return lyrics
    }
}

struct DeezerSearchResponse: Decodable {
    struct Track: Decodable {
        struct Artist: Decodable { let name: String }
        struct Album: Decodable {
            let title: String?
            let cover_big: String?
            let cover_xl: String?
        }
        let id: Int
        let title: String
        let duration: Int?
        let artist: Artist?
        let album: Album?
    }
    let data: [Track]?
}

struct DeezerLyricsResponse: Decodable {
    struct Payload: Decodable {
        struct Track: Decodable {
            struct LyricsBody: Decodable {
                struct Line: Decodable {
                    let lrcTimestamp: String?
                    let line: String?
                }
                let synchronizedLines: [Line]?
            }
            let lyrics: LyricsBody?
        }
        let track: Track?
    }
    let data: Payload?
}
