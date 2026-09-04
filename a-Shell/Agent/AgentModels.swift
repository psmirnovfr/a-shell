//
//  AgentModels.swift
//  a-Shell — Agentic layer
//
//  Chat message model, the tool declarations exposed to Gemini, and the
//  AgentViewModel that drives the tool-calling loop:
//
//    user text -> Gemini -> (functionCalls -> execute -> feed back)* -> final text
//

import Foundation
import SwiftUI

// MARK: - Chat display model

struct ChatMessage: Identifiable, Equatable {
    enum Role: String {
        case user, model, tool, system, error
    }
    let id = UUID()
    let role: Role
    var text: String
    /// For `.tool` rows: the tool name and a short summary of args/result.
    var toolName: String? = nil
    var isStreaming: Bool = false

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool { lhs.id == rhs.id }
}

// MARK: - Host abstraction
//
// The view model does not know about SceneDelegate/ios_system directly. The host
// (implemented by SceneDelegate in CommandRunner.swift) provides bash execution
// and the current working directory. HTML preview is a separate closure supplied
// by the view so it can drive the on-screen browser panel.

@MainActor
protocol AgentHost: AnyObject {
    /// Runs a shell command in a-Shell's sandbox and returns combined stdout/stderr.
    func runBashCapturing(_ command: String, timeout: Int?) async -> String
    /// The directory relative paths are resolved against.
    var agentWorkingDirectory: String { get }
}

// MARK: - View model

@MainActor
final class AgentViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isBusy = false
    @Published var input: String = ""

    weak var host: AgentHost?
    /// Set by AgentView; loads a local file URL into the browser panel.
    var previewHandler: ((URL) -> Void)?

    private let settings = AgentSettings.shared
    /// Raw Gemini `content` history (kept in lock-step with `messages`).
    private var contents: [[String: Any]] = []
    private let maxToolIterations = 12
    /// Guard against runaway output being pushed into the model context.
    private let maxToolOutputChars = 20_000

    private let systemPrompt = """
    You are the built-in coding agent inside a-Shell, a full Unix environment on \
    iPad. You have Python 3, common Unix tools, clang, and a POSIX shell available \
    through the run_bash tool. Prefer doing real work with the tools over describing \
    it. When you build a web artefact (HTML/CSS/JS), write it to a file with \
    write_file and then call preview_html so the user can see it in the in-app \
    browser panel. Keep chat replies concise; put detail in files. Always use \
    relative paths from the current working directory unless given an absolute path.
    """

    // MARK: Tool declarations

    private var tools: [GeminiTool] {
        [
            GeminiTool(
                name: "run_bash",
                description: "Run a shell command in the a-Shell sandbox and return its combined stdout/stderr.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "command": ["type": "string", "description": "The shell command line to execute."],
                        "timeout_s": ["type": "integer", "description": "Optional timeout in seconds (default 60)."],
                    ],
                    "required": ["command"],
                ]),
            GeminiTool(
                name: "write_file",
                description: "Create or overwrite a text file in the sandbox.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "File path (relative to cwd or absolute)."],
                        "content": ["type": "string", "description": "Full file contents."],
                    ],
                    "required": ["path", "content"],
                ]),
            GeminiTool(
                name: "read_file",
                description: "Read a text file from the sandbox.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "File path (relative to cwd or absolute)."],
                    ],
                    "required": ["path"],
                ]),
            GeminiTool(
                name: "preview_html",
                description: "Load a local HTML file into the in-app browser/preview panel so the user can see it.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Path to an .html file (relative to cwd or absolute)."],
                    ],
                    "required": ["path"],
                ]),
        ]
    }

    // MARK: - Public API

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        input = ""
        messages.append(ChatMessage(role: .user, text: text))
        contents.append(GeminiService.userText(text))
        Task { await runLoop() }
    }

    func clear() {
        messages.removeAll()
        contents.removeAll()
    }

    // MARK: - The loop

    private func runLoop() async {
        guard settings.hasAPIKey else {
            messages.append(ChatMessage(role: .error, text: GeminiError.missingAPIKey.localizedDescription))
            return
        }
        isBusy = true
        defer { isBusy = false }

        let service = GeminiService(apiKey: settings.apiKey,
                                    model: settings.model,
                                    thinkingLevel: settings.thinkingLevel)

        var iterations = 0
        while iterations < maxToolIterations {
            iterations += 1
            let result: GeminiResult
            do {
                result = try await service.generate(systemInstruction: systemPrompt,
                                                    contents: contents,
                                                    tools: tools)
            } catch {
                messages.append(ChatMessage(role: .error, text: error.localizedDescription))
                return
            }

            // Preserve the model turn verbatim for the next request.
            if let raw = result.rawModelContent {
                contents.append(raw)
            }
            if let text = result.text, !text.isEmpty {
                messages.append(ChatMessage(role: .model, text: text))
            }

            if result.functionCalls.isEmpty { return } // final answer reached

            for call in result.functionCalls {
                let response = await execute(call)
                contents.append(GeminiService.functionResponse(name: call.name,
                                                               id: call.id,
                                                               response: response))
            }
            // loop again so the model can react to tool results
        }

        messages.append(ChatMessage(role: .error,
                                    text: "Stopped after \(maxToolIterations) tool iterations."))
    }

    // MARK: - Tool execution

    private func execute(_ call: GeminiFunctionCall) async -> [String: Any] {
        switch call.name {
        case "run_bash":
            let command = call.args["command"] as? String ?? ""
            let timeout = call.args["timeout_s"] as? Int
            messages.append(ChatMessage(role: .tool, text: command, toolName: "run_bash"))
            guard let host = host else { return ["error": "No execution host available."] }
            var output = await host.runBashCapturing(command, timeout: timeout)
            var truncated = false
            if output.count > maxToolOutputChars {
                output = String(output.prefix(maxToolOutputChars)) + "\n…[truncated]"
                truncated = true
            }
            return ["output": output, "truncated": truncated]

        case "write_file":
            let path = call.args["path"] as? String ?? ""
            let content = call.args["content"] as? String ?? ""
            messages.append(ChatMessage(role: .tool, text: path, toolName: "write_file"))
            do {
                let url = resolve(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try content.write(to: url, atomically: true, encoding: .utf8)
                return ["ok": true, "path": url.path, "bytes": content.utf8.count]
            } catch {
                return ["ok": false, "error": error.localizedDescription]
            }

        case "read_file":
            let path = call.args["path"] as? String ?? ""
            messages.append(ChatMessage(role: .tool, text: path, toolName: "read_file"))
            do {
                var content = try String(contentsOf: resolve(path), encoding: .utf8)
                if content.count > maxToolOutputChars {
                    content = String(content.prefix(maxToolOutputChars)) + "\n…[truncated]"
                }
                return ["content": content]
            } catch {
                return ["error": error.localizedDescription]
            }

        case "preview_html":
            let path = call.args["path"] as? String ?? ""
            messages.append(ChatMessage(role: .tool, text: path, toolName: "preview_html"))
            let url = resolve(path)
            previewHandler?(url)
            return ["ok": true, "previewing": url.path]

        default:
            return ["error": "Unknown tool \(call.name)"]
        }
    }

    /// Resolve a possibly-relative path against the host's working directory.
    private func resolve(_ path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        let base = host?.agentWorkingDirectory ?? FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: base).appendingPathComponent(path)
    }
}
