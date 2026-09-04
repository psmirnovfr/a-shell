//
//  GeminiService.swift
//  a-Shell — Agentic layer
//
//  Stateless client for the Google Gemini `generateContent` REST API with
//  function calling. The conversation itself is owned by AgentViewModel; this
//  type only knows how to build a request from a history + tool set and parse
//  the model's reply.
//
//  Docs: https://ai.google.dev/gemini-api/docs/function-calling
//        https://ai.google.dev/gemini-api/docs/text-generation
//
//  We deliberately use dictionary / JSONSerialization based encoding rather than
//  Codable so that arbitrary JSON-Schema tool declarations and arbitrary tool
//  argument objects round-trip without bespoke Codable types.
//

import Foundation

/// A tool (function) the model is allowed to call.
struct GeminiTool {
    let name: String
    let description: String
    /// JSON-Schema object describing the parameters, e.g.
    /// ["type": "object", "properties": [...], "required": [...]]
    let parameters: [String: Any]

    var declarationJSON: [String: Any] {
        [
            "name": name,
            "description": description,
            "parameters": parameters,
        ]
    }
}

/// A function call requested by the model.
struct GeminiFunctionCall {
    /// Gemini 3.x returns an id; it must be echoed back in the functionResponse.
    let id: String?
    let name: String
    let args: [String: Any]
}

/// The parsed result of one `generateContent` turn.
struct GeminiResult {
    var text: String?
    var functionCalls: [GeminiFunctionCall] = []
    var finishReason: String?
    /// The raw `content` object of the candidate, to be appended verbatim to the
    /// history as the model turn (preserves parts/order for the next request).
    var rawModelContent: [String: Any]?
}

enum GeminiError: LocalizedError {
    case missingAPIKey
    case badResponse(status: Int, body: String)
    case malformedResponse(String)
    case blocked(reason: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Gemini API key set. Add one in the chat settings."
        case .badResponse(let status, let body):
            return "Gemini API error \(status): \(body)"
        case .malformedResponse(let detail):
            return "Could not parse Gemini response: \(detail)"
        case .blocked(let reason):
            return "Request blocked by Gemini: \(reason)"
        }
    }
}

/// Networking + (de)serialization for the Gemini API. Thread-safe and stateless.
struct GeminiService {
    let apiKey: String
    let model: String
    /// Optional thinking level for Gemini 3.x ("LOW" | "MEDIUM" | "HIGH").
    /// nil = do not send generationConfig.thinkingConfig at all.
    let thinkingLevel: String?
    var session: URLSession = .shared

    init(apiKey: String, model: String, thinkingLevel: String? = "LOW") {
        self.apiKey = apiKey
        self.model = model
        self.thinkingLevel = thinkingLevel
    }

    private var endpoint: URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
    }

    // MARK: - List available models

    /// Fetch the model IDs available to this API key that support generateContent.
    /// This is the authoritative "what's current" source — version strings change
    /// frequently, so we never hardcode "the newest".
    func listModels() async throws -> [String] {
        guard !apiKey.isEmpty else { throw GeminiError.missingAPIKey }
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw GeminiError.badResponse(status: status,
                                          body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            throw GeminiError.malformedResponse("no models array")
        }
        var ids: [String] = []
        for m in models {
            let methods = m["supportedGenerationMethods"] as? [String] ?? []
            guard methods.contains("generateContent") else { continue }
            if let name = m["name"] as? String {
                // API returns "models/gemini-…"; strip the prefix for the request path.
                ids.append(name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name)
            }
        }
        return ids.sorted()
    }

    // MARK: - History builders
    //
    // `contents` is an array of Gemini "content" dictionaries. Callers keep this
    // array and grow it across turns. Helpers below build the individual entries.

    static func userText(_ text: String) -> [String: Any] {
        ["role": "user", "parts": [["text": text]]]
    }

    /// A functionResponse turn (role must be "user" per the API). Gemini 3.x
    /// requires both `name` and `id` (call_id) to be present.
    static func functionResponse(name: String, id: String?, response: [String: Any]) -> [String: Any] {
        var fr: [String: Any] = ["name": name, "response": response]
        if let id = id { fr["id"] = id }
        return ["role": "user", "parts": [["functionResponse": fr]]]
    }

    // MARK: - Request

    /// Perform one generateContent turn.
    /// - Parameters:
    ///   - systemInstruction: system prompt text.
    ///   - contents: the running conversation history (see builders above).
    ///   - tools: the function declarations the model may call.
    func generate(systemInstruction: String?,
                  contents: [[String: Any]],
                  tools: [GeminiTool]) async throws -> GeminiResult {
        guard !apiKey.isEmpty else { throw GeminiError.missingAPIKey }

        var body: [String: Any] = ["contents": contents]

        if let sys = systemInstruction, !sys.isEmpty {
            body["system_instruction"] = ["parts": [["text": sys]]]
        }
        if !tools.isEmpty {
            body["tools"] = [["functionDeclarations": tools.map { $0.declarationJSON }]]
        }
        if let level = thinkingLevel {
            body["generationConfig"] = ["thinkingConfig": ["thinkingLevel": level]]
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.malformedResponse("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "<binary>"
            throw GeminiError.badResponse(status: http.statusCode, body: text)
        }

        return try Self.parse(data: data)
    }

    // MARK: - Response parsing

    static func parse(data: Data) throws -> GeminiResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiError.malformedResponse("root is not an object")
        }

        if let feedback = root["promptFeedback"] as? [String: Any],
           let block = feedback["blockReason"] as? String {
            throw GeminiError.blocked(reason: block)
        }

        guard let candidates = root["candidates"] as? [[String: Any]],
              let first = candidates.first else {
            throw GeminiError.malformedResponse("no candidates")
        }

        var result = GeminiResult()
        result.finishReason = first["finishReason"] as? String

        guard let content = first["content"] as? [String: Any] else {
            // A finishReason with no content (e.g. SAFETY) — surface it.
            if let reason = result.finishReason {
                throw GeminiError.blocked(reason: reason)
            }
            throw GeminiError.malformedResponse("candidate has no content")
        }
        result.rawModelContent = content

        var collectedText = ""
        let parts = content["parts"] as? [[String: Any]] ?? []
        for part in parts {
            if let text = part["text"] as? String {
                collectedText += text
            }
            if let call = part["functionCall"] as? [String: Any],
               let name = call["name"] as? String {
                let args = call["args"] as? [String: Any] ?? [:]
                let id = call["id"] as? String
                result.functionCalls.append(GeminiFunctionCall(id: id, name: name, args: args))
            }
        }
        if !collectedText.isEmpty { result.text = collectedText }
        return result
    }
}
