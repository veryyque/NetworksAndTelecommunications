import Foundation
import SwiftProtobuf

public enum WireError: Error { case size, invalidEnvelope }

public enum Envelope {
    public static func decode(_ data: Data) throws -> Snakes_V2_GameMessage {
        guard (1...1200).contains(data.count) else { throw WireError.size }
        let message = try Snakes_V2_GameMessage(serializedBytes: data)
        guard message.protocolVersion == 2, message.msgSeq >= 0, message.type != nil else {
            throw WireError.invalidEnvelope
        }
        return message
    }
    public static func encode(_ message: Snakes_V2_GameMessage) throws -> Data {
        guard message.protocolVersion == 2, message.msgSeq >= 0, message.type != nil else {
            throw WireError.invalidEnvelope
        }
        let bytes = try message.serializedData()
        guard bytes.count <= 1200 else { throw WireError.size }
        return bytes
    }
}
