//
//  ChatPanel.swift
//  a-Shell — Agentic layer
//
//  The left pane: the Gemini chat transcript + input box + a settings sheet for
//  the API key / model.
//

import SwiftUI

@available(iOS 16.0, *)
struct ChatPanel: View {
    @ObservedObject var vm: AgentViewModel
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            inputBar
        }
        .sheet(isPresented: $showSettings) { AgentSettingsView() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "sparkles")
            Text("Agent").font(.headline)
            Spacer()
            if vm.isBusy {
                ProgressView().scaleEffect(0.8)
            }
            Button { vm.clear() } label: { Image(systemName: "trash") }
                .disabled(vm.messages.isEmpty || vm.isBusy)
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
        }
        .padding(8)
        .background(.thinMaterial)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(vm.messages) { msg in
                        MessageRow(message: msg).id(msg.id)
                    }
                }
                .padding(10)
            }
            .onChange(of: vm.messages.count) { _ in
                if let last = vm.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask the agent to build something…", text: $vm.input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit { vm.send() }
            Button { vm.send() } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(vm.input.trimmingCharacters(in: .whitespaces).isEmpty || vm.isBusy)
        }
        .padding(8)
        .background(.thinMaterial)
    }
}

/// A single chat row, styled by role.
@available(iOS 16.0, *)
private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            bubble(alignment: .trailing, bg: Color.accentColor.opacity(0.15))
        case .model:
            bubble(alignment: .leading, bg: Color.gray.opacity(0.12))
        case .tool:
            toolRow
        case .system:
            Text(message.text).font(.caption).foregroundStyle(.secondary)
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func bubble(alignment: HorizontalAlignment, bg: Color) -> some View {
        HStack {
            if alignment == .trailing { Spacer(minLength: 24) }
            Text(message.text)
                .textSelection(.enabled)
                .padding(10)
                .background(bg)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if alignment == .leading { Spacer(minLength: 24) }
        }
    }

    private var toolRow: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.toolName ?? "tool").font(.caption.bold())
                Text(message.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        switch message.toolName {
        case "run_bash": return "terminal"
        case "write_file": return "square.and.pencil"
        case "read_file": return "doc.text"
        case "preview_html": return "safari"
        default: return "wrench.and.screwdriver"
        }
    }
}

/// API key / model configuration.
@available(iOS 16.0, *)
struct AgentSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AgentSettings.shared
    @State private var apiKey: String = ""
    @State private var model: String = ""
    @State private var thinking: String = "LOW"
    @State private var availableModels: [String] = []
    @State private var isFetchingModels = false
    @State private var fetchError: String?

    private let thinkingLevels = ["OFF", "LOW", "MEDIUM", "HIGH"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Gemini API key") {
                    SecureField("Paste your API key", text: $apiKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("Stored in the device Keychain. Get a key at aistudio.google.com/apikey")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Model") {
                    TextField("model id", text: $model)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !availableModels.isEmpty {
                        Picker("Available", selection: $model) {
                            ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Button {
                        Task { await fetchModels() }
                    } label: {
                        HStack {
                            Text("Fetch available models")
                            if isFetchingModels { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isFetchingModels || apiKey.isEmpty)
                    if let fetchError {
                        Text(fetchError).font(.caption).foregroundStyle(.red)
                    }
                    Picker("Thinking", selection: $thinking) {
                        ForEach(thinkingLevels, id: \.self) { Text($0) }
                    }
                }
                Section {
                    Toggle("Confirm before running commands", isOn: $settings.confirmCommands)
                }
            }
            .navigationTitle("Agent settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        settings.apiKey = apiKey
                        settings.model = model.isEmpty ? AgentSettings.defaultModel : model
                        settings.thinkingLevel = thinking == "OFF" ? nil : thinking
                        dismiss()
                    }
                }
            }
            .onAppear {
                apiKey = settings.apiKey
                model = settings.model
                thinking = settings.thinkingLevel ?? "OFF"
            }
        }
    }

    @MainActor
    private func fetchModels() async {
        fetchError = nil
        isFetchingModels = true
        defer { isFetchingModels = false }
        // Use the key currently typed in the field (may not be saved yet).
        let service = GeminiService(apiKey: apiKey, model: model, thinkingLevel: nil)
        do {
            let all = try await service.listModels()
            // Surface flash-lite / flash first, but keep the full list available.
            availableModels = all.sorted { a, b in
                func rank(_ s: String) -> Int {
                    if s.contains("flash-lite") { return 0 }
                    if s.contains("flash") { return 1 }
                    return 2
                }
                return rank(a) == rank(b) ? a > b : rank(a) < rank(b)
            }
            if !availableModels.contains(model), let first = availableModels.first {
                model = first
            }
        } catch {
            fetchError = error.localizedDescription
        }
    }
}
