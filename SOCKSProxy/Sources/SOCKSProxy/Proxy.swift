import Foundation

import Darwin

final class Connection {
    private static let handshakeTimeout = 30.0
    enum Stage { case greeting, request, dns, connecting, relay, closing }
    let id: Int
    let client: Int32
    var remote: Int32 = -1
    var stage = Stage.greeting
    let upstream = ByteBuffer(), downstream = ByteBuffer() //клиент-> сервер, сервер -> клиент
    var clientEOF = false, remoteEOF = false
    var clientShutdown = false, remoteShutdown = false
    var deadline = now() + Connection.handshakeTimeout
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
    var deadline = Double.infinity //ожидание ответа только после сенд
    var queued = true
    var sendRetryAt = now()
    var queueDeadline = now() + 6
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
    private let listenAddress = "127.0.0.1"
    private let listenBacklog: Int32 = 128
    private let connectTimeout = 15.0
    private let closingTimeout = 2.0
    private let maxDNSAttempts = 3
    private let acceptRetryDelay = 0.2
    private let maxAcceptsPerEvent = 64
    private let maxDNSReadsPerEvent = 64
    private let maxIOOperationsPerEvent = 4
    private let millisecondsPerSecond = 1000.0
    private let dnsSendRetryDelay = 0.2
    private let dnsQueueTimeout = 6.0
    private var jobIDs: [UInt16] = []
    private var clientIDs: [Int] = []
    private let dnsReceiveCapacity = 65535

