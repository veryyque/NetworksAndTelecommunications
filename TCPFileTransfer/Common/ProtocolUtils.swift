
func encodeUInt32(_ value: UInt32) -> [UInt8] {
    return [
        UInt8(truncatingIfNeeded: value >> 24),
        UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value)
    ]
}

func encodeUInt64(_ value: UInt64) -> [UInt8] {
    var bytes: [UInt8] = []
    for index in stride(from: 7, through: 0, by: -1) {
        let byte = UInt8(truncatingIfNeeded: value >> (index * 8))
        bytes.append(byte)
    }
    return bytes
}

func receiveUInt32(_ socket: Int32) throws -> UInt32 {
    let bytes = try recvAll(socket, count: 4)
    var value: UInt32 = 0
    for byte in bytes {
        value = (value << 8) | UInt32(byte)
    }
    return value
}

func receiveUInt64(_ socket: Int32) throws -> UInt64 {
    let bytes = try recvAll(socket, count: 8)
    var value: UInt64 = 0
    for byte in bytes {
        value = (value << 8) | UInt64(byte)
    }
    return value
}
