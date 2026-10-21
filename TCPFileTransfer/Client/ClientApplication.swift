import Foundation
import Darwin

enum ClientApplication {
    static func run() {
        signal(SIGPIPE, SIG_IGN)
        do {
            let args = CommandLine.arguments
            guard args.count == 4 else {
                throw AppError.message("Usage: ./client <file> <host> <port>")
            }
            let port = try parsePort(args[3])
            try TCPClient(filePath: args[1], host: args[2], port: port).sendFile()
        } catch {
            TransferLog.write("[client \(getpid())] ERROR | \(error)")
            exit(1)
        }
    }
}
