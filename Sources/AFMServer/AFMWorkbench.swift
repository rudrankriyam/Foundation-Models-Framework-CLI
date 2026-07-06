import Darwin
import Foundation
import FoundationModelsKit
import NIOHTTP1

public struct AFMWorkbenchConfiguration: Sendable, Equatable {
    public var traceDirectory: String
    public var bridgeDirectory: String

    public init(
        traceDirectory: String = Self.defaultTraceDirectory,
        bridgeDirectory: String = Self.defaultBridgeDirectory
    ) {
        self.traceDirectory = traceDirectory
        self.bridgeDirectory = bridgeDirectory
    }

    public static var defaultTraceDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".afm/traces")
    }

    public static var defaultBridgeDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".afm/bridge")
    }
}

struct AFMWorkbench: Sendable {
    let configuration: AFMWorkbenchConfiguration
    private let traceStore: AFMWorkbenchTraceStore

    init(configuration: AFMWorkbenchConfiguration) {
        self.configuration = configuration
        traceStore = AFMWorkbenchTraceStore(directoryPath: configuration.traceDirectory)
    }

    func indexResponse() -> AFMHTTPResponse {
        .html(AFMWorkbenchHTML.document)
    }

    func statusResponse(catalog: any AFMModelCatalog) -> AFMHTTPResponse {
        .json(
            body: AFMWorkbenchStatusPayload(
                directModels: catalog.models().sorted { $0.id < $1.id }.map(AFMWorkbenchDirectModel.init),
                runtimeModels: FoundationModelRuntimeInspectionUseCase().execute()
                    .map(AFMWorkbenchRuntimeModel.init),
                quotaModels: FoundationModelQuotaUsageInspectionUseCase().execute(runtimes: [.privateCloudCompute])
                    .map(AFMWorkbenchQuotaModel.init),
                bridge: bridgeStatus(),
                traceDirectory: configuration.traceDirectory
            )
        )
    }

    func snippetsResponse() -> AFMHTTPResponse {
        .json(body: AFMWorkbenchSnippetsPayload.default)
    }

    func tracesResponse() -> AFMHTTPResponse {
        .json(body: AFMWorkbenchTracesPayload(traces: traceStore.list(limit: 40)))
    }

    func writeChatResponse(
        body: Data,
        chatCompletions: AFMChatCompletionService?,
        emitting emission: @escaping @Sendable (AFMHTTPEmission) async throws -> Void
    ) async throws {
        let startedAt = Date()
        let request: AFMWorkbenchChatRequest
        do {
            request = try JSONDecoder().decode(AFMWorkbenchChatRequest.self, from: body)
            try request.validate()
        } catch {
            try await emission(.fixed(.apiError(
                status: .badRequest,
                message: "The workbench request body is invalid.",
                code: "invalid_workbench_request"
            )))
            return
        }

        let upstreamBody = try JSONEncoder().encode(request.upstreamRequest)
        do {
            let result = try await performChat(
                request: request,
                upstreamBody: upstreamBody,
                chatCompletions: chatCompletions,
                startedAt: startedAt
            )
            try await emission(.fixed(.json(body: result.payload)))
        } catch {
            let trace = AFMWorkbenchTrace(
                id: UUID().uuidString,
                createdAt: startedAt,
                route: request.resolvedRoute.rawValue,
                model: request.model,
                prompt: request.prompt,
                durationMilliseconds: milliseconds(since: startedAt),
                statusCode: 500,
                response: nil,
                finishReason: nil,
                tokenUsage: nil,
                requestJSON: prettyJSON(upstreamBody),
                responseJSON: nil,
                error: error.localizedDescription
            )
            traceStore.save(trace)
            try await emission(.fixed(.apiError(
                status: .internalServerError,
                message: error.localizedDescription,
                code: "workbench_chat_failed",
                type: "server_error"
            )))
        }
    }

