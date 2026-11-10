import Foundation

import Darwin

final class Connection {
    enum Stage { case greeting, request, dns, connecting, relay, closing }
    let id: Int
    let client: Int32
    var remote: Int32 = -1
    var stage = Stage.greeting
    let upstream = ByteBuffer(), downstream = ByteBuffer() //клиент-> сервер, сервер -> клиент
    var clientEOF = false, remoteEOF = false
    var clientShutdown = false, remoteShutdown = false
    var deadline = now() + 30
    var port: UInt16 = 0
    var dnsID: UInt16?
    init(_ id: Int, _ client: Int32) { self.id = id; self.client = client }
    deinit { close(client); if remote >= 0 { close(remote) } }
}
struct DNSJob {
    let clientID: Int
    let name: String
    let packet: [UInt8]
    var attempts = 0
    var deadline = now()
    var queued = false
}

final class Proxy {
    let listener: Int32, resolver: Int32 //TCP сокет и общий UDP для DNS
    var clients: [Int: Connection] = [:]
    var jobs: [UInt16: DNSJob] = [:]
    var nextID = 0
    var nextDNS = UInt16(truncatingIfNeeded: arc4random())
    var acceptAfter = 0.0
    let dnsTimeout = 2.0
    let maxClients = 512

    init(port: UInt16, dnsIP: String, dnsPort: UInt16) throws {
        listener = try makeSocket(SOCK_STREAM)
        do { resolver = try makeSocket(SOCK_DGRAM) } catch { close(listener); throw error }
        do {
            var yes: Int32 = 1
            _ = setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var local = try address("127.0.0.1", port)
            guard withAddress(&local, { bind(listener, $0, $1) }) == 0, listen(listener, 128) == 0 else { throw systemError("listen/bind") }
            var dns = try address(dnsIP, dnsPort)
            guard withAddress(&dns, { connect(resolver, $0, $1) }) == 0 else { throw systemError("DNS connect") }
        } catch { close(listener); close(resolver); throw error }
    }
    deinit { close(listener); close(resolver) }

