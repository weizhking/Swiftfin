//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Factory
import Foundation

final class ServerURLTestCache {

    struct Entry {
        enum Kind {
            case idle
            case testing
            case reachable
            case failed
        }

        let kind: Kind
        let detail: String?
    }

    private struct CacheValue {
        let generation: Int
        let entries: [URL: Entry]
    }

    private let lock = NSLock()
    private var values: [String: CacheValue] = [:]

    func get(serverID: String, generation: Int) -> [URL: Entry]? {
        lock.lock()
        defer { lock.unlock() }

        guard let value = values[serverID], value.generation == generation else { return nil }
        return value.entries
    }

    func set(serverID: String, generation: Int, entries: [URL: Entry]) {
        lock.lock()
        defer { lock.unlock() }

        values[serverID] = CacheValue(
            generation: generation,
            entries: entries
        )
    }

    func clear(serverID: String) {
        lock.lock()
        defer { lock.unlock() }

        values.removeValue(forKey: serverID)
    }
}

extension Container {
    var serverURLTestCache: Factory<ServerURLTestCache> {
        self { ServerURLTestCache() }.singleton
    }
}