    private func performChat(
        request: AFMWorkbenchChatRequest,
        upstreamBody: Data,
        chatCompletions: AFMChatCompletionService?,
        startedAt: Date
    ) async throws -> AFMWorkbenchChatResult {
        let response: AFMHTTPResponse
        switch request.resolvedRoute {
        case .direct:
            guard let chatCompletions else {
                throw AFMWorkbenchError.directChatUnavailable
            }
            response = try await chatCompletions.response(for: upstreamBody)
        case .bridge:
            let store = try AFMBridgeDescriptorStore(directoryPath: configuration.bridgeDirectory)
            let client = try AFMBridgeClient(descriptorStore: store)
            let bridgeResponse = try await client.chatCompletions(body: upstreamBody)
            response = AFMHTTPResponse(
                status: HTTPResponseStatus(statusCode: bridgeResponse.statusCode),
                body: bridgeResponse.body
            )
        }

        let parsed = AFMWorkbenchParsedChatResponse(data: response.body)
        let trace = AFMWorkbenchTrace(
            id: UUID().uuidString,
            createdAt: startedAt,
            route: request.resolvedRoute.rawValue,
            model: request.model,
            prompt: request.prompt,
            durationMilliseconds: milliseconds(since: startedAt),
            statusCode: Int(response.status.code),
            response: parsed.response,
            finishReason: parsed.finishReason,
            tokenUsage: parsed.tokenUsageJSON,
            requestJSON: prettyJSON(upstreamBody),
            responseJSON: prettyJSON(response.body),
            error: response.status.code >= 400 ? parsed.errorMessage : nil
        )
        traceStore.save(trace)
        return AFMWorkbenchChatResult(payload: .init(trace: trace), status: response.status)
    }

    private func bridgeStatus() -> AFMWorkbenchBridgeStatus {
        let descriptorPath = (configuration.bridgeDirectory as NSString)
            .appendingPathComponent(AFMBridgeDescriptorStore.defaultFileName)
        do {
            let store = try AFMBridgeDescriptorStore(directoryPath: configuration.bridgeDirectory)
            let descriptor = try store.read()
            return AFMWorkbenchBridgeStatus(
                status: processIsRunning(descriptor.processIdentifier) ? "running" : "stale",
                descriptorPath: descriptorPath,
                endpoint: displayString(for: descriptor.endpoint),
                processIdentifier: descriptor.processIdentifier,
                launchIdentifier: descriptor.launchIdentifier.uuidString,
                models: descriptor.modelIdentifiers.sorted().map {
                    AFMWorkbenchBridgeModel(id: $0, available: true)
                },
                startedAt: descriptor.startedAt,
                error: nil
            )
        } catch {
            return AFMWorkbenchBridgeStatus(
                status: "missing",
                descriptorPath: descriptorPath,
                endpoint: nil,
                processIdentifier: nil,
                launchIdentifier: nil,
                models: [],
                startedAt: nil,
                error: error.localizedDescription
            )
        }
    }
}

private enum AFMWorkbenchError: LocalizedError {
    case directChatUnavailable

    var errorDescription: String? {
        switch self {
        case .directChatUnavailable:
            "Direct chat completions are not configured for this server."
        }
    }
}

private func processIsRunning(_ processIdentifier: Int32) -> Bool {
    guard processIdentifier > 0 else { return false }
    if Darwin.kill(processIdentifier, 0) == 0 { return true }
    return errno == EPERM
}

private func displayString(for endpoint: AFMBridgeEndpoint) -> String {
    switch endpoint {
    case .unixSocket(let path):
        "unix:\(path)"
    case .loopbackTCP(let host, let port):
        "http://\(host):\(port)"
    }
}

private func milliseconds(since date: Date) -> Int {
    Int((Date().timeIntervalSince(date) * 1_000).rounded())
}

private func prettyJSON(_ data: Data) -> String {
    guard let object = try? JSONSerialization.jsonObject(with: data),
          let prettyData = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
          ),
          let string = String(data: prettyData, encoding: .utf8) else {
        return String(data: data, encoding: .utf8) ?? ""
    }
    return string
}

private struct AFMWorkbenchStatusPayload: Encodable {
    let command = "workbench status"
    let directModels: [AFMWorkbenchDirectModel]
    let runtimeModels: [AFMWorkbenchRuntimeModel]
    let quotaModels: [AFMWorkbenchQuotaModel]
    let bridge: AFMWorkbenchBridgeStatus
    let traceDirectory: String
}

private struct AFMWorkbenchDirectModel: Encodable {
    let id: String
    let available: Bool
    let owner: String

