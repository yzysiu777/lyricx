import Testing
import Foundation
import LyricsCore
@testable import LyricsService

struct ProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LYRICX_PROBE"] != nil)) func probe() async throws {
        let env = ProcessInfo.processInfo.environment
        let req = LyricsSearchRequest(searchTerm: .info(title: env["T"]!, artist: env["A"]!), duration: Double(env["D"]!)!, limit: 4)
        let group = LyricsProviders.Group(
            providers: LyricsProviders.Service.freeServices.map { $0.create() } + [LyricsProviders.Service.musixmatch.create()],
            plugins: [LyricsSearchVariantsPlugin()]
        )
        for try await l in group.lyrics(for: req) {
            print(String(format: "PROBE %@ | %@ - %@ | len %.0f | q %.2f | ok %@", l.metadata.service ?? "?", l.idTags[.title] ?? "", l.idTags[.artist] ?? "", l.length ?? -1, l.quality, l.isPlausibleMatch ? "YES" : "no"))
        }
    }
}
