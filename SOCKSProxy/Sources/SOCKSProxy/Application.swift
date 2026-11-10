import Foundation
import Darwin

struct Application {
    static func run() {
        do {
            let args = CommandLine.arguments
            guard (2...3).contains(args.count), let port = UInt16(args[1]), port > 0 else {
                throw ProxyError("Использование: socks-proxy <порт> [DNS_IPv4:порт]")
            }
            let dnsIP: String
            let dnsPort: UInt16
            if args.count == 3 {
                let parts = args[2].split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count == 2, let p = UInt16(parts[1]), p > 0 else { throw ProxyError("DNS должен иметь формат IPv4:port") }
                dnsIP = String(parts[0]); dnsPort = p
                _ = try address(dnsIP, dnsPort)
            } else { dnsIP = try systemResolver(); dnsPort = 53 }
            let proxy = try Proxy(port: port, dnsIP: dnsIP, dnsPort: dnsPort)
            print("SOCKS5: 127.0.0.1:\(port), DNS UDP: \(dnsIP):\(dnsPort). Остановка: Ctrl+C")
            fflush(stdout)
            try proxy.run()
        } catch {
            fputs("Ошибка: \(error)\n", stderr)
            exit(1)
        }
    }
}
