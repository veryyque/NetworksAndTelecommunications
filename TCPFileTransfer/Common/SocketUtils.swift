import Foundation
import Darwin

func sendAll(_ socket: Int32, _ bytes: [UInt8]) throws {
    try bytes.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        var sent = 0
        while sent < buffer.count {
            let n = send(socket, base.advanced(by: sent), buffer.count - sent, 0)
            if n < 0 {
                if errno == EINTR { continue }
                throw systemError("send")
            }
            guard n > 0 else { throw AppError.message("send returned zero") }
            sent += n
        }
    }
}

func recvAll(_ socket: Int32, count: Int) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    try bytes.withUnsafeMutableBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        var received = 0
        while received < count {
            let n = recv(socket, base.advanced(by: received), count - received, 0)
            if n < 0 {
                if errno == EINTR { continue }
                throw systemError("recv")
            }
            guard n > 0 else { throw AppError.message("Connection closed too early") }
            received += n
        }
    }
    return bytes
}

func connectToServer(host: String, port: UInt16) throws -> Int32 {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = Int32(IPPROTO_TCP)
    var result: UnsafeMutablePointer<addrinfo>?
    let code = getaddrinfo(host, String(port), &hints, &result)
    guard code == 0 else {
        throw AppError.message("getaddrinfo: \(String(cString: gai_strerror(code)))")
    }
    defer { if let result = result { freeaddrinfo(result) } }
    var current = result
    var lastError = AppError.message("No suitable server address")
    while let entry = current {
        let address = entry.pointee
        let fd = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
        if fd >= 0 {
            if connect(fd, address.ai_addr, address.ai_addrlen) == 0 { return fd }
            lastError = systemError("connect")
            close(fd)
        } else { lastError = systemError("socket") }
        current = address.ai_next
    }
    throw lastError
}

func peerName(_ socket: Int32) -> String {
    var address = sockaddr_storage()
    var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let code = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addr in
            guard getpeername(socket, addr, &length) == 0 else { return Int32(-1) }
            return getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        }
    }
    return code == 0 ? String(cString: host) : "unknown"
}
