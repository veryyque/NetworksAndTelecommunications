import Foundation
import Darwin

final class TCPClient {
    private let filePath: String
    private let host: String
    private let port: UInt16

    init(filePath: String, host: String, port: UInt16) {
        self.filePath = filePath
        self.host = host
        self.port = port
    }

    func sendFile() throws {
        let fileDescriptor = open(filePath, O_RDONLY | O_NONBLOCK)
        guard fileDescriptor >= 0 else { throw systemError("open input file") }
        defer { close(fileDescriptor) }
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0 else { throw systemError("fstat") }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw AppError.message("The path must refer to a regular file")
        }
        guard info.st_size >= 0, UInt64(info.st_size) <= TransferProtocol.maxFileSize else {
            throw AppError.message("File exceeds 1 TB")
        }
        let size = UInt64(info.st_size)
        let name = URL(fileURLWithPath: filePath).lastPathComponent
        let nameBytes = Array(name.utf8)
        guard !nameBytes.isEmpty, nameBytes.count <= TransferProtocol.maxNameBytes else {
            throw AppError.message("Filename must contain 1...4096 UTF-8 bytes")
        }
        let socket = try connectToServer(host: host, port: port)
        defer { close(socket) }
        print("Connected to server")
        print("Sending \(name)")
        try sendAll(socket, encodeUInt32(UInt32(nameBytes.count))) //отпр длину имени
        try sendAll(socket, nameBytes) //имя
        try sendAll(socket, encodeUInt64(size)) //отпр размер содержимого файла
        var buffer = [UInt8](repeating: 0, count: TransferProtocol.bufferSize)
        var sentBytes: UInt64 = 0
        while sentBytes < size {
            let wanted = Int(min(UInt64(buffer.count), size - sentBytes))
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(fileDescriptor, bytes.baseAddress, wanted)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw systemError("read file")
            }
            guard count > 0 else { throw AppError.message("Input file ended too early") }
            try sendAll(socket, Array(buffer.prefix(count))) //отпр часть содержимого
            sentBytes += UInt64(count)
        }
        let status = try recvAll(socket, count: 1)
        guard status[0] == TransferProtocol.success else {
            throw AppError.message("Server reported a transfer error")
        }
    }
}
