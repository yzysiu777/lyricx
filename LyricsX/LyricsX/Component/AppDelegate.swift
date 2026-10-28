import LyricsXFoundation
import AppKit
import GenericID
import MASShortcut
import MusicPlayer
import Sparkle
import Semver

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    static var shared: AppDelegate? {
        return NSApplication.shared.delegate as? AppDelegate
    }

    @IBOutlet var lyricsOffsetView: NSView!
    @IBOutlet var lyricsOffsetTextField: NSTextField!
    @IBOutlet var lyricsOffsetStepper: NSStepper!
    @IBOutlet var statusBarMenu: NSMenu!

    private lazy var updateController = SPUStandardUpdaterController(updaterDelegate: nil, userDriverDelegate: self)

    var firstLaunchForShouldHanlderReopen: Bool = true

    var karaokeLyricsWC: KaraokeLyricsWindowController?

    lazy var searchLyricsWC: SearchLyricsWindowController = .init()

    lazy var lyricsHUD = LyricsStageWindowController()

    lazy var preferencesWindowController: PreferenceWindowController = .create()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        UserDefaultsMigrator.shared.migrateFromSandboxIfNeeded()
        registerUserDefaults()

        let controller = AppController.shared

        // 精简版：不显示桌面歌词和菜单栏滚动歌词，菜单栏只留图标 + 精简菜单
        defaults[.desktopLyricsEnabled] = false
        defaults[.menuBarLyricsEnabled] = false
        defaults[.touchBarLyricsEnabled] = false
        statusBarMenu = makeCompactMenu()
        MenuBarLyricsController.shared.statusBarMenu = statusBarMenu
        statusBarMenu.delegate = self

        lyricsOffsetStepper.bind(
            .value,
            to: controller,
            withKeyPath: #keyPath(AppController.lyricsOffset),
            options: [.continuouslyUpdatesValue: true]
        )

        lyricsOffsetTextField.bind(
            .value,
            to: controller,
            withKeyPath: #keyPath(AppController.lyricsOffset),
            options: [.continuouslyUpdatesValue: true]
        )

        setupShortcuts()

        NSRunningApplication.runningApplications(withBundleIdentifier: lyricsXHelperIdentifier).forEach { $0.terminate() }

        // Mirror the keys LyricsXHelper reads from the shared suite. KVO on the
        // standard defaults is reliable; Cocoa Bindings to a bare UserDefaults
        // instance was not — it never actually pushed values into the suite, so
        // the helper read a stale/absent value and exited. `.initial` writes the
        // current value at launch; `.new` keeps the suite in sync as the user
        // toggles the preference.
        observeDefaults(key: .launchAndQuitWithPlayer, options: [.new, .initial]) { _, change in
            sharedDefaults[.launchAndQuitWithPlayer] = change.newValue
        }
        observeDefaults(key: .preferredPlayerIndex, options: [.new, .initial]) { _, change in
            sharedDefaults[.preferredPlayerIndex] = change.newValue
        }

        // 本地构建版：关闭 Sparkle 自动更新，避免被上游版本覆盖掉本地改动
        updateController.updater.automaticallyChecksForUpdates = false
        updateController.updater.automaticallyDownloadsUpdates = false

        // 精简版：不用触控栏歌词

        if defaults[.isShowLyricsHUD] {
            lyricsHUD.showWindow(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if firstLaunchForShouldHanlderReopen {
            firstLaunchForShouldHanlderReopen = false
            return false
        }
        preferencesWindowController.showWindow(nil)
        return true
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        if AppController.shared.currentLyrics?.metadata.needsPersist == true {
            AppController.shared.currentLyrics?.persist()
        }
        if defaults[.launchAndQuitWithPlayer] {
            let url = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Library/LoginItems/LyricsXHelper.app")
            // Write everything the helper reads at launch right before spawning
            // it, then flush — don't rely on cfprefsd having the latest values
            // batched when this process dies.
            sharedDefaults[.launchAndQuitWithPlayer] = defaults[.launchAndQuitWithPlayer]
            sharedDefaults[.preferredPlayerIndex] = defaults[.preferredPlayerIndex]
            sharedDefaults[.launchHelperTime] = Date()
            sharedDefaults.synchronize()

            // `openApplication` is asynchronous and we're seconds away from
            // process death — block briefly so the LaunchServices request
            // actually leaves this process before NSApp.terminate proceeds.
            let semaphore = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { application, error in
                if let error = error {
                    log("launch LyricsX Helper failed. reason: \(error)")
                } else {
                    log("launch LyricsX Helper succeed.")
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + .milliseconds(500))
        }
    }

    private func setupShortcuts() {
        let binder = MASShortcutBinder.shared()!
        binder.bindShortcut(.shortcutShowLyricsWindow, to: #selector(showLyricsHUD))
        binder.bindShortcut(.shortcutOffsetIncrease, to: #selector(increaseOffset))
        binder.bindShortcut(.shortcutOffsetDecrease, to: #selector(decreaseOffset))
        binder.bindShortcut(.shortcutWrongLyrics, to: #selector(wrongLyrics))
        binder.bindShortcut(.shortcutSearchLyrics, to: #selector(searchLyrics))
        binder.bindShortcut(.shortcutTogglePreferences, to: #selector(togglePreferences))
    }

    // MARK: - NSMenuDelegate

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(writeToiTunes(_:))?:
            return selectedPlayer.name == .appleMusic && AppController.shared.currentLyrics != nil
        case #selector(searchLyrics(_:))?:
            return selectedPlayer.currentTrack != nil
        default:
            return true
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: 202)?.isEnabled = AppController.shared.currentLyrics != nil
    }

    // MARK: - Menubar Action

    @IBAction func showLyricsHUD(_ sender: Any?) {
        if defaults[.isShowLyricsHUD] {
            lyricsHUD.close()
            defaults[.isShowLyricsHUD] = false
        } else {
            lyricsHUD.showWindow(nil)
            defaults[.isShowLyricsHUD] = true
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    @IBAction func aboutLyricsXAction(_ sender: Any) {
        if #available(OSX 10.13, *) {
            let channel = "GitHub"
            let versionString = "\(channel) Version \(Bundle.main.semanticVersion ?? "Unknown")"
            NSApp.orderFrontStandardAboutPanel(options: [.applicationVersion: versionString])
        } else {
            NSApp.orderFrontStandardAboutPanel(sender)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @IBAction func showPreferences(_ sender: Any?) {
        preferencesWindowController.showWindow(nil)
    }

    @objc func togglePreferences(_ sender: Any?) {
        if preferencesWindowController.window?.isVisible ?? false {
            preferencesWindowController.close()
        } else {
            preferencesWindowController.showWindow(nil)
        }
    }

    @IBAction func checkUpdateAction(_ sender: Any) {
        let alert = NSAlert()
        alert.messageText = "这是本地构建版本"
        alert.informativeText = "为避免被上游版本覆盖，已关闭自动更新。需要更新时，请在 lyricx 目录下拉取最新源码后运行 scripts/build.sh 重新构建。"
        alert.runModal()
    }

    @IBAction func increaseOffset(_ sender: Any?) {
        AppController.shared.lyricsOffset += 100
    }

    @IBAction func decreaseOffset(_ sender: Any?) {
        AppController.shared.lyricsOffset -= 100
    }

    @IBAction func showCurrentLyricsInFinder(_ sender: Any?) {
        guard let lyrics = AppController.shared.currentLyrics else {
            return
        }
        if lyrics.metadata.needsPersist {
            lyrics.persist()
        }
        if let url = lyrics.metadata.localURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @IBAction func writeToiTunes(_ sender: Any?) {
        AppController.shared.writeToiTunes(overwrite: true)
    }

    @IBAction func searchLyrics(_ sender: Any?) {
        searchLyricsWC.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @IBAction func wrongLyrics(_ sender: Any?) {
        guard let track = selectedPlayer.currentTrack else {
            return
        }
        defaults[.noSearchingTrackIds].append(track.id)
        if defaults[.writeToiTunesAutomatically] {
            track.setLyrics("")
        }
        if let url = AppController.shared.currentLyrics?.metadata.localURL {
            try? FileManager.default.removeItem(at: url)
        }
        AppController.shared.currentLyrics = nil
        AppController.shared.searchTask?.cancel()
    }

    @IBAction func doNotSearchLyricsForThisAlbum(_ sender: Any?) {
        guard let track = selectedPlayer.currentTrack,
              let album = track.album else {
            return
        }
        defaults[.noSearchingAlbumNames].append(album)
        if defaults[.writeToiTunesAutomatically] {
            track.setLyrics("")
        }
        if let url = AppController.shared.currentLyrics?.metadata.localURL {
            try? FileManager.default.removeItem(at: url)
        }
        AppController.shared.currentLyrics = nil
    }

    func registerUserDefaults() {
        let currentLang = NSLocale.preferredLanguages.first!
        let isZh = currentLang.hasPrefix("zh") || currentLang.hasPrefix("yue")
        let isHant = isZh && (currentLang.contains("-Hant") || currentLang.contains("-HK"))

        let defaultsUrl = Bundle.main.url(forResource: "UserDefaults", withExtension: "plist")!
        if let dict = NSDictionary(contentsOf: defaultsUrl) as? [String: Any] {
            defaults.register(defaults: dict)
        }
        defaults.register(defaults: [
            .desktopLyricsColor: #colorLiteral(red: 1, green: 1, blue: 1, alpha: 1),
            .desktopLyricsProgressColor: #colorLiteral(red: 0.1985405816, green: 1, blue: 0.8664234302, alpha: 1),
            .desktopLyricsShadowColor: #colorLiteral(red: 0, green: 1, blue: 0.8333333333, alpha: 1),
            .desktopLyricsBackgroundColor: #colorLiteral(red: 0, green: 0, blue: 0, alpha: 0.6041579279),
            .lyricsWindowTextColor: #colorLiteral(red: 0.7540688515, green: 0.7540867925, blue: 0.7540771365, alpha: 1),
            .lyricsWindowHighlightColor: #colorLiteral(red: 0.8866666667, green: 1, blue: 0.8, alpha: 1),
            .preferBilingualLyrics: isZh,
            .chineseConversionIndex: isHant ? 2 : 0,
            .desktopLyricsXPositionFactor: 0.5,
            .desktopLyricsYPositionFactor: 0.9,
        ])
    }

    func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated { updateCompactMenu(menu) }
    }
}

extension AppDelegate: SPUStandardUserDriverDelegate {
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        return true
    }
}

extension MASShortcutBinder {
    func bindShortcut<T>(_ defaultsKay: UserDefaults.DefaultsKey<T>, to action: @escaping () -> Void) {
        bindShortcut(withDefaultsKey: defaultsKay.key, toAction: action)
    }

    func bindBoolShortcut<T>(_ defaultsKay: UserDefaults.DefaultsKey<T>, target: UserDefaults.DefaultsKey<Bool>) {
        bindShortcut(withDefaultsKey: defaultsKay.key) {
            defaults[target] = !defaults[target]
        }
    }

    func bindShortcut<T>(_ defaultsKay: UserDefaults.DefaultsKey<T>, to action: Selector) {
        bindShortcut(defaultsKay) {
            let target = NSApplication.shared.target(forAction: action) as AnyObject?
            _ = target?.perform(action, with: self)
        }
    }
}


// MARK: - 精简菜单

@MainActor
extension AppDelegate {
    func makeCompactMenu() -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String = "", tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self
            i.tag = tag
            return i
        }
        let now = NSMenuItem(title: "未在播放", action: nil, keyEquivalent: "")
        now.tag = 900
        now.isEnabled = false
        menu.addItem(now)
        menu.addItem(.separator())
        menu.addItem(item("显示歌词窗口", #selector(showLyricsHUD(_:)), "l", tag: 901))
        menu.addItem(item("欣赏模式", #selector(toggleStageMode(_:)), "m", tag: 902))
        menu.addItem(item("窗口置顶", #selector(toggleStagePin(_:)), "p", tag: 903))
        let sizeItem = NSMenuItem(title: "窗口大小", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for (i, preset) in StageSizePreset.allCases.enumerated() {
            let sub = item(preset.title, #selector(setStageSize(_:)), tag: 910 + i)
            sub.representedObject = preset.rawValue
            sizeMenu.addItem(sub)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        menu.addItem(.separator())
        menu.addItem(item("搜索歌词…", #selector(searchLyrics(_:)), "f"))
        menu.addItem(item("歌词提前 0.1 秒", #selector(increaseOffset(_:)), "]"))
        menu.addItem(item("歌词延后 0.1 秒", #selector(decreaseOffset(_:)), "["))
        menu.addItem(item("歌词不对，不再搜索这首", #selector(wrongLyrics(_:))))
        menu.addItem(.separator())
        menu.addItem(item("偏好设置…", #selector(showPreferences(_:)), ","))
        let quit = NSMenuItem(title: "退出 LyricsX", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    func updateCompactMenu(_ menu: NSMenu) {
        if let track = selectedPlayer.currentTrack {
            menu.item(withTag: 900)?.title = [track.title, track.artist].compactMap { $0 }.joined(separator: " — ")
        } else {
            menu.item(withTag: 900)?.title = "未在播放"
        }
        menu.item(withTag: 901)?.state = defaults[.isShowLyricsHUD] ? .on : .off
        menu.item(withTag: 902)?.state = lyricsHUD.model.mode == .cover ? .on : .off
        menu.item(withTag: 903)?.state = lyricsHUD.model.isPinned ? .on : .off
        if let sizeMenu = menu.items.first(where: { $0.title == "窗口大小" })?.submenu {
            for sub in sizeMenu.items {
                sub.state = (sub.representedObject as? String) == lyricsHUD.model.sizePreset.rawValue ? .on : .off
            }
        }
    }

    @objc func toggleStageMode(_ sender: Any?) {
        if !defaults[.isShowLyricsHUD] { showLyricsHUD(nil) }
        lyricsHUD.switchMode(to: lyricsHUD.model.mode == .lyrics ? .cover : .lyrics)
    }

    @objc func setStageSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let preset = StageSizePreset(rawValue: raw) else { return }
        if !defaults[.isShowLyricsHUD] { showLyricsHUD(nil) }
        lyricsHUD.applySizePreset(preset)
    }

    @objc func toggleStagePin(_ sender: Any?) {
        if !defaults[.isShowLyricsHUD] { showLyricsHUD(nil) }
        lyricsHUD.setPinned(!lyricsHUD.model.isPinned)
    }
}
