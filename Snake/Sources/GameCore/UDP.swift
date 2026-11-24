import Darwin
import Foundation

public struct Endpoint: Hashable {
  public let address: String
  public let port: UInt16
  public init(address: String, port: UInt16) {
    self.address = address
    self.port = port
  }
}

private func withAddress<T>(_ address: inout sockaddr_in, _ body: (UnsafeMutablePointer<sockaddr>) -> T) -> T {
  withUnsafeMutablePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1, body)
  }
}

private func socketError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

public final class UDPTransport {
  public static let group = Endpoint(address: "239.192.0.4", port: 9193)
  private let gameSocket: Int32
  private let interfaces: [in_addr]
  private var readers: [DispatchSourceRead] = []
  public private(set) var discoveryErrors: [String] = []
  public typealias Receive = (Data, Endpoint, Bool) -> Void

  public init(queue: DispatchQueue, receive: @escaping Receive) throws {
    gameSocket = try Self.openSocket(port: 0)
    interfaces = Self.multicastInterfaces()
    watch(gameSocket, multicast: false, queue: queue, receive: receive)
    do {
      let listener = try Self.openSocket(port: Self.group.port)
      for interface in interfaces {
        var membership = ip_mreq(imr_multiaddr: in_addr(s_addr: inet_addr(Self.group.address)), imr_interface: interface)
        if setsockopt(listener, IPPROTO_IP, IP_ADD_MEMBERSHIP, &membership, socklen_t(MemoryLayout.size(ofValue: membership))) < 0 {
          discoveryErrors.append(socketError().localizedDescription)
        }
      }
      watch(listener, multicast: true, queue: queue, receive: receive)
    } catch { discoveryErrors.append(error.localizedDescription) }
  }

  //создание и привязка сокета
  private static func openSocket(port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { throw socketError() }
    do {
      var enabled: Int32 = 1
      if port != 0 {
        for option in [SO_REUSEADDR, SO_REUSEPORT] {
          guard setsockopt(fd, SOL_SOCKET, option, &enabled, 4) == 0 else { throw socketError() }
        }
      }
      guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw socketError() } //неблокирующий режим
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = port.bigEndian
      guard withAddress(&address, { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }) == 0
      else { throw socketError() }
      return fd
    } catch {
      close(fd)
      throw error
    }
  }
  private static func multicastInterfaces() -> [in_addr] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return [] }
    defer { freeifaddrs(head) }
    var result: [in_addr] = []
    var node = head
    while let current = node {
      let item = current.pointee
      node = item.ifa_next
      let flags = UInt32(IFF_UP | IFF_MULTICAST)
      guard item.ifa_flags & flags == flags, let address = item.ifa_addr, address.pointee.sa_family == AF_INET
      else { continue }
      result.append(
        address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr })
    }
    return result
  }
  private func watch(_ fd: Int32, multicast: Bool, queue: DispatchQueue, receive: @escaping Receive) {
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler {
      var buffer = [UInt8](repeating: 0, count: 1201)
      for _ in 0..<64 {
        var peer = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withAddress(&peer) { recvfrom(fd, &buffer, 1201, 0, $0, &length) }
        if count < 0 { break }
        guard (1...1200).contains(count) else { continue }
        var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &peer.sin_addr, &ip, socklen_t(ip.count)) != nil else { continue }
        receive(
          Data(buffer.prefix(count)),
          Endpoint(address: String(cString: ip), port: UInt16(bigEndian: peer.sin_port)), multicast)
      }
    }
    source.setCancelHandler { close(fd) }
    readers.append(source)
    source.resume()
  }
  
  func catalogueEndpoint(for endpoint: Endpoint) -> Endpoint {
    isLocalAddress(endpoint.address) ? Endpoint(address: "127.0.0.1", port: endpoint.port) : endpoint
  }

  private func isLocalAddress(_ address: String) -> Bool {
    var parsed = in_addr()
    guard inet_pton(AF_INET, address, &parsed) == 1 else { return false }
    return address == "127.0.0.1" || interfaces.contains { $0.s_addr == parsed.s_addr }
  }

  func matchesLocalEndpoint(_ endpoint: Endpoint) -> Bool {
    var local = sockaddr_in()
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withAddress(&local) { getsockname(gameSocket, $0, &size) }
    guard result == 0, UInt16(bigEndian: local.sin_port) == endpoint.port else { return false }
    return isLocalAddress(endpoint.address)
  }

  public func send(_ data: Data, to peer: Endpoint) throws {
    guard (1...1200).contains(data.count) else { throw POSIXError(.EMSGSIZE) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = peer.port.bigEndian
    guard inet_pton(AF_INET, peer.address, &address.sin_addr) == 1 else {
      throw POSIXError(.EINVAL)
    }
    let sent = data.withUnsafeBytes { bytes in
      withAddress(&address) {
        sendto(
          gameSocket, bytes.baseAddress, bytes.count, 0, $0,
          socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard sent == data.count else { throw socketError() }
  }
  public func announce(_ bytes: Data) -> [Error] {
    var failures: [Error] = []
    for var interface in interfaces {
      do {
        guard
          setsockopt(
            gameSocket, IPPROTO_IP, IP_MULTICAST_IF, &interface,
            socklen_t(MemoryLayout<in_addr>.size)) == 0
        else { throw socketError() }
        try send(bytes, to: Self.group)
      } catch { failures.append(error) }
    }
    return failures
  }
  deinit { readers.forEach { $0.cancel() } }
}
