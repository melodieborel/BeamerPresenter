import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let state = PresentationState()
    private var presenterWindow: NSWindow?
    private var audienceWindow: NSWindow?
    private var splashWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var mentimeterWindow: NSWindow?
    private var compileHUD: NSWindow?
    private var statusItem: NSStatusItem?
    private weak var statusInfoItem: NSMenuItem?
    private var deckMenuItems: [NSMenuItem] = []   // Presentation/Tools/Whiteboard menus
    private weak var audienceFSItem: NSMenuItem?
    /// One-shot observer used to finish an audience rebuild after the window
    /// has left native full screen.
    private var fullScreenExitObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Night Console is a single fixed dark theme.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        setupMenu()
        installKeyMonitor()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateStatusItem),
            name: .statusItemPrefChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyBackgroundMode),
            name: .backgroundModePrefChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuildAudienceWindow),
            name: .audienceModeChanged, object: nil)
        // Returning to the home screen (unload) hides the audience window and the
        // deck-specific menus.
        state.$isLoaded
            .dropFirst()
            .sink { [weak self] loaded in
                if !loaded { self?.audienceWindow?.orderOut(nil) }
                self?.updateDeckMenusVisibility(loaded: loaded)
            }
            .store(in: &cancellables)
        // Presenting a Mentimeter poll needs the audience screen up even before a
        // deck is open; hide it again afterwards if there's no deck to fall back to.
        state.$mentiActive
            .dropFirst()
            .sink { [weak self] active in
                guard let self else { return }
                if active {
                    self.buildAudienceWindowIfNeeded()
                    self.positionWindows()
                    self.audienceWindow?.orderFront(nil)
                } else if !self.state.isLoaded {
                    self.audienceWindow?.orderOut(nil)
                }
            }
            .store(in: &cancellables)
        buildPresenterWindow()
        applyBackgroundMode()
        showSplash()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu bar status item

    /// Hides/shows the Dock icon: in background mode the app runs as a menu bar
    /// accessory (no Dock icon, the status item stays available).
    @objc private func applyBackgroundMode() {
        let background = UserDefaults.standard.bool(forKey: Prefs.backgroundMode)
        NSApp.setActivationPolicy(background ? .accessory : .regular)
        updateStatusItem()
    }

    /// Adds or removes the Time Machine-style menu bar icon based on the setting
    /// (always present in background mode, so there's a way to interact).
    @objc private func updateStatusItem() {
        let background = UserDefaults.standard.bool(forKey: Prefs.backgroundMode)
        let show = background || (UserDefaults.standard.object(forKey: Prefs.showStatusItem) as? Bool ?? true)
        if show {
            installStatusItem()
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle.angled",
                                     accessibilityDescription: AppInfo.name)
        item.menu = buildStatusMenu()
        statusItem = item
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let info = menu.addItem(withTitle: AppInfo.name, action: nil, keyEquivalent: "")
        info.isEnabled = false
        statusInfoItem = info
        menu.addItem(.separator())
        add(to: menu, "Open…", #selector(openDocument(_:)))
        add(to: menu, "Show Presenter Window", #selector(showPresenter(_:)))
        menu.addItem(.separator())
        add(to: menu, "Next Slide", #selector(nextSlide(_:)))
        add(to: menu, "Previous Slide", #selector(previousSlide(_:)))
        add(to: menu, "Black Out Audience", #selector(toggleBlackout(_:)))
        add(to: menu, "Toggle Whiteboard", #selector(toggleWhiteboard(_:)))
        menu.addItem(.separator())
        add(to: menu, "Settings…", #selector(showSettings(_:)))
        menu.addItem(withTitle: "Quit \(AppInfo.name)",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return menu
    }

    /// Keeps the status menu's header line in sync when it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        statusInfoItem?.title = state.isLoaded
            ? "\(state.title) — \(state.index + 1)/\(state.pageCount)"
            : "No presentation open"
    }

    @objc private func showPresenter(_ sender: Any?) {
        presenterWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Launch splash

    /// Shows a brief launch splash with the icon and version, then fades it out
    /// and brings the presenter window forward.
    private func showSplash() {
        let splash = SplashView(icon: NSApp.applicationIconImage, version: AppInfo.versionLine)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 280),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: splash)
        window.center()
        window.orderFrontRegardless()
        splashWindow = window

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard let window = splashWindow else { return }
            window.animator().alphaValue = 0
            presenterWindow?.makeKeyAndOrderFront(nil)   // reveal home screen behind the fade
            try? await Task.sleep(nanoseconds: 400_000_000)
            window.orderOut(nil)
            splashWindow = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // In background mode the app keeps running in the menu bar after the
        // window is closed; otherwise closing the window quits.
        !UserDefaults.standard.bool(forKey: Prefs.backgroundMode)
    }

    /// On ⌘Q / Quit, offer to save unexported ink + whiteboards first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        confirmDiscardOrSave() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.recordCurrentSession()
        state.saveScratch()
    }

    /// The red button confirms, optionally saves, and hides to the menu bar
    /// instead of closing — the app keeps running there.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === presenterWindow else { return true }

        let alert = NSAlert()
        alert.messageText = "Hide \(AppInfo.name) to the menu bar?"
        alert.informativeText = "It keeps running in the menu bar — click its icon to come back, "
            + "or Quit (⌘Q) to exit.\n\nSave & Hide also saves your notes"
            + (state.hasUnsavedChanges ? " and exports the ink + whiteboards as a PDF." : ".")
        alert.addButton(withTitle: "Save & Hide")
        alert.addButton(withTitle: "Hide")
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:           // Save & Hide
            state.saveScratch()
            if state.hasUnsavedChanges {        // export ink + boards as a new PDF
                runPresentationExport(showSummary: false)
            }
            hideToMenuBar()
        case .alertSecondButtonReturn:          // Hide
            hideToMenuBar()
        case .alertThirdButtonReturn:           // Quit
            NSApp.terminate(nil)
        default:                                // Cancel
            break
        }
        return false   // never actually close via the red button
    }

    private func hideToMenuBar() {
        audienceWindow?.orderOut(nil)
        presenterWindow?.orderOut(nil)
        installStatusItem()   // ensure there's a way back even if the icon is off
    }

    /// Clicking the Dock icon (when no window is visible) brings the presenter back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showPresenter(nil) }
        return true
    }

    // MARK: - Menu

    private func setupMenu() {
        let mainMenu = NSMenu()

        // App menu — About (with version) + standard items.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: AppInfo.name)
        appItem.submenu = appMenu
        add(to: appMenu, "About \(AppInfo.name)", #selector(showAbout(_:)))
        appMenu.addItem(.separator())
        add(to: appMenu, "Settings…", #selector(showSettings(_:)), ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(AppInfo.name)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(AppInfo.name)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu — open, favourites, close.
        let fileMenu = addSubmenu(to: mainMenu, "File")
        add(to: fileMenu, "Open…", #selector(openDocument(_:)), "o")
        add(to: fileMenu, "Add Folder to Favorites…", #selector(addFavoriteFolder(_:)), "d")
        add(to: fileMenu, "Mentimeter…", #selector(showMentimeter(_:)))
        fileMenu.addItem(.separator())
        add(to: fileMenu, "Save Presentation As… (with ink & boards)", #selector(savePresentationAs(_:)), "S")
        add(to: fileMenu, "Save Notes…", #selector(saveNotes(_:)))
        add(to: fileMenu, "Close Presentation", #selector(closePresentation(_:)), "w")

        // Presentation menu — navigation + audience controls.
        let presoMenu = addSubmenu(to: mainMenu, "Presentation")
        let presoItem = mainMenu.items.last!
        add(to: presoMenu, "Next Slide", #selector(nextSlide(_:)), "]")
        add(to: presoMenu, "Previous Slide", #selector(previousSlide(_:)), "[")
        add(to: presoMenu, "First Slide", #selector(firstSlide(_:)))
        add(to: presoMenu, "Last Slide", #selector(lastSlide(_:)))
        presoMenu.addItem(.separator())
        add(to: presoMenu, "Toggle Overview", #selector(toggleOverview(_:)), "1")
        add(to: presoMenu, "Black Out Audience", #selector(toggleBlackout(_:)), "b")
        audienceFSItem = add(to: presoMenu, "Audience Full Screen", #selector(toggleAudienceFullscreen(_:)))
        updateAudienceMenuTitle()

        let blackMenu = addSubmenu(to: presoMenu, "Black Screen")
        for preset in BlackScreen.presets {
            add(to: blackMenu, preset, #selector(setMessagePreset(_:))).representedObject = preset
        }
        blackMenu.addItem(.separator())
        add(to: blackMenu, "Custom Message…", #selector(setBlackScreenMessage(_:)))
        add(to: blackMenu, "Clear Message", #selector(clearBlackMessage(_:)))
        blackMenu.addItem(.separator())
        add(to: blackMenu, "Choose Background Image…", #selector(chooseBlackImage(_:)))
        add(to: blackMenu, "Clear Background Image", #selector(clearBlackImage(_:)))

        presoMenu.addItem(.separator())
        add(to: presoMenu, "Start / Stop Timer", #selector(toggleTimer(_:)), "t")
        add(to: presoMenu, "Reset Timer", #selector(resetTimer(_:)), "r")

        // Tools menu — pen / laser / colours / ink.
        let toolsMenu = addSubmenu(to: mainMenu, "Tools")
        let toolsItem = mainMenu.items.last!
        add(to: toolsMenu, "Pen", #selector(togglePen(_:)), "p")
        add(to: toolsMenu, "Laser Pointer", #selector(toggleLaser(_:)), "l")
        toolsMenu.addItem(.separator())
        for (name, color) in PenPalette.colors {
            let item = add(to: toolsMenu, "Pen Colour: \(name)", #selector(setPenColor(_:)))
            item.representedObject = color
        }
        toolsMenu.addItem(.separator())
        add(to: toolsMenu, "Undo Stroke", #selector(undoInk(_:)), "z")
        add(to: toolsMenu, "Clear Ink", #selector(clearInk(_:)))

        // Whiteboard menu — boards, items, and export.
        let boardMenu = addSubmenu(to: mainMenu, "Whiteboard")
        let boardItem = mainMenu.items.last!
        add(to: boardMenu, "Toggle Whiteboard", #selector(toggleWhiteboard(_:)))
        add(to: boardMenu, "New Whiteboard", #selector(newBoard(_:)))
        add(to: boardMenu, "Next Board", #selector(nextBoard(_:)))
        add(to: boardMenu, "Previous Board", #selector(previousBoard(_:)))
        add(to: boardMenu, "Delete Board", #selector(deleteBoard(_:)))
        boardMenu.addItem(.separator())
        add(to: boardMenu, "Add Text", #selector(addText(_:)))
        add(to: boardMenu, "Add Table", #selector(addTable(_:)))
        add(to: boardMenu, "Add QR Code", #selector(addQR(_:)))
        boardMenu.addItem(.separator())
        add(to: boardMenu, "Save Whiteboard as PDF…", #selector(saveWhiteboard(_:)), "s")
        add(to: boardMenu, "Insert into PDF (Copy)…", #selector(insertWhiteboard(_:)), "i")

        // These deck-specific menus are hidden on the home screen.
        deckMenuItems = [presoItem, toolsItem, boardItem]
        updateDeckMenusVisibility(loaded: state.isLoaded)

        NSApp.mainMenu = mainMenu
    }

    /// `@Published.$isLoaded` fires in `willSet`, so the new value is passed in
    /// rather than read back from `state`.
    private func updateDeckMenusVisibility(loaded: Bool) {
        deckMenuItems.forEach { $0.isHidden = !loaded }
    }

    private func addSubmenu(to mainMenu: NSMenu, _ title: String) -> NSMenu {
        let item = NSMenuItem()
        item.title = title          // shown for nested items (top-level uses the submenu title)
        mainMenu.addItem(item)
        let menu = NSMenu(title: title)
        item.submenu = menu
        return menu
    }

    /// Adds an item targeting this delegate so menu validation/handling routes
    /// here rather than through the responder chain.
    @discardableResult
    private func add(to menu: NSMenu, _ title: String, _ action: Selector,
                     _ key: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// Enables/disables deck- and board-dependent commands and shows checkmarks
    /// for the current tool, colour, and toggles.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(closePresentation(_:)), #selector(nextSlide(_:)),
             #selector(previousSlide(_:)), #selector(firstSlide(_:)),
             #selector(lastSlide(_:)), #selector(resetTimer(_:)),
             #selector(toggleTimer(_:)),
             #selector(toggleLaser(_:)), #selector(newBoard(_:)),
             #selector(saveNotes(_:)), #selector(savePresentationAs(_:)):
            return state.isLoaded

        case #selector(toggleOverview(_:)):
            item.state = state.showOverview ? .on : .off
            return state.isLoaded
        case #selector(toggleBlackout(_:)):
            item.state = state.blackout ? .on : .off
            return state.isLoaded
        case #selector(toggleWhiteboard(_:)):
            item.state = state.isBoardActive ? .on : .off
            return state.isLoaded
        case #selector(toggleAudienceFullscreen(_:)):
            updateAudienceMenuTitle()
            return state.isLoaded && NSScreen.screens.count > 1
        case #selector(togglePen(_:)):
            item.state = state.tool == .pen ? .on : .off
            return state.isLoaded
        case #selector(setPenColor(_:)):
            item.state = (item.representedObject as? Color) == state.penColor ? .on : .off
            return state.isLoaded
        case #selector(undoInk(_:)), #selector(clearInk(_:)):
            return state.isLoaded && state.hasInkOnCurrentSlide

        case #selector(nextBoard(_:)), #selector(previousBoard(_:)),
             #selector(deleteBoard(_:)), #selector(addText(_:)),
             #selector(addTable(_:)), #selector(addQR(_:)):
            return state.isBoardActive
        case #selector(saveWhiteboard(_:)), #selector(insertWhiteboard(_:)):
            return state.isBoardActive && !state.activeBoardIsEmpty

        default:
            return true
        }
    }

    @objc private func showAbout(_ sender: Any?) {
        // Show the same build ID as the welcome screen's bottom-right corner.
        // `.version` is the parenthesised build slot (defaults to CFBundleVersion);
        // override it so it doesn't show a different number than `BuildInfo.id`.
        let credits = "Present LaTeX Beamer PDFs with speaker notes.\n\n\(AppInfo.buildLine)"
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppInfo.name,
            .applicationVersion: AppInfo.versionLine,
            .version: BuildInfo.id,
            .credits: NSAttributedString(
                string: credits,
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }()])
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Settings"
            window.contentView = NSHostingView(rootView: SettingsView())
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showMentimeter(_ sender: Any?) {
        if mentimeterWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Mentimeter"
            window.contentView = NSHostingView(rootView: MentimeterView().environmentObject(state))
            window.isReleasedWhenClosed = false
            window.center()
            mentimeterWindow = window
        }
        mentimeterWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func addFavoriteFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Add Folder to Favorites"
        panel.prompt = "Add"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Favorites.add(url)
    }

    @objc private func closePresentation(_ sender: Any?) {
        guard state.isLoaded else { return }
        if confirmDiscardOrSave() { state.unload() }
    }

    /// If the open deck has unexported ink/whiteboards, ask whether to save them
    /// (export to PDF), discard them, or cancel. Returns `true` if the caller may
    /// proceed (saved or discarded), `false` if the user cancelled.
    @discardableResult
    private func confirmDiscardOrSave() -> Bool {
        guard state.isLoaded, state.hasUnsavedChanges else { return true }
        let alert = NSAlert()
        let name = state.title.isEmpty ? "this presentation" : "“\(state.title)”"
        alert.messageText = "Save your changes to \(name)?"
        alert.informativeText = "You added ink or whiteboards. Save them as a new PDF "
            + "(the original file is left untouched), or discard them."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:   // Save… — proceed only if the export completes
            return runPresentationExport(showSummary: false)
        case .alertSecondButtonReturn:  // Discard
            return true
        default:                        // Cancel
            return false
        }
    }

    /// Exports a new PDF of the deck with the freehand ink and the whiteboards
    /// baked in. Defaults to the source folder (next to the .tex/.pdf) and reports
    /// where each board was inserted.
    @objc private func savePresentationAs(_ sender: Any?) {
        runPresentationExport(showSummary: true)
    }

    @discardableResult
    private func runPresentationExport(showSummary: Bool) -> Bool {
        guard state.isLoaded, let source = state.sourceURL else { return false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(state.title) annotated.pdf"
        panel.directoryURL = source.deletingLastPathComponent()
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return false }

        guard let summary = BoardExporter.exportPresentation(
                sourceURL: source, split: state.notesDoc != nil, aspect: state.slideAspect,
                strokes: state.strokes, boards: state.boards, to: dest) else {
            let alert = NSAlert()
            alert.messageText = "Could not export the presentation"
            alert.informativeText = dest.lastPathComponent
            alert.runModal()
            return false
        }

        state.markSaved()   // the ink + whiteboards are now in a PDF on disk
        guard showSummary else { return true }
        let alert = NSAlert()
        alert.messageText = "Saved \(dest.lastPathComponent)"
        var info = "Folder: \(dest.deletingLastPathComponent().path)\n"
            + "Ink burned onto \(summary.inkSlides) slide(s)."
        if summary.boardsAfterSlides.isEmpty {
            info += "\nNo whiteboards."
        } else {
            let list = summary.boardsAfterSlides.map(String.init).joined(separator: ", ")
            info += "\n\(summary.boardsAfterSlides.count) whiteboard(s) inserted after slide(s): \(list)."
        }
        alert.informativeText = info
        alert.runModal()
        return true
    }

    @objc private func saveNotes(_ sender: Any?) {
        guard state.isLoaded else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(state.title.isEmpty ? "notes" : state.title) notes.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if (try? state.scratch.write(to: url, atomically: true, encoding: .utf8)) == nil {
            let alert = NSAlert()
            alert.messageText = "Could not save the notes"
            alert.informativeText = url.lastPathComponent
            alert.runModal()
        }
    }

    @objc private func nextSlide(_ sender: Any?)      { state.next() }
    @objc private func previousSlide(_ sender: Any?)  { state.previous() }
    @objc private func firstSlide(_ sender: Any?)     { state.goToFirst() }
    @objc private func lastSlide(_ sender: Any?)      { state.goToLast() }
    @objc private func toggleOverview(_ sender: Any?) { state.showOverview.toggle() }
    @objc private func toggleBlackout(_ sender: Any?) { state.blackout.toggle() }
    @objc private func resetTimer(_ sender: Any?)     { state.resetTimer() }
    @objc private func toggleTimer(_ sender: Any?)    { state.toggleTimer() }

    @objc private func setBlackScreenMessage(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Black-Screen Message"
        alert.informativeText = "Shown centered on the blacked-out audience screen "
            + "(the clock stays, smaller, beneath it)."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = UserDefaults.standard.string(forKey: Prefs.blackScreenMessage) ?? ""
        field.placeholderString = "e.g. Back in 5 minutes"
        alert.accessoryView = field
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            UserDefaults.standard.set(field.stringValue, forKey: Prefs.blackScreenMessage)
        case .alertSecondButtonReturn:
            UserDefaults.standard.set("", forKey: Prefs.blackScreenMessage)
        default:
            break
        }
    }

    @objc private func setMessagePreset(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject as? String ?? "", forKey: Prefs.blackScreenMessage)
    }

    @objc private func clearBlackMessage(_ sender: Any?) {
        UserDefaults.standard.set("", forKey: Prefs.blackScreenMessage)
    }

    @objc private func chooseBlackImage(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: Prefs.blackScreenImage)
        }
    }

    @objc private func clearBlackImage(_ sender: Any?) {
        UserDefaults.standard.set("", forKey: Prefs.blackScreenImage)
    }

    // Tools
    @objc private func togglePen(_ sender: Any?)      { state.toggleTool(.pen) }
    @objc private func toggleLaser(_ sender: Any?)    { state.toggleTool(.laser) }
    @objc private func undoInk(_ sender: Any?)        { state.undoStroke() }
    @objc private func clearInk(_ sender: Any?)       { state.clearStrokes() }
    @objc private func setPenColor(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? Color else { return }
        state.penColor = color
        if state.tool == .none { state.tool = .pen }   // keep the laser if it's active
    }

    // Whiteboard
    @objc private func toggleWhiteboard(_ sender: Any?) { state.toggleBoard() }
    @objc private func newBoard(_ sender: Any?)       { state.addBoard() }
    @objc private func nextBoard(_ sender: Any?)      { state.nextBoard() }
    @objc private func previousBoard(_ sender: Any?)  { state.previousBoard() }
    @objc private func deleteBoard(_ sender: Any?)    { state.deleteActiveBoard() }
    @objc private func addText(_ sender: Any?)        { state.addItem(.text) }
    @objc private func addTable(_ sender: Any?)       { state.addItem(.table) }
    @objc private func addQR(_ sender: Any?)          { state.addItem(.qr) }

    @objc private func saveWhiteboard(_ sender: Any?) {
        guard let board = state.activeBoard else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(board.name).pdf"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !BoardExporter.writePDF(board: board, aspect: state.slideAspect, to: url) {
            let alert = NSAlert()
            alert.messageText = "Could not save the whiteboard"
            alert.informativeText = url.lastPathComponent
            alert.runModal()
        }
    }

    @objc private func insertWhiteboard(_ sender: Any?) {
        guard let board = state.activeBoard, let source = state.sourceURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(state.title) + \(board.name).pdf"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        if !BoardExporter.insertIntoCopy(of: source, board: board, afterIndex: state.index,
                                         aspect: state.slideAspect, to: dest) {
            let alert = NSAlert()
            alert.messageText = "Could not insert the whiteboard into the PDF"
            alert.informativeText = dest.lastPathComponent
            alert.runModal()
        }
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.message = "Choose a PDF, a .tex (compiled on the fly), or a PowerPoint (.pptx)."
        panel.allowedContentTypes = [.pdf]
            + ["tex", "pptx", "ppt", "odp"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url: url)
    }

    /// Opens a picked file: a `.pdf` directly; a `.tex` via its sibling PDF or by
    /// compiling it; a PowerPoint/ODP by converting it with LibreOffice.
    private func load(url rawURL: URL) {
        // Opening another deck would discard the current one's edits — offer to save.
        guard confirmDiscardOrSave() else { return }
        switch rawURL.pathExtension.lowercased() {
        case "tex":
            loadOrMake(rawURL, with: latexMaker)
        case "pptx", "ppt", "odp":
            loadOrMake(rawURL, with: libreOfficeMaker)
        default:
            loadPDF(rawURL)
        }
    }

    /// Uses a sibling PDF if present, else runs `maker` to produce one.
    private func loadOrMake(_ source: URL, with maker: (URL) -> Void) {
        let sibling = source.deletingPathExtension().appendingPathExtension("pdf")
        if FileManager.default.fileExists(atPath: sibling.path) {
            loadPDF(sibling)
        } else {
            maker(source)
        }
    }

    private func latexMaker(_ texURL: URL) {
        if let engine = Dependencies.latexEngine() {
            convertToPDF(texURL, title: "Compiling \(texURL.lastPathComponent)…",
                         detail: "Running LaTeX…",
                         work: { Dependencies.compile(texURL: texURL, engine: engine) },
                         onFailure: { self.offerEditor(for: texURL, message: $0) })
        } else {
            offerEditor(for: texURL, message: "No PDF next to it and no LaTeX install found to compile it.")
        }
    }

    private func libreOfficeMaker(_ url: URL) {
        if let soffice = Dependencies.soffice() {
            convertToPDF(url, title: "Converting \(url.lastPathComponent)…",
                         detail: "Using LibreOffice…",
                         work: { Dependencies.convertToPDF(url, soffice: soffice) },
                         onFailure: { self.offerOpenDefault(for: url, message: $0) })
        } else {
            offerOpenDefault(for: url,
                             message: "No PDF next to it and no LibreOffice found to convert it.")
        }
    }

    /// Shared compile/convert flow: HUD, run `work` off the main actor, then load
    /// the PDF or report the failure.
    private func convertToPDF(_ source: URL, title: String, detail: String,
                              work: @escaping @Sendable () -> Dependencies.CompileResult,
                              onFailure: @escaping (String) -> Void) {
        showCompileHUD(title: title, detail: detail)
        Task { @MainActor in
            let result = await Task.detached(operation: work).value
            hideCompileHUD()
            switch result {
            case .success(let pdf): loadPDF(pdf)
            case .failure(let log): onFailure("Failed.\n\n\(log)")
            }
        }
    }

    /// Offers to open a file in its default app (PowerPoint / Keynote / …).
    private func offerOpenDefault(for url: URL, message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't open \(url.lastPathComponent) as a PDF"
        alert.informativeText = message
        alert.addButton(withTitle: "Open in Default App")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
    }

    private func loadPDF(_ url: URL) {
        guard state.load(url: url) else {
            let alert = NSAlert()
            alert.messageText = "Could not open PDF"
            alert.informativeText = url.lastPathComponent
            alert.runModal()
            return
        }
        RecentFiles.add(url)
        buildAudienceWindowIfNeeded()
        positionWindows()
        audienceWindow?.orderFront(nil)
        presenterWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Compile / convert HUD

    private func showCompileHUD(title: String, detail: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = true
        window.contentView = NSHostingView(rootView: CompileHUD(title: title, detail: detail))
        window.center()
        window.orderFrontRegardless()
        compileHUD = window
    }

    private func hideCompileHUD() {
        compileHUD?.orderOut(nil)
        compileHUD = nil
    }

    /// Offers to open a `.tex` in an external editor (Sublime Text if installed,
    /// then VS Code, else the default app).
    private func offerEditor(for texURL: URL, message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't open \(texURL.lastPathComponent)"
        alert.informativeText = message
        alert.addButton(withTitle: "Open in Editor")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let workspace = NSWorkspace.shared
        let editors = ["com.sublimetext.4", "com.sublimetext.3",
                       "com.microsoft.VSCode", "com.apple.TextEdit"]
        for bundleID in editors {
            if let app = workspace.urlForApplication(withBundleIdentifier: bundleID) {
                workspace.open([texURL], withApplicationAt: app,
                               configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        workspace.open(texURL)
    }

    // MARK: - Windows

    private func buildPresenterWindow() {
        let root = RootPresenterView(
            onOpen: { [weak self] in self?.openDocument(nil) },
            onOpenURL: { [weak self] url in self?.load(url: url) }
        ).environmentObject(state)

        let presenter = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        presenter.title = "BeamerPresenter"
        presenter.isReleasedWhenClosed = false   // we hold a strong ref; avoid an ARC over-release crash
        presenter.contentView = NSHostingView(rootView: root)
        presenter.contentMinSize = NSSize(width: 560, height: 380)   // allow shrinking
        // A normal, resizable window whose green button enters real macOS
        // full screen (not just zoom/maximise).
        presenter.collectionBehavior = [.fullScreenPrimary]
        presenter.delegate = self
        presenter.center()
        // Stays hidden behind the launch splash; shown once the splash fades.
        presenterWindow = presenter
    }

    /// Whether the audience window fills the external display (borderless) or is a
    /// normal, resizable window. Defaults to a normal window — borderless fill is
    /// opt-in via the menu/settings (and needs a second display).
    private var audienceFillsExternal: Bool {
        (UserDefaults.standard.object(forKey: Prefs.audienceFullscreen) as? Bool ?? false)
            && NSScreen.screens.count > 1
    }

    private func buildAudienceWindowIfNeeded() {
        guard audienceWindow == nil else { return }
        let fill = audienceFillsExternal
        let style: NSWindow.StyleMask = fill
            ? [.borderless]
            : [.titled, .closable, .resizable, .miniaturizable]

        let audience = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: style, backing: .buffered, defer: false)
        audience.title = "Audience"
        audience.isReleasedWhenClosed = false   // held in a strong ref; avoid an ARC over-release crash
        audience.contentMinSize = NSSize(width: 320, height: 200)
        audience.contentView = NSHostingView(rootView: AudienceView().environmentObject(state))
        if fill {
            // Cover everything on the projector, including the menu bar —
            // nothing of the desktop should peek through during the talk.
            audience.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
            audience.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        } else {
            // A normal, resizable window whose green button enters real macOS
            // full screen (not just zoom/maximise).
            audience.collectionBehavior = [.fullScreenPrimary]
            audience.center()   // sensible spot on a single screen (positionWindows handles two)
        }
        audienceWindow = audience
    }

    /// Recreates the audience window after its full-screen/windowed mode was
    /// changed explicitly (menu item / settings) — always shows the result.
    @objc private func rebuildAudienceWindow() {
        rebuildAudience(showEvenIfHidden: true)
    }

    /// Tears the audience window down and recreates it in the style matching
    /// the current preference and screen setup. `showEvenIfHidden` separates
    /// explicit user actions (always show the rebuilt window) from automatic
    /// screen-change housekeeping (a hidden window stays hidden).
    private func rebuildAudience(showEvenIfHidden: Bool) {
        if let audience = audienceWindow, audience.styleMask.contains(.fullScreen) {
            // Closing a window while it is in native full screen can strand an
            // empty Space — leave full screen first, finish the rebuild after.
            guard fullScreenExitObserver == nil else { return }
            fullScreenExitObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification, object: audience, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if let token = self.fullScreenExitObserver {
                        NotificationCenter.default.removeObserver(token)
                        self.fullScreenExitObserver = nil
                    }
                    self.rebuildAudience(showEvenIfHidden: showEvenIfHidden)
                }
            }
            audience.toggleFullScreen(nil)
            return
        }

        // Always drop the stale window, even with nothing loaded — the next
        // deck would otherwise inherit a window built for the old screen setup.
        let wasVisible = audienceWindow?.isVisible ?? false
        audienceWindow?.close()
        audienceWindow = nil
        guard state.isLoaded || state.mentiActive else { return }
        buildAudienceWindowIfNeeded()
        positionWindows()
        guard showEvenIfHidden || wasVisible else { return }   // e.g. hidden to the menu bar
        audienceWindow?.orderFront(nil)
        presenterWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleAudienceFullscreen(_ sender: Any?) {
        let current = UserDefaults.standard.object(forKey: Prefs.audienceFullscreen) as? Bool ?? false
        UserDefaults.standard.set(!current, forKey: Prefs.audienceFullscreen)
        rebuildAudienceWindow()
        updateAudienceMenuTitle()
    }

    /// Reflects the actual audience state in the menu item's title.
    private func updateAudienceMenuTitle() {
        audienceFSItem?.title = audienceFillsExternal ? "Exit Audience Full Screen"
                                                      : "Enter Audience Full Screen"
    }

    @objc private func screensChanged() {
        // If the audience window's style no longer matches the screen setup,
        // rebuild it: unplugging the projector otherwise strands the borderless
        // fill window on the main screen — above the menu bar, with no title
        // bar, impossible to close. (Replugging restores the fill mode.)
        if let audience = audienceWindow,
           audience.styleMask.contains(.titled) == audienceFillsExternal {
            rebuildAudience(showEvenIfHidden: false)
        }
        // Reposition unconditionally: a completed rebuild positions its own
        // windows, but the deferred/early-return paths and the presenter
        // window still need it (double positioning is idempotent).
        positionWindows()
        updateAudienceMenuTitle()
    }

    /// Positions the windows: a full-screen audience fills the external display; a
    /// windowed audience opens large on it; the presenter stays on the main one.
    private func positionWindows() {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return }   // single screen: leave windows put

        if audienceFillsExternal {
            audienceWindow?.setFrame(screens[1].frame, display: true)
        } else if let audience = audienceWindow, !audience.styleMask.contains(.fullScreen) {
            // (Skip reframing while the user has it in native full screen.)
            let visible = screens[1].visibleFrame
            let size = NSSize(width: visible.width * 0.85, height: visible.height * 0.85)
            audience.setFrame(NSRect(x: visible.midX - size.width / 2,
                                     y: visible.midY - size.height / 2,
                                     width: size.width, height: size.height), display: true)
        }
        if let presenter = presenterWindow, !presenter.styleMask.contains(.fullScreen) {
            // (Skip repositioning while the user has it in native full screen.)
            let visible = (NSScreen.main ?? screens[0]).visibleFrame
            let size = presenter.frame.size
            presenter.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                             y: visible.midY - size.height / 2))
        }
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    /// Returns true if the key was consumed. Only active once a deck is loaded.
    /// Modifier combos (⌘…) are left for the menu bar's key equivalents, and keys
    /// are ignored while a text field (e.g. a whiteboard item editor) is editing.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard state.isLoaded else { return false }
        let modifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.isDisjoint(with: modifiers) else { return false }

        // While typing in a text field (e.g. the scratch notes), still let the
        // arrow / page keys drive the slides; everything else edits the text.
        // Same while a live web page (e.g. Pinpoint) has focus: the page gets
        // its own keyboard controls; the arrows/page keys, esc and F (shrink it
        // back to its placeholder) stay with the deck.
        if (NSApp.keyWindow?.firstResponder as? NSView)?.isInsideWebView == true {
            switch event.keyCode {
            case 124, 121: state.next()                  // → / page down
            case 123, 116: state.previous()              // ← / page up
            case 3:        state.webExpanded.toggle()    // F
            case 53:       NSApp.keyWindow?.makeFirstResponder(nil)   // esc: hand keys back to the deck
            default:       return false
            }
            return true
        }

        if NSApp.keyWindow?.firstResponder is NSTextView {
            switch event.keyCode {
            case 124, 121: state.next()       // → / page down
            case 123, 116: state.previous()   // ← / page up
            default:       return false
            }
            return true
        }

        switch event.keyCode {
        case 124, 49, 121: state.next()              // → / space / page down
        case 123, 116:     state.previous()          // ← / page up
        case 115:          state.goToFirst()         // home
        case 119:          state.goToLast()          // end
        case 5:            state.showOverview.toggle()   // G
        case 11:           state.blackout.toggle()       // B
        case 3:            state.webExpanded.toggle()    // F: live web page fills the slide
        case 15:           state.resetTimer()            // R
        case 13:           state.toggleBoard()           // W
        case 35:           state.toggleTool(.pen)        // P
        case 37:           state.toggleTool(.laser)      // L
        case 6:            state.undoStroke()            // Z
        case 8:            state.clearStrokes()          // C
        case 53:                                         // esc
            if state.selectedItemID != nil { state.selectedItemID = nil }
            else if state.tool != .none { state.tool = .none; state.laserPoint = nil }
            else if state.isBoardActive { state.hideBoard() }
            else if state.showOverview { state.showOverview = false }
            else { return false }
        default:           return false
        }
        return true
    }
}

extension Notification.Name {
    /// Posted by Settings when the "show menu bar icon" preference changes.
    static let statusItemPrefChanged = Notification.Name("statusItemPrefChanged")
    /// Posted by Settings when the "run in background" preference changes.
    static let backgroundModePrefChanged = Notification.Name("backgroundModePrefChanged")
    /// Posted when the audience full-screen/windowed preference changes.
    static let audienceModeChanged = Notification.Name("audienceModeChanged")
}
