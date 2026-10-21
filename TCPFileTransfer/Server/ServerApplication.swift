import Foundation
import Darwin


enum ServerApplication {
    static func run() {
        signal(SIGPIPE, SIG_IGN) //чтобы сервер не завершался аварийно при ошибке записи в сокет
        do {
            guard CommandLine.arguments.count == 2 else {
                throw AppError.message("Usage: ./server <port>")
            }
            let port = try parsePort(CommandLine.arguments[1])
            try TCPServer(port: port).run()
        } catch {
            TransferLog.write("[server] ERROR | \(error)")
            exit(1)
        }
    }
}
