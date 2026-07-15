import SwiftUI
import AppKit
import Carbon

struct ConfigView: View {
    @State private var config: [String: String] = ConfigStore.load()
    @State private var hotwords: [String] = HotwordStore.load()
    @State private var newHotword = ""
    @State private var saved = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("使用说明") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("• ASR 鉴权：火山引擎「语音技术」控制台。旧版用 APP_ID + ACCESS_TOKEN；新版用 API_KEY。二选一。")
                        Text("• TOS：开通火山引擎「对象存储 TOS」并创建桶；AK/SK 在控制台「访问密钥」页创建。")
                        Text("• TOS_ENDPOINT 是 tos-cn-<区域>.volces.com（如 tos-cn-beijing.volces.com），不要带桶名。")
                        Text("• 开通「豆包录音文件识别模型 2.0」服务。")
                        Text("• 大模型：火山方舟 Ark 平台，创建接入点获取 API Key 和模型 ID。")
                        Text("• 配置文件：\(ConfigStore.configURL.path)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                Form {
                    // 1. 热词
                    Section("热词（专业术语/人名，提升识别准确率）") {
                        ForEach(hotwords, id: \.self) { word in
                            HStack {
                                Text(word)
                                Spacer()
                                Button(role: .destructive) { removeHotword(word) } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        HStack {
                            TextField("输入热词后回车添加", text: $newHotword)
                                .onSubmit(addHotword)
                            Button("添加", action: addHotword)
                        }
                    }
                    // 2. 大模型矫正
                    Section("大模型矫正（转写后自动修正错别字/术语）") {
                        Toggle("启用大模型矫正", isOn: bindBool("LLM_OPTIMIZE"))
                    }
                    // 3. 快捷键
                    Section("全局快捷键（发起/停止录音）") {
                        HotkeyRecorder(
                            keyCode: bind("HOTKEY_KEY"),
                            modifiers: bind("HOTKEY_MODIFIERS"),
                            char: bind("HOTKEY_CHAR")
                        )
                    }
                    // 4. 存储位置
                    Section("转写文本保存位置") {
                        TextField("目录路径（留空不额外保存）", text: bind("TRANSCRIPT_SAVE_PATH"))
                    }
                    // 5. 大模型配置
                    Section("大模型配置（火山方舟 Ark）") {
                        SecureField("ARK_API_KEY", text: bind("ARK_API_KEY"))
                        TextField("ARK_MODEL（模型 ID，如 doubao-seed-1.6-250615）", text: bind("ARK_MODEL"))
                    }
                    // 6. ASR 鉴权
                    Section("ASR 鉴权（豆包录音文件识别 2.0）") {
                        TextField("DOUBAO_APP_ID", text: bind("DOUBAO_APP_ID"))
                        SecureField("DOUBAO_ACCESS_TOKEN", text: bind("DOUBAO_ACCESS_TOKEN"))
                        SecureField("DOUBAO_API_KEY（新版，与上面二选一）", text: bind("DOUBAO_API_KEY"))
                    }
                    // 7. TOS
                    Section("TOS 对象存储") {
                        TextField("TOS_AK", text: bind("TOS_AK"))
                        SecureField("TOS_SK", text: bind("TOS_SK"))
                        TextField("TOS_BUCKET", text: bind("TOS_BUCKET"))
                        TextField("TOS_REGION（如 cn-beijing）", text: bind("TOS_REGION"))
                        TextField("TOS_ENDPOINT（如 tos-cn-beijing.volces.com）", text: bind("TOS_ENDPOINT"))
                    }
                }
                .formStyle(.grouped)

                HStack {
                    Button("保存") {
                        try? ConfigStore.save(config)
                        try? HotwordStore.save(hotwords)
                        saved = true
                        NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    if saved { Text("已保存").foregroundStyle(.green).font(.caption) }
                    Spacer()
                }
                .padding(.horizontal)
            }
        }
        .frame(minWidth: 580, minHeight: 520)
    }

    private func bind(_ key: String) -> Binding<String> {
        Binding(get: { config[key] ?? "" }, set: { config[key] = $0 })
    }

    private func bindBool(_ key: String) -> Binding<Bool> {
        Binding(get: { config[key] != "false" }, set: { config[key] = $0 ? "true" : "false" })
    }

    private func addHotword() {
        let w = newHotword.trimmingCharacters(in: .whitespaces)
        if !w.isEmpty && !hotwords.contains(w) {
            hotwords.append(w)
            try? HotwordStore.save(hotwords)  // 自动持久化，回车即存
        }
        newHotword = ""
    }

    private func removeHotword(_ word: String) {
        hotwords.removeAll { $0 == word }
        try? HotwordStore.save(hotwords)  // 删除即存
    }
}

extension Notification.Name {
    static let hotkeyChanged = Notification.Name("hotkeyChanged")
    static let playbackStarted = Notification.Name("playbackStarted")
    static let togglePlayback = Notification.Name("togglePlayback")
    static let showMainWindow = Notification.Name("showMainWindow")
}

private struct HotkeyRecorder: View {
    @Binding var keyCode: String
    @Binding var modifiers: String
    @Binding var char: String
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button(action: toggle) {
                Text(recording ? "按下组合键（Esc 取消）" : display)
                    .frame(minWidth: 160)
            }
            if let kc = Int(keyCode), kc != 0 {
                Button("清除") { keyCode = "0"; modifiers = "0"; char = "" }
            }
        }
    }

    private var display: String {
        let kc = Int(keyCode) ?? 0
        if kc == 0 { return "未设置（默认 ⌘⇧R）" }
        let m = NSEvent.ModifierFlags(rawValue: UInt(modifiers) ?? 0)
        var s = ""
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        s += char.isEmpty ? "键\(kc)" : char.uppercased()
        return s
    }

    private func toggle() {
        if recording { stop() } else { start() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == kVK_Escape { self.stop(); return nil }
            self.keyCode = String(event.keyCode)
            self.modifiers = String(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
            self.char = event.charactersIgnoringModifiers ?? ""
            self.stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}
