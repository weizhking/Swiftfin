//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Foundation
import Logging
import Network

final class LocalMediaProxyService {

    static let shared = LocalMediaProxyService()

    private let host = "127.0.0.1"
    private let port: UInt16 = 18765
    private let logger = Logger.swiftfin()
    private let queue = DispatchQueue(label: "org.jellyfin.swiftfin.local-media-proxy")

    private var listener: NWListener?
    private var isStarted = false

    private init() {
        start()
    }

    func proxiedURL(for remoteURL: URL) -> URL {
        start()

        var components = URLComponents()

        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = "/proxy"
        components.queryItems = [
            URLQueryItem(name: "url", value: remoteURL.absoluteString)
        ]

        return components.url ?? remoteURL
    }

    private func start() {
        queue.sync {
            guard !isStarted else { return }

            do {
                let parameters = NWParameters.tcp

                let listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: port))

                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }

                    switch state {
                    case .ready:
                        self.logger.info("Local media proxy listening on \(self.host):\(self.port)")
                    case let .failed(error):
                        self.logger.error("Local media proxy failed: \(error.localizedDescription)")
                    default:
                        break
                    }
                }

                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { return }
                    ProxyConnection(service: self, connection: connection).start()
                }

                listener.start(queue: queue)

                self.listener = listener
                self.isStarted = true
            } catch {
                logger.error("Unable to start local media proxy: \(error.localizedDescription)")
            }
        }
    }
}

private extension LocalMediaProxyService {

    final class ProxyConnection {

        private let service: LocalMediaProxyService
        private let connection: NWConnection
        private let queue = DispatchQueue(label: "org.jellyfin.swiftfin.local-media-proxy.connection")

        private var buffer = Data()

        init(service: LocalMediaProxyService, connection: NWConnection) {
            self.service = service
            self.connection = connection
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }

                switch state {
                case .ready:
                    self.receive()
                case .failed, .cancelled:
                    self.connection.cancel()
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }

                if let error {
                    self.service.logger.error("Local media proxy receive error: \(error.localizedDescription)")
                    self.finish()
                    return
                }

                if let data {
                    self.buffer.append(data)
                }

                if let request = self.parseRequest() {
                    self.forward(request)
                    return
                }

                if isComplete {
                    self.finish()
                    return
                }