    init(port: UInt16, dnsIP: String, dnsPort: UInt16) throws {
        listener = try makeSocket(SOCK_STREAM)
        do { resolver = try makeSocket(SOCK_DGRAM) } catch { close(listener); throw error }
        do {
            var yes: Int32 = 1
            _ = setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var local = try address(listenAddress, port)
            guard withAddress(&local, { bind(listener, $0, $1) }) == 0, listen(listener, listenBacklog) == 0 else { throw systemError("listen/bind") }
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
        c.stage = .closing; c.deadline = now() + closingTimeout
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
            else if errno == EINPROGRESS { c.stage = .connecting; c.deadline = now() + connectTimeout }
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
            guard b[0] == 5 else { remove(c); return } //версия сокс и количество методов
            let size = Int(b[1]) + 2
            guard b.count >= size else { return }
            let noAuth = (2..<size).contains { b[$0] == 0 } //ищу 0х00 без аунт
            b.drop(size)
            c.downstream.append([5, noAuth ? 0 : 255])
            guard noAuth else { c.stage = .closing; c.deadline = now() + closingTimeout; b.clear(); return }
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
        for _ in 0..<maxAcceptsPerEvent {
            guard clients.count < maxClients else { return }
            let fd = accept(listener, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                if !wouldBlock() { acceptAfter = now() + acceptRetryDelay }
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
        for _ in 0..<maxIOOperationsPerEvent {
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
    func write(_ c: Connection, client: Bool, closeIfStalled: Bool = false) {
        let buffer = client ? c.downstream : c.upstream
        let before = buffer.count
        for _ in 0..<maxIOOperationsPerEvent {
            guard buffer.count > 0 else { break }
            let n = buffer.sendTo(client ? c.client : c.remote)
            if n < 0 {
                if errno == EINTR { continue }
                if !wouldBlock() { remove(c) }
                break
            }
            if n == 0 { break }
        }
        if closeIfStalled && before > 0 && buffer.count == before { remove(c) }
    }
    func finish(_ c: Connection) {
        guard clients[c.id] != nil else { return }
        if c.stage == .closing {
            if c.downstream.count == 0 { remove(c) }
            return
        }
        guard c.stage == .relay else { return }
        if c.clientEOF && c.upstream.count == 0 && !c.remoteShutdown {
            guard shutdownWrite(c.remote) else { remove(c); return }
            c.remoteShutdown = true
        }
        if c.remoteEOF && c.downstream.count == 0 && !c.clientShutdown {
            guard shutdownWrite(c.client) else { remove(c); return }
            c.clientShutdown = true
        }
        if c.clientEOF && c.remoteEOF && c.upstream.count == 0 && c.downstream.count == 0 { remove(c) }
    }
    private func shutdownWrite(_ fd: Int32) -> Bool {
        for _ in 0..<maxIOOperationsPerEvent {
            if shutdown(fd, SHUT_WR) == 0 { return true }
            if errno != EINTR { return false }
        }
        return false
    }

    func sendDNS(_ id: UInt16) {
        guard var job = jobs[id], job.queued, job.sendRetryAt <= now() else { return }
        guard now() < job.queueDeadline else {
            if let c = clients[job.clientID] { fail(c, 4) }
            return
        }
        let n = job.packet.withUnsafeBytes { send(resolver, $0.baseAddress, $0.count, 0) }
        if n == job.packet.count {
            job.attempts += 1 // Считаем только действительно отправленные датаграммы.
            job.deadline = now() + dnsTimeout
            job.queued = false
            jobs[id] = job
        } else if n < 0 {
            let error = errno
            if error == EAGAIN || error == EWOULDBLOCK || error == EINTR { return }
            switch error {
            case EACCES, EPERM, EBADF, ENOTSOCK, EINVAL, EMSGSIZE, EAFNOSUPPORT:
                if let c = clients[job.clientID] { fail(c, 4) }
            default: //временная ошибка чтобы повторить еще раз
                job.sendRetryAt = now() + dnsSendRetryDelay
                jobs[id] = job
            }
        } else if let c = clients[job.clientID] {
            fail(c, 4) //датаграмма отправляется целиком
        }
    }
    func readDNS() {
        var data = [UInt8](repeating: 0, count: dnsReceiveCapacity)
        for _ in 0..<maxDNSReadsPerEvent {
            let n = data.withUnsafeMutableBytes { recv(resolver, $0.baseAddress, $0.count, 0) }
            if n < 0 { if errno == EINTR { continue }; return }
            guard n >= DNS.headerSize else { continue }
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
        jobIDs.removeAll(keepingCapacity: true)
        jobIDs.append(contentsOf: jobs.keys)
        for id in jobIDs {
            guard var job = jobs[id] else { continue }
            guard let c = clients[job.clientID] else { jobs.removeValue(forKey: id); continue }
            if job.queued {
                if job.queueDeadline <= time { fail(c, 4) }
                else if job.sendRetryAt <= time { sendDNS(id) }
                continue
            }
            guard job.deadline <= time else { continue }
            if job.attempts == maxDNSAttempts { fail(c, 4); continue }
            job.queued = true
            job.sendRetryAt = time
            job.queueDeadline = time + dnsQueueTimeout
            jobs[id] = job
            sendDNS(id)
        }
        clientIDs.removeAll(keepingCapacity: true)
        clientIDs.append(contentsOf: clients.keys)
        for id in clientIDs {
            guard let c = clients[id] else { continue }
            if c.stage != .relay && c.stage != .dns && c.deadline <= time {
                if c.stage == .connecting { fail(c, 4) } else { remove(c) }
            }
        }
    }

    func run() throws {
        var polls: [pollfd] = []
        var owners: [(Int, Bool)] = []
        while true {
            timers()
            polls.removeAll(keepingCapacity: true)
            owners.removeAll(keepingCapacity: true)
            func add(_ fd: Int32, _ events: Int16, _ id: Int = -1, _ client: Bool = false) {
                guard events != 0 else { return }
                polls.append(pollfd(fd: fd, events: events, revents: 0)); owners.append((id, client))
            }
            let time = now()
            var nearestDeadline = Double.infinity
            var dnsEvents = Int16(POLLIN)
            for job in jobs.values {
                if job.queued {
                    nearestDeadline = min(nearestDeadline, job.queueDeadline)
                    if job.sendRetryAt <= time { dnsEvents |= Int16(POLLOUT) }
                    else { nearestDeadline = min(nearestDeadline, job.sendRetryAt) }
                } else {
                    nearestDeadline = min(nearestDeadline, job.deadline)
                }
            }
            if clients.count < maxClients && time >= acceptAfter { add(listener, Int16(POLLIN)) }
            if acceptAfter > time { nearestDeadline = min(nearestDeadline, acceptAfter) }
            add(resolver, dnsEvents)
            for c in clients.values {
                if c.stage != .relay && c.stage != .dns {
                    nearestDeadline = min(nearestDeadline, c.deadline)
                }
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
            let timeout: Int32 = nearestDeadline.isFinite
                ? Int32(min(Double(Int32.max), max(1, ((nearestDeadline - now()) * millisecondsPerSecond).rounded(.up))))
                : -1
            let result = polls.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), timeout) }
            if result < 0 { if errno == EINTR { continue }; throw systemError("poll") }
            for i in polls.indices where polls[i].revents != 0 {
                let p = polls[i]
                if p.fd == listener { acceptClients(); continue }
                if p.fd == resolver {
                    if p.revents & Int16(POLLIN | POLLERR) != 0 { readDNS() }
                    if p.revents & Int16(POLLOUT) != 0 {
                        jobIDs.removeAll(keepingCapacity: true)
                        jobIDs.append(contentsOf: jobs.keys)
                        for id in jobIDs { sendDNS(id) }
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
                    let hungUp = p.revents & Int16(POLLHUP) != 0
                    let canRead = p.events & Int16(POLLIN) != 0
                    if (p.revents & Int16(POLLIN) != 0 || hungUp) && canRead { read(c, client: client) }
                    guard clients[id] != nil else { continue }
                    let hupWrite = hungUp && !canRead && p.events & Int16(POLLOUT) != 0
                    if p.revents & Int16(POLLOUT) != 0 || hupWrite {
                        write(c, client: client, closeIfStalled: hungUp && !canRead)
                    }
                }
                finish(c)
            }
        }
    }
}
