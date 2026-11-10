import Foundation

struct DNS {
    private static let headerSize = 12
    private static let typeA = 1
    private static let typeCNAME = 5
    private static let internetClass = 1

    static func makeQuery(id: UInt16, name: String) throws -> [UInt8] {
        var packet: [UInt8] = []
        appendUInt16(id, to: &packet)
        appendUInt16(0x0100, to: &packet) //флаг RD - Recursion Desired, найти ответ, если его нет в кэше
        appendUInt16(1, to: &packet)      //1 вопрос
        appendUInt16(0, to: &packet)      //0 ответов
        appendUInt16(0, to: &packet)      //нет авторитетных серверов
        appendUInt16(0, to: &packet)      //нет доп записей

        var domainName = name
        if domainName.hasSuffix(".") {
            domainName.removeLast()
        }
        guard !domainName.isEmpty else {
            throw ProxyError("Пустое имя DNS")
        }

        let nameParts = domainName.split(separator: ".", omittingEmptySubsequences: false)
        var nameLength = 1
        for part in nameParts {
            let bytes = Array(part.utf8)
            guard !bytes.isEmpty else {
                throw ProxyError("Пустая DNS-метка")
            }
            guard bytes.count <= 63 else {
                throw ProxyError("Слишком длинная DNS-метка")
            }
            guard bytes.allSatisfy({ $0 > 32 && $0 < 127 }) else {
                throw ProxyError("DNS-имя должно быть в ASCII/punycode")
            }
            nameLength += bytes.count + 1
            packet.append(UInt8(bytes.count))
            packet.append(contentsOf: bytes)
        }
        guard nameLength <= 255 else {
            throw ProxyError("Слишком длинное имя DNS")
        }

        packet.append(0)
        appendUInt16(UInt16(typeA), to: &packet)
        appendUInt16(UInt16(internetClass), to: &packet)
        return packet
    }

    private static func appendUInt16(_ value: UInt16, to packet: inout [UInt8]) {
        packet.append(UInt8(value / 256))
        packet.append(UInt8(value % 256))
    }

    static func readUInt16(_ packet: [UInt8], at position: Int) -> Int {
        let highByte = Int(packet[position])
        let lowByte = Int(packet[position + 1])
        return highByte * 256 + lowByte
    }

    static func readName(_ packet: [UInt8], cursor: inout Int) throws -> String {
        var position = cursor
        var positionAfterPointer: Int?
        var nameParts: [String] = []
        var visitedPositions = Set<Int>()
        var nameLength = 0

        while true {
            guard position < packet.count else {
                throw ProxyError("DNS-имя выходит за границы пакета")
            }
            guard visitedPositions.insert(position).inserted else {
                throw ProxyError("Циклическая ссылка в DNS-имени")
            }
            guard visitedPositions.count <= 128 else {
                throw ProxyError("Слишком много переходов при чтении DNS-имени")
            }

            let firstByte = Int(packet[position])
            if firstByte == 0 {
                cursor = positionAfterPointer ?? (position + 1)
                return nameParts.joined(separator: ".").lowercased()
            }

            let isPointer = (firstByte & 0xC0) == 0xC0 //ссылка
            if isPointer {
                guard position + 1 < packet.count else {
                    throw ProxyError("Неполная ссылка в DNS-имени")
                }
                if positionAfterPointer == nil {
                    positionAfterPointer = position + 2
                }
                let highBits = firstByte & 0x3F
                let lowByte = Int(packet[position + 1])
                position = highBits * 256 + lowByte
                continue
            }

            let partLength = firstByte
            guard partLength <= 63 else {
                throw ProxyError("Некорректная длина DNS-метки")
            }
            let partStart = position + 1
            let partEnd = partStart + partLength
            guard partEnd <= packet.count else {
                throw ProxyError("DNS-метка выходит за границы пакета")
            }
            nameLength += partLength + 1
            guard nameLength <= 254 else {
                throw ProxyError("Слишком длинное имя DNS")
            }
            guard let part = String(bytes: packet[partStart..<partEnd], encoding: .ascii) else {
                throw ProxyError("Некорректные символы DNS-имени")
            }
            nameParts.append(part)
            position = partEnd
        }
    }

    enum Reply {
        case address([UInt8])
        case failure
    }
    // nil повреждённый пакет, failure ответ не дал подходящего адреса
    static func parseResponse(_ packet: [UInt8], expected: String) -> Reply? {
        guard packet.count >= headerSize else { return nil }
        let isResponse = (packet[2] & 0x80) != 0
        let operationCode = packet[2] & 0x78
        guard isResponse else { return nil }
        guard operationCode == 0 else { return nil }
        guard readUInt16(packet, at: 4) == 1 else { return nil }

        do {
            var cursor = headerSize
            let questionName = try readName(packet, cursor: &cursor)
            let expectedName = expected.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard questionName == expectedName else { return nil }
            guard cursor + 4 <= packet.count else { return nil }
            guard readUInt16(packet, at: cursor) == typeA else { return nil }
            guard readUInt16(packet, at: cursor + 2) == internetClass else { return nil }
            cursor += 4

            let responseCode = packet[3] & 0x0F
            if responseCode != 0 { return .failure }

            let answerCount = readUInt16(packet, at: 6)
            let isTruncated = (packet[2] & 0x02) != 0 //TC - усеченный ответ
            var aliases: [String: String] = [:]
            var addresses: [String: [UInt8]] = [:]

            for _ in 0..<answerCount {
                do {
                    let ownerName = try readName(packet, cursor: &cursor)
                    //тип 2, класс 2, TTL 4, длина данных 2
                    guard cursor + 10 <= packet.count else {
                        throw ProxyError("Неполная DNS-запись")
                    }
                    let recordType = readUInt16(packet, at: cursor)
                    let recordClass = readUInt16(packet, at: cursor + 2)
                    let dataLength = readUInt16(packet, at: cursor + 8)
                    cursor += 10
                    let dataEnd = cursor + dataLength
                    guard dataEnd <= packet.count else {
                        throw ProxyError("Неполные данные DNS-записи")
                    }

                    if recordClass == internetClass {
                        if recordType == typeA && dataLength == 4 {
                            addresses[ownerName] = Array(packet[cursor..<dataEnd])
                        }
                        if recordType == typeCNAME {
                            var aliasCursor = cursor
                            let aliasName = try readName(packet, cursor: &aliasCursor)
                            guard aliasCursor == dataEnd else {
                                throw ProxyError("Некорректная длина CNAME")
                            }
                            aliases[ownerName] = aliasName
                        }
                    }
                    cursor = dataEnd
                } catch {
                    if isTruncated { break }
                    return nil
                }
            }

            var currentName = expectedName
            var visitedNames = Set<String>()
            while visitedNames.insert(currentName).inserted {
                if let ip = addresses[currentName] {
                    return .address(ip)
                }
                guard let aliasName = aliases[currentName] else { break }
                currentName = aliasName
            }
            return .failure
        } catch {
            return nil
        }
    }
}