                self.receive()
            }
        }

        private func parseRequest() -> ProxyRequest? {
            guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }

            let headerData = buffer[..<headerRange.lowerBound]
            guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

            let lines = headerString.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else { return nil }

            let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { return nil }

            let method = String(parts[0])
            let target = String(parts[1])

            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let separator = line.firstIndex(of: ":") else { continue }
                let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                headers[key] = value
            }

            return .init(method: method, target: target, headers: headers)
        }

        private func forward(_ request: ProxyRequest) {
            guard let targetURL = remoteURL(from: request.target) else {
                respond(statusCode: 400, body: Data("Missing remote URL".utf8))
                return
            }

            let delegate = ProxyRequestDelegate(
                service: service,
                connection: connection,
                requestMethod: request.method,
                remoteURL: targetURL
            )

            let configuration = URLSessionConfiguration.swiftfin
            configuration.timeoutIntervalForRequest = 60

            let session = URLSession(
                configuration: configuration,
                delegate: delegate,
                delegateQueue: nil
            )

            delegate.session = session

            var urlRequest = URLRequest(url: targetURL)
            urlRequest.httpMethod = request.method

            for (header, value) in request.headers {
                switch header.lowercased() {
                case "host", "connection", "proxy-connection", "content-length":
                    continue
                default:
                    urlRequest.setValue(value, forHTTPHeaderField: header)
                }
            }

            session.dataTask(with: urlRequest).resume()
        }

        private func remoteURL(from target: String) -> URL? {
            guard let components = URLComponents(string: "http://localhost\(target)"),
                  let encodedURL = components.queryItems?.first(where: { $0.name == "url" })?.value
            else {
                return nil
            }

            return URL(string: encodedURL)
        }

        private func respond(statusCode: Int, body: Data) {
            var response = "HTTP/1.1 \(statusCode) \(HTTPURLResponse.localizedString(forStatusCode: statusCode))\r\n"
            response += "Content-Length: \(body.count)\r\n"
            response += "Content-Type: text/plain; charset=utf-8\r\n"
            response += "Connection: close\r\n\r\n"

            let responseData = Data(response.utf8) + body

            connection.send(content: responseData, completion: .contentProcessed { [weak self] _ in
                self?.finish()
            })
        }

        private func finish() {
            connection.cancel()
        }
    }

    struct ProxyRequest {
        let method: String
        let target: String
        let headers: [String: String]
    }

    final class ProxyRequestDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {

        weak var session: URLSession?

        private let service: LocalMediaProxyService
        private let connection: NWConnection
        private let requestMethod: String
        private let remoteURL: URL

        private var didSendHeaders = false
        private var shouldRewritePlaylist = false
        private var playlistBuffer = Data()
        private var response: HTTPURLResponse?

        init(
            service: LocalMediaProxyService,
            connection: NWConnection,
            requestMethod: String,
            remoteURL: URL
        ) {
            self.service = service
            self.connection = connection
            self.requestMethod = requestMethod
            self.remoteURL = remoteURL
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let response = response as? HTTPURLResponse else {
                sendError(statusCode: 502, message: "Invalid upstream response")
                completionHandler(.cancel)
                return
            }

            self.response = response
            self.shouldRewritePlaylist = shouldRewrite(response: response, remoteURL: remoteURL)

            if !shouldRewritePlaylist {
                sendHeaders(for: response, contentLength: response.expectedContentLength >= 0 ? Int(response.expectedContentLength) : nil)
            }

            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            if shouldRewritePlaylist {
                playlistBuffer.append(data)
                return
            }

            connection.send(content: data, completion: .contentProcessed { _ in })
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                service.logger.error("Local media proxy upstream error: \(error.localizedDescription)")

                if !didSendHeaders {
                    sendError(statusCode: 502, message: error.localizedDescription)
                }

                finish(session: session)
                return
            }

            guard let response else { return }

            if shouldRewritePlaylist {
                let body = rewrittenPlaylistData(from: playlistBuffer, remoteURL: remoteURL)
                sendHeaders(for: response, contentLength: body.count)

                if requestMethod.uppercased() != "HEAD" {
                    connection.send(content: body, completion: .contentProcessed { [weak self] _ in
                        self?.finish(session: session)
                    })
                } else {
                    finish(session: session)
                }
            } else {
                finish(session: session)
            }
        }

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            handleChallenge(challenge, completionHandler: completionHandler)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            handleChallenge(challenge, completionHandler: completionHandler)
        }

        private func sendHeaders(for response: HTTPURLResponse, contentLength: Int?) {
            guard !didSendHeaders else { return }

            var headerString = "HTTP/1.1 \(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))\r\n"

            for (key, value) in response.allHeaderFields {
                guard let key = key as? String else { continue }
                let lowerKey = key.lowercased()

                if lowerKey == "connection" || lowerKey == "transfer-encoding" || lowerKey == "content-length" {
                    continue
                }

                headerString += "\(key): \(value)\r\n"
            }

            if let contentLength {
                headerString += "Content-Length: \(contentLength)\r\n"
            }

            headerString += "Connection: close\r\n\r\n"

            didSendHeaders = true

            connection.send(content: Data(headerString.utf8), completion: .contentProcessed { _ in })
        }

        private func sendError(statusCode: Int, message: String) {
            let body = Data(message.utf8)
            var headerString = "HTTP/1.1 \(statusCode) \(HTTPURLResponse.localizedString(forStatusCode: statusCode))\r\n"
            headerString += "Content-Length: \(body.count)\r\n"
            headerString += "Content-Type: text/plain; charset=utf-8\r\n"
            headerString += "Connection: close\r\n\r\n"

            let payload = Data(headerString.utf8) + body

            connection.send(content: payload, completion: .contentProcessed { _ in })
        }

        private func finish(session: URLSession) {
            connection.send(content: nil, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
                session.finishTasksAndInvalidate()
            })
        }

        private func handleChallenge(
            _ challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust
            else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            completionHandler(.useCredential, URLCredential(trust: trust))
        }

        private func shouldRewrite(response: HTTPURLResponse, remoteURL: URL) -> Bool {
            if remoteURL.pathExtension.lowercased() == "m3u8" {
                return true
            }

            if let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() {
                return contentType.contains("mpegurl") || contentType.contains("application/x-mpegurl")
            }

            return false
        }

        private func rewrittenPlaylistData(from data: Data, remoteURL: URL) -> Data {
            guard let playlist = String(data: data, encoding: .utf8) else { return data }

            let rewrittenLines = playlist
                .components(separatedBy: .newlines)
                .map { rewritePlaylistLine($0, baseURL: remoteURL) }

            return Data(rewrittenLines.joined(separator: "\n").utf8)
        }

        private func rewritePlaylistLine(_ line: String, baseURL: URL) -> String {
            guard !line.isEmpty else { return line }

            if line.hasPrefix("#") {
                return rewriteDirectiveLine(line, baseURL: baseURL)
            }

            guard let absoluteURL = URL(string: line, relativeTo: baseURL)?.absoluteURL else {
                return line
            }

            return service.proxiedURL(for: absoluteURL).absoluteString
        }

        private func rewriteDirectiveLine(_ line: String, baseURL: URL) -> String {
            let pattern = #"URI="([^"]+)""#

            guard let regex = try? NSRegularExpression(pattern: pattern) else { return line }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, options: [], range: range),
                  let fullRange = Range(match.range(at: 0), in: line),
                  let captureRange = Range(match.range(at: 1), in: line)
            else {
                return line
            }

            let originalValue = String(line[captureRange])
            guard let absoluteURL = URL(string: originalValue, relativeTo: baseURL)?.absoluteURL else {
                return line
            }

            let replacement = #"URI="\#(service.proxiedURL(for: absoluteURL).absoluteString)""#
            return line.replacingCharacters(in: fullRange, with: replacement)
        }
    }
}
