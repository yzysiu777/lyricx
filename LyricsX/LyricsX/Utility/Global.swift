import AppKit
import Combine
import GenericID
import LyricsXFoundation
import MusicPlayer

let fontNameFallbackCountMax = 1
// 7 days. after this period of time since the app built, the app is not considered as "in review".
let masReviewPeriodLimit: TimeInterval = 60 * 60 * 24 * 7

// NOTE: to build your own product, replace these identifiers with yours and
// do the same in LyricsXHelper.
#if DEBUG
let lyricsXSharedSuiteName = "dev.JH.LyricsX.shared"
let lyricsXHelperIdentifier = "dev.JH.LyricsXHelper"
let lyricsXErrorDomain = "dev.JH.LyricsX"
#else
let lyricsXSharedSuiteName = "com.JH.LyricsX.shared"
let lyricsXHelperIdentifier = "com.JH.LyricsXHelper"
let lyricsXErrorDomain = "com.JH.LyricsX"
#endif

let crowdinProjectURL = URL(string: "https://crowdin.com/project/lyricsx")!

let defaults = UserDefaults.standard
// Shared between the app and the (non-sandboxed) LyricsXHelper via a plain
// preferences suite at ~/Library/Preferences/<suite>.plist. Deliberately NOT an
// App Group container: a non-sandboxed process can't read App Group preferences
// through cfprefsd ("kCFPreferencesAnyUser ... only allowed for System
// Containers"); a plain suite works for both processes.
let sharedDefaults = UserDefaults(suiteName: lyricsXSharedSuiteName)!
let defaultNC = NotificationCenter.default
let workspaceNC = NSWorkspace.shared.notificationCenter
let selectedPlayer = MusicPlayers.Selected.shared

let isInSandbox = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
let isFromMacAppStore = (try? Bundle.main.appStoreReceiptURL?.checkResourceIsReachable()) == true

extension DispatchQueue {
    static let lyricsDisplay = DispatchQueue(label: "LyricsDisplay")
}

extension CAMediaTimingFunction {
    static let mystery = CAMediaTimingFunction(controlPoints: 0.2, 0.1, 0.2, 1)
    static let swiftOut = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1)
}

func log(_ message: @autoclosure () -> String, file: String = #file, line: UInt = #line) {
    let fileName = (file as NSString).lastPathComponent
    // Adding prefix to distinguish from ton of AppleEvent error log.
    NSLog("CustomLog:\(fileName):\(line): \(message())")
}

// MARK: - Identifier

extension NSUserInterfaceItemIdentifier {
//    static let WriteToiTunes = NSUserInterfaceItemIdentifier("MainMenu.WriteToiTunes")
//    static let SearchLyrics = NSUserInterfaceItemIdentifier("MainMenu.SearchLyrics")
//    static let LyricsMenu = NSUserInterfaceItemIdentifier("MainMenu.Lyrics")

    static let searchResultColumnTitle = NSUserInterfaceItemIdentifier("SearchResult.TableColumn.Title")
    static let searchResultColumnArtist = NSUserInterfaceItemIdentifier("SearchResult.TableColumn.Artist")
    static let searchResultColumnSource = NSUserInterfaceItemIdentifier("SearchResult.TableColumn.Source")
}

extension NSStoryboard.SceneIdentifier {
    static let desktopLyricsWindow = NSStoryboard.SceneIdentifier("DesktopLyricsWindow")
    static let lyricsHUDAccessory = NSStoryboard.SceneIdentifier("LyricsHUDAccessory")
}

// MARK: - User Defaults

extension UserDefaults.DefaultsKeys {
    static let notifiedUpdateVersion = Key<String?>("NotifiedUpdateVersion")
    static let noSearchingTrackIds = Key<[String]>("NoSearchingTrackIds")
    static let noSearchingAlbumNames = Key<[String]>("NoSearchingAlbumNames")

    // Menu
    static let desktopLyricsEnabled = Key<Bool>("DesktopLyricsEnabled")
    static let menuBarLyricsEnabled = Key<Bool>("MenuBarLyricsEnabled")
    static let touchBarLyricsEnabled = Key<Bool>("TouchBarLyricsEnabled")

