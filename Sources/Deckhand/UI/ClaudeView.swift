import SwiftUI

struct ClaudeView: View {
    @StateObject private var vm = ClaudeViewModel()
    @StateObject private var api = ClaudeAPIBridge()

    var body: some View {
        VStack(spacing: 10) {
            if !api.hasKey {
                apiKeyPrompt
            } else {
                HStack(spacing: 4) {
                    ForEach(ClaudeViewModel.Mode.allCases) { mode in
                        Button(action: { vm.mode = mode }) {
                            Text(mode.title)
                                .font(Theme.monoSmall)
                                .foregroundColor(vm.mode == mode ? Theme.accent : Theme.fgMute)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(vm.mode == mode ? Theme.accent.opacity(0.12) : Color.clear)
                                )
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                    if vm.mode == .chat {
                        Button(action: { vm.clearChat() }) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.fgMute)
                        }.buttonStyle(.plain)
                    }
                }

                Group {
                    if vm.mode == .presets {
                        presetsPane
                    } else {
                        chatPane
                    }
                }
                .animation(.easeOut(duration: 0.2), value: vm.mode)
            }
        }
        .onAppear {
            api.refresh()
            vm.loadFromClipboardIfEmpty()
        }
    }

    // MARK: - API key prompt

    @EnvironmentObject private var notch: NotchViewModel

    private var apiKeyPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "key")
                .font(.system(size: 26, weight: .light))
                .foregroundColor(Theme.fgMute)
            Text("Add your Claude API key")
                .font(Theme.title).foregroundColor(Theme.fg)
            Text("It is stored in your Mac's Keychain and only used to talk to the Anthropic API.")
                .font(Theme.caption).foregroundColor(Theme.fgDim)
                .multilineTextAlignment(.center)
            PrimaryButton(title: "Open Settings") {
                notch.requestClose()
                SettingsWindow.show()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Presets

    private var presetsPane: some View {
        VStack(spacing: 8) {
            // Preset picker chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Presets.all) { p in
                        Button(action: { vm.selectedPresetId = p.id }) {
                            HStack(spacing: 4) {
                                Image(systemName: p.symbol).font(.system(size: 10))
                                Text(p.name).font(Theme.monoSmall)
                            }
                            .foregroundColor(vm.selectedPresetId == p.id ? Theme.accent : Theme.fgDim)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(vm.selectedPresetId == p.id ? Theme.accent.opacity(0.12) : Theme.surface2)
                            )
                        }.buttonStyle(.plain)
                    }
                }
            }

            TextEditor(text: $vm.inputText)
                .scrollContentBackground(.hidden)
                .padding(8).font(Theme.body)
                .foregroundColor(Theme.fg)
                .background(Theme.surface2)
                .cornerRadius(8)
                .frame(minHeight: 80, maxHeight: 140)

            HStack {
                Spacer()
                if vm.isRunning { ProgressView().controlSize(.small) }
                Button(action: { vm.runPreset() }) {
                    Text("Run").font(Theme.label)
                        .foregroundColor(Theme.bg)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.accent).cornerRadius(6)
                }.buttonStyle(.plain)
                .disabled(vm.inputText.isEmpty || vm.isRunning)
            }

            if let err = vm.error {
                Text(err).font(Theme.caption).foregroundColor(Theme.warn)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !vm.outputText.isEmpty {
                ScrollView {
                    Text(vm.outputText).font(Theme.body).foregroundColor(Theme.fg)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(Theme.surface2.opacity(0.5))
                .cornerRadius(8)
                HStack {
                    Spacer()
                    Button(action: { vm.copyOutput() }) {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(Theme.monoSmall).foregroundColor(Theme.fgDim)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Chat

    private var chatPane: some View {
        VStack(spacing: 8) {
            if vm.messages.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "brain")
                        .font(.system(size: 24))
                        .foregroundColor(Theme.fgMute)
                    Text("Start a conversation")
                        .font(Theme.body).foregroundColor(Theme.fgDim)
                    Spacer()
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(vm.messages) { msg in
                            ChatBubble(msg: msg)
                        }
                        if vm.isRunning {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Thinking…").font(Theme.caption).foregroundColor(Theme.fgMute)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let err = vm.error {
                Text(err).font(Theme.caption).foregroundColor(Theme.warn)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                TextField("Ask anything", text: $vm.chatInput, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.body).foregroundColor(Theme.fg)
                    .padding(8).background(Theme.surface2).cornerRadius(8)
                    .onSubmit { vm.sendChat() }
                Button(action: { vm.sendChat() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20)).foregroundColor(Theme.accent)
                }.buttonStyle(.plain)
                .disabled(vm.chatInput.isEmpty || vm.isRunning)
            }
        }
    }
}

struct ChatBubble: View {
    let msg: ClaudeMessage
    var body: some View {
        VStack(alignment: msg.role == .user ? .trailing : .leading) {
            HStack {
                if msg.role == .user { Spacer() }
                Text(msg.content)
                    .font(Theme.body)
                    .foregroundColor(msg.role == .user ? Theme.bg : Theme.fg)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(msg.role == .user ? Theme.accent : Theme.surface2)
                    .cornerRadius(10)
                if msg.role == .assistant { Spacer() }
            }
        }
    }
}

/// Tracks whether an API key exists so the tab updates after it is saved in Settings.
@MainActor
final class ClaudeAPIBridge: ObservableObject {
    @Published var hasKey: Bool = ClaudeAPI.shared.hasAPIKey
    func refresh() { hasKey = ClaudeAPI.shared.hasAPIKey }
}
