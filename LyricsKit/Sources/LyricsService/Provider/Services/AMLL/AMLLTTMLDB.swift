import Foundation
import LyricsCore

// AMLL TTML DB（github.com/Steve-xmh/amll-ttml-db）：社区人工校对的逐字歌词库，
// 带逐字时间、翻译、背景和声，质量通常是所有来源里最好的。
// 仓库里有一份 metadata/raw-lyrics-index.jsonl（约 1.6 MB），列出每个文件的歌名/歌手。
// 我们把索引缓存在本地（24 小时刷新），按歌名+歌手在本地匹配，再下载对应 TTML。
// 没收录的歌就没有结果，属于正常情况。

extension LyricsProviders {
    final class AMLLTTMLDB {
        let httpClient: HTTPClient
        private var performer: NetworkPerformer { NetworkPerformer(httpClient: httpClient) }

        /// 主地址 + 国内更容易连上的镜像，依次尝试。
        static let mirrors = [
            "https://raw.githubusercontent.com/Steve-xmh/amll-ttml-db/main/",
            "https://cdn.jsdelivr.net/gh/Steve-xmh/amll-ttml-db@main/",
        ]

        init(httpClient: HTTPClient = .shared) {
            self.httpClient = httpClient
        }
    }
}

extension LyricsProviders.AMLLTTMLDB: _LyricsProvider {
    typealias LyricsToken = AMLLIndex.Entry

    static let service: String = "AMLL"

    var isAuthorized: Bool { get async { true } }

    func search(for request: LyricsSearchRequest) async throws -> [LyricsToken] {
        let entries = try await AMLLIndex.shared.entries(using: self)
        let matched: [AMLLIndex.Entry]
        switch request.searchTerm {
        case .info(let title, let artist):
            let core = LyricsSearchNormalizer.comparable(LyricsSearchNormalizer.coreTitle(title))
            let full = LyricsSearchNormalizer.comparable(title)
            let wantedArtists = Set(LyricsSearchNormalizer.artists(artist).map(LyricsSearchNormalizer.comparable))
            matched = entries.filter { entry in
                let titleOK = entry.comparableTitles.contains { $0 == core || $0 == full }
                guard titleOK else { return false }
                if wantedArtists.isEmpty { return true }
                return entry.comparableArtists.contains { a in
                    wantedArtists.contains { $0 == a || (!a.isEmpty && ($0.contains(a) || a.contains($0))) }
                }
            }
        case .keyword(let keyword):
            let k = LyricsSearchNormalizer.comparable(keyword)
            matched = entries.filter { entry in
                entry.comparableTitles.contains { !$0.isEmpty && k.contains($0) }
                    && entry.comparableArtists.contains { !$0.isEmpty && k.contains($0) }
            }
        }
        // 同一首歌可能有多次提交，只留最新的。
        var latest: [String: AMLLIndex.Entry] = [:]
        for entry in matched {
            let key = entry.dedupeKey
            if let existing = latest[key], existing.file >= entry.file { continue }
            latest[key] = entry
        }
        return latest.values.sorted { $0.file > $1.file }
    }

    func fetch(with token: LyricsToken) async throws -> Lyrics {
        let data = try await download("raw-lyrics/" + token.file)
        guard let text = String(data: data, encoding: .utf8),
              let lyrics = Lyrics(ttmlContent: text) else {
            throw LyricsProviderError.processingFailed(reason: "AMLL: invalid TTML")
        }
        lyrics.applyMetadata(
            title: token.titles.first,
            artist: token.artists.joined(separator: "/"),
            album: token.album,
            length: lyrics.lines.last.map { line in
                line.position + (line.attachments.timetag?.duration ?? 0)
            },
            serviceToken: token.file
        )
        // 歌词结尾不等于歌曲时长，不能当作时长参与打分。
        lyrics.length = nil
        return lyrics
    }

    func download(_ path: String) async throws -> Data {
        var lastError: Error = LyricsProviderError.processingFailed(reason: "AMLL: unreachable")
        for base in Self.mirrors {
            do {
                var request = try Endpoint.absolute(base + path)
                request.timeoutInterval = 10
                let (data, response) = try await performer.execute(request)
                if response.statusCode == 200 { return data }
                lastError = LyricsProviderError.processingFailed(reason: "AMLL: HTTP \(response.statusCode)")
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}

/// AMLL 索引：内存 + 磁盘双层缓存。
actor AMLLIndex {
    static let shared = AMLLIndex()

    struct Entry: Sendable {
        let titles: [String]
        let artists: [String]
        let album: String?
        let file: String
        let comparableTitles: [String]
        let comparableArtists: [String]

        var dedupeKey: String {
            (comparableTitles.first ?? "") + "|" + comparableArtists.sorted().joined(separator: ",")
        }
    }

    private var cached: [Entry]?
    private var loadedAt: Date?
    private var loading: Task<[Entry], Error>?
    private static let maxAge: TimeInterval = 24 * 3600

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LyricsX", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("amll-raw-lyrics-index.jsonl")
    }

    func entries(using provider: LyricsProviders.AMLLTTMLDB) async throws -> [Entry] {
        if let cached, let loadedAt, Date().timeIntervalSince(loadedAt) < Self.maxAge {
            return cached
        }
        if let loading { return try await loading.value }

        let task = Task<[Entry], Error> {
            let url = Self.cacheURL
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let modified = attrs?[.modificationDate] as? Date
            if let modified, Date().timeIntervalSince(modified) < Self.maxAge,
               let data = try? Data(contentsOf: url) {
                return Self.parse(data)
            }
            do {
                let data = try await provider.download("metadata/raw-lyrics-index.jsonl")
                try? data.write(to: url, options: .atomic)
                return Self.parse(data)
            } catch {
                // 网络不通时退回旧缓存，总比没有好。
                if let data = try? Data(contentsOf: url) { return Self.parse(data) }
                throw error
            }
        }
        loading = task
        defer { loading = nil }
        let result = try await task.value
        cached = result
        loadedAt = Date()
        return result
    }

    static func parse(_ data: Data) -> [Entry] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var entries: [Entry] = []
        entries.reserveCapacity(4096)
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let file = obj["rawLyricFile"] as? String,
                  let pairs = obj["metadata"] as? [[Any]] else { continue }
            var meta: [String: [String]] = [:]
            for pair in pairs where pair.count == 2 {
                if let key = pair[0] as? String, let values = pair[1] as? [String] {
                    meta[key] = values
                }
            }
            let titles = meta["musicName"] ?? []
            guard !titles.isEmpty else { continue }
            let artists = meta["artists"] ?? []
            entries.append(Entry(
                titles: titles,
                artists: artists,
                album: meta["album"]?.first,
                file: file,
                comparableTitles: titles.flatMap { t in
                    [LyricsSearchNormalizer.comparable(t),
                     LyricsSearchNormalizer.comparable(LyricsSearchNormalizer.coreTitle(t))]
                },
                comparableArtists: artists.flatMap(LyricsSearchNormalizer.artists).map(LyricsSearchNormalizer.comparable)
            ))
        }
        return entries
    }
}
