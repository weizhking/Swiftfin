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

    enum MoveDirection {
        case higherPriority
        case lowerPriority
    }

    private struct URLSortMetric {
        let url: URL
        let bitrate: Int?
    }

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

    var preferredURL: URL? {
        prioritizedURLs.first
    }

    func checkState(for url: URL) -> URLCheckState {
        urlCheckStates[url] ?? .idle
    }

    func statusText(for url: URL) -> String {
        let state = checkState(for: url)
        var parts: [String] = []

        if preferredURL == url {
            parts.append("Preferred")
        }

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
            if parts.isEmpty, state.detail == nil {
                parts.append("Available")
            }
        case .failed:
            parts.append("Failed")
        }

        return parts.joined(separator: " | ")
    }

    func canMove(_ url: URL, direction: MoveDirection) -> Bool {
        guard let index = prioritizedURLs.firstIndex(of: url) else { return false }

        switch direction {
        case .higherPriority:
            return index > 0
        case .lowerPriority:
            return index < prioritizedURLs.count - 1
        }
    }

    func moveURL(_ url: URL, direction: MoveDirection) {
        guard let index = prioritizedURLs.firstIndex(of: url) else { return }

        let destinationIndex: Int

        switch direction {
        case .higherPriority:
            guard index > 0 else { return }
            destinationIndex = index - 1
        case .lowerPriority:
            guard index < prioritizedURLs.count - 1 else { return }
            destinationIndex = index + 1
        }

        var newOrder = prioritizedURLs
        let movedURL = newOrder.remove(at: index)
        newOrder.insert(movedURL, at: destinationIndex)

        server.persistOrderedURLs(newOrder)
        objectWillChange.send()
    }

    func sortURLsByBitrate() async {
        guard !isTestingAllURLs else { return }

        isTestingAllURLs = true
        var metrics: [URLSortMetric] = []

        for url in prioritizedURLs {
            urlCheckStates[url] = .testing
            let result = await probeURL(url)
            urlCheckStates[url] = result

            let bitrate = bitrateValue(from: result.detail)
            metrics.append(.init(url: url, bitrate: bitrate))
        }

        let sortedURLs = metrics
            .sorted { lhs, rhs in
                switch (lhs.bitrate, rhs.bitrate) {
                case let (left?, right?):
                    if left != right {
                        return left > right
                    }
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                case (nil, nil):
                    break
                }

                return prioritizedURLs.firstIndex(of: lhs.url) ?? 0 < prioritizedURLs.firstIndex(of: rhs.url) ?? 0
            }
            .map(\.url)

        server.persistOrderedURLs(sortedURLs)
        objectWillChange.send()
        isTestingAllURLs = false
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
            let bitrate = try? await server.testBitrate(for: url)
            let detail = detailText(
                version: publicInfo.version,
                bitrate: bitrate
            )
            return .reachable(detail: detail)
        } catch {
            return .failed(detail: Self.message(for: error))
        }
    }

    private func detailText(version: String?, bitrate: Int?) -> String? {
        if let bitrate {
            return bitrateDisplayTitle(for: bitrate)
        }

        if let version {
            return "Jellyfin \(version)"
        }

        return nil
    }

    private func bitrateValue(from detail: String?) -> Int? {
        guard let detail else { return nil }

        return PlaybackBitrate.allCases
            .filter { $0 != .auto }
            .first(where: { $0.displayTitle == detail })?
            .rawValue
    }

    private func bitrateDisplayTitle(for bitrate: Int) -> String {
        let orderedBitrates = PlaybackBitrate.allCases
            .filter { $0 != .auto }
            .sorted { $0.rawValue < $1.rawValue }

        for candidate in orderedBitrates {
            if bitrate <= candidate.rawValue {
                return candidate.displayTitle
            }
        }

        return PlaybackBitrate.max.displayTitle
    }

    private static func message(for error: Error) -> String {
        if let error = error as? ErrorMessage,
           let description = error.errorDescription
        {
            return description
        }

        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain
        {
            let code = URLError.Code(rawValue: nsError.code)

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
