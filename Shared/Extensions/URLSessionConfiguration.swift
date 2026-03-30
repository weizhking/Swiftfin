//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Foundation
import Logging
import Pulse

extension URLSessionConfiguration {

    /// A session configuration object built upon the default
    /// configuration with values for Swiftfin.
    static let swiftfin: URLSessionConfiguration = {
        .default.mutating(\.timeoutIntervalForRequest, with: 20)
    }()
}

enum SwiftfinNetworking {

    static func sessionDelegate() -> URLSessionProxyDelegate {
        URLSessionProxyDelegate(
            logger: NetworkLogger.swiftfin(),
            delegate: HTTPSCompatibilityDelegate()
        )
    }
}

private final class HTTPSCompatibilityDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {

    private let logger = Logger.swiftfin()

    private func handleChallenge(
        source: String,
        challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let host = challenge.protectionSpace.host
        let method = challenge.protectionSpace.authenticationMethod

        logger.info("TLS challenge received [\(source)] host=\(host) method=\(method)")

        guard method == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            logger.warning("TLS challenge default handling [\(source)] host=\(host) method=\(method)")
            completionHandler(.performDefaultHandling, nil)
            return
        }

        logger.info("TLS challenge accepted [\(source)] host=\(host)")
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleChallenge(
            source: "session",
            challenge: challenge,
            completionHandler: completionHandler
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleChallenge(
            source: "task",
            challenge: challenge,
            completionHandler: completionHandler
        )
    }
}
