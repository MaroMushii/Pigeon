import Foundation
import Network
import os

/// Minimal HTTP/1.0 client that connects to a hardcoded IPv4 address and
/// wraps the socket in TLS with a configurable SNI. Used to bypass DNS
/// poisoning on filtered networks (Iran-grade DPI) by skipping the system
/// resolver entirely — Foundation's URLSession owns DNS opaquely and won't
/// let us pin per-request.
///
/// Deliberately dumb:
///   - HTTP/1.0 + `Connection: close`  → no chunked transfer encoding
///   - `Accept-Encoding: identity`     → no gzip/brotli to decode
///   - One request per connection      → no keep-alive bookkeeping
///   - Read until EOF                  → server closes when body is done
///
/// One request = one connection. ~150 lines of code, no external deps.
actor PinnedHTTPSClient {
    enum ClientError: Error, LocalizedError {
        case invalidIP(String)
        case connectionFailed(String)
        case timedOut
        case truncated
        case malformedResponse
        case statusCode(Int)

        var errorDescription: String? {
            switch self {
            case .invalidIP(let ip): "Invalid pinned IP \(ip)."
            case .connectionFailed(let msg): "Pinned connection failed: \(msg)"
            case .timedOut: "Pinned request timed out."
            case .truncated: "Server closed connection mid-response."
            case .malformedResponse: "Could not parse pinned HTTP response."
            case .statusCode(let s): "Pinned proxy returned HTTP \(s)."
            }
        }
    }

    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private let queue = DispatchQueue(label: "dev.MaroMushii.Pigeon.PinnedHTTPS")

    /// Pool of Google anycast IPs that historically serve the
    /// `*.translate.goog` proxy. Rotated on per-request failure.
    static let translateGoogIPs: [String] = [
        "216.239.38.120",
        "142.250.191.196",
        "142.250.184.196",
        "142.250.74.14"
    ]

    /// Sticky cache of the last IP that produced a successful response.
    /// On the next rotation, we start from this IP so flaky-but-reachable
    /// peers don't get re-paid on every request. Reset implicitly when
    /// that IP starts failing — we just fall through to the next one.
    private var lastGoodIP: String?

    /// Try `get(ip:sni:...)` against the pinned IP pool with a Happy
    /// Eyeballs first stage: race the first 2 candidates in parallel,
    /// take whichever connects + delivers a response first, cancel the
    /// sibling. If both fail, walk the remaining IPs serially.
    ///
    /// The first candidate is `lastGoodIP` (if set), then the static order
    /// with that IP filtered out. This biases toward whichever Google
    /// frontend the local network is currently happy with.
    func getWithIPRotation(
        sni: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        timeout: TimeInterval = 30
    ) async throws -> Response {
        let ordered = orderedIPs()
        guard !ordered.isEmpty else {
            throw ClientError.connectionFailed("no pinned IPs configured")
        }

        var lastError: Error?

        // Stage 1: race the first two candidates. Whoever wins updates
        // `lastGoodIP`; the loser is cancelled. NWConnection.cancel() in
        // the per-call `catch` tears down its socket cleanly.
        let firstPair = Array(ordered.prefix(2))
        if firstPair.count == 2 {
            do {
                let (winnerIP, response) = try await race(
                    ips: firstPair,
                    sni: sni,
                    path: path,
                    queryItems: queryItems,
                    headers: headers,
                    timeout: timeout
                )
                lastGoodIP = winnerIP
                return response
            } catch {
                lastError = error
            }
        } else {
            // Single-IP pool — fall through to serial.
        }

        // Stage 2: walk the rest serially. We've already burned the first
        // two; pick up at index 2 (or 1 if we only had one IP to begin with).
        let serialStart = min(firstPair.count, ordered.count)
        for ip in ordered[serialStart...] {
            do {
                let response = try await get(
                    ip: ip,
                    sni: sni,
                    path: path,
                    queryItems: queryItems,
                    headers: headers,
                    timeout: timeout
                )
                lastGoodIP = ip
                return response
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError ?? ClientError.connectionFailed("no pinned IPs reachable")
    }

    /// Build the rotation order: `lastGoodIP` first (if any), then the
    /// static pool with that IP filtered out so we don't double-try it.
    private func orderedIPs() -> [String] {
        guard let preferred = lastGoodIP else { return Self.translateGoogIPs }
        var ordered = [preferred]
        for ip in Self.translateGoogIPs where ip != preferred {
            ordered.append(ip)
        }
        return ordered
    }

    /// Race two pinned-IP attempts. Returns `(winnerIP, response)` from
    /// the first child to deliver a non-throwing result; cancels the
    /// other. Throws only if both children fail.
    ///
    /// Two-element race is enough — we don't want to fan out to 4 sockets
    /// per request, that's noisy on metered links and pointless once one
    /// IP responds. `withTaskGroup` is fine even though `get` is
    /// actor-isolated: each child suspends inside `connect`/`send`/`read`
    /// continuations, which release actor isolation, so the two sockets
    /// genuinely overlap on the wire.
    private func race(
        ips: [String],
        sni: String,
        path: String,
        queryItems: [URLQueryItem],
        headers: [String: String],
        timeout: TimeInterval
    ) async throws -> (String, Response) {
        try await withThrowingTaskGroup(of: (String, Response).self) { group in
            for ip in ips {
                group.addTask { [self] in
                    let response = try await self.get(
                        ip: ip,
                        sni: sni,
                        path: path,
                        queryItems: queryItems,
                        headers: headers,
                        timeout: timeout
                    )
                    return (ip, response)
                }
            }

            var lastError: Error?
            while !group.isEmpty {
                do {
                    if let result = try await group.next() {
                        group.cancelAll()
                        return result
                    }
                } catch {
                    // One child failed; keep waiting on the sibling.
                    lastError = error
                }
            }
            throw lastError ?? ClientError.connectionFailed("race produced no result")
        }
    }

    /// Perform a GET against `https://<ip>:443<path>?<query>` with TLS SNI
    /// rewritten to `sni` and `Host: sni` set in the request line.
    func get(
        ip: String,
        sni: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        timeout: TimeInterval = 30
    ) async throws -> Response {
        guard let address = IPv4Address(ip) else {
            throw ClientError.invalidIP(ip)
        }

        let endpoint = NWEndpoint.hostPort(host: .ipv4(address), port: 443)

        // Pin the SNI to the proxy hostname even though the TCP socket
        // is bound to a hardcoded IP.
        let tlsOptions = NWProtocolTLS.Options()
        sni.withCString { ptr in
            sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, ptr)
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = Int(timeout)
        tcpOptions.noDelay = true

        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        let connection = NWConnection(to: endpoint, using: parameters)

        do {
            try await connect(connection, timeout: timeout)
            let request = buildRequest(host: sni, path: path, queryItems: queryItems, extraHeaders: headers)
            try await send(request, on: connection)
            let raw = try await readUntilClose(connection, timeout: timeout)
            connection.cancel()
            return try parse(raw)
        } catch {
            connection.cancel()
            throw error
        }
    }

    // MARK: - Lifecycle helpers

    private func connect(_ conn: NWConnection, timeout: TimeInterval) async throws {
        // `stateUpdateHandler` fires on `queue` (a DispatchQueue), not on the
        // actor, so concurrent `.waiting` / `.failed` callbacks could race on
        // a plain Bool flag. The lock makes the test-and-set atomic; whichever
        // path (state callback or timeout sleep) wins flips the bit, the
        // others observe `true` and no-op. This guarantees the continuation
        // is resumed exactly once.
        let resumed = OSAllocatedUnfairLock<Bool>(initialState: false)

        let claim: @Sendable () -> Bool = {
            resumed.withLock { state in
                guard !state else { return false }
                state = true
                return true
            }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard claim() else { return }
                    conn.stateUpdateHandler = nil
                    cont.resume()
                case .failed(let err):
                    guard claim() else { return }
                    conn.stateUpdateHandler = nil
                    conn.cancel()
                    cont.resume(throwing: ClientError.connectionFailed(err.localizedDescription))
                case .waiting(let err):
                    guard claim() else { return }
                    conn.stateUpdateHandler = nil
                    conn.cancel()
                    cont.resume(throwing: ClientError.connectionFailed(err.localizedDescription))
                case .cancelled:
                    guard claim() else { return }
                    conn.stateUpdateHandler = nil
                    cont.resume(throwing: ClientError.connectionFailed("cancelled"))
                default:
                    break
                }
            }

            // Race a deadline against the connection. On DPI'd networks a
            // stuck `.preparing` / `.setup` is the common failure mode, so
            // we can't rely on NWConnection alone to ever fail us out.
            Task { [conn] in
                try? await Task.sleep(for: .seconds(timeout))
                guard claim() else { return }
                conn.stateUpdateHandler = nil
                conn.cancel()
                cont.resume(throwing: ClientError.timedOut)
            }

            conn.start(queue: queue)
        }
    }

    private func send(_ data: Data, on conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err {
                    cont.resume(throwing: ClientError.connectionFailed(err.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func readUntilClose(_ conn: NWConnection, timeout: TimeInterval) async throws -> Data {
        var accumulated = Data()
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            let (chunk, isComplete) = try await receiveChunk(on: conn)
            if let chunk, !chunk.isEmpty { accumulated.append(chunk) }
            if isComplete { return accumulated }
        }
        throw ClientError.timedOut
    }

    private func receiveChunk(on conn: NWConnection) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data?, Bool), Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, err in
                if let err {
                    cont.resume(throwing: ClientError.connectionFailed(err.localizedDescription))
                } else {
                    cont.resume(returning: (data, isComplete))
                }
            }
        }
    }

    // MARK: - Wire format

    private func buildRequest(
        host: String,
        path: String,
        queryItems: [URLQueryItem],
        extraHeaders: [String: String]
    ) -> Data {
        var fullPath = path
        if !queryItems.isEmpty {
            var components = URLComponents()
            components.queryItems = queryItems
            if let query = components.percentEncodedQuery {
                fullPath += "?" + query
            }
        }

        var lines: [String] = []
        lines.append("GET \(fullPath) HTTP/1.0")
        lines.append("Host: \(host)")
        lines.append("Connection: close")
        lines.append("Accept-Encoding: identity")
        for (k, v) in extraHeaders {
            lines.append("\(k): \(v)")
        }
        lines.append("")
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private func parse(_ raw: Data) throws -> Response {
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let range = raw.range(of: separator) else {
            throw ClientError.malformedResponse
        }
        let headerBytes = raw.subdata(in: 0..<range.lowerBound)
        let body = raw.subdata(in: range.upperBound..<raw.count)

        guard let headerString = String(data: headerBytes, encoding: .utf8) else {
            throw ClientError.malformedResponse
        }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw ClientError.malformedResponse
        }
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw ClientError.malformedResponse
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        return Response(status: status, headers: headers, body: body)
    }
}