    func remove(_ c: Connection) {
        if let id = c.dnsID { jobs.removeValue(forKey: id); c.dnsID = nil }
        clients.removeValue(forKey: c.id)
    }
    func fail(_ c: Connection, _ rep: UInt8) {
        if let id = c.dnsID { jobs.removeValue(forKey: id); c.dnsID = nil }
        if c.remote >= 0 { close(c.remote); c.remote = -1 }
        c.upstream.clear()
        c.downstream.append([5, rep, 0, 1, 0, 0, 0, 0, 0, 0]) //сокс5, код ошибки, резерв поле, IPv4, нулевой адрес, нулевой порт
        c.stage = .closing; c.deadline = now() + 2
    }
    func connected(_ c: Connection) {
        var a = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &a) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(c.remote, $0, &length) }
        }
        guard ok == 0 else { fail(c, 1); return }
        let ip = withUnsafeBytes(of: a.sin_addr.s_addr) { Array($0) }
        let port = UInt16(bigEndian: a.sin_port)
        c.downstream.append([5, 0, 0, 1] + ip + [UInt8(port >> 8), UInt8(port & 255)])
        c.stage = .relay
    }
    func connectRemote(_ c: Connection, _ ip: [UInt8]) {
        do {
            c.remote = try makeSocket(SOCK_STREAM)
            var a = try address(ip.map(String.init).joined(separator: "."), c.port)
            let result = withAddress(&a) { connect(c.remote, $0, $1) }
            if result == 0 { connected(c) }
            else if errno == EINPROGRESS { c.stage = .connecting; c.deadline = now() + 15 }
            else { fail(c, code(errno)) }
        } catch { fail(c, 1) }
    }
    func code(_ error: Int32) -> UInt8 { //перевод системной ошибки в сокс5
        switch error {
        case ECONNREFUSED: return 5
        case ENETUNREACH: return 3
        case EHOSTUNREACH, ETIMEDOUT: return 4
        case EACCES, EPERM: return 2
        default: return 1
        }
    }
    func parse(_ c: Connection) {
        let b = c.upstream
        if c.stage == .greeting {
            guard b.count >= 2 else { return }
            guard b[0] == 5, b[1] > 0 else { remove(c); return } //версия сокс и количество методов
            let size = Int(b[1]) + 2
            guard b.count >= size else { return }
            let noAuth = (2..<size).contains { b[$0] == 0 } //ищу 0х00 без аунт
            b.drop(size)
            c.downstream.append([5, noAuth ? 0 : 255])
            guard noAuth else { c.stage = .closing; c.deadline = now() + 2; b.clear(); return }
            c.stage = .request
        }
        if c.stage == .request {
            guard b.count >= 4 else { return }
            guard b[0] == 5, b[2] == 0 else { fail(c, 1); return }
            guard b[1] == 1 else { fail(c, 7); return } //ошибка манда не поддерживется
            let size: Int
            switch b[3] {
            case 1: size = 10
            case 3:
                guard b.count >= 5 else { return }
                guard b[4] > 0 else { fail(c, 4); return }
                size = 7 + Int(b[4])
            default: fail(c, 8); return
            }
            guard b.count >= size else { return }
            c.port = UInt16(b[size-2]) << 8 | UInt16(b[size-1])
            if b[3] == 1 {
                let ip = (4..<8).map { b[$0] }
                b.drop(size); connectRemote(c, ip)
            } else {
                let bytes = (5..<(size-2)).map { b[$0] }
                b.drop(size)
                guard let name = String(bytes: bytes, encoding: .ascii) else { fail(c, 4); return }
                do {
                    repeat { nextDNS &+= 1 } while jobs[nextDNS] != nil
                    let packet = try DNS.makeQuery(id: nextDNS, name: name)
                    c.stage = .dns; c.dnsID = nextDNS
                    jobs[nextDNS] = DNSJob(clientID: c.id, name: name, packet: packet)
                } catch { fail(c, 4) }
            }
        }
    }
    func acceptClients() {
        for _ in 0..<64 {
            guard clients.count < maxClients else { return }
            let fd = accept(listener, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                if !wouldBlock() { acceptAfter = now() + 0.2 }
                return
            }
            do { try configure(fd) } catch { close(fd); continue }
            nextID += 1
            clients[nextID] = Connection(nextID, fd)
        }
    }
    func read(_ c: Connection, client: Bool) {
        let buffer = client ? c.upstream : c.downstream
        let fd = client ? c.client : c.remote
        //ставлю макс 4 попытки чтения чтобы обрабатывать остальных клиентов
        for _ in 0..<4 {
            guard buffer.free > 0 else { break }
            let n = buffer.receive(fd)
            if n > 0 {
                if client { parse(c); if clients[c.id] == nil || c.stage == .closing { return } }
            } else if n == 0 {
                if client { c.clientEOF = true } else { c.remoteEOF = true }
                if c.stage == .greeting || c.stage == .request { remove(c) }
                break
            } else {
                if errno == EINTR { continue }
                if !wouldBlock() { remove(c) }
                break
            }
        }
    }
    func write(_ c: Connection, client: Bool) {
        let buffer = client ? c.downstream : c.upstream
        for _ in 0..<4 {
            guard buffer.count > 0 else { break }
            let n = buffer.sendTo(client ? c.client : c.remote)
            if n < 0 {
                if errno == EINTR { continue }
                if !wouldBlock() { remove(c) }
                break
            }
            if n == 0 { break }
        }
    }
    func finish(_ c: Connection) {
        guard clients[c.id] != nil else { return }
        if c.stage == .closing {
            if c.downstream.count == 0 { remove(c) }
            return
        }
        guard c.stage == .relay else { return }
        if c.clientEOF && c.upstream.count == 0 && !c.remoteShutdown {
            _ = shutdown(c.remote, SHUT_WR); c.remoteShutdown = true
        }
        if c.remoteEOF && c.downstream.count == 0 && !c.clientShutdown {
            _ = shutdown(c.client, SHUT_WR); c.clientShutdown = true
        }
        if c.clientEOF && c.remoteEOF && c.upstream.count == 0 && c.downstream.count == 0 { remove(c) }
    }
    func sendDNS(_ id: UInt16) {
        guard var job = jobs[id], job.queued else { return }
        let n = job.packet.withUnsafeBytes { send(resolver, $0.baseAddress, $0.count, 0) }
        if n == job.packet.count { job.queued = false; jobs[id] = job }
        else if n < 0 && (wouldBlock() || errno == EINTR) { return }
        else if let c = clients[job.clientID] { fail(c, 4) }
    }
    func readDNS() {
        var data = [UInt8](repeating: 0, count: 65535)
        for _ in 0..<64 {
            let n = data.withUnsafeMutableBytes { recv(resolver, $0.baseAddress, $0.count, 0) }
            if n < 0 { if errno == EINTR { continue }; return }
            guard n >= 12 else { continue }
            let id = UInt16(DNS.readUInt16(data, at: 0))
            guard let job = jobs[id], let c = clients[job.clientID],
                  let reply = DNS.parseResponse(Array(data.prefix(n)), expected: job.name) else { continue }
            jobs.removeValue(forKey: id); c.dnsID = nil
            switch reply {
            case .address(let ip): connectRemote(c, ip)
            case .failure: fail(c, 4)
            }
        }
    }
    func timers() {
        let time = now()
        for id in Array(jobs.keys) {
            guard var job = jobs[id], job.deadline <= time else { continue }
            guard let c = clients[job.clientID] else { jobs.removeValue(forKey: id); continue }
            if job.attempts == 3 { fail(c, 4); continue }
            job.attempts += 1; job.deadline = time + dnsTimeout; job.queued = true
            jobs[id] = job; sendDNS(id)
        }
        for c in Array(clients.values) {
            if c.stage != .relay && c.stage != .dns && c.deadline <= time {
                if c.stage == .connecting { fail(c, 4) } else { remove(c) }
            }
        }
    }
    func run() throws {
        while true {
            timers()
            var polls: [pollfd] = [], owners: [(Int, Bool)] = []
            func add(_ fd: Int32, _ events: Int16, _ id: Int = -1, _ client: Bool = false) {
                guard events != 0 else { return }
                polls.append(pollfd(fd: fd, events: events, revents: 0)); owners.append((id, client))
            }
            if clients.count < maxClients && now() >= acceptAfter { add(listener, Int16(POLLIN)) }
            add(resolver, Int16(POLLIN) | (jobs.values.contains(where: { $0.queued }) ? Int16(POLLOUT) : 0))
            for c in clients.values {
                var events: Int16 = 0
                if c.stage != .closing && !c.clientEOF && c.upstream.free > 0 { events |= Int16(POLLIN) }
                if c.downstream.count > 0 { events |= Int16(POLLOUT) }
                add(c.client, events, c.id, true)
                if c.stage == .connecting { add(c.remote, Int16(POLLOUT), c.id) }
                else if c.stage == .relay {
                    events = 0
                    if !c.remoteEOF && c.downstream.free > 0 { events |= Int16(POLLIN) }
                    if c.upstream.count > 0 { events |= Int16(POLLOUT) }
                    add(c.remote, events, c.id)
                }
            }
            var deadlines = jobs.values.map { $0.deadline }
            deadlines += clients.values.filter { $0.stage != .relay && $0.stage != .dns }.map { $0.deadline }
            if acceptAfter > now() { deadlines.append(acceptAfter) }
            let timeout: Int32 = deadlines.min().map { Int32(min(2_147_483_647, max(1, (($0 - now()) * 1000).rounded(.up)))) } ?? -1
            let result = polls.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), timeout) }
            if result < 0 { if errno == EINTR { continue }; throw systemError("poll") }
            for i in polls.indices where polls[i].revents != 0 {
                let p = polls[i]
                if p.fd == listener { acceptClients(); continue }
                if p.fd == resolver {
                    if p.revents & Int16(POLLIN | POLLERR) != 0 { readDNS() }
                    if p.revents & Int16(POLLOUT) != 0 {
                        for id in Array(jobs.keys) { sendDNS(id) }
                    }
                    continue
                }
                let (id, client) = owners[i]
                guard let c = clients[id] else { continue }
                if !client && c.stage == .connecting {
                    var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
                    if getsockopt(c.remote, SOL_SOCKET, SO_ERROR, &error, &length) != 0 { fail(c, 1) }
                    else if error != 0 { fail(c, code(error)) } else { connected(c) }
                } else {
                    if p.revents & Int16(POLLNVAL | POLLERR) != 0 { remove(c); continue }
                    if p.revents & Int16(POLLIN | POLLHUP) != 0 && p.events & Int16(POLLIN) != 0 { read(c, client: client) }
                    guard clients[id] != nil else { continue }
                    if p.revents & Int16(POLLOUT) != 0 { write(c, client: client) }
                    if p.revents & Int16(POLLHUP) != 0 && p.events & Int16(POLLIN) == 0 && p.events & Int16(POLLOUT) != 0 {
                        write(c, client: client)
                    }
                }
                finish(c)
            }
        }
    }
}
