import Foundation
import LyricsCore

// 咪咕音乐：版权曲库较全，常能补上其他平台缺失的华语歌；歌词为逐行 LRC，
// 有翻译时单独给出 trcUrl。

extension LyricsProviders {
    final class Migu {
        let httpClient: HTTPClient
        private var performer: NetworkPerformer { NetworkPerformer(httpClient: httpClient) }

        init(httpClient: HTTPClient = .shared) {
            self.httpClient = httpClient
        }
    }
}

extension LyricsProviders.Migu: _LyricsProvider {
    struct LyricsToken {
        let id: String
        let title: String
        let artist: String
        let album: String?
        let lyricURL: String
        let translationURL: String?
        let artworkURL: URL?
    }

    static let service: String = "Migu"

    var isAuthorized: Bool { get async { true } }

    private static let headers = [
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
        "Referer": "https://m.music.migu.cn/",
    ]

    func search(for request: LyricsSearchRequest) async throws -> [LyricsToken] {
        let endpoint = Endpoint(
            host: "pd.musicapp.migu.cn",
            path: "/MIGUM3.0/v1.0/content/search_all.do",
            queryItems: [
                URLQueryItem(name: "text", value: request.searchTerm.description),
                URLQueryItem(name: "pageNo", value: "1"),
                URLQueryItem(name: "pageSize", value: "10"),
                URLQueryItem(name: "searchSwitch", value: #"{"song":1}"#),
            ],
            headers: Self.headers
        )
        let response: MiguSearchResponse = try await performer.performJSON(endpoint)
        return (response.songResultData?.result ?? []).compactMap { song in
            guard let lyricURL = song.lyricUrl, !lyricURL.isEmpty else { return nil }
            let art = song.imgItems?.last?.img.flatMap(URL.init(string:))
            return LyricsToken(
                id: song.copyrightId ?? song.id ?? "",
                title: song.name ?? "",
                artist: (song.singers ?? []).compactMap(\.name).joined(separator: "/"),
                album: song.albums?.first?.name,
                lyricURL: lyricURL,
                translationURL: song.trcUrl,
                artworkURL: art
            )
        }
    }

    func fetch(with token: LyricsToken) async throws -> Lyrics {
        let request = try Endpoint.absolute(token.lyricURL, headers: Self.headers)
        let data = try await performer.executeReturningData(request)
        guard let text = String(data: data, encoding: .utf8), let lyrics = Lyrics(text) else {
            throw LyricsProviderError.processingFailed(reason: "Migu: unparsable lyrics")
        }
        if let trc = token.translationURL, !trc.isEmpty,
           let req = try? Endpoint.absolute(trc, headers: Self.headers),
           let trData = try? await performer.executeReturningData(req),
           let trText = String(data: trData, encoding: .utf8),
           let translation = Lyrics(trText) {
            lyrics.merge(translation: translation)
        }
        lyrics.applyMetadata(
            title: token.title,
            artist: token.artist,
            album: token.album,
            artworkURL: token.artworkURL,
            serviceToken: token.id
        )
        return lyrics
    }
}

struct MiguSearchResponse: Decodable {
    struct ResultData: Decodable {
        let result: [Song]?
    }
    struct Song: Decodable {
        struct Named: Decodable { let name: String? }
        struct Image: Decodable { let img: String? }
        let id: String?
        let copyrightId: String?
        let name: String?
        let singers: [Named]?
        let albums: [Named]?
        let lyricUrl: String?
        let trcUrl: String?
        let imgItems: [Image]?
    }
    let songResultData: ResultData?
}
