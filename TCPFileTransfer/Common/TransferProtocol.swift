import Foundation
import Darwin

enum TransferLog {
    private static let lock = NSLock()
    private static var screenLines: [String] = []
    static var isTerminal: Bool {
        isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["TERM"] != "dumb"
    }

    private static func clearScreenLines() {
        if !screenLines.isEmpty {
            print("\u{1B}[\(screenLines.count)A\r\u{1B}[J", terminator: "")
        }
    }

    static func render(_ lines: [String]) {
        lock.lock()
        defer { lock.unlock() }
        clearScreenLines()
        screenLines = lines
        print(lines.joined(separator: "\n"))
        fflush(stdout)
    }

    static func write(_ message: String) {
        let line = message.replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        lock.lock()
        defer { lock.unlock() }
        clearScreenLines()
        print(line)
        if !screenLines.isEmpty { print(screenLines.joined(separator: "\n")) }
        fflush(stdout)
    }
}

enum TransferProtocol {
    static let maxNameBytes = 4096
    static let maxFileSize: UInt64 = 1000000000000
    static let bufferSize = 64 * 1024
    static let success: UInt8 = 1
    static let failure: UInt8 = 0
}

enum AppError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let text): return text }
    }
}

func systemError(_ operation: String) -> AppError {
    let code = errno
    return .message("\(operation): \(String(cString: strerror(code)))")
}

func parsePort(_ text: String) throws -> UInt16 {
    guard let port = UInt16(text), port > 0 else {
        throw AppError.message("Port must be an integer from 1 to 65535")
    }
    return port
}
