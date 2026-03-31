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
        let remainingURLs = urls
            .filter { $0 != currentURL }
            .sorted(using: \.absoluteString)

        return [currentURL] + remainingURLs
    }

    private func client(for url: URL) -> JellyfinClient {
        JellyfinClient(
            configuration: .swiftfinConfiguration(url: url),
            sessionConfiguration: .swiftfin,
            sessionDelegate: SwiftfinNetworking.sessionDelegate()
        )
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
}
