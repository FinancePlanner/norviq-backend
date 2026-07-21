import Foundation
import NIOCore
import Vapor

/// Serializes IBKR SOD fetches to respect 1 req/sec and 10 req/min.
actor IBKRSODRateLimiter {
    private var secondWindow: [Date] = []
    private var minuteWindow: [Date] = []

    func waitTurn(now: Date = Date()) async {
        var cursor = now
        while true {
            prune(now: cursor)
            if secondWindow.count < 1, minuteWindow.count < 10 {
                secondWindow.append(cursor)
                minuteWindow.append(cursor)
                return
            }
            let waitSeconds = nextWaitInterval(now: cursor)
            try? await Task.sleep(nanoseconds: UInt64(max(waitSeconds, 0.01) * 1_000_000_000))
            cursor = Date()
        }
    }

    private func prune(now: Date) {
        secondWindow = secondWindow.filter { now.timeIntervalSince($0) < 1 }
        minuteWindow = minuteWindow.filter { now.timeIntervalSince($0) < 60 }
    }

    private func nextWaitInterval(now: Date) -> TimeInterval {
        var wait: TimeInterval = 0.05
        if let oldestSecond = secondWindow.first {
            wait = max(wait, 1 - now.timeIntervalSince(oldestSecond) + 0.01)
        }
        if minuteWindow.count >= 10, let oldestMinute = minuteWindow.first {
            wait = max(wait, 60 - now.timeIntervalSince(oldestMinute) + 0.01)
        }
        return wait
    }
}

protocol IBKRSODHTTPTransport: Sendable {
    func get(uri: URI, on req: Request) async throws -> (status: HTTPResponseStatus, body: ByteBuffer)
}

struct VaporIBKRSODHTTPTransport: IBKRSODHTTPTransport {
    func get(uri: URI, on req: Request) async throws -> (status: HTTPResponseStatus, body: ByteBuffer) {
        let response = try await req.client.get(uri) { clientRequest in
            clientRequest.headers.replaceOrAdd(name: .accept, value: "*/*")
            clientRequest.timeout = .seconds(60)
        }
        let body = response.body ?? ByteBuffer()
        return (response.status, body)
    }
}

struct IBKRSODClient: Sendable {
    let configuration: IBKRSODConfiguration
    let transport: any IBKRSODHTTPTransport
    let rateLimiter: IBKRSODRateLimiter

    init(
        configuration: IBKRSODConfiguration = .fromEnvironment(),
        transport: any IBKRSODHTTPTransport = VaporIBKRSODHTTPTransport(),
        rateLimiter: IBKRSODRateLimiter = IBKRSODRateLimiter()
    ) {
        self.configuration = configuration
        self.transport = transport
        self.rateLimiter = rateLimiter
    }

    func makeRequestURL(token: String, queryId: String, reportDate: String) throws -> URI {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedQuery = queryId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDate = reportDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty, !trimmedQuery.isEmpty else {
            throw IBKRSODError.missingCredentials
        }
        guard trimmedDate.range(of: #"^\d{8}$"#, options: .regularExpression) != nil else {
            throw IBKRSODError.service(.invalidDateFormat, detail: trimmedDate)
        }

        guard var components = URLComponents(string: configuration.baseURL) else {
            throw IBKRSODError.invalidConfiguration("Invalid IBKR_SOD_BASE_URL.")
        }
        components.queryItems = [
            URLQueryItem(name: "t", value: trimmedToken),
            URLQueryItem(name: "q", value: trimmedQuery),
            URLQueryItem(name: "rd", value: trimmedDate),
            URLQueryItem(name: "s", value: configuration.serviceCode),
        ]
        guard let url = components.url else {
            throw IBKRSODError.invalidConfiguration("Unable to build IBKR SOD request URL.")
        }
        return URI(string: url.absoluteString)
    }

    /// Fetches SOD payload for `reportDate` (`yyyymmdd`).
    /// On `1019`, caller should wait and re-call with the **same** date (no new submit).
    func fetch(
        token: String,
        queryId: String,
        reportDate: String,
        on req: Request,
        maxGenerationRetries: Int = 5
    ) async throws -> IBKRSODFetchResult {
        let uri = try makeRequestURL(token: token, queryId: queryId, reportDate: reportDate)
        var attempt = 0
        while true {
            attempt += 1
            await rateLimiter.waitTurn()
            let (status, body) = try await transport.get(uri: uri, on: req)
            let text = body.getString(at: body.readerIndex, length: body.readableBytes) ?? ""

            if let code = Self.parseErrorCode(from: text) {
                if code == .generationInProgress, attempt <= maxGenerationRetries {
                    let delay = min(2.0 * Double(attempt), 15.0)
                    req.logger.info("IBKR SOD generation in progress (1019); retry \(attempt) in \(delay)s")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw IBKRSODError.service(code, detail: text.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            guard status == .ok else {
                if let code = Self.parseErrorCode(from: text) {
                    throw IBKRSODError.service(code, detail: text)
                }
                throw IBKRSODError.httpStatus(Int(status.code), body: text)
            }

            let files = try Self.decodePayload(body: body, fallbackName: "statement-\(reportDate).csv")
            guard !files.isEmpty else {
                throw IBKRSODError.emptyResponse
            }
            return IBKRSODFetchResult(reportDate: reportDate, files: files)
        }
    }

    static func parseErrorCode(from body: String) -> IBKRSODErrorCode? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Prefer an exact leading code, then any documented code token.
        let patterns = [
            #"^Error\s*(10(?:10|18|19|50|52|53|54|55|56))\b"#,
            #"^(10(?:10|18|19|50|52|53|54|55|56))\b"#,
            #"\b(10(?:10|18|19|50|52|53|54|55|56))\b"#,
        ]
        for pattern in patterns {
            if let match = trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                let token = String(trimmed[match]).replacingOccurrences(
                    of: #"[^\d]"#,
                    with: "",
                    options: .regularExpression
                )
                if let value = Int(token), let code = IBKRSODErrorCode(rawValue: value) {
                    // Avoid false positives on large CSV numeric fields: only treat as error
                    // when the body is short (error page) or clearly labeled.
                    let looksLikeErrorPage = trimmed.count < 500
                        || trimmed.lowercased().contains("error")
                        || trimmed.lowercased().hasPrefix("\(value)")
                    if looksLikeErrorPage {
                        return code
                    }
                }
            }
        }
        return nil
    }

    static func decodePayload(body: ByteBuffer, fallbackName: String) throws -> [IBKRSODFilePayload] {
        var copy = body
        guard copy.readableBytes > 0 else {
            throw IBKRSODError.emptyResponse
        }

        // ZIP magic "PK"
        if copy.readableBytes >= 2,
           let b0 = copy.getInteger(at: copy.readerIndex, as: UInt8.self),
           let b1 = copy.getInteger(at: copy.readerIndex + 1, as: UInt8.self),
           b0 == 0x50, b1 == 0x4B
        {
            throw IBKRSODError.unsupportedPayload(
                "IBKR returned a ZIP archive. Unpack support is not enabled yet — save the payload and add fixtures."
            )
        }

        guard let text = copy.readString(length: copy.readableBytes)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            throw IBKRSODError.emptyResponse
        }

        if let code = parseErrorCode(from: text), text.count < 500 {
            throw IBKRSODError.service(code, detail: text)
        }

        return [IBKRSODFilePayload(name: fallbackName, csvText: text)]
    }
}
