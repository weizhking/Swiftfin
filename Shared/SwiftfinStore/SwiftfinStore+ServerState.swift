//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import CoreStore
import Defaults
import Factory
import Foundation
import JellyfinAPI
import Logging
import Pulse

extension SwiftfinStore.State {

    struct Server: Hashable, Identifiable {

        let urls: Set<URL>
        let currentURL: URL
        let name: String
        let id: String
        let userIDs: [String]

        init(
            urls: Set<URL>,
            currentURL: URL,
            name: String,
            id: String,
            usersIDs: [String]
        ) {
            self.urls = urls
            self.currentURL = currentURL
            self.name = name
            self.id = id
            self.userIDs = usersIDs
        }

        /// - Note: Since this is created from a server, it does not
        ///         have a user access token.
        var client: JellyfinClient {
            JellyfinClient(
                configuration: .swiftfinConfiguration(url: currentURL),
                sessionConfiguration: .swiftfin,
                sessionDelegate: SwiftfinNetworking.sessionDelegate()
            )
        }
    }
}

extension ServerState {

    var prioritizedURLs: [URL] {
        normalizedURLOrder(
            urls: urls,
            orderedURLs: StoredValues[.Server.orderedURLs(id: id)],
            currentURL: currentURL
        )
    }

    private func normalizedURLOrder(
        urls: Set<URL>,
        orderedURLs: [URL],
        currentURL: URL
    ) -> [URL] {
        let seedURLs = orderedURLs.isEmpty ? [currentURL] : orderedURLs
        var seenURLs = Set<URL>()

        let normalizedURLs = seedURLs.filter { url in
            guard urls.contains(url), !seenURLs.contains(url) else { return false }
            seenURLs.insert(url)
            return true
        }

        let missingURLs = urls
            .subtracting(normalizedURLs)
            .sorted(using: \.absoluteString)

        return normalizedURLs + missingURLs
    }

    private func client(for url: URL) -> JellyfinClient {
        JellyfinClient(
            configuration: .swiftfinConfiguration(
                url: url,
                accessToken: sessionAccessToken
            ),
            sessionConfiguration: .swiftfin,
            sessionDelegate: SwiftfinNetworking.sessionDelegate()
        )
    }

    private var sessionAccessToken: String? {
        guard let session = Container.shared.currentUserSession(),
              session.server.id == id
        else { return nil }

        return session.user.accessToken
    }

    func getPublicSystemInfo(for url: URL) async throws -> PublicSystemInfo {
        let request = Paths.getPublicSystemInfo
        let response = try await client(for: url).send(request)

        return response.value
    }

    func validateURL(_ url: URL) async throws -> PublicSystemInfo {
        let publicInfo = try await getPublicSystemInfo(for: url)

        guard let candidateID = publicInfo.id, candidateID == id else {
            throw ErrorMessage("Server identifier mismatch")
        }

        return publicInfo
    }

    func testBitrate(for url: URL) async throws -> Int {
        let testSize = Defaults[.VideoPlayer.appMaximumBitrateTest].rawValue
        let request = Paths.getBitrateTestBytes(size: testSize)
        let testStartTime = Date()
        let _ = try await client(for: url).send(request)
        let testDuration = Date().timeIntervalSince(testStartTime)
        let testSizeBits = Double(testSize * 8)
        let testBitrate = testSizeBits / testDuration

        return clamp(Int(testBitrate), min: 1_500_000, max: Int(Int32.max))
    }

    private func persistConnection(
        url: URL,
        publicInfo: PublicSystemInfo
    ) throws -> ServerState {
        try SwiftfinStore.dataStack.perform { transaction in
            guard let storedServer = try transaction.fetchOne(From<ServerModel>().where(\.$id == id)) else {
                throw ErrorMessage("Unable to find server for connection update")
            }

            storedServer.currentURL = url
            storedServer.name = publicInfo.serverName ?? storedServer.name
            storedServer.id = publicInfo.id ?? storedServer.id

            return storedServer.state
        }
    }

    @MainActor
    func resolveCurrentURL() async throws -> ServerState {
        let logger = Logger.swiftfin()
        var lastError: Error?

        for candidateURL in prioritizedURLs {
            do {
                let publicInfo = try await validateURL(candidateURL)

                StoredValues[.Server.publicInfo(id: id)] = publicInfo

                if candidateURL == currentURL {
                    logger.info("Confirmed current URL for server \(self.name): \(candidateURL.absoluteString)")
                } else {
                    logger.info("Switching server \(self.name) to reachable URL: \(candidateURL.absoluteString)")
                }

                return try persistConnection(
                    url: candidateURL,
                    publicInfo: publicInfo
                )
            } catch {
                lastError = error
                logger.warning("Server URL failed for \(self.name): \(candidateURL.absoluteString) (\(error.localizedDescription))")
            }
        }

        throw lastError ?? ErrorMessage("Unable to connect to any saved URL for \(name)")
    }

    /// Deletes the model that this state represents and
    /// all settings from `StoredValues`.
    func delete() throws {
        try SwiftfinStore.dataStack.perform { transaction in
            guard let storedServer = try transaction.fetchOne(From<ServerModel>().where(\.$id == id)) else {
                throw ErrorMessage("Unable to find server to delete")
            }

            let storedDataClause = AnyStoredData.fetchClause(ownerID: id)
            let storedData = try transaction.fetchAll(storedDataClause)

            transaction.delete(storedData)
            transaction.delete(storedServer)
        }
    }

    func getPublicSystemInfo() async throws -> PublicSystemInfo {
        try await getPublicSystemInfo(for: currentURL)
    }

    var splashScreenImageSource: ImageSource {
        let request = Paths.getSplashscreen()
        return ImageSource(url: client.fullURL(with: request))
    }

    @MainActor
    func updateServerInfo() async throws {
        let publicInfo = try await getPublicSystemInfo()
        _ = try persistConnection(
            url: currentURL,
            publicInfo: publicInfo
        )

        StoredValues[.Server.publicInfo(id: id)] = publicInfo
    }

    var isVersionCompatible: Bool {
        let publicInfo = StoredValues[.Server.publicInfo(id: self.id)]

        if let version = publicInfo.version {
            return JellyfinClient.Version(stringLiteral: version).majorMinor >= JellyfinClient.sdkVersion.majorMinor
        } else {
            return false
        }
    }

    func persistOrderedURLs(_ orderedURLs: [URL]) {
        StoredValues[.Server.orderedURLs(id: id)] = normalizedURLOrder(
            urls: urls,
            orderedURLs: orderedURLs,
            currentURL: currentURL
        )
    }
}
