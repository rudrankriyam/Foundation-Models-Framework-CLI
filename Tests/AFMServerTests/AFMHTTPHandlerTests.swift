import Darwin
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing
@testable import AFMServer

@Test("Health and model discovery use the injected catalog and clock")
func healthAndModels() throws {
    let catalog = AFMStaticModelCatalog(
        models: [
            .init(id: "system", isAvailable: true),
            .init(id: "adapter-demo", isAvailable: false, owner: "local")
        ]
    )
    let router = AFMRequestRouter(
        configuration: .init(),
        catalog: catalog,
        clock: TestClock(value: 1_234)
    )

    let health = try performRequest(path: "/health", router: router)
    #expect(health.head.status == .ok)
    let healthJSON = try jsonObject(health.body)
    #expect(healthJSON["status"] as? String == "afm serve is running")
    let healthModels = try #require(healthJSON["models"] as? [[String: Any]])
    #expect(healthModels.map { $0["name"] as? String } == ["adapter-demo", "system"])
    #expect(healthModels[0]["available"] as? Bool == false)

    let models = try performRequest(path: "/v1/models?ignored=true", router: router)
    #expect(models.head.status == .ok)
    let modelsJSON = try jsonObject(models.body)
    let modelData = try #require(modelsJSON["data"] as? [[String: Any]])
    #expect(modelData.map { $0["id"] as? String } == ["adapter-demo", "system"])
    #expect(modelData.allSatisfy { $0["created"] as? Int == 1_234 })
    #expect(modelData[0]["owned_by"] as? String == "local")
}

@Test("Unknown routes and wrong methods return JSON API errors")
func routingErrors() throws {
    let router = testRouter()

    let missing = try performRequest(path: "/missing", router: router)
    #expect(missing.head.status == .notFound)
    #expect(try errorCode(missing.body) == "not_found")

    let wrongMethod = try performRequest(method: .POST, path: "/health", router: router)
    #expect(wrongMethod.head.status == .methodNotAllowed)
    #expect(wrongMethod.head.headers.first(name: "allow") == "GET")
    #expect(try errorCode(wrongMethod.body) == "method_not_allowed")
}

@Test("Loopback Host and Origin policies reject cross-site requests by default")
func hostAndOriginPolicy() throws {
    let router = testRouter()

    let hostileHost = try performRequest(path: "/health", host: "example.com", router: router)
    #expect(hostileHost.head.status == .forbidden)
    #expect(try errorCode(hostileHost.body) == "forbidden_host")

    let hostileOrigin = try performRequest(
        path: "/health",
        additionalHeaders: [("origin", "https://example.com")],
        router: router
    )
    #expect(hostileOrigin.head.status == .forbidden)
    #expect(try errorCode(hostileOrigin.body) == "origin_not_allowed")

    let sameOrigin = try performRequest(
        path: "/health",
        additionalHeaders: [("origin", "http://127.0.0.1:1976")],
        router: router
    )
    #expect(sameOrigin.head.status == .ok)
    #expect(sameOrigin.head.headers.first(name: "access-control-allow-origin") == "http://127.0.0.1:1976")

    let allowedRouter = testRouter(allowedOrigins: ["https://trusted.example"])
    let allowed = try performRequest(
        path: "/health",
        additionalHeaders: [("origin", "https://trusted.example")],
        router: allowedRouter
    )
    #expect(allowed.head.status == .ok)
    #expect(allowed.head.headers.first(name: "access-control-allow-origin") == "https://trusted.example")
    #expect(allowed.head.headers.first(name: "vary") == "Origin")
}

@Test("Bearer authentication protects every route when configured")
func bearerAuthentication() throws {
    let router = testRouter(token: "correct-token", allowedOrigins: ["https://trusted.example"])

    let missing = try performRequest(
        path: "/health",
        additionalHeaders: [("origin", "https://trusted.example")],
        router: router
    )
    #expect(missing.head.status == .unauthorized)
    #expect(missing.head.headers.first(name: "www-authenticate") == "Bearer")
    #expect(missing.head.headers.first(name: "access-control-allow-origin") == "https://trusted.example")
    #expect(missing.head.headers.first(name: "vary") == "Origin")

    let incorrect = try performRequest(
        path: "/health",
        additionalHeaders: [("authorization", "Bearer incorrect-token")],
        router: router
    )
    #expect(incorrect.head.status == .unauthorized)

    let valid = try performRequest(
        path: "/health",
        additionalHeaders: [("authorization", "bearer correct-token")],
        router: router
    )
    #expect(valid.head.status == .ok)
}

