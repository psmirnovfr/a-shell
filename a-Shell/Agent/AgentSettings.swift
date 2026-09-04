//
//  AgentSettings.swift
//  a-Shell — Agentic layer
//
//  Persisted configuration for the agent: Gemini API key (Keychain), model name,
//  and feature flags (UserDefaults). Kept tiny and dependency-free.
//

import Foundation
import Security

final class AgentSettings: ObservableObject {
    static let shared = AgentSettings()

    // Default to the newest flash-lite (see docs/AGENTIC.md). User-overridable.
    static let defaultModel = "gemini-3.1-flash-lite"

    private enum Keys {
        static let model = "agentModel"
        static let enabled = "agentModeEnabled"
        static let confirm = "agentConfirmCommands"
        static let thinking = "agentThinkingLevel"
    }

    // Keychain identifiers for the API key.
    private let keychainService = "AsheKube.app.a-Shell.gemini"
    private let keychainAccount = "geminiAPIKey"

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Keys.model: Self.defaultModel,
            Keys.enabled: false,
            Keys.confirm: false,
            Keys.thinking: "LOW",
        ])
    }

    // MARK: - Feature flag

    /// When true, `scene(_:willConnectTo:)` uses the 3-panel AgentView root.
    var agentModeEnabled: Bool {
        get { defaults.bool(forKey: Keys.enabled) }
        set { defaults.set(newValue, forKey: Keys.enabled); objectWillChange.send() }
    }

    /// When true, the UI asks before each `run_bash` call.
    @Published var confirmCommands: Bool = UserDefaults.standard.bool(forKey: Keys.confirm) {
        didSet { defaults.set(confirmCommands, forKey: Keys.confirm) }
    }

    // MARK: - Model

    var model: String {
        get { defaults.string(forKey: Keys.model) ?? Self.defaultModel }
        set { defaults.set(newValue, forKey: Keys.model); objectWillChange.send() }
    }

    /// nil disables thinking config; otherwise "LOW"|"MEDIUM"|"HIGH".
    var thinkingLevel: String? {
        get {
            let v = defaults.string(forKey: Keys.thinking) ?? "LOW"
            return v == "OFF" ? nil : v
        }
        set {
            defaults.set(newValue ?? "OFF", forKey: Keys.thinking)
            objectWillChange.send()
        }
    }

    // MARK: - API key (Keychain)

    var apiKey: String {
        get { readKeychain() ?? "" }
        set {
            if newValue.isEmpty { deleteKeychain() } else { writeKeychain(newValue) }
            objectWillChange.send()
        }
    }

    var hasAPIKey: Bool { !apiKey.isEmpty }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private func readKeychain() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeKeychain(_ value: String) {
        let data = Data(value.utf8)
        let query = baseQuery()
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private func deleteKeychain() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}
