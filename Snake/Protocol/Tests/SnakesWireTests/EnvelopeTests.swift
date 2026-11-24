import XCTest
@testable import Snakes

final class EnvelopeTests: XCTestCase {
    func testMaximumPlayingStateRoundTrip() throws {
        // Same dimensions, turn pattern and counters as the course protocol test.
        let masterID = Int32.max - 10
        let heads: [(Int32, Int32)] = [(64, 64), (66, 64), (68, 64), (64, 68)]
        var state = Snakes_V2_GameState()
        state.stateOrder = Int32.max
        state.nextPlayerID = Int32.max

        for index in 0..<6 {
            var player = Snakes_V2_GamePlayer()
            player.id = masterID + Int32(index)
            player.name = String(repeating: "n", count: 24)
            player.score = Int32.max
            player.type = .human
            player.role = index == 0 ? .master : (index == 1 ? .deputy : .normal)
            player.status = index < heads.count ? .playing : .viewing
            if index > 0 {
                player.ipAddress = "192.168.255.254"
                player.port = 65535 - Int32(index)
            }
            state.players.players.append(player)
        }

        for (index, head) in heads.enumerated() {
            var snake = Snakes_V2_GameState.Snake()
            snake.playerID = masterID + Int32(index)
            snake.headDirection = .right
            snake.points = [coordinate(head.0, head.1)]
            for edge in 0..<31 {
                snake.points.append(edge.isMultiple(of: 2) ? coordinate(-1, 0) : coordinate(0, -1))
            }
            state.snakes.append(snake)
        }
        for index: Int32 in 0..<14 {
            state.foods.append(coordinate(65 + index % 5, 65 + index / 5))
        }

        var message = Snakes_V2_GameMessage()
        message.protocolVersion = 2
        message.msgSeq = Int64.max
        message.gameName = String(repeating: "g", count: 32)
        message.senderID = masterID
        message.receiverID = masterID + 1
        message.state.state = state

        let datagram = try Envelope.encode(message)
        XCTAssertEqual(datagram.count, 1145)
        XCTAssertEqual(try Envelope.decode(datagram), message)
    }

    private func coordinate(_ x: Int32, _ y: Int32) -> Snakes_V2_GameState.Coord {
        var point = Snakes_V2_GameState.Coord()
        if x != 0 { point.x = x }
        if y != 0 { point.y = y }
        return point
    }
}
