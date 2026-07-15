import SwiftUI
import AVFoundation
import AppKit

struct RecordingRow: View {
    let item: RecordingItem
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var isDragging = false
    @State private var progressTimer: Timer?
    @State private var editingTitle = false
    @State private var titleInput = ""
    @FocusState private var titleFocused: Bool
    @FocusState private var speakerFocused: Bool
    @State private var totalDuration: TimeInterval = 0
    @State private var rate: Float = 1.0
    @State private var utterances: [Utterance] = []
    @State private var currentUtterance: Utterance?
    @State private var showError = false
    @State private var errorMsg = ""
    @State private var showDeleteConfirm = false
    @State private var speakerMap: [String: String] = [:]
    @State private var editingSpeaker = false
    @State private var speakerInput = ""

    private let rates: [Float] = [0.5, 1, 1.25, 1.5, 1.75, 2]

    private var dir: URL { RecordingStore.dir(for: item.id) }
    private var displayTitle: String {
        item.title ?? item.startTime.formatted(date: .abbreviated, time: .shortened)
    }
    private var status: RecordingStatus { item.status ?? .done }
    private var audioURL: URL? {
        for ext in ["wav", "mp3", "m4a", "ogg"] {
            let u = dir.appendingPathComponent("mixed.\(ext)")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if editingTitle {
                    TextField("标题", text: $titleInput)
                        .textFieldStyle(.roundedBorder)
                        .focused($titleFocused)
                        .onSubmit(commitTitle)
                        .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
                } else {
                    Text(displayTitle).font(.headline)
                    Button(action: startEdit) {
                        Image(systemName: "pencil").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                StatusBadge(status: status)
                if let d = item.duration {
                    Text(formatDuration(d)).foregroundStyle(.secondary).font(.caption.monospacedDigit())
                }
            }

            if status == .uploading || status == .transcribing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status == .uploading ? "上传中..." : "转写中...").font(.caption).foregroundStyle(.secondary)
                }
            } else if audioURL != nil {
                HStack(spacing: 8) {
                    Button(action: togglePlay) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill").frame(width: 20)
                    }
                    .buttonStyle(.borderless)
                    Slider(value: $progress, in: 0...1, onEditingChanged: { editing in
                        isDragging = editing
                        if editing {
                            updateCurrentUtterance(time: totalDuration * progress)
                        } else if let player {
                            player.currentTime = totalDuration * progress
                            updateCurrentUtterance(time: player.currentTime)
                        }
                    })
                    Text("\(formatTime(isDragging ? totalDuration * progress : (player?.currentTime ?? 0))) / \(formatTime(totalDuration))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Menu("\(String(format: "%g", rate))x") {
                        ForEach(rates, id: \.self) { r in
                            Button("\(String(format: "%g", r))x") { setRate(r) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(.caption2)
                }
            }

            if let u = currentUtterance {
                let spk = u.speaker ?? "?"
                let displaySpeaker = speakerMap[spk] ?? spk
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        if editingSpeaker {
                            TextField("改为", text: $speakerInput)
                                .textFieldStyle(.roundedBorder)
                                .focused($speakerFocused)
                                .onSubmit { commitSpeakerRename(original: spk) }
                                .onChange(of: speakerFocused) { _, focused in if !focused { commitSpeakerRename(original: spk) } }
                        } else {
                            Text(displaySpeaker).font(.headline).foregroundColor(.accentColor)
                            Button(action: { speakerInput = displaySpeaker; editingSpeaker = true; DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { speakerFocused = true } }) {
                                Image(systemName: "person.crop.circle.badge.plus").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                        Spacer()
                        Button("下一个未替换 ⏭") { jumpToNextUnassigned() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                    Text(u.text).font(.title3)
                }
                .padding(.vertical, 2)
            }

            if !item.summary.isEmpty {
                Text(item.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Button(action: download) { Label("下载", systemImage: "square.and.arrow.down") }
                Button(action: openTxt) { Label("查看txt", systemImage: "doc.text") }
                Spacer()
                Button(action: { showDeleteConfirm = true }) {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)
        }
        .confirmationDialog("确定删除这条录音？将同时删除云端文件。", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive, action: onDelete)
            Button("取消", role: .cancel) {}
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear(perform: loadDuration)
        .alert(errorMsg, isPresented: $showError) { Button("好") {} }
        .onReceive(NotificationCenter.default.publisher(for: .playbackStarted)) { note in
            if let id = note.object as? UUID, id != item.id, isPlaying {
                player?.pause()
                isPlaying = false
                progressTimer?.invalidate()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .togglePlayback)) { _ in
            if player != nil { togglePlay() }
        }
    }

    private func loadDuration() {
        guard let audioURL, totalDuration == 0 else { return }
        let asset = AVURLAsset(url: audioURL)
        let d = CMTimeGetSeconds(asset.duration)
        if d > 0 { totalDuration = d }
        loadUtterances()
        speakerMap = item.speakerMap ?? [:]
    }

    private func loadUtterances() {
        let url = dir.appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["utterances"] as? [[String: Any]] else { return }
        utterances = arr.map { u in
            Utterance(text: u["text"] as? String ?? "",
                      startTime: u["start_time"] as? Int,
                      endTime: u["end_time"] as? Int,
                      speaker: u["speaker"] as? String)
        }
    }

    private func updateCurrentUtterance(time: TimeInterval) {
        let ms = Int(time * 1000)
        currentUtterance = utterances.first { ($0.startTime ?? 0) <= ms && ms <= ($0.endTime ?? 0) }
    }

    private func togglePlay() {
        guard let audioURL else { return }
        if player == nil {
            player = try? AVAudioPlayer(contentsOf: audioURL)
            if let p = player {
                if totalDuration == 0 { totalDuration = p.duration }
                p.enableRate = true
                p.rate = rate
            }
        }
        guard let player else { return }
        if isPlaying {
            player.pause()
            progressTimer?.invalidate()
        } else {
            player.play()
            startProgressTimer()
            NotificationCenter.default.post(name: .playbackStarted, object: item.id)
        }
        isPlaying.toggle()
    }

    private func setRate(_ r: Float) {
        rate = r
        player?.enableRate = true
        player?.rate = r
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            guard let player else { return }
            if !isDragging {
                progress = totalDuration > 0 ? player.currentTime / totalDuration : 0
                updateCurrentUtterance(time: player.currentTime)
            }
            if !player.isPlaying {
                isPlaying = false
                progress = 0
                progressTimer?.invalidate()
            }
        }
    }

    private func startEdit() {
        titleInput = item.title ?? displayTitle
        editingTitle = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { titleFocused = true }
    }

    private func commitTitle() {
        let trimmed = titleInput.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { onRename(trimmed) }
        editingTitle = false
        titleFocused = false
    }

    private func commitSpeakerRename(original: String) {
        let name = speakerInput.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            speakerMap[original] = name
            try? TranscriptWriter.rewrite(dir: dir, speakerMap: speakerMap)
            var updated = item
            updated.speakerMap = speakerMap
            try? RecordingStore.saveMeta(updated)
            // 同步更新自定义路径 txt
            let path = ConfigStore.load()["TRANSCRIPT_SAVE_PATH"] ?? ""
            if !path.isEmpty {
                let transcriptURL = dir.appendingPathComponent("transcript.txt")
                let safe = displayTitle.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                let dest = URL(fileURLWithPath: path).appendingPathComponent("\(safe).txt")
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.copyItem(at: transcriptURL, to: dest)
            }
        }
        editingSpeaker = false
    }

    private func jumpToNextUnassigned() {
        guard let player else { return }
        let currentMs = Int(player.currentTime * 1000)
        let next = utterances.first { u in
            let s = u.speaker ?? "?"
            return speakerMap[s] == nil && (u.startTime ?? 0) > currentMs
        }
        let target = next ?? utterances.first { u in speakerMap[u.speaker ?? "?"] == nil }
        if let t = target {
            player.currentTime = TimeInterval(t.startTime ?? 0) / 1000
            updateCurrentUtterance(time: player.currentTime)
            if !isPlaying { togglePlay() }
        }
    }

    private func notReadyMessage() -> String? {
        switch status {
        case .uploading: return "还没上传成功，请稍后再试"
        case .transcribing: return "还没转写完，请稍后再试"
        case .recording: return "还在录音中，请稍后再试"
        case .failed: return "转写失败，无法下载"
        case .done: return nil
        }
    }

    private func download() {
        if let msg = notReadyMessage() { errorMsg = msg; showError = true; return }
        guard let audioURL else { errorMsg = "音频文件不存在"; showError = true; return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = audioURL.lastPathComponent
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: audioURL, to: dest)
    }

    private func openTxt() {
        if let msg = notReadyMessage() { errorMsg = msg; showError = true; return }
        let url = dir.appendingPathComponent("transcript.txt")
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMsg = "转写文件不存在"; showError = true; return
        }
        NSWorkspace.shared.open(url)
    }

    private func formatDuration(_ sec: Int) -> String {
        String(format: "%02d:%02d", sec / 60, sec % 60)
    }
    private func formatTime(_ t: TimeInterval) -> String {
        let sec = Int(t)
        return String(format: "%02d:%02d", sec / 60, sec % 60)
    }
}

private struct StatusBadge: View {
    let status: RecordingStatus
    var body: some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
    private var label: String {
        switch status {
        case .recording: "录音中"
        case .uploading: "上传中"
        case .transcribing: "转写中"
        case .done: "完成"
        case .failed: "失败"
        }
    }
    private var color: Color {
        switch status {
        case .recording: .red
        case .uploading: .blue
        case .transcribing: .orange
        case .done: .green
        case .failed: .red
        }
    }
}
