import Foundation

final class PeerManager {
    private var peers: [String: Peer] = [:]
    private let timeout: Double

    init(timeout: Double) {
        self.timeout = timeout
    }

    func updatePeer(id: String, ip: String) {
        let oldPeer = peers[id]
        peers[id] = Peer(ip: ip, lastSeen: currentTime())

        if oldPeer == nil {
            print("\nПоявилась копия: \(ip) | UUID: \(id)")
            printPeers()
        } else if let oldPeer = oldPeer, oldPeer.ip != ip {
            print("\nУ копии изменился IP: \(oldPeer.ip) -> \(ip) | UUID: \(id)")
            printPeers()
        }
    }

    func removeExpiredPeers() {
        var expiredIDs: [String] = []
        let now = currentTime()

        for (id, peer) in peers {
            if now - peer.lastSeen >= timeout {
                expiredIDs.append(id)
            }
        }

        for id in expiredIDs {
            if let peer = peers.removeValue(forKey: id) {
                print("\nИстёк тайм-аут копии: \(peer.ip) | UUID: \(id)")
            }
        }

        if !expiredIDs.isEmpty {
            printPeers()
        }
    }

    func printPeers() {
        print("Живые копии: \(peers.count)")

        if peers.isEmpty {
            print("  Других копий пока нет.")
            return
        }

        let sortedPeers = peers.sorted {
            if $0.value.ip != $1.value.ip { return $0.value.ip < $1.value.ip }
            return $0.key < $1.key
        }
        for (id, peer) in sortedPeers {
            print("  \(peer.ip) | UUID: \(id)")
        }
    }

    private func currentTime() -> Double {
        return ProcessInfo.processInfo.systemUptime
    }
}
