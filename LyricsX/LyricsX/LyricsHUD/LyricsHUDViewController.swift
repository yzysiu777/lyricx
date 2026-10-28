import OpenCC
import SwiftUI
import LyricsXFoundation
import AppKit
import Combine
import GenericID
import MusicPlayer

class LyricsHUDViewController: NSViewController, NSWindowDelegate, ScrollLyricsViewDelegate, DragNDropDelegate {
    @IBOutlet var dragNDropView: DragNDropView!
    @IBOutlet var lyricsScrollView: ScrollLyricsView!
    @IBOutlet var noLyricsLabel: NSTextField!

    @IBOutlet var lyricsScrollViewTopMargin: NSLayoutConstraint!
    @IBOutlet var lyricsScrollViewLeftMargin: NSLayoutConstraint!

    @objc dynamic var isTracking = true {
        didSet {
            if !oldValue, isTracking {
                displayLyrics()
            }
        }
    }

    private var isWillTerminate = false

    private var cancelBag = Set<AnyCancellable>()

    override func awakeFromNib() {
        super.awakeFromNib()

        view.window?.do {
            $0.title = "Lyrics Window"
            $0.titlebarAppearsTransparent = true
//            $0.titleVisibility = .hidden
            $0.styleMask.insert(.borderless)
            $0.delegate = self
        }
        // swiftlint:disable:next force_cast
        let accessory = NSStoryboard.main!.instantiateController(withIdentifier: .lyricsHUDAccessory) as! NSTitlebarAccessoryViewController
        accessory.layoutAttribute = .right
        view.window?.addTitlebarAccessoryViewController(accessory)

        dragNDropView.dragDelegate = self
        lyricsScrollView.delegate = self
        lyricsScrollView.setupTextContents(lyrics: AppController.shared.currentLyrics)

        lyricsScrollView.bind(\.fontName, withDefaultName: .lyricsWindowFontName)
        lyricsScrollView.bind(\.fontSize, withUnmatchedDefaultName: .lyricsWindowFontSize)
        lyricsScrollView.bind(\.textColor, withDefaultName: .lyricsWindowTextColor)
        lyricsScrollView.bind(\.highlightColor, withDefaultName: .lyricsWindowHighlightColor)

        observeDefaults(key: .lyricsWindowFontSize, options: [.new, .initial]) { [unowned self] _, change in
            let fontSize = CGFloat(change.newValue)
            self.lyricsScrollViewTopMargin.constant = fontSize
            self.lyricsScrollViewLeftMargin.constant = fontSize
            self.displayLyrics(animation: false)
        }

        AppController.shared.$currentLyrics
            .signal()
            .receive(on: DispatchQueue.main)
            .invoke(LyricsHUDViewController.lyricsChanged, weaklyOn: self)
            .store(in: &cancelBag)
        AppController.shared.$currentLineIndex
            .receive(on: DispatchQueue.main)
            .sink { [unowned self] _ in
                self.displayLyrics()
            }.store(in: &cancelBag)

        observeNotification(
            name: NSScrollView.willStartLiveScrollNotification,
            object: lyricsScrollView,
            queue: .main
        ) { [unowned self] _ in self.isTracking = false }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate(_:)), name: NSApplication.willTerminateNotification, object: nil)
    }

    override func viewWillAppear() {
        noLyricsLabel.isHidden = AppController.shared.currentLyrics != nil
        displayLyrics(animation: false)
    }

    // MARK: - Handler

    private func lyricsChanged() {
        DispatchQueue.main.async {
            let newLyrics = AppController.shared.currentLyrics
            self.lyricsScrollView.setupTextContents(lyrics: newLyrics)
            self.noLyricsLabel.isHidden = newLyrics != nil
            self.displayLyrics(animation: false)
        }
    }

    private func displayLyrics(animation: Bool = true) {
        var pos = selectedPlayer.playbackTime
        pos += AppController.shared.currentLyrics?.adjustedTimeDelay ?? 0
        lyricsScrollView.highlight(position: pos)
        guard isTracking else {
            return
        }
        if animation {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.allowsImplicitAnimation = true
                context.timingFunction = .swiftOut
                self.lyricsScrollView.scroll(position: pos)
            }
        } else {
            lyricsScrollView.scroll(position: pos)
        }
    }

    // MARK: ScrollLyricsViewDelegate

    func doubleClickLyricsLine(at position: TimeInterval) {
        let pos = position - (AppController.shared.currentLyrics?.adjustedTimeDelay ?? 0)
        selectedPlayer.playbackTime = pos
        isTracking = true
    }

    func scrollWheelDidStartScroll() {
        isTracking = false
    }

    func scrollWheelDidEndScroll() {}

    // MARK: NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        DispatchQueue.main.async {
            self.displayLyrics(animation: false)
        }
    }

    // MARK: DragNDropDelegate

    func dragFinished(content: String) {
        do {
            try AppController.shared.importLyrics(content)
        } catch {
            let alert = NSAlert(error: error)
            alert.beginSheetModal(for: view.window!)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard !isWillTerminate else { return }
        defaults[.isShowLyricsHUD] = false
    }

    @objc func applicationWillTerminate(_ notification: Notification) {
        isWillTerminate = true
    }
}