@Test("Bearer authentication lets the workbench shell load but protects its APIs")
func bearerAuthenticationWithWorkbench() throws {
    let directory = try WorkbenchTestDirectory()
    defer { directory.remove() }
    let router = testRouter(token: "correct-token", workbenchDirectory: directory)

    let shell = try performRequest(path: "/", router: router)
    #expect(shell.head.status == .ok)
    let html = try #require(String(data: shell.body, encoding: .utf8))
    #expect(html.contains("afm.workbench.token"))
    #expect(html.contains("authorization"))
    #expect(html.contains("async function workbenchChat"))
    #expect(html.contains("Saved failure"))
    #expect(html.contains("refresh failed"))

    let statusWithoutToken = try performRequest(path: "/api/workbench/status", router: router)
    #expect(statusWithoutToken.head.status == .unauthorized)

    let statusWithToken = try performRequest(
        path: "/api/workbench/status",
        additionalHeaders: [("authorization", "Bearer correct-token")],
        router: router
    )
    #expect(statusWithToken.head.status == .ok)
}

@Test("Body and media-type limits produce deterministic JSON errors")
func bodyAndMediaTypeLimits() throws {
    let limits = AFMServerLimits(maximumBodyBytes: 4)
    let router = testRouter(limits: limits)

    let exactLimit = try performRequest(
        path: "/health",
        body: Data("1234".utf8),
        contentType: "application/json; charset=utf-8",
        router: router,
        limits: limits
    )
    #expect(exactLimit.head.status == .ok)

    let tooLarge = try performRequest(
        path: "/health",
        body: Data("12345".utf8),
        contentType: "application/json",
        router: router,
        limits: limits
    )
    #expect(tooLarge.head.status == .payloadTooLarge)
    #expect(try errorCode(tooLarge.body) == "request_too_large")

    let enormousDeclaration = try performRequest(
        path: "/health",
        additionalHeaders: [
            ("content-length", String(UInt64.max)),
            ("content-type", "application/json")
        ],
        router: router,
        limits: limits
    )
    #expect(enormousDeclaration.head.status == .payloadTooLarge)

    let unsupported = try performRequest(
        path: "/health",
        body: Data("1".utf8),
        contentType: "text/plain",
        router: router,
        limits: limits
    )
    #expect(unsupported.head.status == .unsupportedMediaType)
    #expect(try errorCode(unsupported.body) == "unsupported_media_type")
}

@Test("Header overflow becomes a JSON 431 response")
func headerOverflow() throws {
    let channel = EmbeddedChannel(handler: AFMHTTPHandler(router: testRouter(), limits: .init()))
    channel.pipeline.fireErrorCaught(HTTPParserError.headerOverflow)

    let response = try readResponse(from: channel)
    #expect(response.head.status.code == 431)
    #expect(response.head.status.reasonPhrase == "Request Header Fields Too Large")
    #expect(try errorCode(response.body) == "headers_too_large")
    _ = try? channel.finish()
}

@Test("Keep-alive connections reset request state between requests")
func keepAliveRequests() throws {
    let channel = EmbeddedChannel(handler: AFMHTTPHandler(router: testRouter(), limits: .init()))
    try writeRequest(path: "/health", to: channel)
    let first = try readResponse(from: channel)
    try writeRequest(path: "/v1/models", to: channel)
    let second = try readResponse(from: channel)

    #expect(first.head.status == .ok)
    #expect(second.head.status == .ok)
    _ = try? channel.finish()
}