    // General
    static let preferredPlayerIndex = Key<Int>("PreferredPlayerIndex")
    static let launchAndQuitWithPlayer = Key<Bool>("LaunchAndQuitWithPlayer")

    static let lyricsSavingPathPopUpIndex = Key<Int>("LyricsSavingPathPopUpIndex")
    static let lyricsCustomSavingPathBookmark = Key<Data?>("LyricsCustomSavingPathBookmark")
    static let loadLyricsBesideTrack = Key<Bool>("LoadLyricsBesideTrack")

    static let selectedLanguage = Key<String?>("SelectedLanguage")

    static let strictSearchEnabled = Key<Bool>("StrictSearchEnabled")
    static let preferBilingualLyrics = Key<Bool>("PreferBilingualLyrics")
    static let chineseConversionIndex = Key<Int>("ChineseConversionIndex")

    static let combinedMenubarLyrics = Key<Bool>("CombinedMenubarLyrics")

    static let hideLyricsWhenMousePassingBy = Key<Bool>("HideLyricsWhenMousePassingBy")
    static let disableLyricsWhenPaused = Key<Bool>("DisableLyricsWhenPaused")
    static let disableLyricsWhenSreenShot = Key<Bool>("DisableLyricsWhenSreenShot")

    static let hideMenuBarItems = Key<Bool>("HideMenuBarItems")

    // Display
    static let desktopLyricsOneLineMode = Key<Bool>("DesktopLyricsOneLineMode")
    static let desktopLyricsVerticalMode = Key<Bool>("DesktopLyricsVerticalMode")
    static let desktopLyricsDraggable = Key<Bool>("DesktopLyricsDraggable")

    static let desktopLyricsXPositionFactor = Key<CGFloat>("DesktopLyricsXPositionFactor")
    static let desktopLyricsYPositionFactor = Key<CGFloat>("DesktopLyricsYPositionFactor")

    static let desktopLyricsEnableFurigana = Key<Bool>("DesktopLyricsEnableFurigana")
    static let desktopLyricsEnableRomajin = Key<Bool>("DesktopLyricsEnableRomajin")

    static let desktopLyricsFontName = Key<String>("DesktopLyricsFontName")
    static let desktopLyricsFontSize = Key<Int>("DesktopLyricsFontSize")
    static let desktopLyricsFontNameFallback = Key<[String]>("DesktopLyricsFontNameFallback")

    static let desktopLyricsColor = Key<NSColor>("DesktopLyricsColor", transformer: .keyedArchive)
    static let desktopLyricsProgressColor = Key<NSColor>("DesktopLyricsProgressColor", transformer: .keyedArchive)
    static let desktopLyricsShadowColor = Key<NSColor>("DesktopLyricsShadowColor", transformer: .keyedArchive)
    static let desktopLyricsBackgroundColor = Key<NSColor>("DesktopLyricsBackgroundColor", transformer: .keyedArchive)

    static let lyricsWindowFontName = Key<String>("LyricsWindowFontName")
    static let lyricsWindowFontSize = Key<Int>("LyricsWindowFontSize")
    static let lyricsWindowFontNameFallback = Key<[String]>("LyricsWindowFontNameFallback")

    static let lyricsWindowTextColor = Key<NSColor>("LyricsWindowTextColor", transformer: .keyedArchive)
    static let lyricsWindowHighlightColor = Key<NSColor>("LyricsWindowHighlightColor", transformer: .keyedArchive)

    // Shortcut
    static let shortcutToggleMenuBarLyrics = Key<String>("ShortcutToggleMenuBarLyrics")
    static let shortcutToggleKaraokeLyrics = Key<String>("ShortcutToggleKaraokeLyrics")
    static let shortcutShowLyricsWindow = Key<String>("ShortcutShowLyricsWindow")
    static let shortcutOffsetIncrease = Key<String>("ShortcutOffsetIncrease")
    static let shortcutOffsetDecrease = Key<String>("ShortcutOffsetDecrease")
    static let shortcutWriteToiTunes = Key<String>("ShortcutWriteToiTunes")
    static let shortcutSearchLyrics = Key<String>("ShortcutSearchLyrics")
    static let shortcutWrongLyrics = Key<String>("ShortcutWrongLyrics")
    static let shortcutTogglePreferences = Key<String>("ShortcutTogglePreferences")