    init(_ model: AFMServerModel) {
        id = model.id
        available = model.isAvailable
        owner = model.owner
    }
}

private struct AFMWorkbenchRuntimeModel: Encodable {
    let id: String
    let runtime: FoundationModelRuntime
    let isSupported: Bool
    let isAvailable: Bool
    let isRunnableInCurrentProcess: Bool
    let authorization: FoundationModelRuntimeAuthorization
    let reason: FoundationModelRuntimeUnavailableReason?

    init(_ status: FoundationModelRuntimeStatus) {
        id = status.runtime == .onDevice ? "system" : "pcc"
        runtime = status.runtime
        isSupported = status.isSupported
        isAvailable = status.isAvailable
        isRunnableInCurrentProcess = status.isRunnableInCurrentProcess
        authorization = status.authorization
        reason = status.reason
    }
}

private struct AFMWorkbenchQuotaModel: Encodable {
    let id: String
    let runtime: FoundationModelRuntime
    let status: FoundationModelQuotaStatus
    let resetDate: Date?
    let canRequestLimitIncrease: Bool
    let unavailableReason: FoundationModelRuntimeUnavailableReason?

    init(_ quota: FoundationModelQuotaUsage) {
        id = quota.runtime == .onDevice ? "system" : "pcc"
        runtime = quota.runtime
        status = quota.status
        resetDate = quota.resetDate
        canRequestLimitIncrease = quota.canRequestLimitIncrease
        unavailableReason = quota.unavailableReason
    }
}

private struct AFMWorkbenchBridgeStatus: Encodable {
    let status: String
    let descriptorPath: String
    let endpoint: String?
    let processIdentifier: Int32?
    let launchIdentifier: String?
    let models: [AFMWorkbenchBridgeModel]
    let startedAt: Date?
    let error: String?
}

private struct AFMWorkbenchBridgeModel: Encodable {
    let id: String
    let available: Bool
}

private enum AFMWorkbenchRoute: String, Codable {
    case direct
    case bridge
}

private struct AFMWorkbenchChatRequest: Decodable {
    let route: AFMWorkbenchRoute?
    let model: String
    let prompt: String
    let temperature: Double?
    let topP: Double?
    let maximumCompletionTokens: Int?

    var resolvedRoute: AFMWorkbenchRoute {
        route ?? (model == "pcc" ? .bridge : .direct)
    }

    var upstreamRequest: AFMWorkbenchUpstreamChatRequest {
        AFMWorkbenchUpstreamChatRequest(
            model: model,
            messages: [.init(role: "user", content: prompt)],
            temperature: temperature,
            topP: topP,
            maximumCompletionTokens: maximumCompletionTokens
        )
    }

    private enum CodingKeys: String, CodingKey {
        case route
        case model
        case prompt
        case temperature
        case topP = "top_p"
        case maximumCompletionTokens = "max_completion_tokens"
    }

    func validate() throws {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AFMWorkbenchValidationError.emptyModel
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AFMWorkbenchValidationError.emptyPrompt
        }
        if let temperature, !temperature.isFinite || !(0...1).contains(temperature) {
            throw AFMWorkbenchValidationError.invalidTemperature
        }
        if let topP, !topP.isFinite || topP <= 0 || topP > 1 {
            throw AFMWorkbenchValidationError.invalidTopP
        }
        if let maximumCompletionTokens, maximumCompletionTokens <= 0 {
            throw AFMWorkbenchValidationError.invalidTokenLimit
        }
    }
}

private enum AFMWorkbenchValidationError: Error {
    case emptyModel
    case emptyPrompt
    case invalidTemperature
    case invalidTopP
    case invalidTokenLimit
}

private struct AFMWorkbenchUpstreamChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double?
    let topP: Double?
    let maximumCompletionTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case topP = "top_p"
        case maximumCompletionTokens = "max_completion_tokens"
    }
}

private struct AFMWorkbenchChatResult {
    let payload: AFMWorkbenchChatPayload
    let status: HTTPResponseStatus
}

private struct AFMWorkbenchChatPayload: Encodable {
    let command = "workbench chat"
    let traceID: String
    let route: String
    let model: String
    let response: String?
    let finishReason: String?
    let tokenUsage: String?
    let durationMilliseconds: Int
    let requestJSON: String
    let responseJSON: String?