@Test("A closing response ignores request parts received before its flush completes")
func closingResponseIgnoresLateRequest() throws {
    let delayedEnd = DelayedResponseEndHandler()
    let channel = EmbeddedChannel(handler: delayedEnd)
    try channel.pipeline.syncOperations.addHandler(
        AFMHTTPHandler(router: testRouter(), limits: .init())
    )

    try writeRequest(
        path: "/health",
        additionalHeaders: [("connection", "close")],
        to: channel
    )
    try writeRequest(path: "/v1/models", to: channel)

    let response = try readResponse(from: channel)
    #expect(response.head.status == .ok)
    #expect(response.head.headers.first(name: "connection") == "close")
    #expect(try channel.readOutbound(as: HTTPServerResponsePart.self) == nil)
    delayedEnd.completeWrites()
    channel.embeddedEventLoop.run()
    _ = try? channel.finish()
}

@Test("Chat POST requires JSON even when the body is empty")
func chatRequiresJSONContentType() throws {
    let channel = EmbeddedChannel(
        handler: AFMHTTPHandler(router: testRouter(), limits: .init())
    )
    try writeRequest(method: .POST, path: "/v1/chat/completions", to: channel)
    let response = try readResponse(from: channel)
    #expect(response.head.status == .unsupportedMediaType)
    #expect(try errorCode(response.body) == "unsupported_media_type")
    _ = try? channel.finish()
}

@Test("Workbench routes are available only when the browser surface is enabled")
func workbenchRoutesRequireOptIn() throws {
    let disabled = try performRequest(path: "/", router: testRouter())
    #expect(disabled.head.status == .notFound)
    #expect(try errorCode(disabled.body) == "workbench_not_enabled")

    let directory = try WorkbenchTestDirectory()
    defer { directory.remove() }
    let enabled = try performRequest(path: "/", router: testRouter(workbenchDirectory: directory))

    #expect(enabled.head.status == .ok)
    #expect(enabled.head.headers.first(name: "content-type") == "text/html; charset=utf-8")
    #expect(String(data: enabled.body, encoding: .utf8)?.contains("AFM Workbench") == true)
}

@Test("Workbench status, snippets, and traces return structured JSON")
func workbenchDiscoveryEndpoints() throws {
    let directory = try WorkbenchTestDirectory()
    defer { directory.remove() }
    let router = testRouter(workbenchDirectory: directory)

    let status = try performRequest(path: "/api/workbench/status", router: router)
    #expect(status.head.status == .ok)
    let statusJSON = try jsonObject(status.body)
    #expect(statusJSON["command"] as? String == "workbench status")
    #expect(statusJSON["traceDirectory"] as? String == directory.trace.path())
    let directModels = try #require(statusJSON["directModels"] as? [[String: Any]])
    #expect(directModels.map { $0["id"] as? String } == ["system"])
    let bridge = try #require(statusJSON["bridge"] as? [String: Any])
    #expect(bridge["status"] as? String == "missing")

    let snippets = try performRequest(path: "/api/workbench/snippets", router: router)
    #expect(snippets.head.status == .ok)
    let snippetsJSON = try jsonObject(snippets.body)
    let snippetData = try #require(snippetsJSON["snippets"] as? [[String: Any]])
    #expect(snippetData.map { $0["id"] as? String }.contains("codex-walkthrough"))

    let traces = try performRequest(path: "/api/workbench/traces", router: router)
    #expect(traces.head.status == .ok)
    let tracesJSON = try jsonObject(traces.body)
    #expect(tracesJSON["command"] as? String == "workbench traces")
    #expect((tracesJSON["traces"] as? [[String: Any]])?.isEmpty == true)
}

@Test("Workbench marks stale bridge models unavailable")
func workbenchStaleBridgeModelsAreUnavailable() throws {
    let directory = try WorkbenchTestDirectory()
    defer { directory.remove() }
    let store = try AFMBridgeDescriptorStore(directoryPath: directory.bridge.path())
    _ = try store.publish(try makeAFMBridgeTestDescriptor(
        processIdentifier: Int32.max,
        modelIdentifiers: ["pcc", "system"]
    ))
    let router = testRouter(workbenchDirectory: directory)

    let status = try performRequest(path: "/api/workbench/status", router: router)
    #expect(status.head.status == .ok)
    let statusJSON = try jsonObject(status.body)
    let bridge = try #require(statusJSON["bridge"] as? [String: Any])
    #expect(bridge["status"] as? String == "stale")
    let models = try #require(bridge["models"] as? [[String: Any]])
    #expect(models.map { $0["id"] as? String } == ["pcc", "system"])
    #expect(models.allSatisfy { $0["available"] as? Bool == false })
}

