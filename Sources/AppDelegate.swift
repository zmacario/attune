import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let settings = Settings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.normalIcon
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        statusItem.menu = menu

        refreshLoginItemState()
        Engine.shared.onStatusChange = { [weak self] status in self?.render(status) }
        // Rebuild the device list when the devices change, not only when the submenu is
        // opened: a DAC unplugged with the menu already open should leave the list at once.
        Engine.shared.onDevicesChanged = { [weak self] in self?.populateDeviceMenu() }
        Engine.shared.start()
    }

    /// Reopening a menu bar app — from Launchpad, Finder, or the Dock — normally does
    /// nothing at all, because there is no window to raise. That silence is impossible to
    /// tell apart from a crash, so open the menu instead: it is the app's only way to say
    /// "I'm here".
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Asynchronously: clicking the status item from inside the reopen callback can
        // land before AppKit has finished handling the launch event.
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
        return true
    }

    private func render(_ status: EngineStatus) {
        guard let button = statusItem.button else { return }
        button.title = status.deviceRate > 0
            ? " " + rateLabel(status.deviceRate).replacingOccurrences(of: " kHz", with: "k")
            : ""
        button.image = warning(in: status) == nil ? Self.normalIcon : Self.warningIcon
        // Updates the header in place rather than rebuilding: a rebuild tore out the row
        // under the pointer mid-click, and the replacement row starts unhighlighted, so
        // the highlight vanished until the mouse moved. Text changes move nothing.
        updateStatusDisplay(status)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        // A submenu is rebuilt on its own, when it opens. The main menu deliberately is
        // not rebuilt while open — that would tear out the row under the pointer — so a
        // device plugged in meanwhile would otherwise not show until the menu was closed
        // and opened again.
        if menu === deviceSubmenu {
            populateDeviceMenu()
            return
        }

        Engine.shared.refreshStatus()
        refreshLoginItemState()
        rebuild()
    }

    /// Held so the header can be refreshed without rebuilding the menu around it.
    private var headerViews: [ScrollingLabelMenuItemView] = []
    private weak var checklistItem: NSMenuItem?
    private let deviceSubmenu = NSMenu()

    /// The menu bar icon, in its normal and warning forms.
    ///
    /// contentTintColor does not work here: SF Symbols arrive as template images, and the
    /// menu bar draws those monochrome to follow the system appearance, overriding any
    /// tint. Colour has to be baked into a non-template image instead.
    private static let normalIcon = statusImage(warning: false)
    private static let warningIcon = statusImage(warning: true)

    private static func statusImage(warning: Bool) -> NSImage? {
        let description = "Attune"
        guard warning else {
            return NSImage(systemSymbolName: "waveform", accessibilityDescription: description)
        }
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: description)?
            .withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
        image?.isTemplate = false
        return image
    }

    /// A hard failure outranks a standing condition like a lowered volume.
    private func warning(in status: EngineStatus) -> String? {
        status.problem ?? status.hygieneProblem
    }

    private func updateStatusDisplay(_ status: EngineStatus) {
        // The warning rides on the item that fixes it rather than on a status line: the
        // detail is one click away in the report, which says more than a summary line,
        // and the header stays purely factual.
        //
        // An emoji rather than item.image: an NSMenuItem image makes AppKit reserve an
        // image column and indent the normal items, while the view-backed toggles draw
        // themselves and ignore it — the menu would come out misaligned down the middle.
        // Being coloured already, it also sidesteps how a tinted title fares against the
        // blue highlight, so the title keeps its native appearance throughout.
        checklistItem?.title = warning(in: status) == nil
            ? localized("menu.checklist")
            : "⚠️ " + localized("menu.checklist")

        guard headerViews.count == 3 else { return }

        let device: String
        if !status.targetConnected {
            device = status.targetName          // already reads as a sentence of its own
        } else if status.deviceRate > 0 {
            device = "\(status.targetName) · \(rateLabel(status.deviceRate))"
        } else {
            device = status.targetName
        }

        var track = localized("menu.nothingPlaying")
        if let title = status.trackTitle {
            track = (status.playing ? "▶ " : "⏸ ") + title
            if let detected = status.detected {
                track += " · " + localized("menu.trackFormat", detected.summary, detected.source.label)
            }
        }

        headerViews[0].attributedText = attributed(device, bold: true)
        // A warning takes the wire-format row rather than adding one of its own: the row
        // count has to stay fixed, and of the three the wire format is the least urgent.
        headerViews[1].attributedText = attributed(localized("menu.wire", status.wireFormat ?? "—"))
        headerViews[2].attributedText = attributed(track)
    }

    private static var headlineFont: NSFont { .menuBarFont(ofSize: 0) }
    private static var detailFont: NSFont { .menuFont(ofSize: NSFont.smallSystemFontSize) }

    private func attributed(_ string: String, bold: Bool = false, colour: NSColor? = nil) -> NSAttributedString {
        let font = bold ? Self.headlineFont : Self.detailFont
        return NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: colour ?? (bold ? NSColor.labelColor : NSColor.secondaryLabelColor),
        ])
    }

    private func rebuild() {
        menu.removeAllItems()
        let status = Engine.shared.status

        // View-backed so that clicking one does not dismiss the menu — there are six of
        // these, and reopening the menu between each was tedious. See ToggleMenuItemView.
        let toggles: [(title: String, isOn: () -> Bool, toggle: () -> Void)] = [
            (localized("menu.route"),
             { [unowned self] in settings.routeToTarget }, { [unowned self] in toggleRoute() }),
            (localized("menu.matchRate"),
             { [unowned self] in settings.matchSampleRate }, { [unowned self] in toggleMatch() }),
            (localized("menu.deepestFormat"),
             { [unowned self] in settings.maximizeBitDepth }, { [unowned self] in toggleDepth() }),
            (localized("menu.restartOnChange"),
             { [unowned self] in settings.seamlessSwitch }, { [unowned self] in toggleSeamless() }),
            (localized("menu.restoreOnStop"),
             { [unowned self] in settings.restoreOnStop }, { [unowned self] in toggleRestore() }),
        ]
        let toggleWidth = ToggleMenuItemView.width(for: toggles.map(\.title))

        // Three header rows, always. The count has to be fixed: the menu can only be
        // updated in place while it is open if nothing above the toggles appears or
        // disappears, and anything that shifts rows vertically moves them out from under
        // the pointer mid-click. They are view-backed and share the toggles' width so a
        // long track title cannot stretch the menu — it scrolls inside the row instead.
        headerViews = [
            ScrollingLabelMenuItemView(width: toggleWidth, font: Self.headlineFont),
            ScrollingLabelMenuItemView(width: toggleWidth, font: Self.detailFont),
            ScrollingLabelMenuItemView(width: toggleWidth, font: Self.detailFont),
        ]
        for view in headerViews {
            let item = NSMenuItem()
            item.view = view
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        for entry in toggles {
            let item = NSMenuItem()
            item.view = ToggleMenuItemView(title: entry.title, width: toggleWidth,
                                           isOn: entry.isOn, action: entry.toggle)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(deviceMenu())
        menu.addItem(fallbackMenu())

        menu.addItem(.separator())
        add(localized("menu.reapply"), #selector(reapply), on: nil)
        checklistItem = add(localized("menu.checklist"), #selector(showChecklist), on: nil)
        add(localized("menu.activity"), #selector(showActivity), on: nil)
        add(localized("menu.audioMidi"), #selector(openAudioMIDI), on: nil)

        menu.addItem(.separator())
        let loginItem = add(loginItemState.title, #selector(toggleLogin), on: loginItemState.checked)
        loginItem.isEnabled = loginItemState.enabled
        add(localized("menu.about"), #selector(showAbout), on: nil)
        add(localized("menu.quit"), #selector(quit), on: nil, key: "q")

        // Last: it styles the checklist item too, which does not exist until the menu is
        // fully built.
        updateStatusDisplay(status)
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, on state: Bool?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let state { item.state = state ? .on : .off }
        menu.addItem(item)
        return item
    }

    private func deviceMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: localized("menu.outputDevice"), action: nil, keyEquivalent: "")
        deviceSubmenu.delegate = self
        populateDeviceMenu()
        parent.submenu = deviceSubmenu
        return parent
    }

    private func populateDeviceMenu() {
        let sub = deviceSubmenu
        sub.removeAllItems()
        Log.write("device menu rebuilt")

        // The tick marks the device actually in play, not the saved preference — the two
        // differ whenever the preferred one is unplugged and another has taken over, and
        // showing the preference there would point at a device doing nothing.
        let active = settings.resolveTargetDevice()
        let outputs = AudioDevice.allOutputs()
        let dacs = outputs.filter(\.isWiredDAC)
        let others = outputs.filter { !$0.isWiredDAC }

        func addSection(_ title: String, _ devices: [AudioDevice]) {
            guard !devices.isEmpty else { return }
            if sub.numberOfItems > 0 { sub.addItem(.separator()) }
            let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            sub.addItem(header)
            for device in devices {
                let item = NSMenuItem(title: "    \(device.name)  (\(device.transport))",
                                      action: #selector(pickDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device
                item.state = device.uid == active?.uid ? .on : .off
                sub.addItem(item)
            }
        }

        addSection(localized("menu.dacs"), dacs)
        addSection(localized("menu.otherOutputs"), others)
    }

    private func fallbackMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: localized("menu.unknownRate"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let options: [(String, Double)] = [
            (localized("menu.leaveAlone"), 0),
            (localized("menu.assumeRate", rateLabel(44100)), 44100),
            (localized("menu.assumeRate", rateLabel(48000)), 48000),
            (localized("menu.assumeRate", rateLabel(96000)), 96000),
        ]
        for (title, rate) in options {
            let item = NSMenuItem(title: title, action: #selector(pickFallback(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = rate
            item.state = abs(settings.fallbackRate - rate) < 1 ? .on : .off
            sub.addItem(item)
        }
        parent.submenu = sub
        return parent
    }

    // MARK: Actions

    @objc private func toggleRoute()    { settings.routeToTarget = !settings.routeToTarget; Engine.shared.reapply() }
    @objc private func toggleMatch()    { settings.matchSampleRate = !settings.matchSampleRate; Engine.shared.reapply() }
    @objc private func toggleDepth()    { settings.maximizeBitDepth = !settings.maximizeBitDepth; Engine.shared.reapply() }
    @objc private func toggleSeamless() { settings.seamlessSwitch = !settings.seamlessSwitch }
    @objc private func toggleRestore()  { settings.restoreOnStop = !settings.restoreOnStop }
    @objc private func reapply()        { Engine.shared.reapply() }

    @objc private func pickDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AudioDevice else { return }
        settings.setTargetDevice(device)
        Engine.shared.reapply()
    }

    @objc private func pickFallback(_ sender: NSMenuItem) {
        settings.fallbackRate = sender.representedObject as? Double ?? 44100
        Engine.shared.reapply()
    }

    @objc private func openAudioMIDI() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
    }

    /// The system panel rather than a window of our own: it already pulls the icon, name
    /// and version straight from the bundle, and looks like every other About box.
    @objc private func showAbout() {
        // An accessory app is never frontmost on its own, so the panel would open behind
        // whatever the user is looking at.
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: localized("about.credits"),
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Login item

    /// SMAppService.status is synchronous, and this session saw it block indefinitely
    /// when read outside a normally launched app. Reading it while building the menu
    /// would put that risk on the main thread, so the menu draws a cached value that is
    /// refreshed in the background.
    private struct LoginItemState {
        var title = localized("login.title")
        var checked = false
        var enabled = true
    }
    private var loginItemState = LoginItemState()

    /// Treating anything that is not `.enabled` as "off" is what made this item look
    /// broken: macOS answers `.requiresApproval` when it wants the user to finish the
    /// job in System Settings, and calling register() again from there changes nothing.
    private func refreshLoginItemState() {
        guard #available(macOS 13, *) else {
            loginItemState = LoginItemState(title: localized("login.needsVentura"),
                                            checked: false, enabled: false)
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let state: LoginItemState
            switch SMAppService.mainApp.status {
            case .enabled:
                state = LoginItemState(title: localized("login.title"), checked: true, enabled: true)
            case .requiresApproval:
                state = LoginItemState(title: localized("login.needsApproval"),
                                       checked: false, enabled: true)
            case .notFound:
                state = LoginItemState(title: localized("login.notFound"),
                                       checked: false, enabled: false)
            default:
                state = LoginItemState(title: localized("login.title"), checked: false, enabled: true)
            }
            DispatchQueue.main.async { self?.loginItemState = state }
        }
    }

    @objc private func toggleLogin() {
        guard #available(macOS 13, *) else { return }
        let wasEnabled = loginItemState.checked

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Nothing to toggle: macOS is waiting on the user, not on us.
            if SMAppService.mainApp.status == .requiresApproval {
                DispatchQueue.main.async { self?.openLoginItemsSettings() }
                return
            }

            var failure: String?
            do {
                if wasEnabled { try SMAppService.mainApp.unregister() }
                else { try SMAppService.mainApp.register() }
            } catch {
                failure = error.localizedDescription
            }
            let needsApproval = SMAppService.mainApp.status == .requiresApproval

            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshLoginItemState()
                if let failure {
                    self.alert(localized("login.failed"), failure)
                } else if needsApproval {
                    // Registering often lands here rather than .enabled — say so, instead
                    // of leaving an unchecked box and no explanation.
                    let response = self.alert(localized("login.oneMoreStep"),
                                              localized("login.approveBody"),
                                              extraButton: localized("login.openSettings"))
                    if response == .alertSecondButtonReturn { self.openLoginItemsSettings() }
                }
            }
        }
    }

    private func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showActivity() {
        let entries = Log.recent
        let body = entries.isEmpty ? localized("activity.empty") : entries.suffix(30).joined(separator: "\n")
        if alert(localized("activity.title"), body, extraButton: localized("activity.copy")) == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entries.joined(separator: "\n"), forType: .string)
        }
    }

    // MARK: Checklist

    @objc private func showChecklist() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let report = self.checklist()
            DispatchQueue.main.async {
                // Offering "Fix what I can" when nothing is fixable is how this button
                // came to look like a crash: both repairs need Music, and with Music
                // closed they threw and left the user staring at an unchanged dialog.
                let response = self.alert(localized("check.title"),
                                          report.lines.joined(separator: "\n"),
                                          extraButton: report.fixable.isEmpty ? nil : localized("check.fix"))
                guard response == .alertSecondButtonReturn else { return }
                self.applyFixes(report.fixable)
            }
        }
    }

    private func applyFixes(_ fixable: [String]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var done: [String] = []
            var failed: [String] = []
            for fix in fixable {
                do {
                    switch fix {
                    case "volume": try MusicBridge.setVolumeToUnity(); done.append(localized("fix.volume"))
                    case "eq":     try MusicBridge.disableEQ();        done.append(localized("fix.eq"))
                    default:       break
                    }
                } catch {
                    failed.append("\(error)")
                }
            }
            Engine.shared.reapply()
            DispatchQueue.main.async {
                let body = (done + failed).isEmpty ? localized("fix.nothing") : (done + failed).joined(separator: "\n")
                self?.alert(failed.isEmpty ? localized("fix.done") : localized("fix.partial"), body)
            }
        }
    }

    private func checklist() -> (lines: [String], fixable: [String]) {
        var lines: [String] = []
        var fixable: [String] = []
        let status = Engine.shared.status

        if settings.resolveTargetDevice() == nil {
            lines.append(localized("menu.noDAC"))
        }
        if let device = settings.resolveTargetDevice() {
            lines.append(localized("check.output", device.name, rateLabel(device.nominalSampleRate)))
            if let wire = device.currentPhysicalFormat { lines.append(localized("check.wireFormat", wire.describedBriefly)) }
            if let detected = status.detected {
                let matched = abs(device.nominalSampleRate - detected.sampleRate) < 1
                lines.append(localized(matched ? "check.rateMatches" : "check.rateDiffers", detected.summary))
            }
            lines.append(localized(device.hasHardwareVolumeControl ? "check.volumeHardware" : "check.volumeNone"))
        }

        if let snapshot = try? MusicBridge.snapshot() {
            lines.append(localized("check.musicVolume",
                                   snapshot.hygiene.volume == 100 ? "✓" : "✗",
                                   snapshot.hygiene.volume))
            lines.append(localized("check.eq",
                                   snapshot.hygiene.eqEnabled ? "✗" : "✓",
                                   localized(snapshot.hygiene.eqEnabled ? "check.on" : "check.off")))
            if snapshot.hygiene.volume != 100 { fixable.append("volume") }
            if snapshot.hygiene.eqEnabled { fixable.append("eq") }
        } else {
            lines.append(localized("check.noMusic"))
        }

        lines.append("")
        lines.append(localized("check.manualHeader"))
        lines.append(localized("check.soundEnhancer"))
        lines.append(localized("check.soundCheck"))
        lines.append(localized("check.crossfade"))
        lines.append(localized("check.audioQuality"))
        return (lines, fixable)
    }

    @discardableResult
    private func alert(_ title: String, _ body: String, extraButton: String? = nil) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: localized("alert.ok"))
        if let extraButton { alert.addButton(withTitle: extraButton) }
        return alert.runModal()
    }
}