class LyricsHUDAccessoryViewController: NSTitlebarAccessoryViewController {
    @IBAction func lockAction(_ sender: NSButton) {
        if sender.state == .on {
            view.window?.level = .modalPanel
        } else {
            view.window?.level = .normal
        }
    }
}

// MARK: - 新版歌词窗口（Apple Music 风格）
// 界面在 LyricsXFoundation/Stage 里；这里负责建窗口、把播放器和歌词数据喂给 StageModel。


final class LyricsStageWindowController: NSWindowController, NSWindowDelegate {
    let model = StageModel()
    private var cancelBag = Set<AnyCancellable>()
    private var isWillTerminate = false
    private var artworkTask: URLSessionDataTask?
    private var searchingTimeout: DispatchWorkItem?
    private var artworkURLInUse: URL?

    private var dragMonitor: Any?
    private var mouseDownEvent: NSEvent?

    init() {
        let size = Self.currentSize()
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            // 不带 .resizable：边缘不能拖动改大小，尺寸只在菜单里选
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "歌词"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)

        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let hosting = NSHostingView(rootView: StageRootView(model: model))
        hosting.sizingOptions = []
        window.contentView = hosting

        if let origin = Self.savedTopLeft() {
            window.setFrameTopLeftPoint(origin)
        } else {
            window.center()
        }
        model.sizePreset = Self.currentPreset()
        installDragMonitor()
        installHoverTracking()
        // 窗口不可缩放，绿色按钮永远是灰的，直接隐藏
        window.standardWindowButton(.zoomButton)?.isHidden = true

