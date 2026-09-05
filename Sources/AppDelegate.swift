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

    private func render(_ status: EngineStatus) {
        guard let button = statusItem.button else { return }
        button.title = status.deviceRate > 0
            ? " " + rateLabel(status.deviceRate).replacingOccurrences(of: " kHz", with: "k")
            : ""
        button.contentTintColor = status.problem == nil ? nil : .systemOrange
        if menu.numberOfItems > 0, statusItem.button?.window?.isVisible == true { rebuild() }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        Engine.shared.refreshStatus()
        refreshLoginItemState()
        rebuild()
    }

    private func rebuild() {
        menu.removeAllItems()
        let status = Engine.shared.status

        // — Current state —
        let headline = status.deviceRate > 0
            ? "\(status.targetName) · \(rateLabel(status.deviceRate))"
            : status.targetName
        menu.addItem(disabled(headline, bold: true))
        if let wire = status.wireFormat { menu.addItem(disabled("Wire: \(wire)", small: true)) }
        if let track = status.trackTitle {
            menu.addItem(disabled((status.playing ? "▶ " : "⏸ ") + track, small: true))
        }
        if let detected = status.detected {
            menu.addItem(disabled("Track: \(detected.summary) (from \(detected.source.rawValue))", small: true))
        }
        if let action = status.lastAction { menu.addItem(disabled(action, small: true)) }
        if let problem = status.problem {
            let item = disabled("⚠︎ " + problem, small: true)
            item.attributedTitle = NSAttributedString(
                string: "⚠︎ " + problem,
                attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                             .foregroundColor: NSColor.systemOrange])
            menu.addItem(item)
        }

        menu.addItem(.separator())

        add("Route Music to this device", #selector(toggleRoute), on: settings.routeToTarget)
        add("Match the track's sample rate", #selector(toggleMatch), on: settings.matchSampleRate)
        add("Use the deepest bit format", #selector(toggleDepth), on: settings.maximizeBitDepth)
        add("Restart track on rate change", #selector(toggleSeamless), on: settings.seamlessSwitch)
        add("Restore previous output when Music stops", #selector(toggleRestore), on: settings.restoreOnStop)
        add("Dolby Atmos is set to Always On", #selector(toggleAtmos), on: settings.assumeAtmos)

        menu.addItem(.separator())
        menu.addItem(deviceMenu())
        menu.addItem(fallbackMenu())

        menu.addItem(.separator())
        add("Re-apply now", #selector(reapply), on: nil)
        add("Check bit-perfect setup…", #selector(showChecklist), on: nil)
        add("Show recent activity…", #selector(showActivity), on: nil)
        add("Open Audio MIDI Setup", #selector(openAudioMIDI), on: nil)

        menu.addItem(.separator())
        let loginItem = add(loginItemState.title, #selector(toggleLogin), on: loginItemState.checked)
        loginItem.isEnabled = loginItemState.enabled
        add("Quit", #selector(quit), on: nil, key: "q")
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
        let parent = NSMenuItem(title: "Output device", action: nil, keyEquivalent: "")
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
        let parent = NSMenuItem(title: "When the rate is unknown", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let options: [(String, Double)] = [
            ("Leave the device alone", 0),
            ("Assume 44.1 kHz", 44100),
            ("Assume 48 kHz", 48000),
            ("Assume 96 kHz", 96000),
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
        var title = "Launch at login"
        var checked = false
        var enabled = true
    }
    private var loginItemState = LoginItemState()

    /// Treating anything that is not `.enabled` as "off" is what made this item look
    /// broken: macOS answers `.requiresApproval` when it wants the user to finish the
    /// job in System Settings, and calling register() again from there changes nothing.
    private func refreshLoginItemState() {
        guard #available(macOS 13, *) else {
            loginItemState = LoginItemState(title: "Launch at login (needs macOS 13)",
                                            checked: false, enabled: false)
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let state: LoginItemState
            switch SMAppService.mainApp.status {
            case .enabled:
                state = LoginItemState(title: "Launch at login", checked: true, enabled: true)
            case .requiresApproval:
                state = LoginItemState(title: "Launch at login (approve in System Settings…)",
                                       checked: false, enabled: true)
            case .notFound:
                state = LoginItemState(title: "Launch at login (move the app to /Applications)",
                                       checked: false, enabled: false)
            default:
                state = LoginItemState(title: "Launch at login", checked: false, enabled: true)
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
                    self.alert("Couldn’t change the login item", failure)
                } else if needsApproval {
                    // Registering often lands here rather than .enabled — say so, instead
                    // of leaving an unchecked box and no explanation.
                    let response = self.alert("One more step",
                                              "macOS needs you to approve BitPerfect DX under Login Items.",
                                              extraButton: "Open System Settings")
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
        let body = entries.isEmpty ? "Nothing logged yet." : entries.suffix(30).joined(separator: "\n")
        if alert("Recent activity", body, extraButton: "Copy all") == .alertSecondButtonReturn {
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
                let response = self.alert("Bit-perfect check",
                                          report.lines.joined(separator: "\n"),
                                          extraButton: report.fixable.isEmpty ? nil : "Fix what I can")
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
                    case "volume": try MusicBridge.setVolumeToUnity(); done.append("Music volume set to 100%")
                    case "eq":     try MusicBridge.disableEQ();        done.append("Equalizer turned off")
                    default:       break
                    }
                } catch {
                    failed.append("\(error)")
                }
            }
            Engine.shared.reapply()
            DispatchQueue.main.async {
                let body = (done + failed).isEmpty ? "Nothing changed." : (done + failed).joined(separator: "\n")
                self?.alert(failed.isEmpty ? "Fixed" : "Partly fixed", body)
            }
        }
    }

    private func checklist() -> (lines: [String], fixable: [String]) {
        var lines: [String] = []
        var fixable: [String] = []
        let status = Engine.shared.status

        if let device = settings.resolveTargetDevice() {
            lines.append("• Output: \(device.name) at \(rateLabel(device.nominalSampleRate))")
            if let wire = device.currentPhysicalFormat { lines.append("• Wire format: \(wire.describedBriefly)") }
            if let detected = status.detected {
                let matched = abs(device.nominalSampleRate - detected.sampleRate) < 1
                lines.append("\(matched ? "✓" : "✗") Device rate \(matched ? "matches" : "does not match") the track (\(detected.summary))")
            }
            lines.append("• Volume is \(device.hasHardwareVolumeControl ? "handled by the DAC" : "not exposed to macOS") — either way macOS isn’t scaling the samples")
        }

        if let snapshot = try? MusicBridge.snapshot() {
            lines.append("\(snapshot.hygiene.volume == 100 ? "✓" : "✗") Music’s own volume: \(snapshot.hygiene.volume)%")
            lines.append("\(snapshot.hygiene.eqEnabled ? "✗" : "✓") Equalizer: \(snapshot.hygiene.eqEnabled ? "on" : "off")")
            if snapshot.hygiene.volume != 100 { fixable.append("volume") }
            if snapshot.hygiene.eqEnabled { fixable.append("eq") }
        } else {
            lines.append("✗ Can’t reach Music (open it, and allow Automation)")
        }

        lines.append("")
        lines.append("Set these by hand in Music → Settings → Playback:")
        lines.append("  • Sound Enhancer: off")
        lines.append("  • Sound Check: off")
        lines.append("  • Crossfade Songs: off")
        lines.append("  • Audio Quality → Lossless (or Hi-Res Lossless)")
        return (lines, fixable)
    }

    @discardableResult
    private func alert(_ title: String, _ body: String, extraButton: String? = nil) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "OK")
        if let extraButton { alert.addButton(withTitle: extraButton) }
        return alert.runModal()
    }
}
