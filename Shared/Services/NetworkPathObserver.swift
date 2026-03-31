//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2025 Jellyfin & Jellyfin Contributors
//

import Factory
import Foundation
import Network

final class NetworkPathObserver {

    private struct Snapshot: Equatable {
        let status: NWPath.Status
        let isExpensive: Bool
        let isConstrained: Bool
        let interfaceTypes: Set<NWInterface.InterfaceType>
    }

    private let lock = NSLock()
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "swiftfin.network-path-monitor")

    private var hasPendingPathChange: Bool = false
    private var isStarted: Bool = false
    private var latestSnapshot: Snapshot?

    func start() {
        lock.lock()
        defer { lock.unlock() }

        guard !isStarted else { return }
        isStarted = true

        monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        monitor.start(queue: queue)
    }

    func consumePendingPathChange() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let didChange = hasPendingPathChange
        hasPendingPathChange = false
        return didChange
    }

    private func handlePathUpdate(_ path: NWPath) {
        let snapshot = Snapshot(
            status: path.status,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            interfaceTypes: Set(
                [
                    NWInterface.InterfaceType.wifi,
                    .cellular,
                    .wiredEthernet,
                    .loopback,
                    .other,
                ]
                .filter { path.usesInterfaceType($0) }
            )
        )

        lock.lock()
        defer { lock.unlock() }

        if let latestSnapshot, latestSnapshot != snapshot {
            hasPendingPathChange = true
        }

        latestSnapshot = snapshot
    }
}

extension Container {
    var networkPathObserver: Factory<NetworkPathObserver> {
        self { NetworkPathObserver() }.singleton
    }
}
