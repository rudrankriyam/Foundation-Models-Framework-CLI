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
            try await emission(.fixed(.json(status: result.status, body: result.payload)))
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
          --bg: #eef1f5;
          --pane: #f8f9fb;
          --pane-raised: #ffffff;
          --pane-muted: #f1f3f6;
          --ink: #171a1f;
          --muted: #59616d;
          --faint: #7a828d;
          --line: #d6dbe2;
          --line-strong: #b7c0ca;
          --accent: #0a84ff;
          --accent-soft: #e8f2ff;
          --good: #228b53;
          --warn: #9a6a11;
          --bad: #c43c24;
          --code: #101318;
          --code-ink: #e7edf7;
          --radius: 8px;
          --focus: 0 0 0 3px rgba(10, 132, 255, .22);
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #15181d;
            --pane: #1d2026;
            --pane-raised: #242831;
            --pane-muted: #20242b;
            --ink: #f2f5f8;
            --muted: #a8b0bb;
            --faint: #7f8996;
            --line: #333944;
            --line-strong: #48515f;
            --accent: #63a8ff;
            --accent-soft: #1e334d;
            --code: #0d1015;
            --code-ink: #e8eef8;
          }
        }
        * {
          box-sizing: border-box;
        }
        html {
          background: var(--bg);
        }
        body {
          margin: 0;
          height: 100svh;
          min-height: 100svh;
          overflow: hidden;
          background: var(--bg);
          color: var(--ink);
          font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
          letter-spacing: 0;
        }
        button, input, textarea, select {
          font: inherit;
        }
        button {
          color: inherit;
        }
        button:focus-visible,
        textarea:focus-visible {
          outline: none;
          box-shadow: var(--focus);
        }
        .shell {
          height: 100svh;
          display: grid;
          grid-template-rows: auto 1fr;
        }
        .topbar {
          height: 46px;
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 16px;
          padding: 0 14px;
          border-bottom: 1px solid var(--line);
          background: var(--pane-raised);
        }
        .brand {
          display: flex;
          align-items: center;
          gap: 9px;
          min-width: 0;
        }
        .mark {
          width: 27px;
          height: 27px;
          display: grid;
          place-items: center;
          border-radius: 7px;
          background: var(--ink);
          color: var(--bg);
          font-size: 12px;
          font-weight: 760;
        }
        h1 {
          margin: 0;
          font-size: 14px;
          line-height: 1.1;
          font-weight: 720;
        }
        .subtitle {
          margin-top: 1px;
          color: var(--muted);
          font-size: 11px;
          line-height: 1.25;
        }
        .top-actions {
          display: flex;
          align-items: center;
          gap: 8px;
          min-width: 0;
        }
        .chip {
          display: inline-flex;
          align-items: center;
          gap: 6px;
          min-height: 26px;
          max-width: 100%;
          padding: 0 9px;
          border: 1px solid var(--line);
          border-radius: 999px;
          background: var(--pane-raised);
          color: var(--muted);
          font-size: 11px;
          line-height: 1;
          white-space: nowrap;
        }
        .chip strong {
          color: var(--ink);
          font-weight: 640;
        }
        .dot {
          width: 8px;
          height: 8px;
          border-radius: 50%;
          background: var(--muted);
          flex: 0 0 auto;
        }
        .dot.good { background: var(--good); }
        .dot.warn { background: var(--warn); }
        .dot.bad { background: var(--bad); }
        .layout {
          min-height: 0;
          display: grid;
          grid-template-columns: clamp(196px, 22vw, 220px) minmax(360px, 1fr) clamp(320px, 35vw, 360px);
          background: var(--line);
          gap: 1px;
        }
        .pane {
          min-width: 0;
          min-height: 0;
          background: var(--pane);
        }
        .rail,
        .center,
        .inspector {
          overflow: auto;
        }
        .rail {
          padding: 13px 12px;
        }
        .center {
          display: grid;
          grid-template-rows: auto minmax(0, 1fr);
          gap: 0;
          padding: 0;
          overflow: hidden;
        }
        .inspector {
          display: grid;
          grid-template-rows: auto auto minmax(0, 1fr);
          overflow: hidden;
        }
        .section {
          margin-bottom: 18px;
        }
        .section:last-child {
          margin-bottom: 0;
        }
        .section-title {
          margin: 0 0 8px;
          color: var(--ink);
          font-size: 12px;
          line-height: 1.2;
          font-weight: 700;
        }
        .row {
          display: grid;
          grid-template-columns: 62px minmax(0, 1fr);
          align-items: center;
          gap: 8px;
          min-height: 29px;
          border-top: 1px solid var(--line);
        }
        .row:first-child {
          border-top: 0;
        }
        .row span:first-child {
          color: var(--muted);
          font-size: 11px;
        }
        .row strong {
          min-width: 0;
          overflow: hidden;
          text-overflow: ellipsis;
          white-space: nowrap;
          color: var(--ink);
          font-size: 11px;
          font-weight: 640;
          text-align: right;
        }
        .model-strip {
          display: flex;
          flex-wrap: wrap;
          gap: 6px;
        }
        .model-option {
          min-height: 28px;
          padding: 0 9px;
          border: 1px solid var(--line);
          border-radius: 7px;
          background: var(--pane-raised);
          color: var(--ink);
          cursor: pointer;
          font-size: 12px;
        }
        .model-option:hover {
          border-color: var(--line-strong);
          background: var(--pane-muted);
        }
        .model-option.active {
          border-color: var(--accent);
          background: var(--accent-soft);
          color: var(--ink);
        }
        .model-option:disabled {
          color: var(--faint);
          cursor: not-allowed;
          opacity: .68;
        }
        .prompt-pane,
        .response-pane {
          min-width: 0;
          background: var(--pane-raised);
        }
        .prompt-pane {
          padding: 14px;
          border-bottom: 1px solid var(--line);
        }
        .pane-head {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 10px;
        }
        .pane-head > div:first-child {
          min-width: 0;
        }
        .pane-title {
          margin: 0;
          font-size: 13px;
          line-height: 1.2;
          font-weight: 700;
        }
        .pane-note {
          margin: 3px 0 0;
          overflow: hidden;
          text-overflow: ellipsis;
          white-space: nowrap;
          color: var(--muted);
          font-size: 11px;
          line-height: 1.35;
        }
        textarea {
          width: 100%;
          height: 124px;
          min-height: 84px;
          max-height: 190px;
          resize: vertical;
          margin-top: 9px;
          padding: 10px 11px;
          border: 1px solid var(--line);
          border-radius: 7px;
          outline: none;
          background: var(--pane);
          color: var(--ink);
          font-size: 13px;
          line-height: 1.45;
        }
        textarea::placeholder {
          color: var(--muted);
        }
        textarea:focus {
          border-color: var(--accent);
        }
        .prompt-actions {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 8px;
          margin-top: 9px;
        }
        .primary,
        .secondary,
        .quiet,
        .tab,
        .snippet-row {
          min-height: 29px;
          border: 1px solid var(--line);
          border-radius: 7px;
          background: var(--pane-raised);
          color: var(--ink);
          cursor: pointer;
        }
        .primary,
        .secondary,
        .quiet {
          padding: 0 10px;
          font-size: 12px;
        }
        .primary {
          min-width: 74px;
          border-color: var(--accent);
          background: var(--accent);
          color: #fff;
          font-weight: 720;
        }
        .primary:hover:not(:disabled) {
          filter: brightness(.98);
        }
        .secondary:hover,
        .quiet:hover,
        .tab:hover,
        .snippet-row:hover {
          border-color: var(--line-strong);
          background: var(--pane-muted);
        }
        .primary:disabled,
        .secondary:disabled,
        .quiet:disabled {
          cursor: not-allowed;
          opacity: .58;
        }
        .response-pane {
          min-height: 0;
          display: flex;
          flex-direction: column;
          overflow: hidden;
        }
        .response-pane .pane-head,
        .inspector-head {
          min-height: 44px;
          padding: 10px 12px;
          border-bottom: 1px solid var(--line);
          background: var(--pane-muted);
        }
        .run-card {
          min-width: 0;
          padding: 10px 12px;
          border-bottom: 1px solid var(--line);
          background: var(--pane);
        }
        .evidence-section {
          min-height: 0;
          display: flex;
          flex-direction: column;
          margin: 0;
        }
        .meta-list {
          display: grid;
          gap: 1px;
        }
        .meta-row {
          display: grid;
          grid-template-columns: 70px minmax(0, 1fr);
          gap: 8px;
          min-height: 26px;
          align-items: center;
          border-top: 1px solid var(--line);
        }
        .meta-row:first-child {
          border-top: 0;
        }
        .meta-row span {
          color: var(--muted);
          font-size: 11px;
        }
        .meta-row strong {
          min-width: 0;
          overflow: hidden;
          text-overflow: ellipsis;
          white-space: nowrap;
          color: var(--ink);
          font-size: 11px;
          font-weight: 650;
          text-align: right;
        }
        .response-body {
          flex: 1 1 auto;
          min-height: 0;
          overflow: auto;
          padding: 13px 14px;
          white-space: pre-wrap;
          color: var(--ink);
          font-size: 13px;
          line-height: 1.52;
        }
        .response-body.is-error {
          color: var(--bad);
        }
        .tabs {
          display: flex;
          align-items: center;
          gap: 0;
          padding: 2px;
          border: 1px solid var(--line);
          border-radius: 7px;
          background: var(--pane-raised);
        }
        .tab {
          min-height: 22px;
          padding: 0 7px;
          border: 0;
          border-radius: 5px;
          background: transparent;
          color: var(--muted);
          font-size: 11px;
        }
        .tab.active {
          background: var(--pane-muted);
          color: var(--ink);
          box-shadow: inset 0 0 0 1px var(--line);
        }
        .evidence {
          min-height: 0;
          margin: 0;
          overflow: auto;
          padding: 10px 12px 12px;
          background: var(--pane);
        }
        .snippet-picker {
          display: grid;
          gap: 6px;
          margin-bottom: 9px;
        }
        .snippet-row {
          width: 100%;
          display: grid;
          grid-template-columns: minmax(0, 1fr) auto;
          align-items: center;
          gap: 8px;
          padding: 7px 8px;
          text-align: left;
        }
        .snippet-row strong {
          overflow: hidden;
          text-overflow: ellipsis;
          white-space: nowrap;
          font-size: 11px;
          font-weight: 680;
        }
        .snippet-row span {
          color: var(--muted);
          font-size: 11px;
        }
        .snippet-row.active {
          border-color: var(--accent);
          background: var(--accent-soft);
        }
        .code-head {
          min-height: 0;
          padding: 0 0 7px;
          border: 0;
          background: transparent;
        }
        pre {
          margin: 0;
          max-height: 260px;
          padding: 10px;
          overflow: auto;
          border-radius: 7px;
          background: var(--code);
          color: var(--code-ink);
          font: 11px/1.48 ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
          overflow-wrap: anywhere;
          white-space: pre-wrap;
        }
        .trace-list {
          display: grid;
          gap: 7px;
        }
        .trace {
          border: 1px solid var(--line);
          border-radius: 7px;
          padding: 9px;
          background: var(--pane-raised);
        }
        .trace h3 {
          margin: 0;
          overflow-wrap: anywhere;
          color: var(--ink);
          font-size: 11px;
          font-weight: 700;
        }
        .trace p {
          margin: 5px 0 0;
          color: var(--muted);
          font-size: 11px;
          line-height: 1.35;
          display: -webkit-box;
          -webkit-line-clamp: 2;
          -webkit-box-orient: vertical;
          overflow: hidden;
        }
        .trace small {
          display: block;
          margin-top: 7px;
          color: var(--faint);
          font-size: 10px;
        }
        .empty {
          min-height: 90px;
          display: flex;
          align-items: center;
          justify-content: center;
          padding: 14px;
          border: 1px solid var(--line);
          border-radius: 7px;
          color: var(--muted);
          text-align: center;
          font-size: 11px;
          line-height: 1.4;
        }
        @keyframes fadeIn {
          from { opacity: 0; transform: translateY(5px); }
          to { opacity: 1; transform: translateY(0); }
        }
        .response-body.updated {
          animation: fadeIn .18s ease-out both;
        }
        @media (prefers-reduced-motion: reduce) {
          *, *::before, *::after {
            animation-duration: .01ms !important;
            transition-duration: .01ms !important;
          }
        }
        @media (max-width: 920px) {
          body { overflow: auto; }
          .shell { min-height: 100svh; height: auto; }
          .layout {
            grid-template-columns: 1fr;
            gap: 1px;
          }
          .rail {
            display: grid;
            grid-template-columns: repeat(3, minmax(0, 1fr));
            gap: 12px;
          }
          .section { margin-bottom: 0; }
          .center { overflow: visible; }
          .response-pane { min-height: 320px; }
          .inspector { overflow: visible; }
          .evidence { min-height: 220px; }
        }
        @media (max-width: 760px) {
          .topbar {
            height: auto;
            align-items: flex-start;
            flex-direction: column;
            padding: 12px;
          }
          .top-actions {
            width: 100%;
            justify-content: space-between;
          }
          .rail {
            grid-template-columns: 1fr;
          }
          .center,
          .rail {
            padding: 12px;
          }
        }
      </style>
    </head>
    <body>
      <div class="shell">
        <header class="topbar">
          <div class="brand">
            <div class="mark">afm</div>
            <div>
              <h1>AFM Workbench</h1>
              <div class="subtitle">Local Foundation Models control plane</div>
            </div>
          </div>
          <div class="top-actions">
            <div class="chip"><span id="bridgeDot" class="dot"></span><span id="bridgeLabel">Bridge</span></div>
            <button id="refresh" class="secondary">Refresh</button>
          </div>
        </header>
        <main class="layout">
          <aside class="rail pane">
            <section class="section">
              <h2 class="section-title">Runtime</h2>
              <div id="runtimeRows"></div>
            </section>
            <section class="section">
              <h2 class="section-title">Bridge</h2>
              <div id="bridgeRows"></div>
            </section>
            <section class="section">
              <h2 class="section-title">Models</h2>
              <div id="models" class="model-strip"></div>
            </section>
          </aside>
          <section class="center pane">
            <div class="prompt-pane">
              <div class="pane-head">
                <div>
                  <h2 class="pane-title">Prompt</h2>
                  <p class="pane-note">Local request</p>
                </div>
                <div class="chip"><span id="routeDot" class="dot"></span><strong id="routeLabel">No model selected</strong></div>
              </div>
              <textarea id="prompt">Reply with one precise sentence about why the signed bridge matters for PCC.</textarea>
              <div class="prompt-actions">
                <button id="copyResponse" class="quiet" disabled>Copy response</button>
                <button id="run" class="primary">Run</button>
              </div>
            </div>
            <div class="response-pane">
              <div class="pane-head">
                <div>
                  <h2 class="pane-title">Response</h2>
                  <p class="pane-note" id="responseNote">Ready</p>
                </div>
              </div>
              <div id="response" class="response-body">Ready.</div>
            </div>
          </section>
          <aside class="inspector pane">
            <div class="inspector-head">
              <div class="pane-head">
                <div>
                  <h2 class="pane-title">Run</h2>
                  <p class="pane-note">Current trace</p>
                </div>
              </div>
            </div>
            <section class="run-card">
              <div class="meta-list">
                <div class="meta-row"><span>Trace</span><strong id="traceID" title="-">-</strong></div>
                <div class="meta-row"><span>Duration</span><strong id="duration" title="-">-</strong></div>
                <div class="meta-row"><span>Finish</span><strong id="finish" title="-">-</strong></div>
              </div>
            </section>
            <section class="section evidence-section">
              <div class="inspector-head">
                <div class="pane-head">
                  <h2 class="pane-title">Evidence</h2>
                  <div class="tabs" role="tablist" aria-label="Evidence panels">
                    <button class="tab active" data-panel="snippets" type="button">Snippets</button>
                    <button class="tab" data-panel="traces" type="button">Traces</button>
                  </div>
                </div>
              </div>
              <div id="evidence" class="evidence"></div>
            </section>
          </aside>
        </main>
      </div>
      <script>
        const state = {
          status: null,
          selected: null,
          snippets: [],
          traces: [],
          activePanel: "snippets",
          activeSnippet: 0,
          lastResponse: ""
        };
        const $ = (id) => document.getElementById(id);
        const originToken = () => location.origin;

        async function json(path, options) {
          const requestOptions = withAuthorization(options || {});
          const response = await fetch(path, requestOptions);
          const payload = await response.json();
          if (!response.ok) throw new Error(payload?.error?.message || response.statusText);
          return payload;
        }

        async function workbenchChat(path, options) {
          const requestOptions = withAuthorization(options || {});
          const response = await fetch(path, requestOptions);
          const payload = await response.json();
          if (!response.ok && payload?.command !== "workbench chat") {
            throw new Error(payload?.error?.message || response.statusText);
          }
          return payload;
        }

        function withAuthorization(options) {
          const token = workbenchToken();
          if (!token) return options;
          return {
            ...options,
            headers: {
              ...(options.headers || {}),
              authorization: `Bearer ${token}`
            }
          };
        }

        function workbenchToken() {
          const hash = new URLSearchParams(location.hash.replace(/^#/, ""));
          const hashToken = hash.get("token");
          if (hashToken) {
            sessionStorage.setItem("afm.workbench.token", hashToken);
            history.replaceState(null, "", location.pathname + location.search);
            return hashToken;
          }
          return sessionStorage.getItem("afm.workbench.token") || "";
        }

        function row(label, value) {
          const rendered = humanize(value ?? "-");
          return `<div class="row"><span>${escapeHTML(label)}</span><strong title="${escapeHTML(rendered)}">${escapeHTML(rendered)}</strong></div>`;
        }

        function escapeHTML(value) {
          return String(value).replace(/[&<>"']/g, (char) => ({
            "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
          }[char]));
        }

        function humanize(value) {
          const string = String(value);
          return string
            .replace(/([a-z])([A-Z])/g, "$1 $2")
            .replace(/_/g, " ")
            .toLowerCase();
        }

        function statusClass(value) {
          if (["running", "runnable", "available", "ok"].includes(String(value))) return "good";
          if (["stale", "unknown", "missingEntitlement", "unavailable"].includes(String(value))) return "warn";
          return "bad";
        }

        function setBridge(status) {
          const bridge = status.bridge;
          $("bridgeLabel").textContent = bridge.status === "running" ? "Bridge running" : "Bridge " + bridge.status;
          $("bridgeDot").className = "dot " + statusClass(bridge.status);
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

        function availableModels(status) {
          return [
            ...status.directModels.map((model) => ({ route: "direct", id: model.id, available: model.available })),
            ...status.bridge.models.map((model) => ({ route: "bridge", id: model.id, available: model.available }))
          ];
        }

        function ensureSelected(models) {
          const selectedStillExists = models.some((model) =>
            model.available && state.selected?.route === model.route && state.selected?.model === model.id
          );
          if (selectedStillExists) return;
          const preferred = models.find((model) => model.available && model.route === "bridge" && model.id === "pcc")
            || models.find((model) => model.available && model.route === "direct" && model.id === "system")
            || models.find((model) => model.available);
          state.selected = preferred ? { route: preferred.route, model: preferred.id } : null;
        }

        function setModels(status) {
          const models = availableModels(status);
          ensureSelected(models);
          const direct = status.directModels.map((model) => modelButton("direct", model.id, model.available));
          const bridge = status.bridge.models.map((model) => modelButton("bridge", model.id, model.available));
          $("models").innerHTML = [...direct, ...bridge].join("");
          $("models").querySelectorAll("button").forEach((button) => {
            button.addEventListener("click", () => {
              state.selected = { route: button.dataset.route, model: button.dataset.model };
              render();
            });
          });
        }

        function setRoute() {
          if (!state.selected) {
            $("routeLabel").textContent = "No runnable model";
            $("routeDot").className = "dot bad";
            $("run").disabled = true;
            return;
          }
          $("routeLabel").textContent = `${state.selected.route}:${state.selected.model}`;
          $("routeDot").className = "dot " + (state.selected.route === "bridge" ? "good" : "warn");
          $("run").disabled = false;
        }

        function renderSnippets() {
          if (!state.snippets.length) {
            $("evidence").innerHTML = `<div class="empty">Snippets are not available yet.</div>`;
            return;
          }
          if (state.activeSnippet >= state.snippets.length) state.activeSnippet = 0;
          const selected = state.snippets[state.activeSnippet];
          const code = selected.code.replaceAll("$AFM_ORIGIN", originToken());
          const rows = state.snippets.map((snippet, index) => {
            const active = index === state.activeSnippet ? "active" : "";
            return `<button class="snippet-row ${active}" data-snippet="${index}" type="button">
              <strong>${escapeHTML(snippet.title)}</strong>
              <span>${escapeHTML(snippet.language)}</span>
            </button>`;
          }).join("");
          $("evidence").innerHTML = `
            <div class="snippet-picker">${rows}</div>
            <div class="code-block">
              <div class="pane-head code-head">
                <h3 class="pane-title">${escapeHTML(selected.title)}</h3>
                <button id="copySnippet" class="quiet" type="button">Copy</button>
              </div>
              <pre>${escapeHTML(code)}</pre>
            </div>
          `;
          $("evidence").querySelectorAll("[data-snippet]").forEach((button) => {
            button.addEventListener("click", () => {
              state.activeSnippet = Number(button.dataset.snippet);
              renderEvidence();
            });
          });
          $("copySnippet").addEventListener("click", async () => {
            await navigator.clipboard.writeText(code);
            $("copySnippet").textContent = "Copied";
            setTimeout(() => { $("copySnippet").textContent = "Copy"; }, 900);
          });
        }

        function renderTraces(traces) {
          if (!traces.length) {
            $("evidence").innerHTML = `<div class="empty">No traces yet. Run a prompt to create the first saved record.</div>`;
            return;
          }
          $("evidence").innerHTML = `<div class="trace-list">${traces.map((trace) => `
            <article class="trace">
              <h3>${escapeHTML(trace.route)}:${escapeHTML(trace.model)}</h3>
              <p>${escapeHTML(trace.prompt)}</p>
              <small>${new Date(trace.createdAt).toLocaleTimeString()} - ${trace.durationMilliseconds} ms - ${trace.statusCode}</small>
            </article>
          `).join("")}</div>`;
        }

        function renderEvidence() {
          document.querySelectorAll("[data-panel]").forEach((button) => {
            button.classList.toggle("active", button.dataset.panel === state.activePanel);
          });
          if (state.activePanel === "traces") {
            renderTraces(state.traces);
          } else {
            renderSnippets();
          }
        }

        function render() {
          if (!state.status) return;
          setBridge(state.status);
          setRuntime(state.status);
          setModels(state.status);
          setRoute();
          renderEvidence();
        }

        async function refresh() {
          const [status, snippets, traces] = await Promise.all([
            json("/api/workbench/status"),
            json("/api/workbench/snippets"),
            json("/api/workbench/traces")
          ]);
          state.status = status;
          state.snippets = snippets.snippets;
          state.traces = traces.traces;
          render();
        }

        function markResponseUpdated() {
          const response = $("response");
          response.classList.remove("updated");
          void response.offsetWidth;
          response.classList.add("updated");
        }

        async function runPrompt() {
          if (!state.selected) return;
          $("run").disabled = true;
          $("copyResponse").disabled = true;
          $("response").classList.remove("is-error");
          $("response").textContent = "Running on " + state.selected.route + ":" + state.selected.model + "...";
          $("responseNote").textContent = "Request in progress.";
          markResponseUpdated();
          try {
            const payload = await workbenchChat("/api/workbench/chat", {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({
                route: state.selected.route,
                model: state.selected.model,
                prompt: $("prompt").value
              })
            });
            state.lastResponse = payload.response || payload.responseJSON || "Done.";
            $("response").textContent = state.lastResponse;
            $("responseNote").textContent = "Saved";
            $("traceID").textContent = payload.traceID;
            $("traceID").title = payload.traceID;
            $("duration").textContent = payload.durationMilliseconds + " ms";
            $("duration").title = payload.durationMilliseconds + " ms";
            $("finish").textContent = payload.finishReason || "-";
            $("finish").title = payload.finishReason || "-";
            $("copyResponse").disabled = false;
            state.activePanel = "traces";
            markResponseUpdated();
            await refresh();
          } catch (error) {
            $("response").textContent = error.message;
            $("response").classList.add("is-error");
            $("responseNote").textContent = "Request failed.";
            markResponseUpdated();
          } finally {
            $("run").disabled = state.selected == null;
          }
        }

        $("refresh").addEventListener("click", refresh);
        $("run").addEventListener("click", runPrompt);
        $("copyResponse").addEventListener("click", async () => {
          if (!state.lastResponse) return;
          await navigator.clipboard.writeText(state.lastResponse);
          $("copyResponse").textContent = "Copied";
          setTimeout(() => { $("copyResponse").textContent = "Copy response"; }, 900);
        });
        document.querySelectorAll("[data-panel]").forEach((button) => {
          button.addEventListener("click", () => {
            state.activePanel = button.dataset.panel;
            renderEvidence();
          });
        });
        refresh().catch((error) => { $("response").textContent = error.message; });
      </script>
    </body>
    </html>
    """#
}
