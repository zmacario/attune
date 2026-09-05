import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let settings = Settings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform",
                                           accessibilityDescription: "BitPerfect DX")
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        statusItem.menu = menu

        refreshLoginItemState()
        Engine.shared.onStatusChange = { [weak self] status in self?.render(status) }
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
        button.contentTintColor = status.problem == nil ? nil : .systemOrange
        // Updates the header in place rather than rebuilding: a rebuild tore out the row
        // under the pointer mid-click, and the replacement row starts unhighlighted, so
        // the highlight vanished until the mouse moved. Text changes move nothing.
        updateHeader(status)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        Engine.shared.refreshStatus()
        refreshLoginItemState()
        rebuild()
    }

    /// Held so the header can be refreshed without rebuilding the menu around it.
    private var headerItems: [NSMenuItem] = []

    private func updateHeader(_ status: EngineStatus) {
        guard headerItems.count == 4 else { return }

        let device = status.deviceRate > 0
            ? "\(status.targetName) · \(rateLabel(status.deviceRate))"
            : status.targetName

        var track = localized("menu.nothingPlaying")
        if let title = status.trackTitle {
            track = (status.playing ? "▶ " : "⏸ ") + title
            if let detected = status.detected {
                track += " · " + localized("menu.trackFormat", detected.summary, detected.source.label)
            }
        }

        // One line carries whichever of these matters most right now.
        let note = status.problem.map { "⚠︎ " + $0 } ?? status.lastAction ?? "—"

        headerItems[0].attributedTitle = attributed(device, bold: true)
        headerItems[1].attributedTitle = attributed(localized("menu.wire", status.wireFormat ?? "—"))
        headerItems[2].attributedTitle = attributed(track)
        headerItems[3].attributedTitle = attributed(note, colour: status.problem == nil ? nil : .systemOrange)
    }

    private func attributed(_ string: String, bold: Bool = false, colour: NSColor? = nil) -> NSAttributedString {
        let font = bold ? NSFont.menuBarFont(ofSize: 0) : NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        return NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: colour ?? (bold ? NSColor.labelColor : NSColor.secondaryLabelColor),
        ])
    }

    private func rebuild() {
        menu.removeAllItems()
        let status = Engine.shared.status

        // Four header rows, always. The count has to be fixed: the menu can only be
        // updated in place while it is open if nothing above the toggles appears or
        // disappears, and anything that shifts rows vertically moves them out from under
        // the pointer mid-click.
        headerItems = (0..<4).map { _ in disabled("", small: true) }
        headerItems.forEach(menu.addItem)
        updateHeader(status)

        menu.addItem(.separator())

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
            (localized("menu.assumeAtmos"),
             { [unowned self] in settings.assumeAtmos }, { [unowned self] in toggleAtmos() }),
        ]
        let toggleWidth = ToggleMenuItemView.width(for: toggles.map(\.title))
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
        add(localized("menu.checklist"), #selector(showChecklist), on: nil)
        add(localized("menu.activity"), #selector(showActivity), on: nil)
        add(localized("menu.audioMidi"), #selector(openAudioMIDI), on: nil)

        menu.addItem(.separator())
        let loginItem = add(loginItemState.title, #selector(toggleLogin), on: loginItemState.checked)
        loginItem.isEnabled = loginItemState.enabled
        add(localized("menu.quit"), #selector(quit), on: nil, key: "q")
    }

    private func disabled(_ title: String, bold: Bool = false, small: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let font = bold ? NSFont.menuBarFont(ofSize: 0)
                        : small ? NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
                                : NSFont.menuFont(ofSize: 0)
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: font,
                         .foregroundColor: small ? NSColor.secondaryLabelColor : NSColor.labelColor])
        return item
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
        let sub = NSMenu()
        let current = settings.resolveTargetDevice()
        for device in AudioDevice.allOutputs() {
            let item = NSMenuItem(title: "\(device.name)  (\(device.transport))",
                                  action: #selector(pickDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = device.uid == current?.uid ? .on : .off
            sub.addItem(item)
        }
        parent.submenu = sub
        return parent
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
    @objc private func toggleAtmos()    { settings.assumeAtmos = !settings.assumeAtmos; Engine.shared.reapply() }
    @objc private func reapply()        { Engine.shared.reapply() }

    @objc private func pickDevice(_ sender: NSMenuItem) {
        settings.targetDeviceUID = sender.representedObject as? String
        Engine.shared.reapply()
    }

    @objc private func pickFallback(_ sender: NSMenuItem) {
        settings.fallbackRate = sender.representedObject as? Double ?? 44100
        Engine.shared.reapply()
    }

    @objc private func openAudioMIDI() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
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
