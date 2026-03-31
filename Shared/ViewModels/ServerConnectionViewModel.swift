//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import CoreStore
import Foundation
import JellyfinAPI

@MainActor
final class ServerConnectionViewModel: ViewModel {

    struct URLCheckState: Equatable {

        enum Kind: Equatable {
            case idle
            case testing
            case reachable
            case failed
        }

        let kind: Kind
        let detail: String?

        static let idle = URLCheckState(kind: .idle, detail: nil)
        static let testing = URLCheckState(kind: .testing, detail: nil)

        static func reachable(detail: String?) -> URLCheckState {
            .init(kind: .reachable, detail: detail)
        }

        static func failed(detail: String) -> URLCheckState {
            .init(kind: .failed, detail: detail)
        }
    }

    @Published
    private(set) var server: ServerState
    @Published
    private(set) var isResolvingBestURL: Bool = false
    @Published
    private(set) var isTestingAllURLs: Bool = false
    @Published
    private(set) var urlCheckStates: [URL: URLCheckState] = [:]
    @Published
    var testError: ErrorMessage?

    init(server: ServerState) {
        self.server = server
        super.init()
    }

    var prioritizedURLs: [URL] {
        server.prioritizedURLs
    }

    func checkState(for url: URL) -> URLCheckState {
        urlCheckStates[url] ?? .idle
    }

    func statusText(for url: URL) -> String {
        let state = checkState(for: url)
        var parts: [String] = []

        if server.currentURL == url {
            parts.append("Current")
        }

        switch state.kind {
        case .idle:
            if parts.isEmpty {
                parts.append("Not tested")
            }
        case .testing:
            parts.append("Testing...")
        case .reachable:
            parts.append("Reachable")
        case .failed:
            parts.append("Failed")
        }

        return parts.joined(separator: " | ")
    }

    func testURL(_ url: URL) async {
        urlCheckStates[url] = .testing
        urlCheckStates[url] = await probeURL(url)
    }

    func testAllURLs() async {
        guard !isTestingAllURLs else { return }

        isTestingAllURLs = true

        for url in prioritizedURLs {
            urlCheckStates[url] = .testing
            urlCheckStates[url] = await probeURL(url)
        }

        isTestingAllURLs = false
    }

    func selectBestURL() async {
        guard !isResolvingBestURL else { return }

        isResolvingBestURL = true
        let previousURL = server.currentURL

        do {
            let newState = try await server.resolveCurrentURL()
            server = newState

            if newState.currentURL != previousURL {
                Notifications[.didChangeCurrentServerURL].post(newState)
            }

            await testAllURLs()
        } catch {
            testError = ErrorMessage(Self.message(for: error))
        }

        isResolvingBestURL = false
    }

    private func probeURL(_ url: URL) async -> URLCheckState {
        do {
            let publicInfo = try await server.validateURL(url)
            let detail = publicInfo.version.map { "Jellyfin \($0)" }
            return .reachable(detail: detail)
        } catch {
            return .failed(detail: Self.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? ErrorMessage,
           let description = error.errorDescription
        {
            return description
        }

        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain,
           let code = URLError.Code(rawValue: nsError.code)
        {
            switch code {
            case .cannotConnectToHost:
                return L10n.cannotConnectToHost
            case .cannotFindHost:
                return L10n.unableToFindHost
            case .notConnectedToInternet,
                 .networkConnectionLost:
                return "Network unavailable"
            case .timedOut:
                return L10n.networkTimedOut
            case .userAuthenticationRequired:
                return L10n.unauthorized
            case .secureConnectionFailed,
                 .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid,
                 .serverCertificateUntrusted,
                 .clientCertificateRejected,
                 .clientCertificateRequired:
                return "TLS failed"
            default:
                break
            }
        }

        return error.localizedDescription
    }

    // TODO: this could probably be cleaner
    func delete() {

        guard let storedServer = try? dataStack.fetchOne(From<ServerModel>().where(\.$id == server.id)) else {
            logger.critical("Unable to find server to delete")
            return
        }

        let userStates = storedServer.users.map(\.state)

        // Note: don't use Server/UserState.delete() to have
        //       all deletions in a single transaction
        do {
            try dataStack.perform { transaction in

                /// Delete stored data for all users
                for user in storedServer.users {
                    let storedDataClause = AnyStoredData.fetchClause(ownerID: user.id)
                    let storedData = try transaction.fetchAll(storedDataClause)

                    transaction.delete(storedData)
                }

                transaction.delete(storedServer.users)
                transaction.delete(storedServer)
            }

            for user in userStates {
                UserDefaults.userSuite(id: user.id).removeAll()
            }

            Notifications[.didDeleteServer].post(server)
        } catch {
            logger.critical("Unable to delete server: \(server.name)")
        }
    }

    func setCurrentURL(to url: URL) {
        do {
            let newState = try dataStack.perform { transaction in
                guard let storedServer = try transaction.fetchOne(From<ServerModel>().where(\.$id == self.server.id)) else {
                    throw ErrorMessage("Unable to find server for URL change: \(self.server.name)")
                }
                storedServer.currentURL = url

                return storedServer.state
            }

            Notifications[.didChangeCurrentServerURL].post(newState)

            self.server = newState
        } catch {
            logger.critical("\(error.localizedDescription)")
        }
    }
}