        configureModel()
        bindData()
        // 记住上次的置顶状态
        if UserDefaults.standard.bool(forKey: "LyricsStagePinned") { setPinned(true, announce: false) }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate(_:)), name: NSApplication.willTerminateNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: 动作

    private func configureModel() {
        model.timeProvider = {
            selectedPlayer.playbackTime + (AppController.shared.currentLyrics?.adjustedTimeDelay ?? 0)
        }
        var actions = StageActions()
        actions.seek = { lyricsTime in
            let delay = AppController.shared.currentLyrics?.adjustedTimeDelay ?? 0
            selectedPlayer.playbackTime = max(0, lyricsTime - delay)
            AppController.shared.scheduleCurrentLineCheck()
        }
        actions.playPause = { selectedPlayer.playPause() }
        actions.next = { selectedPlayer.skipToNextItem() }
        actions.previous = { selectedPlayer.skipToPreviousItem() }
        actions.adjustOffset = { [weak self] seconds in
            guard AppController.shared.currentLyrics != nil else { return }
            AppController.shared.lyricsOffset += Int((seconds * 1000).rounded())
            self?.updateOffsetDescription(showToast: true, delta: seconds)
        }
        actions.resetOffset = { [weak self] in
            guard AppController.shared.currentLyrics != nil else { return }
            AppController.shared.lyricsOffset = 0
            self?.updateOffsetDescription(showToast: true, delta: nil)
        }
        actions.searchLyrics = { (NSApp.delegate as? AppDelegate)?.searchLyrics(nil) }
        actions.wrongLyrics = { (NSApp.delegate as? AppDelegate)?.wrongLyrics(nil) }
        actions.showInFinder = { (NSApp.delegate as? AppDelegate)?.showCurrentLyricsInFinder(nil) }
        actions.openPreferences = { (NSApp.delegate as? AppDelegate)?.showPreferences(nil) }
        actions.setPinned = { [weak self] pinned in self?.setPinned(pinned) }
        actions.setMode = { [weak self] mode in self?.switchMode(to: mode) }
        actions.setSizePreset = { [weak self] preset in self?.applySizePreset(preset) }
        actions.importLyrics = { [weak self] content in
            do {
                try AppController.shared.importLyrics(content)
                self?.model.showToast("已导入歌词")
            } catch {
                if let window = self?.window { NSAlert(error: error).beginSheetModal(for: window) }
            }
        }
        model.actions = actions
    }

    private func bindData() {
        AppController.shared.$currentLyrics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] lyrics in self?.lyricsChanged(lyrics) }
            .store(in: &cancelBag)

        selectedPlayer.currentTrackWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in self?.trackChanged(track) }
            .store(in: &cancelBag)

        selectedPlayer.playbackStateWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.model.isPlaying = state.isPlaying
                self?.model.tick(force: true)
            }
            .store(in: &cancelBag)

        model.$isHoveringWindow
            .removeDuplicates()
            .sink { [weak self] hovering in self?.setTrafficLightsVisible(hovering) }
            .store(in: &cancelBag)

        trackChanged(selectedPlayer.currentTrack)
        model.isPlaying = selectedPlayer.playbackState.isPlaying
        lyricsChanged(AppController.shared.currentLyrics)
        setTrafficLightsVisible(false)
    }

    private func trackChanged(_ track: MusicTrack?) {
        model.hasTrack = track != nil
        model.title = track?.title ?? ""
        model.artist = track?.artist ?? ""
        model.album = track?.album ?? ""
        model.duration = track?.duration ?? 0
        artworkURLInUse = nil
        artworkTask?.cancel()
        model.setArtwork(track?.artwork)
        // Apple Music 的封面有时晚一点才能读到：同一首歌里隔几秒再取几次
        if let id = track?.id, track?.artwork == nil {
            for delay in [1.0, 2.5, 5.0, 10.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.model.artwork == nil,
                          let current = selectedPlayer.currentTrack, current.id == id else { return }
                    selectedPlayer.updatePlayerState()
                    if let art = selectedPlayer.currentTrack?.artwork {
                        self.model.setArtwork(art)
                    } else if delay == 2.5 {
                        self.lookupArtworkOnline(title: current.title ?? "", artist: current.artist ?? "", trackID: id)
                    }
                }
            }
        }

        searchingTimeout?.cancel()
        model.isSearching = track != nil && AppController.shared.currentLyrics == nil
        let work = DispatchWorkItem { [weak self] in self?.model.isSearching = false }
        searchingTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    private func lyricsChanged(_ lyrics: Lyrics?) {
        // @Published 在 willSet 时发出，这里直接用传入的值
        guard let lyrics else {
            model.lines = []
            model.sourceDescription = nil
            model.offsetDescription = nil
            return
        }
        model.isSearching = false
        let code = lyrics.metadata.translationLanguages.first
        let converter = ChineseConverter.shared
        model.lines = StageModel.makeLines(from: lyrics, translationCode: code) { text in
            converter?.convert(text) ?? text
        }

        var parts: [String] = []
        if let service = lyrics.metadata.service {
            parts.append("来源：\(service)")
        } else if lyrics.metadata.localURL != nil {
            parts.append("来源：本地文件")
        }
        if model.lines.contains(where: \.isWordSynced) { parts.append("逐字") }
        if model.hasTranslation { parts.append("含翻译") }
        model.sourceDescription = parts.isEmpty ? nil : parts.joined(separator: " · ")
        DispatchQueue.main.async { self.updateOffsetDescription(showToast: false, delta: nil) }

        // 播放器没给封面时，用歌词来源提供的封面
        if model.artwork == nil, let url = lyrics.metadata.artworkURL, url != artworkURLInUse {
            loadArtwork(from: url)
        }
    }

    /// 流媒体曲目读不到封面时，用 iTunes 搜索接口按歌名+歌手查（依次试中国区、美区、日区）
    private func lookupArtworkOnline(title: String, artist: String, trackID: String) {
        guard !title.isEmpty else { return }
        Task { @MainActor [weak self] in
            for country in ["cn", "us", "jp"] {
                var c = URLComponents(string: "https://itunes.apple.com/search")!
                c.queryItems = [
                    .init(name: "term", value: "\(title) \(artist)"),
                    .init(name: "entity", value: "song"),
                    .init(name: "limit", value: "1"),
                    .init(name: "country", value: country),
                ]
                guard let url = c.url,
                      let (data, _) = try? await URLSession.shared.data(from: url),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let first = (json["results"] as? [[String: Any]])?.first,
                      let small = first["artworkUrl100"] as? String,
                      let big = URL(string: small.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
                else { continue }
                guard let self, self.model.artwork == nil, selectedPlayer.currentTrack?.id == trackID else { return }
                self.loadArtwork(from: big)
                return
            }
        }
    }

    private func loadArtwork(from url: URL) {
        var https = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if https?.scheme == "http" { https?.scheme = "https" }
        guard let target = https?.url else { return }
        artworkURLInUse = url
        artworkTask?.cancel()
        artworkTask = URLSession.shared.dataTask(with: target) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self, self.artworkURLInUse == url, self.model.artwork == nil else { return }
                self.model.setArtwork(image)
            }
        }
        artworkTask?.resume()
    }

    private func updateOffsetDescription(showToast: Bool, delta: Double?) {
        guard let lyrics = AppController.shared.currentLyrics else {
            model.offsetDescription = nil
            return
        }
        let seconds = Double(lyrics.offset) / 1000
        model.offsetDescription = seconds == 0
            ? "时间偏移：无"
            : String(format: "时间偏移：%@%.1f 秒（%@）", seconds > 0 ? "+" : "", seconds, seconds > 0 ? "提前" : "延后")
        guard showToast else { return }
        if let delta {
            model.showToast(String(format: "歌词%@ %.1f 秒 · 当前 %@%.1f 秒", delta > 0 ? "提前" : "延后", abs(delta), seconds > 0 ? "+" : "", seconds))
        } else {
            model.showToast("已重置时间偏移")
        }
    }

    // MARK: 窗口

    func setPinned(_ pinned: Bool, announce: Bool = true) {
        model.isPinned = pinned
        UserDefaults.standard.set(pinned, forKey: "LyricsStagePinned")
        window?.level = pinned ? .floating : .normal
        if pinned {
            window?.collectionBehavior.insert(.canJoinAllSpaces)
        } else {
            window?.collectionBehavior.remove(.canJoinAllSpaces)
        }
        if announce { model.showToast(pinned ? "窗口已置顶" : "已取消置顶") }
    }

    /// 在整个窗口框架（含标题栏和红绿灯按钮）上跟踪鼠标进出
    private func installHoverTracking() {
        guard let frameView = window?.contentView?.superview else { return }
        frameView.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        model.isHoveringWindow = true
    }

    override func mouseExited(with event: NSEvent) {
        model.isHoveringWindow = false
    }

    private func setTrafficLightsVisible(_ visible: Bool) {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton]
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            for type in buttons {
                window?.standardWindowButton(type)?.animator().alphaValue = visible ? 1 : 0
            }
        }
    }

    func switchMode(to mode: StageMode) {
        guard mode != model.mode else { return }
        // 两种模式共用同一尺寸，切换时窗口不跳
        withAnimation(.easeInOut(duration: 0.35)) { model.mode = mode }
    }

    // MARK: 尺寸档位

    private static let presetKey = "LyricsStageSizePreset"
    private static let customSizeKey = "LyricsStageCustomSize"
    private static let originKey = "LyricsStageTopLeft"

    private static func currentPreset() -> StageSizePreset {
        StageSizePreset(rawValue: UserDefaults.standard.string(forKey: presetKey) ?? "") ?? .medium
    }

    private static func customSize() -> NSSize? {
        guard let s = UserDefaults.standard.string(forKey: customSizeKey) else { return nil }
        let size = NSSizeFromString(s)
        return size.width > 0 && size.height > 0 ? size : nil
    }

    private static func currentSize() -> NSSize {
        let preset = currentPreset()
        if preset == .custom, let size = customSize() { return size }
        return preset.size ?? StageSizePreset.medium.size!
    }

    func applySizePreset(_ preset: StageSizePreset) {
        if preset == .custom {
            promptCustomSize()
            return
        }
        UserDefaults.standard.set(preset.rawValue, forKey: Self.presetKey)
        model.sizePreset = preset
        resize(to: preset.size!)
    }

    private func resize(to size: NSSize) {
        guard let window else { return }
        let old = window.frame
        // 保持左上角不动，并确保不超出屏幕
        var target = NSRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height)
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            target.origin.x = min(max(target.minX, visible.minX), visible.maxX - target.width)
            target.origin.y = min(max(target.minY, visible.minY), visible.maxY - target.height)
        }
        window.setFrame(target, display: true, animate: true)
    }

    private func promptCustomSize() {
        let current = window?.frame.size ?? Self.currentSize()
        let alert = NSAlert()
        alert.messageText = "自定义窗口大小"
        alert.informativeText = "单位为点。宽 220～1600，高 160～1200。"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        func field(_ value: CGFloat) -> NSTextField {
            let f = NSTextField(string: "\(Int(value))")
            f.alignment = .right
            f.frame = NSRect(x: 0, y: 0, width: 70, height: 22)
            let formatter = NumberFormatter()
            formatter.allowsFloats = false
            formatter.minimum = 1
            f.formatter = formatter
            return f
        }
        let widthField = field(current.width)
        let heightField = field(current.height)
        let stack = NSStackView(views: [
            NSTextField(labelWithString: "宽"), widthField,
            NSTextField(labelWithString: "高"), heightField,
        ])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = widthField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let w = min(1600, max(220, CGFloat(widthField.integerValue)))
        let h = min(1200, max(160, CGFloat(heightField.integerValue)))
        let size = NSSize(width: w, height: h)
        UserDefaults.standard.set(NSStringFromSize(size), forKey: Self.customSizeKey)
        UserDefaults.standard.set(StageSizePreset.custom.rawValue, forKey: Self.presetKey)
        model.sizePreset = .custom
        resize(to: size)
    }

    private static func savedTopLeft() -> NSPoint? {
        guard let s = UserDefaults.standard.string(forKey: originKey) else { return nil }
        let p = NSPointFromString(s)
        let probe = NSRect(x: p.x, y: p.y - 50, width: 100, height: 50)
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(probe) }) else { return nil }
        return p
    }

    func windowDidMove(_ notification: Notification) {
        guard let frame = window?.frame else { return }
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: frame.minX, y: frame.maxY)), forKey: Self.originKey)
    }

    // MARK: 拖动

    /// 在窗口任意位置按住拖动都能移动窗口（歌词行、进度条也一样）；
    /// 只有移动超过 3 点才算拖动，单击仍然交给界面处理。
    private func installDragMonitor() {
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            switch event.type {
            case .leftMouseDown:
                // 标题栏区域（红绿灯）交给系统
                self.mouseDownEvent = event.locationInWindow.y > window.frame.height - 28 && event.locationInWindow.x < 80 ? nil : event
            case .leftMouseDragged:
                if let down = self.mouseDownEvent {
                    let dx = event.locationInWindow.x - down.locationInWindow.x
                    let dy = event.locationInWindow.y - down.locationInWindow.y
                    if dx * dx + dy * dy > 9 {
                        self.mouseDownEvent = nil
                        window.performDrag(with: down)
                        return nil
                    }
                }
            default:
                self.mouseDownEvent = nil
            }
            return event
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func windowWillClose(_ notification: Notification) {
        guard !isWillTerminate else { return }
        defaults[.isShowLyricsHUD] = false
    }

    @objc private func applicationWillTerminate(_ notification: Notification) {
        isWillTerminate = true
    }
}
