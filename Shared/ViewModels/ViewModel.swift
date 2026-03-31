//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Combine
import Factory
import Foundation
import KeychainSwift
import Logging

class ViewModel: ObservableObject {

    @Injected(\.dataStore)
    var dataStack

    @Injected(\.keychainService)
    var keychain

    let logger = Logger.swiftfin()

    /// The current *signed in* user session
    @Injected(\.currentUserSession)
    var userSession: UserSession!

    var cancellables = Set<AnyCancellable>()

    private var userSessionResolverCancellable: AnyCancellable?

    init() {
        userSessionResolverCancellable = Notifications[.didChangeCurrentServerURL]
            .publisher
            .sink { [weak self] _ in
                self?.$userSession.resolve(reset: .scope)
            }
    }

    func withConnectionRecovery<T>(
        _ operation: @escaping () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard shouldAttemptConnectionRecovery(for: error),
                  let currentSession = userSession
            else {
                throw error
            }

            let resolvedServer = try await currentSession.server.resolveCurrentURL()

            if resolvedServer.currentURL != currentSession.server.currentURL {
                Notifications[.didChangeCurrentServerURL].post(resolvedServer)
                $userSession.resolve(reset: .scope)
            }

            return try await operation()
        }
    }

    private func shouldAttemptConnectionRecovery(for error: Error) -> Bool {
        let nsError = error as NSError

        guard nsError.domain == NSURLErrorDomain else { return false }

        let code = URLError.Code(rawValue: nsError.code)

        switch code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .notConnectedToInternet,
             .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .serverCertificateUntrusted,
             .clientCertificateRejected,
             .clientCertificateRequired:
            return true
        default:
            return false
        }
    }
}
