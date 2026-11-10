import Foundation
import Darwin
import SystemConfiguration

struct ProxyError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
func systemError(_ operation: String) -> ProxyError {
    ProxyError("\(operation): \(String(cString: strerror(errno)))")
}
func now() -> Double {
    var t = timespec()
    clock_gettime(CLOCK_MONOTONIC, &t)
    return Double(t.tv_sec) + Double(t.tv_nsec) / 1000000000
}
func wouldBlock() -> Bool { errno == EAGAIN || errno == EWOULDBLOCK }
func makeSocket(_ type: Int32) throws -> Int32 {
    let fd = socket(AF_INET, type, 0)
    guard fd >= 0 else { throw systemError("socket") }
    do { try configure(fd, stream: type == SOCK_STREAM) } catch { close(fd); throw error }
    return fd
}
func configure(_ fd: Int32, stream: Bool = true) throws {
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw systemError("fcntl") }
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    var yes: Int32 = 1
    if stream {
        guard setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw systemError("TCP_NODELAY")
        }
    }
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw systemError("SO_NOSIGPIPE")
    }
}
func address(_ ip: String, _ port: UInt16) throws -> sockaddr_in {
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian
    guard ip.withCString({ inet_pton(AF_INET, $0, &a.sin_addr) }) == 1 else {
        throw ProxyError("Некорректный IPv4: \(ip)")
    }
    return a
}
func withAddress<T>(_ a: inout sockaddr_in, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &a) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
}

//на старте программы, если DNS не указан
func systemResolver() throws -> String {
    if let store = SCDynamicStoreCreate(nil, "SOCKSProxy" as CFString, nil, nil) { //получение динамических сетевых настроек
        var keys = ["State:/Network/Global/DNS"]
        if let services = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/DNS" as CFString) as? [String] {
            keys += services.sorted()
        }
        for key in keys {
            if let settings = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
               let servers = settings["ServerAddresses"] as? [String] {
                for ip in servers where (try? address(ip, 53)) != nil { return ip }
            }
        }
    }
    if let config = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) {
        for line in config.split(separator: "\n") {
            let words = line.split(whereSeparator: { $0.isWhitespace })
            if words.count >= 2, words[0] == "nameserver", (try? address(String(words[1]), 53)) != nil {
                return String(words[1])
            }
        }
    }
    throw ProxyError("Не найден системный IPv4 DNS. Укажите второй аргумент, например 1.1.1.1:53")
}

final class ByteBuffer {
    static let capacity = 64 * 1024
    private var storage = [UInt8](repeating: 0, count: capacity)
    private var readIndex = 0
    private var writeIndex = 0

    var count: Int { writeIndex - readIndex }
    var free: Int { Self.capacity - count }

    subscript(_ index: Int) -> UInt8 {
        precondition(index >= 0 && index < count)
        return storage[readIndex + index]
    }

    func drop(_ n: Int) {
        precondition(n >= 0 && n <= count)
        readIndex += n
        if readIndex == writeIndex {
            clear()
        }
    }

    func clear() {
        readIndex = 0
        writeIndex = 0
    }

    private func compact() {
        let remaining = count
        for index in 0..<remaining {
            storage[index] = storage[readIndex + index]
        }
        readIndex = 0
        writeIndex = remaining
    }

    func append(_ values: [UInt8]) {
        precondition(values.count <= free)
        if Self.capacity - writeIndex < values.count {
            compact()
        }
        for value in values {
            storage[writeIndex] = value
            writeIndex += 1
        }
    }

    func receive(_ fd: Int32) -> Int {
        guard free > 0 else {
            errno = EAGAIN
            return -1
        }
        if writeIndex == Self.capacity {
            compact()
        }
        let start = writeIndex
        let available = Self.capacity - start
        let bytesRead = storage.withUnsafeMutableBytes { memory in
            recv(fd, memory.baseAddress!.advanced(by: start), available, 0)
        }
        if bytesRead > 0 {
            writeIndex += bytesRead
        }
        return bytesRead
    }

    func sendTo(_ fd: Int32) -> Int {
        guard count > 0 else { return 0 }
        let start = readIndex
        let available = count
        let bytesSent = storage.withUnsafeBytes { memory in
            send(fd, memory.baseAddress!.advanced(by: start), available, 0)
        }
        if bytesSent > 0 {
            drop(bytesSent)
        }
        return bytesSent
    }
}
