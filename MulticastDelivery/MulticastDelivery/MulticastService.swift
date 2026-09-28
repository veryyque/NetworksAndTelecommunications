import Foundation
import Darwin
import SystemConfiguration

final class MulticastService {
    private let id = UUID().uuidString
    private let group: String
    private let family: Int32
    private let peerManager: PeerManager
    private var networkInterface: NetworkInterface
    private let requestedInterfaceName: String?
    private var lastNetworkError: String?

    private var socketFD: Int32 = -1
    private var destination4 = sockaddr_in()
    private var destination6 = sockaddr_in6()

    init(group: String, family: Int32, interfaceName: String? = nil, peerManager: PeerManager) throws {
        self.group = group
        self.family = family
        self.peerManager = peerManager
        self.requestedInterfaceName = interfaceName
        self.networkInterface = try MulticastService.findInterface(family: family, requestedName: interfaceName)

        try openSocket()
    }

    private func openSocket() throws {
        socketFD = socket(family, SOCK_DGRAM, IPPROTO_UDP)
        try Utils.check(socketFD, "Создание UDP-сокета")

        do {
            var yes: Int32 = 1
            let size = socklen_t(MemoryLayout<Int32>.size)
            try Utils.check(setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, size), "SO_REUSEADDR")
            try Utils.check(setsockopt(socketFD, SOL_SOCKET, SO_REUSEPORT, &yes, size), "SO_REUSEPORT")

            if family == AF_INET {
                try configureIPv4()
            } else {
                try configureIPv6()
            }

            let flags = fcntl(socketFD, F_GETFL, 0)
            try Utils.check(flags, "Чтение флагов сокета")
            try Utils.check(fcntl(socketFD, F_SETFL, flags | O_NONBLOCK), "Неблокирующий режим")
        } catch {
            close(socketFD)
            socketFD = -1
            throw error
        }
    }

    deinit {
        if socketFD >= 0 {
            close(socketFD)
        }
    }

    private func closeSocket() {
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }

    private func refreshInterface() throws {
        let current = try MulticastService.findInterface(family: family, requestedName: requestedInterfaceName)
        let changed = current.index != networkInterface.index
            || current.name != networkInterface.name
            || current.ipv4Address.s_addr != networkInterface.ipv4Address.s_addr
            || current.addresses != networkInterface.addresses
        guard changed || socketFD < 0 else { return }

        let previous = networkInterface
        closeSocket()
        networkInterface = current
        do {
            try openSocket()
        } catch {
            networkInterface = previous
            throw error
        }
        if changed {
            print("Сеть этой копии изменилась: \(previous.name) [\(previous.addresses.joined(separator: ", "))] -> \(current.name) [\(current.addresses.joined(separator: ", "))] | UUID: \(id)")
        }
    }

    private func configureIPv4() throws {
        var groupAddress = in_addr()
        inet_pton(AF_INET, group, &groupAddress)

        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = Utils.port.bigEndian
        local.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                Darwin.bind(socketFD, address, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try Utils.check(bindResult, "Привязка к UDP-порту \(Utils.port)")

        var membership = ip_mreq()
        membership.imr_multiaddr = groupAddress
        membership.imr_interface = networkInterface.ipv4Address
        try Utils.check(setsockopt(socketFD, IPPROTO_IP, IP_ADD_MEMBERSHIP, &membership, socklen_t(MemoryLayout<ip_mreq>.size)), "Вступление в IPv4-группу")

        var interfaceAddress = networkInterface.ipv4Address
        try Utils.check(setsockopt(socketFD, IPPROTO_IP, IP_MULTICAST_IF, &interfaceAddress, socklen_t(MemoryLayout<in_addr>.size)), "Выбор IPv4-интерфейса")

        var one: UInt8 = 1
        try Utils.check(setsockopt(socketFD, IPPROTO_IP, IP_MULTICAST_TTL, &one, 1), "IPv4 TTL")
        try Utils.check(setsockopt(socketFD, IPPROTO_IP, IP_MULTICAST_LOOP, &one, 1), "IPv4 loopback")

        destination4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination4.sin_family = sa_family_t(AF_INET)
        destination4.sin_port = Utils.port.bigEndian
        destination4.sin_addr = groupAddress
    }

    private func configureIPv6() throws {
        var groupAddress = in6_addr()
        inet_pton(AF_INET6, group, &groupAddress)

        var local = sockaddr_in6()
        local.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        local.sin6_family = sa_family_t(AF_INET6)
        local.sin6_port = Utils.port.bigEndian

        let bindResult = withUnsafePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                Darwin.bind(socketFD, address, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        try Utils.check(bindResult, "Привязка к UDP-порту \(Utils.port)")

        var membership = ipv6_mreq()
        membership.ipv6mr_multiaddr = groupAddress
        membership.ipv6mr_interface = networkInterface.index
        try Utils.check(setsockopt(socketFD, IPPROTO_IPV6, IPV6_JOIN_GROUP, &membership, socklen_t(MemoryLayout<ipv6_mreq>.size)), "Вступление в IPv6-группу")

        var index = networkInterface.index
        try Utils.check(setsockopt(socketFD, IPPROTO_IPV6, IPV6_MULTICAST_IF, &index, socklen_t(MemoryLayout<UInt32>.size)), "Выбор IPv6-интерфейса")

        var hops: Int32 = 1
        var loop: UInt32 = 1
        try Utils.check(setsockopt(socketFD, IPPROTO_IPV6, IPV6_MULTICAST_HOPS, &hops, socklen_t(MemoryLayout<Int32>.size)), "IPv6 hop limit")
        try Utils.check(setsockopt(socketFD, IPPROTO_IPV6, IPV6_MULTICAST_LOOP, &loop, socklen_t(MemoryLayout<UInt32>.size)), "IPv6 loopback")

        destination6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        destination6.sin6_family = sa_family_t(AF_INET6)
        destination6.sin6_port = Utils.port.bigEndian
        destination6.sin6_addr = groupAddress
        destination6.sin6_scope_id = networkInterface.index
    }

    private func sendHeartbeat() throws {
        let bytes = Array("\(Utils.messagePrefix)|\(id)".utf8)
        while true {
            let sent: Int
    
            if family == AF_INET {
                sent = withUnsafePointer(to: &destination4) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                        sendto(socketFD, bytes, bytes.count, 0, address, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            } else {
                sent = withUnsafePointer(to: &destination6) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                        sendto(socketFD, bytes, bytes.count, 0, address, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
            }
            if sent >= 0 { return }
            let errorCode = errno
            
            if errorCode == EINTR { continue }
            if errorCode == EAGAIN || errorCode == EWOULDBLOCK { return }
            throw AppError(message: "Ошибка отправки: \(String(cString: strerror(errorCode)))")
        }
    }

    private func receiveMessages() throws {
        for _ in 0..<32 {
            var buffer = [UInt8](repeating: 0, count: 512)
            var sender = sockaddr_storage()
            var senderLength = socklen_t(MemoryLayout<sockaddr_storage>.size)

            let count = withUnsafeMutablePointer(to: &sender) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    recvfrom(socketFD, &buffer, buffer.count, 0, address, &senderLength)
                }
            }

            if count == -1 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                throw AppError(message: "Ошибка приёма: \(String(cString: strerror(errno)))")
            }

            guard let message = String(bytes: buffer.prefix(count), encoding: .utf8) else { continue }
            let parts = message.components(separatedBy: "|")
            guard parts.count == 2,
                  parts[0] == Utils.messagePrefix,
                  let peerUUID = UUID(uuidString: parts[1]) else { continue }
            let peerID = peerUUID.uuidString
            if peerID == id { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = withUnsafePointer(to: &sender) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    getnameinfo(address, senderLength, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                }
            }

            if result == 0 {
                peerManager.updatePeer(id: peerID, ip: String(cString: host))
            }
        }
    }

    func run() throws {
        print("UUID этой копии: \(id)")
        print("Группа: \(group), порт: \(Utils.port)")
        print("Протокол: \(family == AF_INET ? "IPv4" : "IPv6")")
        print("Интерфейс: \(networkInterface.name)")
        print("Остановка: Ctrl+C или Stop в Xcode")
        peerManager.printPeers()

        var nextHeartbeat = 0.0

        while true {
            let now = ProcessInfo.processInfo.systemUptime
            do {
                if now >= nextHeartbeat {
                    nextHeartbeat = now + Utils.heartbeatInterval
                    try refreshInterface()
                    try sendHeartbeat()
                    if lastNetworkError != nil {
                        print("Связь восстановлена через \(networkInterface.name) | UUID: \(id)")
                        lastNetworkError = nil
                    }
                }
                if socketFD >= 0 { try receiveMessages() }
            } catch {
                let message = (error as? AppError)?.message ?? String(describing: error)
                if message != lastNetworkError {
                    print("Сеть недоступна: \(message). Повтор через \(Utils.heartbeatInterval) с.")
                }
                lastNetworkError = message
                closeSocket()
                nextHeartbeat = now + Utils.heartbeatInterval
            }
            peerManager.removeExpiredPeers()

            var descriptor = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, 200)
            if result == -1 && errno != EINTR {
                try Utils.check(result, "Ожидание UDP-пакета")
            }
        }
    }

    private static func findInterface(family: Int32, requestedName: String?) throws -> NetworkInterface {
        var first: UnsafeMutablePointer<ifaddrs>?
        try Utils.check(getifaddrs(&first), "Получение сетевых интерфейсов")
        defer { freeifaddrs(first) }

        let protocolName = family == AF_INET ? "IPv4" : "IPv6"
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        var connectionPriorities: [String: Int] = [:]
        for interface in interfaces {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String? else { continue }
            if type == kSCNetworkInterfaceTypeIEEE80211 as String {
                connectionPriorities[name] = 0
            } else if type == kSCNetworkInterfaceTypeEthernet as String {
                connectionPriorities[name] = 1
            }
        }

        var candidates: [UInt32: NetworkInterface] = [:]
        var priorities: [UInt32: Int] = [:]
        var current = first
        while let pointer = current {
            let item = pointer.pointee
            current = item.ifa_next
            guard let address = item.ifa_addr else { continue }

            let name = String(cString: item.ifa_name)
            if Int32(address.pointee.sa_family) != family { continue }
            if item.ifa_flags & UInt32(IFF_UP) == 0 { continue }
            if item.ifa_flags & UInt32(IFF_RUNNING) == 0 { continue }
            if item.ifa_flags & UInt32(IFF_MULTICAST) == 0 { continue }
            if requestedName == nil {
                if item.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) != 0 { continue }
                if connectionPriorities[name] == nil { continue }
            }
            var ipv4Address = in_addr()
            if family == AF_INET {
                ipv4Address = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    return $0.pointee.sin_addr
                }
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let numericAddress = String(cString: host)
            let index = if_nametoindex(item.ifa_name)
            if index != 0 && candidates[index] == nil {
                candidates[index] = NetworkInterface(name: name, index: index, ipv4Address: ipv4Address)
                priorities[index] = connectionPriorities[name] ?? 2
            }
            if index != 0 {
                candidates[index]?.addresses.append(numericAddress)
            }
        }
        for index in Array(candidates.keys) {
            let addresses = candidates[index]?.addresses ?? []
            candidates[index]?.addresses = Array(Set(addresses)).sorted()
        }

        let available = candidates.values.sorted {
            let leftPriority = priorities[$0.index] ?? 3
            let rightPriority = priorities[$1.index] ?? 3
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            return $0.name < $1.name
        }
        let names = available.map { $0.name }.joined(separator: ", ")

        if let requestedName = requestedName {
            guard let selected = available.first(where: { $0.name == requestedName }) else {
                throw AppError(message: "Интерфейс \(requestedName) недоступен для \(protocolName) multicast. Подходящие интерфейсы: \(names.isEmpty ? "нет" : names)")
            }
            return selected
        }

        guard let selected = available.first else {
            throw AppError(message: "Не найден активный Wi-Fi/Ethernet-интерфейс с поддержкой \(protocolName) multicast")
        }
        return selected
    }

}