    // Filter
    static let lyricsFilterEnabled = Key<Bool>("LyricsFilterEnabled")
    static let lyricsSmartFilterEnabled = Key<Bool>("LyricsSmartFilterEnabled")
    static let lyricsFilterKeys = Key<[String]>("LyricsFilterKeys")

    // Lab
    static let useSystemWideNowPlaying = Key<Bool>("UseSystemWideNowPlaying")
    static let systemWideNowPlayingAppList = Key<[String]>("SystemWideNowPlayingAppList")

    static let writeiTunesWithTranslation = Key<Bool>("WriteiTunesWithTranslation")
    static let writeToiTunesAutomatically = Key<Bool>("WriteToiTunesAutomatically")
    static let writeiTunesConvertToPlainLRC = Key<Bool>("WriteiTunesConvertToPlainLRC")

    static let globalLyricsOffset = Key<Int>("GlobalLyricsOffset")

    static let musixmatchToken = Key<String?>("MusixmatchToken")

    //
    static let isInMASReview = Key<Bool?>("isInMASReview")

    static let launchHelperTime = Key<Date?>("launchHelperTime")

    static let appleLanguages = Key<[String]>("AppleLanguages")

    static let isShowLyricsHUD = Key<Bool>("isShowLyricsHUD")

    // Source Priority
    static let lyricsSourcePriorityEnabled = Key<Bool>("LyricsSourcePriorityEnabled")
    static let lyricsSourcePriorityOrder = Key<[String]>("LyricsSourcePriorityOrder")
    static let lyricsPriorityWindow = Key<Double>("LyricsPriorityWindow")
}

// MARK: - Lyrics Priority

/// 默认来源可信度（高 → 低）。偏好设置里拖动排序后以用户顺序为准。
let defaultSourceTrustOrder = ["AMLL", "QQMusic", "NetEase", "Deezer", "Kugou", "LRCLIB", "Kuwo", "Migu", "Musixmatch"]

/// 实际使用的来源顺序：用户自定义顺序（若启用）+ 缺失的来源按默认顺序补齐。
func effectiveSourceOrder() -> [String] {
    var order: [String] = []
    if defaults[.lyricsSourcePriorityEnabled], let saved = defaults[.lyricsSourcePriorityOrder], !saved.isEmpty {
        order = saved
        // 旧设置里没有 AMLL：人工校对的逐字歌词，放最前
        if !order.contains("AMLL") { order.insert("AMLL", at: 0) }
    }
    for source in defaultSourceTrustOrder where !order.contains(source) {
        order.append(source)
    }
    return order
}

/// 来源排名（0 = 最可信）；未知来源排最后。
func sourceRank(_ service: String?) -> Int {
    let order = effectiveSourceOrder().map { $0.lowercased() }
    guard let s = service?.lowercased(), let i = order.firstIndex(of: s) else { return order.count }
    return i
}

/// 可信度加分：第 1 名 +0.3，往后线性递减到 0（每差一名约 0.04）。
/// 量级足以让高可信来源压过低可信来源的「标签更像」，
/// 但歌名/歌手/时长明显对不上的结果已在 isPlausibleMatch 被拦掉，不会因加分翻盘。
func sourceTrustBonus(_ service: String?) -> Double {
    let count = defaultSourceTrustOrder.count
    let rank = sourceRank(service)
    guard rank < count else { return 0 }
    return 0.3 * Double(count - 1 - rank) / Double(count - 1)
}

/// 综合分 = 匹配质量（歌名/歌手/时长/逐字/翻译）+ 来源可信度加分
func lyricsScore(_ lyrics: Lyrics) -> Double {
    lyrics.quality + sourceTrustBonus(lyrics.metadata.service)
}

func lyricsHasHigherPriority(_ new: Lyrics, over existing: Lyrics) -> Bool {
    let a = lyricsScore(new), b = lyricsScore(existing)
    if abs(a - b) < 0.005 {
        return sourceRank(new.metadata.service) < sourceRank(existing.metadata.service)
    }
    return a > b
}

extension CGFloat: @retroactive DefaultConstructible {}
