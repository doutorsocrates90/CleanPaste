import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Borderless window that can take keyboard focus (plain borderless windows cannot).
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let panelSize = NSSize(width: 460, height: 560)

    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private let model = CleanerModel()
    private var hotKeyRef: EventHotKeyRef?
    private var clickMonitor: Any?
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        installMainMenu()
        installPanel()
        installHotKey()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "doc.plaintext", accessibilityDescription: "CleanPaste")
                ?? NSImage(systemSymbolName: "textformat", accessibilityDescription: "CleanPaste")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        model.onShortcutChange = { [weak self] shortcut in self?.registerHotKey(shortcut) ?? false }
        model.onCopied = { [weak self] in
            self?.hidePanel()
            NSApp.hide(nil)                      // give focus back to the previous app so ⌘V works right away
        }

        // `open build/CleanPaste.app --args --show` pops the window open right away (handy for testing)
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showPanel() }
        }
    }

    // MARK: Panel

    /// A custom panel instead of NSPopover: popover placement proved unreliable for status items
    /// (it could end up above the top of the screen). Here the position is computed explicitly.
    private func installPanel() {
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.panelSize))
        background.material = .popover
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor

        let host = NSHostingView(rootView: ContentView(model: model))
        host.frame = background.bounds
        host.autoresizingMask = [.width, .height]
        background.addSubview(host)
        panel.contentView = background

        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.hidePanel()
        }
    }

    private func showPanel() {
        guard let buttonWindow = statusItem.button?.window else { return }
        let mouse = NSEvent.mouseLocation
        var screen = buttonWindow.screen
            ?? NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        var anchor = buttonWindow.frame                       // the icon, in screen coordinates
        if anchor.height < 1 || anchor.origin == .zero {      // icon not laid out yet: fall back to the pointer
            screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? screen
            let bar = NSStatusBar.system.thickness
            anchor = NSRect(x: mouse.x - 19, y: screen.frame.maxY - bar, width: 38, height: bar)
        }
        let area = screen.visibleFrame
        let size = Self.panelSize

        var x = anchor.midX - size.width / 2
        x = min(max(x, area.minX + 8), area.maxX - size.width - 8)
        var y = anchor.minY - size.height - 4                 // directly below the menu bar
        y = max(y, screen.frame.minY + 8)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)

        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.activate()
        DispatchQueue.main.async { self.model.focusInput() }

        // Close when clicking anywhere else, or pressing Esc.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            // Clicks on the menu bar icon are handled by the toggle itself.
            if !anchor.contains(NSEvent.mouseLocation) { self.hidePanel() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.model.recordingShortcut {            // capturing a new global shortcut
                if event.keyCode == 53 { self.model.recordingShortcut = false }
                else if let shortcut = Shortcut(event: event) { self.model.applyShortcut(shortcut) }
                return nil
            }
            if event.keyCode == 53 { self.hidePanel(); return nil }
            return event
        }
    }

    private func hidePanel() {
        guard panel.isVisible else { return }
        model.recordingShortcut = false
        panel.orderOut(nil)
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        clickMonitor = nil
        keyMonitor = nil
    }

    // MARK: Global shortcut

    /// Carbon hot keys need no Accessibility permission and work from any app.
    private func installHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.togglePanel() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)

        _ = registerHotKey(model.shortcut)
    }

    /// Registers `shortcut` and, only if that worked, releases the previous one.
    private func registerHotKey(_ shortcut: Shortcut) -> Bool {
        var newRef: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x434C_5053), id: 1)   // 'CLPS'
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id,
                                         GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr else { return false }
        if let old = hotKeyRef { UnregisterEventHotKey(old) }
        hotKeyRef = newRef
        return true
    }

    private func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    // MARK: Status item

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let open = menu.addItem(withTitle: "Open CleanPaste", action: #selector(openFromMenu),
                                keyEquivalent: model.shortcut.menuKeyEquivalent)
        open.keyEquivalentModifierMask = model.shortcut.modifierFlags   // displays the global shortcut
        open.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit CleanPaste", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openFromMenu() { showPanel() }

    /// Menu-bar apps have no menu bar of their own; without an Edit menu ⌘V/⌘C/⌘Z do nothing in text fields.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit CleanPaste", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
