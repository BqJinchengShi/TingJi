import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    let manager: RecordingManager
    @Environment(\.openWindow) var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: toggleRecording) {
                    Label(manager.state == .recording ? "停止" : "录音",
                          systemImage: manager.state == .recording ? "stop.circle.fill" : "mic.fill")
                        .font(.title3)
                }
                .disabled(manager.state == .transcribing)
                .buttonStyle(.borderedProminent)
                .tint(manager.state == .recording ? .red : .accentColor)

                Button(action: pickAudio) {
                    Label("上传音频", systemImage: "arrow.up.doc")
                }
                .disabled(manager.state == .transcribing)

                if manager.state == .recording {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 10, height: 10).pulse()
                        Text(formatElapsed(manager.elapsed))
                            .font(.title3.monospacedDigit())
                            .foregroundStyle(.red)
                    }
                } else if manager.state == .transcribing {
                    ProgressView().controlSize(.small)
                    Text(manager.statusText).foregroundStyle(.secondary)
                } else if !manager.statusText.isEmpty {
                    Text(manager.statusText).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal).padding(.vertical, 10)
            .background(.regularMaterial)

            Divider()

            ScrollView {
                LazyVStack(spacing: 10) {
                    if manager.recordings.isEmpty {
                        ContentUnavailableView("还没有录音", systemImage: "waveform",
                                               description: Text("点「录音」开始，或「上传音频」转写本地文件"))
                            .padding(.top, 60)
                    } else {
                        ForEach(manager.recordings) { item in
                            RecordingRow(
                                item: item,
                                onRename: { title in manager.rename(item, to: title) },
                                onDelete: { manager.delete(item) }
                            )
                            .padding(.horizontal)
                        }
                    }
                }
                .padding(.top, 8).padding(.bottom, 8)
            }
        }
        .onAppear {
            FileHandle.standardError.write(Data("[TingJi] ContentView onAppear\n".utf8))
            AppDelegate.shared?.openMainWindow = { openWindow(id: "main") }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showMainWindow)) { _ in
            openWindow(id: "main")
        }
    }

    private func toggleRecording() {
        Task {
            if manager.state == .recording {
                await manager.stopRecording()
            } else {
                await manager.startRecording()
            }
        }
    }

    private func pickAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mp3, .wav, .mpeg4Audio, .aiff, .audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await manager.uploadAndTranscribe(url: url) }
    }

    private func formatElapsed(_ sec: Int) -> String {
        String(format: "%02d:%02d", sec / 60, sec % 60)
    }
}

private struct PulseModifier: ViewModifier {
    @State private var scale = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(scale ? 1.3 : 1.0)
            .opacity(scale ? 0.5 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: scale)
            .onAppear { scale = true }
    }
}

private extension View {
    func pulse() -> some View { modifier(PulseModifier()) }
}