    init(trace: AFMWorkbenchTrace) {
        traceID = trace.id
        route = trace.route
        model = trace.model
        response = trace.response
        finishReason = trace.finishReason
        tokenUsage = trace.tokenUsage
        durationMilliseconds = trace.durationMilliseconds
        requestJSON = trace.requestJSON
        responseJSON = trace.responseJSON
    }
}

private struct AFMWorkbenchParsedChatResponse {
    let response: String?
    let finishReason: String?
    let tokenUsageJSON: String?
    let errorMessage: String?

    init(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            response = String(data: data, encoding: .utf8)
            finishReason = nil
            tokenUsageJSON = nil
            errorMessage = nil
            return
        }

        let choices = object["choices"] as? [[String: Any]]
        let choice = choices?.sorted {
            ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0)
        }.first
        let message = choice?["message"] as? [String: Any]
        response = (message?["content"] as? String) ?? (message?["refusal"] as? String)
        finishReason = choice?["finish_reason"] as? String

        if let usage = object["usage"],
           JSONSerialization.isValidJSONObject(usage),
           let usageData = try? JSONSerialization.data(
            withJSONObject: usage,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
           ) {
            tokenUsageJSON = String(data: usageData, encoding: .utf8)
        } else {
            tokenUsageJSON = nil
        }

        if let error = object["error"] as? [String: Any] {
            errorMessage = error["message"] as? String
        } else {
            errorMessage = nil
        }
    }
}

private struct AFMWorkbenchTrace: Codable {
    let id: String
    let createdAt: Date
    let route: String
    let model: String
    let prompt: String
    let durationMilliseconds: Int
    let statusCode: Int
    let response: String?
    let finishReason: String?
    let tokenUsage: String?
    let requestJSON: String
    let responseJSON: String?
    let error: String?

    var summary: AFMWorkbenchTraceSummary {
        AFMWorkbenchTraceSummary(
            id: id,
            createdAt: createdAt,
            route: route,
            model: model,
            prompt: prompt,
            durationMilliseconds: durationMilliseconds,
            statusCode: statusCode,
            responsePreview: response?.prefixString(maxLength: 180),
            finishReason: finishReason,
            hasError: error != nil
        )
    }
}

private struct AFMWorkbenchTraceSummary: Codable {
    let id: String
    let createdAt: Date
    let route: String
    let model: String
    let prompt: String
    let durationMilliseconds: Int
    let statusCode: Int
    let responsePreview: String?
    let finishReason: String?
    let hasError: Bool
}

private struct AFMWorkbenchTracesPayload: Encodable {
    let command = "workbench traces"
    let traces: [AFMWorkbenchTraceSummary]
}

private final class AFMWorkbenchTraceStore: @unchecked Sendable {
    private let directoryPath: String
    private let lock = NSLock()

    init(directoryPath: String) {
        self.directoryPath = directoryPath
    }

    func save(_ trace: AFMWorkbenchTrace) {
        lock.withLock {
            do {
                try prepareDirectory()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(trace)
                let path = (directoryPath as NSString).appendingPathComponent("\(trace.id).json")
                FileManager.default.createFile(atPath: path, contents: data)
                Darwin.chmod(path, 0o600)
            } catch {
                // Trace persistence should never break a model response.
            }
        }
    }

    func list(limit: Int) -> [AFMWorkbenchTraceSummary] {
        lock.withLock {
            do {
                try prepareDirectory()
                let urls = try FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: directoryPath),
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
                let traces = urls
                    .filter { $0.pathExtension == "json" }
                    .compactMap(decodeTrace)
                    .sorted { $0.createdAt > $1.createdAt }
                    .prefix(limit)
                return traces.map(\.summary)
            } catch {
                return []
            }
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            atPath: directoryPath,
            withIntermediateDirectories: true
        )
        Darwin.chmod(directoryPath, 0o700)
    }

    private func decodeTrace(_ url: URL) -> AFMWorkbenchTrace? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AFMWorkbenchTrace.self, from: data)
    }
}

private extension NSLock {
    func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try operation()
    }
}

