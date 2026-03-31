//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import CoreStore
import Factory
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

    @Injected(\.serverURLTestCache)
    private var serverURLTestCache

    init(server: ServerState) {
        self.server = server
        super.init()

        if let cachedStates = serverURLTestCache.get(
            serverID: server.id,
            generation: networkPathObserver.currentGeneration()
        ) {
            self.urlCheckStates = cachedStates.mapValues(Self.urlCheckState(from:))
        }
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

    func canDeleteURL(_ url: URL) -> Bool {
        prioritizedURLs.count > 1 && prioritizedURLs.contains(url)
    }

    func deleteURL(_ url: URL) {
        guard canDeleteURL(url) else {
            testError = ErrorMessage("At least one URL must remain")
            return
        }

        do {
            let previousCurrentURL = server.currentURL
            let remainingOrderedURLs = prioritizedURLs.filter { $0 != url }

            let newState = try dataStack.perform { transaction in
                guard let storedServer = try transaction.fetchOne(From<ServerModel>().where(\.$id == self.server.id)) else {
                    throw ErrorMessage("Unable to find server for URL deletion: \(self.server.name)")
                }

                storedServer.urls.remove(url)

                if storedServer.currentURL == url,
                   let replacementURL = remainingOrderedURLs.first
                {
                    storedServer.currentURL = replacementURL
                }

                return storedServer.state
            }

            server = newState
            server.persistOrderedURLs(remainingOrderedURLs)
            urlCheckStates.removeValue(forKey: url)
            persistCheckStates()

            if newState.currentURL != previousCurrentURL {
                Notifications[.didChangeCurrentServerURL].post(newState)
            }
        } catch {
            testError = ErrorMessage(error.localizedDescription)
        }
    }

    func sortURLsByBitrate() async {
        guard !isTestingAllURLs else { return }

        isTestingAllURLs = true
        let metrics = await runParallelChecks()

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
        persistCheckStates()
    }

    func testAllURLs() async {
        guard !isTestingAllURLs else { return }

        isTestingAllURLs = true
        let _ = await runParallelChecks()
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

    private func runParallelChecks() async -> [URLSortMetric] {
        let urls = prioritizedURLs
        let testingStates = Dictionary(uniqueKeysWithValues: urls.map { ($0, URLCheckState.testing) })
        urlCheckStates.merge(testingStates) { _, new in new }

        let results = await withTaskGroup(
            of: (URL, URLCheckState, Int?).self,
            returning: [(URL, URLCheckState, Int?)].self
        ) { group in
            for url in urls {
                let server = self.server
                group.addTask {
                    let result = await Self.probeURL(server: server, url: url)
                    return (
                        url,
                        result,
                        Self.bitrateValue(from: result.detail)
                    )
                }
            }

            var collected: [(URL, URLCheckState, Int?)] = []

            for await result in group {
                collected.append(result)
            }

            return collected
        }

        let states = Dictionary(uniqueKeysWithValues: results.map { ($0.0, $0.1) })
        urlCheckStates.merge(states) { _, new in new }
        persistCheckStates()

        return results.map { URLSortMetric(url: $0.0, bitrate: $0.2) }
    }

    private func detailText(version: String?, bitrate: Int?) -> String? {
        if let bitrate {
            return Self.bitrateDisplayTitle(for: bitrate)
        }

        if let version {
            return "Jellyfin \(version)"
        }

        return nil
    }

    private static func urlCheckState(from entry: ServerURLTestCache.Entry) -> URLCheckState {
        switch entry.kind {
        case .idle:
            .idle
        case .testing:
            .testing
        case .reachable:
            .reachable(detail: entry.detail)
        case .failed:
            .failed(detail: entry.detail ?? L10n.unknownError)
        }
    }

    private func persistCheckStates() {
        let entries = urlCheckStates.mapValues { state in
            let kind: ServerURLTestCache.Entry.Kind

            switch state.kind {
            case .idle:
                kind = .idle
            case .testing:
                kind = .testing
            case .reachable:
                kind = .reachable
            case .failed:
                kind = .failed
            }

            return ServerURLTestCache.Entry(
                kind: kind,
                detail: state.detail
            )
        }

        serverURLTestCache.set(
            serverID: server.id,
            generation: networkPathObserver.currentGeneration(),
            entries: entries
        )
    }

    private static func bitrateValue(from detail: String?) -> Int? {
        guard let detail else { return nil }

        return PlaybackBitrate.allCases
            .filter { $0 != .auto }
            .first(where: { $0.displayTitle == detail })?
            .rawValue
    }

    private static func bitrateDisplayTitle(for bitrate: Int) -> String {
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

    private static func probeURL(server: ServerState, url: URL) async -> URLCheckState {
        do {
            let publicInfo = try await server.validateURL(url)
            let bitrate = try? await server.testBitrate(for: url)

            if let bitrate {
                return .reachable(detail: Self.bitrateDisplayTitle(for: bitrate))
            }

            if let version = publicInfo.version {
                return .reachable(detail: "Jellyfin \(version)")
            }

            return .reachable(detail: nil)
        } catch {
            return .failed(detail: message(for: error))
        }
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
