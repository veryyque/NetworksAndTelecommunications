import Foundation
import Darwin

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
    let ext = nsName.pathExtension
    let stem = nsName.deletingPathExtension
    var index = 0
    while true {
        var candidate = name
        if index > 0 {
            candidate = "\(stem)_\(index)"
            if !ext.isEmpty {
                candidate += "." + ext
            }
        }
        let fd = openat(directory, candidate, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o644))
        if fd >= 0 { return (fd, candidate) }
        if errno != EEXIST { throw systemError("create upload") }
        index += 1
    }
}
