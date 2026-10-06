import Foundation
import Darwin

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
