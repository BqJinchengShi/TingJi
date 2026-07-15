import SwiftUI
import AppKit
import Carbon

@main
struct TingJiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("听记", id: "main") {
            ContentView(manager: RecordingManager.shared)
        }
        .defaultSize(width: 820, height: 600)
        Settings {
            ConfigView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    private var statusItem: NSStatusItem?
    private var hotKeyRef: EventHotKeyRef?
    private var timer: Timer?
    private var hotKeyMenuItem: NSMenuItem?
    private var lastToggleTime: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        setupStatusItem()
        setupHotKey()
        // 定时刷新菜单栏图标（录音状态）
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            self.updateStatusItem()
        }
        // 空格键暂停/继续播放（输入框激活时不响应）
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 49, !(NSApp.keyWindow?.firstResponder is NSTextView) {
                NotificationCenter.default.post(name: .togglePlayback, object: nil)
                return nil
            }
            return event
        }
    }

    // MARK: - 菜单栏图标

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItem()
        let menu = NSMenu()
        menu.addItem(withTitle: "显示主窗口", action: #selector(showMainWindow), keyEquivalent: "")
        menu.addItem(.separator())
        let hotKeyItem = NSMenuItem(title: "开始/停止录音", action: #selector(toggleRecording), keyEquivalent: "")
        applyHotkey(to: hotKeyItem)
        menu.addItem(hotKeyItem)
        hotKeyMenuItem = hotKeyItem
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出听记", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
    }

    /// 根据用户自定义快捷键刷新菜单项显示
    private func applyHotkey(to item: NSMenuItem) {
        let cfg = ConfigStore.load()
        let kc = Int(cfg["HOTKEY_KEY"] ?? "") ?? 0
        let char = (cfg["HOTKEY_CHAR"] ?? "").lowercased()
        let nsMods = UInt32(cfg["HOTKEY_MODIFIERS"] ?? "") ?? 0
        if kc == 0 || char.isEmpty {
            // 未设置：默认 ⌘⇧R
            item.keyEquivalent = "r"
            item.keyEquivalentModifierMask = [.command, .shift]
        } else {
            item.keyEquivalent = String(char.prefix(1))
            item.keyEquivalentModifierMask = nsMods == 0 ? [.command, .shift] : NSEvent.ModifierFlags(rawValue: UInt(nsMods))
        }
    }

    private func updateStatusItem() {
        let button = statusItem?.button
        let m = RecordingManager.shared
        if m.state == .recording {
            button?.image = nil
            button?.title = "●"
            button?.contentTintColor = .systemRed
        } else if m.state == .transcribing {
            button?.title = ""
            button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "转写中")
            button?.contentTintColor = .systemOrange
        } else {
            button?.title = ""
            button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "听记")
            button?.contentTintColor = nil
        }
    }

    var openMainWindow: (() -> Void)?

    @objc func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = findMainWindow() {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            FileHandle.standardError.write(Data("[TingJi] showMainWindow: 无可见窗口，openMainWindow 回调存在=\(openMainWindow != nil)\n".utf8))
            // 双通道重开：通知 ContentView（窗口仍存活时调 openWindow）+ AppDelegate 持有的闭包兜底
            NotificationCenter.default.post(name: .showMainWindow, object: nil)
            openMainWindow?()
        }
    }

    private func findMainWindow() -> NSWindow? {
        NSApp.windows.first { !$0.isKind(of: NSPanel.self) && $0.contentView != nil && $0.title == "听记" }
    }

    /// Dock 图标点击且无可见窗口时重开主窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    @objc func toggleRecording() {
        // 防抖：菜单本地快捷键与 Carbon 全局热键可能同时触发，0.5s 内重复忽略
        let now = Date()
        if let last = lastToggleTime, now.timeIntervalSince(last) < 0.5 { return }
        lastToggleTime = now
        showMainWindow()  // 快捷键先呼起主窗口
        let m = RecordingManager.shared
        if m.state == .transcribing {
            showAlert("正在转写中", "请等当前转写完成后再开始/停止录音。")
            return
        }
        Task {
            if m.state == .recording {
                await m.stopRecording()
            } else {
                await m.startRecording()
            }
        }
    }

    private func showAlert(_ title: String, _ msg: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = msg
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - 全局快捷键 Cmd+Shift+R

    private func setupHotKey() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: @convention(c) (EventHandlerCallRef?, EventRef?, UnsafeMutableRawPointer?) -> OSStatus = { _, _, _ in
            AppDelegate.shared?.toggleRecording()
            return noErr
        }
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventSpec, nil, nil)
        FileHandle.standardError.write(Data("[TingJi] InstallEventHandler status=\(installStatus)\n".utf8))
        reregisterHotKey()
        NotificationCenter.default.addObserver(self, selector: #selector(reregisterHotKey),
                                               name: .hotkeyChanged, object: nil)
    }

    @objc func reregisterHotKey() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        let cfg = ConfigStore.load()
        let keyCode = UInt32(cfg["HOTKEY_KEY"] ?? "") ?? UInt32(kVK_ANSI_R)
        let nsMods = UInt32(cfg["HOTKEY_MODIFIERS"] ?? "") ?? 0
        // NSEvent.ModifierFlags -> Carbon flags（RegisterEventHotKey 需要 Carbon flags）
        var mods: UInt32 = 0
        if nsMods == 0 {
            mods = UInt32(cmdKey | shiftKey)  // 默认 Cmd+Shift+R
        } else {
            if nsMods & UInt32(NSEvent.ModifierFlags.command.rawValue) != 0 { mods |= UInt32(cmdKey) }
            if nsMods & UInt32(NSEvent.ModifierFlags.shift.rawValue) != 0 { mods |= UInt32(shiftKey) }
            if nsMods & UInt32(NSEvent.ModifierFlags.option.rawValue) != 0 { mods |= UInt32(optionKey) }
            if nsMods & UInt32(NSEvent.ModifierFlags.control.rawValue) != 0 { mods |= UInt32(controlKey) }
        }
        var hotKeyID = EventHotKeyID(signature: fourCharCode("TJ01"), id: 1)
        let status = RegisterEventHotKey(keyCode, mods, hotKeyID,
                                          GetApplicationEventTarget(), 0, &hotKeyRef)
        FileHandle.standardError.write(Data("[TingJi] RegisterHotKey keyCode=\(keyCode) mods=\(mods) status=\(status)\n".utf8))
        if status != noErr {
            RecordingManager.shared.statusText = "快捷键冲突或无效，请在设置里换一个"
        }
        // 同步菜单项快捷键显示
        if let item = hotKeyMenuItem { applyHotkey(to: item) }
    }

    private func fourCharCode(_ s: String) -> OSType {
        var result: OSType = 0
        for b in s.utf8 { result = (result << 8) | OSType(b) }
        return result
    }
}
