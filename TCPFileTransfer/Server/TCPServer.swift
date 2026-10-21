import Foundation
import Darwin

final class TCPServer {
    private let port: UInt16
    init(port: UInt16) { self.port = port }

    func run() throws {
        let listener = socket(AF_INET, SOCK_STREAM, Int32(IPPROTO_TCP))
        guard listener >= 0 else { throw systemError("socket") }
        defer { close(listener) }
        var reuse: Int32 = 1
        guard setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse))) == 0 else {
            throw systemError("setsockopt")
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw systemError("bind") }
        guard listen(listener, SOMAXCONN) == 0 else { throw systemError("listen") } 

        var attributes = pthread_attr_t()
        var code = pthread_attr_init(&attributes)
        guard code == 0 else { throw AppError.message("pthread_attr_init: \(code)") }
        defer { pthread_attr_destroy(&attributes) }
        code = pthread_attr_setdetachstate(&attributes, Int32(PTHREAD_CREATE_DETACHED))
        guard code == 0 else { throw AppError.message("pthread_attr_setdetachstate: \(code)") }
        print("Server started on port \(port)")

        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno != EINTR { print(systemError("accept")) }
                continue
            }
            startClientThread(socket: client, attributes: &attributes)
        }
    }

    private func startClientThread(socket: Int32, attributes: inout pthread_attr_t) {
        let handler = ClientHandler(socket: socket)
        let context = Unmanaged.passRetained(handler).toOpaque()
        var thread: pthread_t?
        let result = pthread_create(&thread, &attributes, handleClient, context)

        if result != 0 {
            Unmanaged<ClientHandler>.fromOpaque(context).release()
            close(socket)
            print("pthread_create: \(String(cString: strerror(result)))")
        }
    }
}

private func handleClient(_ context: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    let handler = Unmanaged<ClientHandler>.fromOpaque(context).takeRetainedValue()
    handler.run()
    return nil
}
