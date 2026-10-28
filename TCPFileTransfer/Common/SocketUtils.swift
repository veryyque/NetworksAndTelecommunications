import Foundation
import Darwin

func setSocketTimeouts(_ socket: Int32) throws {
    var timeout = timeval(tv_sec: 30, tv_usec: 0)
    for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
        guard setsockopt(socket, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw systemError("setsockopt timeout")
        }
    }
}

func sendAll(_ socket: Int32, _ bytes: [UInt8]) throws {
    try bytes.withUnsafeBytes { try sendAll(socket, $0) }
}

func sendAll(_ socket: Int32, _ buffer: UnsafeRawBufferPointer) throws {
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

private func connectWithTimeout(_ fd: Int32, _ address: addrinfo) throws {
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw systemError("fcntl") }
    defer { _ = fcntl(fd, F_SETFL, flags) }
    if connect(fd, address.ai_addr, address.ai_addrlen) == 0 { return }
    guard errno == EINPROGRESS else { throw systemError("connect") }
    let deadline = ProcessInfo.processInfo.systemUptime + 30
    while true {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw AppError.message("connect timeout") }
        var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let result = poll(&event, 1, Int32(remaining * 1000))
        if result < 0 && errno == EINTR { continue }
        guard result > 0 else { throw AppError.message("connect failed or timed out") }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { throw systemError("getsockopt") }
        guard error == 0 else { throw AppError.message("connect: \(String(cString: strerror(error)))") }
        return
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
            do {
                try connectWithTimeout(fd, address)
                try setSocketTimeouts(fd)
                return fd
            } catch {
                lastError = AppError.message(String(describing: error))
            }
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