@Test("Workbench trace listing does not chmod existing trace directories")
func workbenchTraceListingPreservesExistingDirectoryPermissions() throws {
    let directory = try WorkbenchTestDirectory()
    defer { directory.remove() }
    try FileManager.default.createDirectory(at: directory.trace, withIntermediateDirectories: true)
    Darwin.chmod(directory.trace.path(), 0o755)
    let router = testRouter(workbenchDirectory: directory)

    let traces = try performRequest(path: "/api/workbench/traces", router: router)
    #expect(traces.head.status == .ok)
    #expect(afmBridgePermissions(try afmBridgeStatus(at: directory.trace.path())) == 0o755)
}

@Test("Workbench chat POST requires JSON even when the body is empty")
func workbenchChatRequiresJSONContentType() throws {
    let directory = try WorkbenchTestDirectory()
    defer { directory.remove() }
    let channel = EmbeddedChannel(
        handler: AFMHTTPHandler(router: testRouter(workbenchDirectory: directory), limits: .init())
    )
    try writeRequest(method: .POST, path: "/api/workbench/chat", to: channel)
    let response = try readResponse(from: channel)
    #expect(response.head.status == .unsupportedMediaType)
    #expect(try errorCode(response.body) == "unsupported_media_type")
    _ = try? channel.finish()
}

@Test("Workbench chat preserves non-success upstream status")
func workbenchChatPreservesUpstreamStatus() async throws {
    let directory = try WorkbenchTestDirectory()
    defer { directory.remove() }
    let workbench = AFMWorkbench(configuration: .init(traceDirectory: directory.trace.path()))
    let service = AFMChatCompletionService(
        catalog: AFMStaticModelCatalog(models: [.init(id: "system", isAvailable: true)]),
        generator: HandlerTestGenerator(),
        clock: TestClock(value: 123),
        policy: .init()
    )
    let body = Data(#"{"route":"direct","model":"missing","prompt":"Hello"}"#.utf8)

    let recorder = FixedResponseRecorder()
    try await workbench.writeChatResponse(
        body: body,
        chatCompletions: service
    ) { emission in
        if case .fixed(let response) = emission {
            await recorder.record(response)
        }
    }

    let response = try #require(await recorder.response())
    #expect(response.status == .notFound)
    let json = try jsonObject(response.body)
    #expect(json["command"] as? String == "workbench chat")
    #expect(json["model"] as? String == "missing")
}

@Test("Workbench chat errors still return saved trace payloads")
func workbenchChatErrorsReturnTracePayloads() async throws {
    let directory = try WorkbenchTestDirectory()
    defer { directory.remove() }
    let workbench = AFMWorkbench(configuration: .init(traceDirectory: directory.trace.path()))
    let body = Data(#"{"route":"direct","model":"system","prompt":"Hello"}"#.utf8)

    let recorder = FixedResponseRecorder()
    try await workbench.writeChatResponse(
        body: body,
        chatCompletions: nil
    ) { emission in
        if case .fixed(let response) = emission {
            await recorder.record(response)
        }
    }

    let response = try #require(await recorder.response())
    #expect(response.status == .internalServerError)
    let json = try jsonObject(response.body)
    #expect(json["command"] as? String == "workbench chat")
    #expect(json["model"] as? String == "system")
    #expect(json["traceID"] is String)
    #expect((json["error"] as? String)?.contains("Direct chat completions") == true)
}

private struct TestClock: AFMServerClock {
    let value: Int64

    func unixTime() -> Int64 { value }
}

private struct HandlerTestGenerator: AFMChatCompletionGenerating {
    func generate(_ request: AFMChatGenerationRequest) async throws -> AFMChatGenerationResult {
        .init(
            content: "Done",
            usage: .init(inputTokenCount: 1, measurement: .estimated, scope: .response)
        )
    }
}

private actor FixedResponseRecorder {
    private var storedResponse: AFMHTTPResponse?

    func record(_ response: AFMHTTPResponse) {
        storedResponse = response
    }

    func response() -> AFMHTTPResponse? {
        storedResponse
    }
}

private struct TestHTTPResponse {
    let head: HTTPResponseHead
    let body: Data
}

private final class DelayedResponseEndHandler: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = HTTPServerResponsePart
    typealias OutboundOut = HTTPServerResponsePart

    private var completionPromises: [EventLoopPromise<Void>] = []

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if case .end = unwrapOutboundIn(data) {
            if let promise {
                completionPromises.append(promise)
            }
            context.write(data, promise: nil)
        } else {
            context.write(data, promise: promise)
        }
    }

    func completeWrites() {
        completionPromises.forEach { $0.succeed(()) }
        completionPromises.removeAll()
    }
}

