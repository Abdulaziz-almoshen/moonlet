import Foundation
import MoonletBrain

/// Writes a few-word summary of an agent's final message with a model running
/// in Ollama on this Mac. Nothing leaves the machine. Without Ollama, or when
/// the model rambles or is too slow, it falls back to a plain trim.
actor LocalModel {
    /// Instruct models that answer directly. Reasoning models are skipped
    /// unless chosen explicitly, because they tend to think out loud.
    static let preferredModels = [
        "qwen2.5:7b", "qwen2.5:3b", "llama3.2:3b", "llama3.1:8b", "gemma3:4b", "gemma2:2b", "phi4-mini", "mistral",
    ]

    private let endpoint: URL
    private let session: URLSession
    /// The model chosen in settings, or nil to pick one automatically.
    private var configuredModel: String?
    private var resolvedModel: String?
    private var lastLookup = Date.distantPast

    init(endpoint: URL = URL(string: "http://127.0.0.1:11434")!, model: String? = nil) {
        self.endpoint = endpoint
        configuredModel = model
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        session = URLSession(configuration: configuration)
    }

    func setModel(_ model: String?) {
        configuredModel = model
        resolvedModel = nil
        lastLookup = .distantPast
    }

    /// Models installed in Ollama, or an empty list when it isn't running.
    func installedModels() async -> [String] {
        var request = URLRequest(url: endpoint.appendingPathComponent("api/tags"))
        request.timeoutInterval = 1
        guard let (data, _) = try? await session.data(for: request),
              let tags = try? JSONDecoder().decode(Tags.self, from: data) else { return [] }
        return tags.models.map(\.name)
    }

    /// The model Moonlet will use right now, if any.
    func activeModel() async -> String? {
        if let resolvedModel, Date().timeIntervalSince(lastLookup) < 300 { return resolvedModel }
        lastLookup = Date()
        let installed = await installedModels()
        if let configuredModel, installed.contains(configuredModel) {
            resolvedModel = configuredModel
        } else {
            resolvedModel = Self.preferredModels.first(where: installed.contains)
        }
        return resolvedModel
    }

    /// Loads the model into memory without generating anything.
    func warmUp() async {
        guard let model = await activeModel() else { return }
        var request = URLRequest(url: endpoint.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": "30m"])
        _ = try? await session.data(for: request)
    }

    /// A few words for a card. Always returns something.
    func summarize(_ finalMessage: String) async -> Summary {
        let fallback = SummaryWriter.fallback(for: finalMessage)
        guard !finalMessage.isEmpty, let model = await activeModel() else { return fallback }
        let body = ChatRequest(
            model: model,
            messages: [.init(role: "system", content: SummaryWriter.systemPrompt),
                       .init(role: "user", content: SummaryWriter.prompt(for: finalMessage))],
            options: .init(temperature: 0.1, num_predict: 32))
        var request = URLRequest(url: endpoint.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? JSONDecoder().decode(ChatResponse.self, from: data),
              var summary = SummaryWriter.parse(reply.message.content)
        else { return fallback }
        // The plain question check is precise; trust it when the model missed the question.
        if summary.kind == .outcome, fallback.kind == .question { summary = fallback }
        return summary
    }

    private struct Tags: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }

    private struct ChatRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        struct Options: Encodable { let temperature: Double; let num_predict: Int }
        let model: String
        let messages: [Message]
        let options: Options
        var stream = false
        var think = false
        var keep_alive = "30m"
    }

    private struct ChatResponse: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
}
