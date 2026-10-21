import Foundation
import Darwin

final class ClientHandler {
    private let socket: Int32
    init(socket: Int32) { self.socket = socket }

    func run() {
        defer { close(socket) }
        let client = "\(peerName(socket)) [socket \(socket)]"
        print("Client connected: \(client)")
        do {
            try receiveFile(client: client)
            try sendAll(socket, [TransferProtocol.success])
        } catch {
            print("Client \(client): \(error)")
            try? sendAll(socket, [TransferProtocol.failure])
        }
    }

    private func receiveFile(client: String) throws {
        let nameLength = try receiveUInt32(socket)
        guard nameLength > 0, nameLength <= TransferProtocol.maxNameBytes else { // ограничение длины пути
            throw AppError.message("Invalid filename length")
        }
        let nameBytes = try recvAll(socket, count: Int(nameLength))
        guard let receivedName = String(bytes: nameBytes, encoding: .utf8),
              !receivedName.utf8.contains(0) else {
            throw AppError.message("Invalid UTF-8 filename")
        }
        let safeName = URL(fileURLWithPath: receivedName).lastPathComponent
        guard !safeName.isEmpty, safeName != ".", safeName != "..", !safeName.contains("/") else {
            throw AppError.message("Invalid filename")
        }
        let size = try receiveUInt64(socket)
        guard size <= TransferProtocol.maxFileSize else {
            throw AppError.message("File exceeds 1 TB") //ограничение размера
        }

        if mkdir("uploads", mode_t(0o755)) != 0 && errno != EEXIST {
            throw systemError("mkdir uploads")
        }
        
        let directory = open("uploads", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw systemError("open uploads") }
        defer { close(directory) }
        let output = try createUpload(directory: directory, name: safeName)
        var fileDescriptor = output.fd
        var complete = false
        defer {
            if fileDescriptor >= 0 { close(fileDescriptor) }
            if !complete && unlinkat(directory, output.name, 0) != 0 {
                print(systemError("remove incomplete file"))
            }
        }
        print("Receiving: \(output.name) [\(client)]")
        let statistics = TransferStatistics(client: client)
        defer { statistics.printIfNeeded(force: true) }
        var buffer = [UInt8](repeating: 0, count: TransferProtocol.bufferSize)
        var receivedBytes: UInt64 = 0
        while receivedBytes < size {
            let wanted = Int(min(UInt64(buffer.count), size - receivedBytes))
            let count = buffer.withUnsafeMutableBytes { bytes in
                recv(socket, bytes.baseAddress, wanted, 0)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw systemError("recv file")
            }
            guard count > 0 else { throw AppError.message("Connection closed before the whole file arrived") }
            receivedBytes += UInt64(count)
            statistics.add(count)
            try buffer.withUnsafeBytes { bytes in
                try writeAll(fileDescriptor, bytes, count: count)
            }
            statistics.printIfNeeded()
        }
        guard receivedBytes == size else { throw AppError.message("File size mismatch") }
        let closeResult = close(fileDescriptor)
        fileDescriptor = -1
        guard closeResult == 0 else { throw systemError("close output file") }
        complete = true
        print("File \(output.name) received successfully")
    }
}