private struct WorkbenchTestDirectory {
    let root: URL
    let trace: URL
    let bridge: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "afm-workbench-\(UUID().uuidString)")
        trace = root.appending(path: "traces")
        bridge = root.appending(path: "bridge")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func testRouter(
    token: String? = nil,
    allowedOrigins: Set<String> = [],
    limits: AFMServerLimits = .init(),
    workbenchDirectory: WorkbenchTestDirectory? = nil
) -> AFMRequestRouter {
    AFMRequestRouter(
        configuration: .init(
            limits: limits,
            security: .init(bearerToken: token, allowedOrigins: allowedOrigins)
        ),
        catalog: AFMStaticModelCatalog(models: [.init(id: "system", isAvailable: true)]),
        clock: TestClock(value: 123),
        workbench: workbenchDirectory.map {
            AFMWorkbench(configuration: .init(
                traceDirectory: $0.trace.path(),
                bridgeDirectory: $0.bridge.path()
            ))
        }
    )
}

private func performRequest(
    method: HTTPMethod = .GET,
    path: String,
    host: String = "127.0.0.1:1976",
    additionalHeaders: [(String, String)] = [],
    body: Data? = nil,
    contentType: String? = nil,
    router: AFMRequestRouter,
    limits: AFMServerLimits = .init()
) throws -> TestHTTPResponse {
    let channel = EmbeddedChannel(handler: AFMHTTPHandler(router: router, limits: limits))
    try writeRequest(
        method: method,
        path: path,
        host: host,
        additionalHeaders: additionalHeaders,
        body: body,
        contentType: contentType,
        to: channel
    )
    let response = try readResponse(from: channel)
    _ = try? channel.finish()
    return response
}

private func writeRequest(
    method: HTTPMethod = .GET,
    path: String,
    host: String = "127.0.0.1:1976",
    additionalHeaders: [(String, String)] = [],
    body: Data? = nil,
    contentType: String? = nil,
    to channel: EmbeddedChannel
) throws {
    var headers = HTTPHeaders()
    headers.add(name: "host", value: host)
    for (name, value) in additionalHeaders {
        headers.add(name: name, value: value)
    }
    if let body {
        headers.add(name: "content-length", value: String(body.count))
    }
    if let contentType {
        headers.add(name: "content-type", value: contentType)
    }

    let head = HTTPRequestHead(version: .http1_1, method: method, uri: path, headers: headers)
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    if let body {
        var buffer = channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        try channel.writeInbound(HTTPServerRequestPart.body(buffer))
    }
    try channel.writeInbound(HTTPServerRequestPart.end(nil))
}

private func readResponse(from channel: EmbeddedChannel) throws -> TestHTTPResponse {
    var responseHead: HTTPResponseHead?
    var responseBody = Data()

    while let part = try channel.readOutbound(as: HTTPServerResponsePart.self) {
        switch part {
        case .head(let head):
            responseHead = head
        case .body(.byteBuffer(var buffer)):
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                responseBody.append(contentsOf: bytes)
            }
        case .body(.fileRegion):
            Issue.record("Unexpected file-region response body")
        case .end:
            return TestHTTPResponse(head: try #require(responseHead), body: responseBody)
        }
    }
    throw TestResponseError.missingEnd
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func errorCode(_ data: Data) throws -> String? {
    let object = try jsonObject(data)
    let error = try #require(object["error"] as? [String: Any])
    return error["code"] as? String
}

private enum TestResponseError: Error {
    case missingEnd
}
