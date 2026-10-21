import Foundation
import Darwin
import CryptoKit

func writeAll(_ fd: Int32, _ buffer: UnsafeRawBufferPointer, count: Int) throws {
    guard let base = buffer.baseAddress else { return }
    var written = 0
    while written < count {
        let n = write(fd, base.advanced(by: written), count - written)
        if n < 0 {
            if errno == EINTR { continue }
            throw systemError("write file")
        }
        guard n > 0 else { throw AppError.message("write returned zero") }
        written += n
    }
}

func createUpload(directory: Int32, name: String) throws -> (fd: Int32, name: String) {
    let nsName = name as NSString
    var ext = nsName.pathExtension
    var stem = nsName.deletingPathExtension
    var baseName = name
    var usesHash = false
    var index = 0
    while true {
        var candidate = baseName
        if index > 0 {
            candidate = "\(stem)_\(index)"
            if !ext.isEmpty {
                candidate += "." + ext
            }
        }
        let fd = openat(directory, candidate, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o644))
        if fd >= 0 { return (fd, candidate) }
        if errno == ENAMETOOLONG && !usesHash {
            stem = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
            if ext.utf8.count > 32 { ext = "" }
            baseName = stem + (ext.isEmpty ? "" : "." + ext)
            usesHash = true
            index = 0
            continue
        }
        if errno != EEXIST { throw systemError("create upload") }
        index += 1
    }
}