private extension StringProtocol {
    func prefixString(maxLength: Int) -> String {
        guard count > maxLength else { return String(self) }
        return String(prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}

private struct AFMWorkbenchSnippetsPayload: Encodable {
    struct Snippet: Encodable {
        let id: String
        let title: String
        let language: String
        let code: String
    }

    let command = "workbench snippets"
    let snippets: [Snippet]

    static let `default` = AFMWorkbenchSnippetsPayload(snippets: [
        .init(
            id: "curl-status",
            title: "Status",
            language: "bash",
            code: "curl -s \"$AFM_ORIGIN/api/workbench/status\" | jq ."
        ),
        .init(
            id: "curl-pcc",
            title: "PCC via bridge",
            language: "bash",
            code: """
            curl -s "$AFM_ORIGIN/api/workbench/chat" \\
              -H 'content-type: application/json' \\
              -d '{"route":"bridge","model":"pcc","prompt":"Summarize this repository."}' | jq .
            """
        ),
        .init(
            id: "codex-walkthrough",
            title: "Codex walkthrough",
            language: "text",
            code: """
            Open $AFM_ORIGIN in the in-app browser, inspect status, run one system prompt and one PCC prompt, then summarize the saved trace evidence.
            """
        ),
        .init(
            id: "js-fetch",
            title: "Fetch",
            language: "javascript",
            code: """
            const response = await fetch(`${location.origin}/api/workbench/chat`, {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ route: "bridge", model: "pcc", prompt: "Reply with one sentence." })
            });
            console.log(await response.json());
            """
        )
    ])
}

private enum AFMWorkbenchHTML {
    static let document = #"""
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>AFM Workbench</title>
      <style>
        :root {
          color-scheme: light dark;
          --bg: #f7f8fa;
          --panel: rgba(255,255,255,.86);
          --panel-strong: rgba(255,255,255,.96);
          --text: #121417;
          --muted: #66707c;
          --line: rgba(20,25,31,.12);
          --accent: #0a84ff;
          --good: #1f9d55;
          --warn: #b7791f;
          --bad: #c2410c;
          --code: #0d1117;
          --codeText: #d6e2ff;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #111315;
            --panel: rgba(30,32,36,.78);
            --panel-strong: rgba(35,38,42,.94);
            --text: #f4f7fb;
            --muted: #9aa6b2;
            --line: rgba(230,237,245,.13);
            --code: #080a0d;
            --codeText: #dbe8ff;
          }
        }
        * { box-sizing: border-box; }
        body {
          margin: 0;
          min-height: 100svh;
          background:
            radial-gradient(circle at 20% 0%, rgba(10,132,255,.14), transparent 34rem),
            linear-gradient(135deg, rgba(255,255,255,.52), transparent 40%),
            var(--bg);
          color: var(--text);
          font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
          letter-spacing: 0;
        }
        button, input, textarea, select { font: inherit; }
        .shell {
          min-height: 100svh;
          display: grid;
          grid-template-rows: auto 1fr;
        }
        header {
          height: 68px;
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 20px;
          padding: 0 24px;
          border-bottom: 1px solid var(--line);
          backdrop-filter: blur(20px);
          background: color-mix(in srgb, var(--bg) 82%, transparent);
        }
        .brand {
          display: flex;
          align-items: center;
          gap: 12px;
          min-width: 0;
        }
        .mark {
          width: 34px;
          height: 34px;
          display: grid;
          place-items: center;
          border-radius: 8px;
          background: var(--text);
          color: var(--bg);
          font-weight: 740;
        }
        h1 {
          margin: 0;
          font-size: 18px;
          line-height: 1.1;
        }
        .sub {
          margin-top: 2px;
          color: var(--muted);
          font-size: 12px;
        }
        .top-actions {
          display: flex;
          align-items: center;
          gap: 10px;
        }
        .status-pill {
          display: inline-flex;
          align-items: center;
          gap: 8px;
          min-height: 32px;
          padding: 0 11px;
          border: 1px solid var(--line);
          border-radius: 999px;
          background: var(--panel);
          color: var(--muted);
          font-size: 12px;
          white-space: nowrap;
        }
        .dot {
          width: 8px;
          height: 8px;
          border-radius: 50%;
          background: var(--muted);
        }
        .dot.good { background: var(--good); }
        .dot.warn { background: var(--warn); }
        .dot.bad { background: var(--bad); }
        main {
          display: grid;
          grid-template-columns: 280px minmax(420px, 1fr) 340px;
          gap: 1px;
          min-height: 0;
          background: var(--line);
        }
        aside, section {
          min-width: 0;
          min-height: 0;
          background: color-mix(in srgb, var(--bg) 94%, transparent);
        }
        .sidebar, .inspector {
          padding: 20px;
          overflow: auto;
        }
        .workspace {
          padding: 22px;
          overflow: auto;
          background:
            linear-gradient(180deg, color-mix(in srgb, var(--bg) 96%, transparent), var(--bg));
        }
        .label {
          margin: 0 0 10px;
          color: var(--muted);
          font-size: 11px;
          font-weight: 700;
          letter-spacing: .06em;
          text-transform: uppercase;
        }
        .row {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 12px;
          min-height: 38px;
          border-top: 1px solid var(--line);
        }
        .row:first-of-type { border-top: 0; }
        .row span:first-child { color: var(--muted); font-size: 13px; }
        .row strong { font-size: 13px; font-weight: 650; text-align: right; }
        .block {
          margin-bottom: 24px;
        }
        .model-strip {
          display: flex;
          flex-wrap: wrap;
          gap: 8px;
        }
        .model-option {
          min-height: 34px;
          padding: 0 11px;
          border: 1px solid var(--line);
          border-radius: 8px;
          background: var(--panel);
          color: var(--text);
          cursor: pointer;
        }
        .model-option.active {
          border-color: color-mix(in srgb, var(--accent) 72%, var(--line));
          box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent) 18%, transparent);
        }
        textarea {
          width: 100%;
          min-height: 170px;
          resize: vertical;
          padding: 16px;
          border: 1px solid var(--line);
          border-radius: 8px;
          outline: none;
          background: var(--panel-strong);
          color: var(--text);
          line-height: 1.45;
        }
        textarea:focus {
          border-color: color-mix(in srgb, var(--accent) 72%, var(--line));
          box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent) 18%, transparent);
        }
        .runbar {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 12px;
          margin-top: 12px;
        }
        .primary, .secondary, .copy {
          min-height: 36px;
          border: 1px solid var(--line);
          border-radius: 8px;
          padding: 0 13px;
          cursor: pointer;
          background: var(--panel);
          color: var(--text);
        }
        .primary {
          border-color: var(--accent);
          background: var(--accent);
          color: white;
          font-weight: 700;
        }
        .primary:disabled { opacity: .58; cursor: default; }
        .response {
          margin-top: 22px;
          padding: 18px;
          min-height: 170px;
          border: 1px solid var(--line);
          border-radius: 8px;
          background: var(--panel-strong);
          white-space: pre-wrap;
          line-height: 1.55;
        }
        .meta-grid {
          margin-top: 12px;
          display: grid;
          grid-template-columns: repeat(3, minmax(0, 1fr));
          gap: 1px;
          border: 1px solid var(--line);
          border-radius: 8px;
          overflow: hidden;
          background: var(--line);
        }
        .metric {
          padding: 12px;
          background: var(--panel);
          min-width: 0;
        }
        .metric div { color: var(--muted); font-size: 11px; margin-bottom: 5px; }
        .metric strong { display: block; overflow-wrap: anywhere; font-size: 13px; }
        pre {
          margin: 0;
          padding: 14px;
          border-radius: 8px;
          overflow: auto;
          background: var(--code);
          color: var(--codeText);
          font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
        }
        .snippet {
          margin-bottom: 12px;
        }
        .snippet-head {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 10px;
          margin-bottom: 8px;
        }
        .snippet h3, .trace h3 {
          margin: 0;
          font-size: 13px;
        }
        .copy {
          min-height: 30px;
          font-size: 12px;
        }
        .trace {
          width: 100%;
          text-align: left;
          border: 1px solid var(--line);
          border-radius: 8px;
          padding: 12px;
          margin-bottom: 10px;
          background: var(--panel);
          color: var(--text);
          cursor: pointer;
        }
        .trace p {
          margin: 6px 0 0;
          color: var(--muted);
          font-size: 12px;
          line-height: 1.35;
        }
        .trace small {
          display: block;
          margin-top: 8px;
          color: var(--muted);
        }
        .fade-in {
          animation: fadeIn .28s ease both;
        }
        @keyframes fadeIn {
          from { opacity: 0; transform: translateY(5px); }
          to { opacity: 1; transform: translateY(0); }
        }
        @media (max-width: 1080px) {
          main { grid-template-columns: 240px minmax(0, 1fr); }
          .inspector { grid-column: 1 / -1; border-top: 1px solid var(--line); }
        }
        @media (max-width: 760px) {
          header { height: auto; align-items: flex-start; padding: 16px; flex-direction: column; }
          main { display: block; }
          .sidebar, .workspace, .inspector { padding: 16px; }
          .meta-grid { grid-template-columns: 1fr; }
          .runbar { align-items: stretch; flex-direction: column; }
        }
      </style>
    </head>
    <body>
      <div class="shell">
        <header>
          <div class="brand">
            <div class="mark">afm</div>
            <div>
              <h1>AFM Workbench</h1>
              <div class="sub">Local Foundation Models control plane</div>
            </div>
          </div>
          <div class="top-actions">
            <div class="status-pill"><span id="bridgeDot" class="dot"></span><span id="bridgeLabel">Bridge</span></div>
            <button id="refresh" class="secondary">Refresh</button>
          </div>
        </header>
        <main>
          <aside class="sidebar">
            <div class="block">
              <p class="label">Runtime</p>
              <div id="runtimeRows"></div>
            </div>
            <div class="block">
              <p class="label">Bridge</p>
              <div id="bridgeRows"></div>
            </div>
            <div class="block">
              <p class="label">Models</p>
              <div id="models" class="model-strip"></div>
            </div>
          </aside>
          <section class="workspace">
            <p class="label">Prompt</p>
            <textarea id="prompt">Reply with one precise sentence about why the signed bridge matters for PCC.</textarea>
            <div class="runbar">
              <div class="status-pill"><span id="routeDot" class="dot"></span><span id="routeLabel">No model selected</span></div>
              <button id="run" class="primary">Run</button>
            </div>
            <div id="response" class="response fade-in">Ready.</div>
            <div class="meta-grid">
              <div class="metric"><div>Trace</div><strong id="traceID">-</strong></div>
              <div class="metric"><div>Duration</div><strong id="duration">-</strong></div>
              <div class="metric"><div>Finish</div><strong id="finish">-</strong></div>
            </div>
          </section>
          <aside class="inspector">
            <div class="block">
              <p class="label">Snippets</p>
              <div id="snippets"></div>
            </div>
            <div class="block">
              <p class="label">Traces</p>
              <div id="traces"></div>
            </div>
          </aside>
        </main>
      </div>
      <script>
        const state = { status: null, selected: null, snippets: [] };
        const $ = (id) => document.getElementById(id);
        const originToken = () => location.origin;

        async function json(path, options) {
          const response = await fetch(path, options);
          const payload = await response.json();
          if (!response.ok) throw new Error(payload?.error?.message || response.statusText);
          return payload;
        }

        function row(label, value) {
          return `<div class="row"><span>${escapeHTML(label)}</span><strong>${escapeHTML(value ?? "-")}</strong></div>`;
        }

        function escapeHTML(value) {
          return String(value).replace(/[&<>"']/g, (char) => ({
            "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
          }[char]));
        }

        function setBridge(status) {
          const bridge = status.bridge;
          $("bridgeLabel").textContent = bridge.status === "running" ? "Bridge running" : "Bridge " + bridge.status;
          $("bridgeDot").className = "dot " + (bridge.status === "running" ? "good" : bridge.status === "stale" ? "warn" : "bad");
          $("bridgeRows").innerHTML = [
            row("Status", bridge.status),
            row("Endpoint", bridge.endpoint || "-"),
            row("Models", bridge.models.map((model) => model.id).join(", ") || "-"),
            row("Trace dir", status.traceDirectory)
          ].join("");
        }

        function setRuntime(status) {
          const pcc = status.runtimeModels.find((model) => model.id === "pcc");
          const system = status.runtimeModels.find((model) => model.id === "system");
          const quota = status.quotaModels.find((model) => model.id === "pcc");
          $("runtimeRows").innerHTML = [
            row("System", system?.isRunnableInCurrentProcess ? "runnable" : system?.reason || "unknown"),
            row("PCC", pcc?.isRunnableInCurrentProcess ? "runnable" : pcc?.reason || "unknown"),
            row("Quota", quota?.status || "-")
          ].join("");
        }

        function modelButton(route, id, available) {
          const active = state.selected?.route === route && state.selected?.model === id;
          return `<button class="model-option ${active ? "active" : ""}" data-route="${route}" data-model="${id}" ${available ? "" : "disabled"}>${escapeHTML(route)}:${escapeHTML(id)}</button>`;
        }

        function setModels(status) {
          const direct = status.directModels.map((model) => modelButton("direct", model.id, model.available));
          const bridge = status.bridge.models.map((model) => modelButton("bridge", model.id, model.available));
          $("models").innerHTML = [...direct, ...bridge].join("");
          $("models").querySelectorAll("button").forEach((button) => {
            button.addEventListener("click", () => {
              state.selected = { route: button.dataset.route, model: button.dataset.model };
              render();
            });
          });
          if (!state.selected) {
            const preferred = status.bridge.models.find((model) => model.id === "pcc")
              ? { route: "bridge", model: "pcc" }
              : { route: "direct", model: "system" };
            state.selected = preferred;
            render();
          }
        }

        function setRoute() {
          if (!state.selected) return;
          $("routeLabel").textContent = `${state.selected.route}:${state.selected.model}`;
          $("routeDot").className = "dot " + (state.selected.route === "bridge" ? "good" : "warn");
        }

        function renderSnippets() {
          $("snippets").innerHTML = state.snippets.map((snippet) => {
            const code = snippet.code.replaceAll("$AFM_ORIGIN", originToken());
            return `<div class="snippet">
              <div class="snippet-head"><h3>${escapeHTML(snippet.title)}</h3><button class="copy" data-copy="${escapeHTML(code)}">Copy</button></div>
              <pre>${escapeHTML(code)}</pre>
            </div>`;
          }).join("");
          $("snippets").querySelectorAll("[data-copy]").forEach((button) => {
            button.addEventListener("click", async () => {
              await navigator.clipboard.writeText(button.dataset.copy);
              button.textContent = "Copied";
              setTimeout(() => { button.textContent = "Copy"; }, 900);
            });
          });
        }

        function renderTraces(traces) {
          $("traces").innerHTML = traces.length ? traces.map((trace) => `
            <button class="trace">
              <h3>${escapeHTML(trace.route)}:${escapeHTML(trace.model)}</h3>
              <p>${escapeHTML(trace.prompt)}</p>
              <small>${new Date(trace.createdAt).toLocaleTimeString()} · ${trace.durationMilliseconds} ms · ${trace.statusCode}</small>
            </button>
          `).join("") : `<div class="sub">No traces yet.</div>`;
        }

        function render() {
          if (!state.status) return;
          setBridge(state.status);
          setRuntime(state.status);
          setModels(state.status);
          setRoute();
        }

        async function refresh() {
          const [status, snippets, traces] = await Promise.all([
            json("/api/workbench/status"),
            json("/api/workbench/snippets"),
            json("/api/workbench/traces")
          ]);
          state.status = status;
          state.snippets = snippets.snippets;
          render();
          renderSnippets();
          renderTraces(traces.traces);
        }

        async function runPrompt() {
          if (!state.selected) return;
          $("run").disabled = true;
          $("response").textContent = "Running on " + state.selected.route + ":" + state.selected.model + "...";
          try {
            const payload = await json("/api/workbench/chat", {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({
                route: state.selected.route,
                model: state.selected.model,
                prompt: $("prompt").value
              })
            });
            $("response").textContent = payload.response || payload.responseJSON || "Done.";
            $("traceID").textContent = payload.traceID;
            $("duration").textContent = payload.durationMilliseconds + " ms";
            $("finish").textContent = payload.finishReason || "-";
            await refresh();
          } catch (error) {
            $("response").textContent = error.message;
          } finally {
            $("run").disabled = false;
          }
        }

        $("refresh").addEventListener("click", refresh);
        $("run").addEventListener("click", runPrompt);
        refresh().catch((error) => { $("response").textContent = error.message; });
      </script>
    </body>
    </html>
    """#
}
