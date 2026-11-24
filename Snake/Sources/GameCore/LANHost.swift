import Foundation

final class LANHost {
  typealias Wire = Snakes_V2_GameMessage
  private struct Peer {
    let endpoint: Endpoint
    var received: UInt64
    var sent: UInt64
    var statusOrder: Int64 = -1
    var pending: [Int64: Pending] = [:]
  }
  private struct Pending {
    let message: Wire
    let bytes: Data
    var sent: UInt64
    var expires: UInt64? = nil
  }
  private enum Exit {
    case snapshot(peer: Int, sequence: Int64, until: UInt64)
    case role(peer: Int, sequence: Int64, until: UInt64)
  }

  private(set) var game: Game
  private(set) var order: Int32
  let id: Int
  private let transport: UDPTransport
  private let notify: (CourseSession.Event) -> Void
  private let stop: (String) -> Void
  private var peers: [Int: Peer]
  private var replies: [Endpoint: ReplyWindow] = [:]
  private var types: [Int: Snakes_V2_PlayerType]
  private var rejected: [Endpoint: Pending] = [:]
  private var sequence: Int64
  private var turn: UInt64
  private var lastAnnouncement: UInt64 = 0
  private var exit: Exit?

  init(game: Game, id: Int, order: Int32 = 0, sequence: Int64 = 0,
       addresses: [Int: Endpoint] = [:], types: [Int: Snakes_V2_PlayerType] = [:],
       transport: UDPTransport, now: UInt64,
       notify: @escaping (CourseSession.Event) -> Void, stop: @escaping (String) -> Void) {
    self.game = game
    self.id = id
    self.order = order
    self.sequence = sequence
    self.transport = transport
    self.notify = notify
    self.stop = stop
    self.types = types
    peers = addresses.filter { $0.key != id && game.players[$0.key] != nil }
      .mapValues { Peer(endpoint: $0, received: now, sent: now) }
    for peer in peers.values { replies[peer.endpoint] = ReplyWindow() }
    turn = now + UInt64(game.interval)
  }

  func start(now: UInt64, inherited: Bool = false) {
    publish(now: now, changed: inherited)
    if inherited {
      for peer in peers.keys {
        var role = Wire.NodeRoleChangeMsg()
        role.senderRole = .master
        role.stateOrder = order
        send(.nodeRoleChange(role), to: peer, now: now)
      }
      notifyDeputy(now: now)
    }
    announce(now: now)
  }

  func steer(_ direction: Direction) {
    guard exit == nil else { return }
    guard let seq = nextSequence() else { return }
    game.steer(direction, id: id, sequence: seq)
  }

  func changeStatus(_ playing: Bool, now: UInt64) {
    guard exit == nil else { return }
    do {
      let changed = game.players[id]?.body.isEmpty == playing
      try game.setPlaying(playing, id: id)
      if changed { publish(now: now) }
    } catch { notify(.notice(error.localizedDescription)) }
  }

  func leave(now: UInt64) {
    guard exit == nil else { return }
    guard let deputy, peers[deputy] != nil, order < Int32.max,
      let seq = send(.state(state()), to: deputy, now: now) else { stop(""); return }
    exit = .snapshot(peer: deputy, sequence: seq, until: now + 1000)
  }

  func tick(now: UInt64) {
    if let exit {
      switch exit {
      case let .snapshot(_, _, until), let .role(_, _, until):
        if now >= until { stop(""); return }
      }
    } else {
      let expired = peers.filter { now - $0.value.received >= 1000 }.map(\.key)
      if !expired.isEmpty {
        let previous = deputy
        for peer in expired { remove(peer) }
        publish(now: now)
        if deputy != previous { notifyDeputy(now: now) }
      }
      if now >= turn {
        turn = now + UInt64(game.interval)
        game.tick()
        publish(now: now)
      }
      if now - lastAnnouncement >= 1000 { announce(now: now) }

    }
    // A rejected Join has no assigned player ID, but its Error still needs an ACK.
    for (endpoint, var item) in rejected where now - item.sent >= 100 {
      if let expires = item.expires, now >= expires { rejected.removeValue(forKey: endpoint); continue }
      try? transport.send(item.bytes, to: endpoint)
      item.sent = now
      rejected[endpoint] = item
    }
    for peer in peers.keys {
      guard let current = peers[peer] else { continue }
      for (seq, var pending) in current.pending where now - pending.sent >= 100 {
        try? transport.send(pending.bytes, to: current.endpoint)
        pending.sent = now
        peers[peer]?.pending[seq] = pending
        peers[peer]?.sent = now
      }
      if exit == nil, let sent = peers[peer]?.sent, now - sent >= 100 {
        send(.ping(.init()), to: peer, now: now)
      }
    }
  }

  func receive(_ message: Wire, from endpoint: Endpoint, now: UInt64) {
    if case .discover = message.type {
      if exit == nil { announce(to: endpoint, now: now) }
      return
    }
    guard message.gameName == game.name, let type = message.type else { return }
    if case .ack = type {
      guard let peer = authenticated(message, endpoint), peers[peer]?.pending[message.msgSeq] != nil else {
        if !message.hasSenderID, message.hasReceiverID, message.receiverID == Int32(id),
          rejected[endpoint]?.message.msgSeq == message.msgSeq {
          rejected.removeValue(forKey: endpoint)
        }
        return
      }
      peers[peer]?.received = now
      peers[peer]?.pending.removeValue(forKey: message.msgSeq)
      handleExitAck(peer: peer, sequence: message.msgSeq, now: now)
      return
    }

    switch replies[endpoint]?.lookup(message.msgSeq) ?? .new {
    case let .cached(bytes):
      if !message.hasSenderID {
        guard case .join = type else { return }
      } else if authenticated(message, endpoint) == nil {
        guard case .leave = type, message.hasReceiverID, message.receiverID == Int32(id),
          let cached = try? Envelope.decode(bytes), cached.receiverID == message.senderID else { return }
      }
      if let peer = authenticated(message, endpoint) { peers[peer]?.received = now }
      try? transport.send(bytes, to: endpoint)
      return
    case .expired: return
    case .new: break
    }

    if case let .join(join) = type {
      guard exit == nil, !message.hasSenderID, join.gameName == game.name else { return }
      joinPlayer(join, request: message, endpoint: endpoint, now: now)
      return
    }
    guard let peer = authenticated(message, endpoint) else { return }
    if exit != nil {
      if case .ping = type { acknowledge(message, endpoint: endpoint, id: peer) }
      return
    }
    switch type {
    case .ping:
      acknowledge(message, endpoint: endpoint, id: peer)
    case let .steer(command):
      if game.players[peer]?.body.isEmpty == false {
        game.steer(Self.direction(command.direction), id: peer, sequence: message.msgSeq)
      }
      acknowledge(message, endpoint: endpoint, id: peer)
    case let .playerStatusChange(status):
      if let previous = peers[peer]?.statusOrder, message.msgSeq > previous {
        peers[peer]?.statusOrder = message.msgSeq
        let playing = status.status == .playing
        let changed = game.players[peer]?.body.isEmpty == playing
        do {
          try game.setPlaying(playing, id: peer)
          acknowledge(message, endpoint: endpoint, id: peer)
          if changed { publish(now: now) }
          else { send(.state(state()), to: peer, now: now) }
        } catch { reject(message, reason: error.localizedDescription, endpoint: endpoint, peer: peer, now: now) }
      } else {
        acknowledge(message, endpoint: endpoint, id: peer)
      }
    case .leave:
      acknowledge(message, endpoint: endpoint, id: peer)
      let previous = deputy
      remove(peer)
      publish(now: now)
      if previous != deputy { notifyDeputy(now: now) }
    default: return
    }
    peers[peer]?.received = now
  }

  private func joinPlayer(_ join: Wire.JoinMsg, request: Wire, endpoint: Endpoint, now: UInt64) {
    guard (1...24).contains(join.playerName.utf8.count) else { return }
    if let existing = peers.first(where: { $0.value.endpoint == endpoint })?.key {
      peers[existing]?.received = now
      acknowledge(request, endpoint: endpoint, id: existing)
      send(.state(state()), to: existing, now: now)
      return
    }
    // Keep a bounded history for retired endpoints, including their Leave responses.
    guard replies[endpoint] != nil || replies.count < 128 else { return }
    if replies[endpoint] == nil { replies[endpoint] = ReplyWindow() }
    rejected.removeValue(forKey: endpoint)
    let previous = deputy
    do {
      let id = try game.join(name: join.playerName, playing: join.requestedStatus == .playing)
      peers[id] = Peer(endpoint: endpoint, received: now, sent: now)
      types[id] = join.playerType
      acknowledge(request, endpoint: endpoint, id: id)
      announce(to: endpoint, now: now)
      publish(now: now)
      if previous != deputy { notifyDeputy(now: now) }
    } catch { reject(request, reason: error.localizedDescription, endpoint: endpoint, peer: nil, now: now) }
  }

  private func authenticated(_ message: Wire, _ endpoint: Endpoint) -> Int? {
    let peer = Int(message.senderID)
    guard message.hasSenderID, message.hasReceiverID, message.receiverID == Int32(id),
      peers[peer]?.endpoint == endpoint else { return nil }
    return peer
  }

  private var deputy: Int? { game.players.first(where: { $0.value.role == .deputy })?.key }

  private func remove(_ peer: Int) {
    game.leave(peer)
    peers.removeValue(forKey: peer)
    types.removeValue(forKey: peer)
  }

  private func handleExitAck(peer: Int, sequence: Int64, now: UInt64) {
    switch exit {
    case let .snapshot(deputy, expected, until) where peer == deputy && sequence == expected:
      var role = Wire.NodeRoleChangeMsg()
      role.senderRole = .normal
      role.receiverRole = .master
      role.stateOrder = order + 1
      if let seq = send(.nodeRoleChange(role), to: deputy, now: now) {
        exit = .role(peer: deputy, sequence: seq, until: until)
      }
    case let .role(deputy, expected, _) where peer == deputy && sequence == expected:
      stop("")
    default: break
    }
  }

  private func notifyDeputy(now: UInt64) {
    guard let deputy else { return }
    var role = Wire.NodeRoleChangeMsg()
    role.receiverRole = .deputy
    role.stateOrder = order
    send(.nodeRoleChange(role), to: deputy, now: now)
  }

  private func nextSequence() -> Int64? {
    guard sequence < Int64.max else { stop("Исчерпан счётчик сообщений"); return nil }
    sequence += 1
    return sequence
  }

  private func packet(_ type: Wire.OneOf_Type, sequence: Int64, peer: Int?) -> Wire {
    var message = Wire()
    message.protocolVersion = 2
    message.msgSeq = sequence
    message.type = type
    if case .announcement = type { return message }
    message.gameName = game.name
    message.senderID = Int32(id)
    if let peer { message.receiverID = Int32(peer) }
    return message
  }

  @discardableResult
  private func send(_ type: Wire.OneOf_Type, to peer: Int, now: UInt64) -> Int64? {
    guard let endpoint = peers[peer]?.endpoint, let seq = nextSequence() else { return nil }
    let message = packet(type, sequence: seq, peer: peer)
    guard let bytes = encode(message) else { return nil }
    var pending = peers[peer]?.pending ?? [:]
    pending = pending.filter { seq - $0.key < 1024 }
    // A newer State/Ping supersedes an older one. Leave room for role notifications.
    switch type {
    case .state:
      pending = pending.filter { item in
        if case .state = item.value.message.type { return false }
        return true
      }
    case .ping:
      pending = pending.filter { item in
        if case .ping = item.value.message.type { return false }
        return true
      }
    default: break
    }
    guard pending.count < 64 else { return nil }
    pending[seq] = Pending(message: message, bytes: bytes, sent: now)
    peers[peer]?.pending = pending
    peers[peer]?.sent = now
    try? transport.send(bytes, to: endpoint)
    return seq
  }

  private func encode(_ message: Wire) -> Data? {
    do { return try Envelope.encode(message) }
    catch {
      stop("Не удалось сформировать пакет v2: \(error)")
      return nil
    }
  }

  private func acknowledge(_ request: Wire, endpoint: Endpoint, id: Int) {
    reply(.ack(.init()), sequence: request.msgSeq, to: endpoint, peer: id, request: request)
  }

  private func reject(_ request: Wire, reason: String, endpoint: Endpoint, peer: Int?, now: UInt64) {
    var error = Wire.ErrorMsg()
    error.errorMessage = reason
    error.requestSeq = request.msgSeq
    if let peer, let seq = send(.error(error), to: peer, now: now),
       let bytes = peers[peer]?.pending[seq]?.bytes {
      replies[endpoint]?.commit(request.msgSeq, response: bytes)
    } else if peer == nil, let seq = nextSequence() {
      let message = packet(.error(error), sequence: seq, peer: nil)
      guard let bytes = encode(message) else { return }
      replies[endpoint]?.commit(request.msgSeq, response: bytes)
      rejected[endpoint] = Pending(message: message, bytes: bytes, sent: now, expires: now + 1000)
      try? transport.send(bytes, to: endpoint)
    }
  }

  private func reply(_ type: Wire.OneOf_Type, sequence: Int64, to endpoint: Endpoint, peer: Int?, request: Wire) {
    guard let bytes = encode(packet(type, sequence: sequence, peer: peer)) else { return }
    replies[endpoint]?.commit(request.msgSeq, response: bytes)
    try? transport.send(bytes, to: endpoint)
  }

  private func publish(now: UInt64, changed: Bool = true) {
    if changed {
      guard order < Int32.max else { stop("Исчерпан счётчик состояния"); return }
      order += 1
    }
    notify(.snapshot(game, id))
    let snapshot = state()
    for peer in peers.keys { send(.state(snapshot), to: peer, now: now) }
  }

  private func announce(to endpoint: Endpoint? = nil, now: UInt64) {
    guard let seq = nextSequence() else { return }
    var config = Snakes_V2_GameConfig()
    config.width = Int32(game.width)
    config.height = Int32(game.height)
    config.foodStatic = Int32(game.reserve)
    config.stateDelayMs = Int32(game.interval)
    var announcement = Snakes_V2_GameAnnouncement()
    announcement.gameName = game.name
    announcement.config = config
    announcement.players = players()
    var probe = Participant(name: "", role: .normal)
    announcement.canJoin = game.players.count < 6 && game.nextID < Int32.max
      && (try? game.spawn(&probe)) != nil
    var payload = Wire.AnnouncementMsg()
    payload.games = [announcement]
    guard let bytes = encode(packet(.announcement(payload), sequence: seq, peer: nil)) else { return }
    if let endpoint { try? transport.send(bytes, to: endpoint) }
    else {
      lastAnnouncement = now
      _ = transport.announce(bytes)
    }
  }

  private func players() -> Snakes_V2_GamePlayers {
    var list = Snakes_V2_GamePlayers()
    list.players = game.players.keys.sorted().compactMap { id in
      guard let model = game.players[id] else { return nil }
      var player = Snakes_V2_GamePlayer()
      player.id = Int32(id)
      player.name = model.name
      player.score = Int32(model.score)
      switch model.role {
      case .master: player.role = .master
      case .deputy: player.role = .deputy
      case .normal: player.role = .normal
      }
      player.type = types[id] ?? .human
      player.status = model.body.isEmpty ? .viewing : .playing
      if let endpoint = peers[id]?.endpoint {
        player.ipAddress = endpoint.address
        player.port = Int32(endpoint.port)
      }
      return player
    }
    return list
  }

  private func state() -> Wire.StateMsg {
    var message = Wire.StateMsg()
    message.state.stateOrder = order
    message.state.nextPlayerID = Int32(game.nextID)
    message.state.players = players()
    message.state.foods = game.food.map { Self.coord($0.x, $0.y) }
    message.state.snakes = game.players.compactMap { id, player in
      guard let head = player.body.first else { return nil }
      var snake = Snakes_V2_GameState.Snake()
      snake.playerID = Int32(id)
      snake.headDirection = Self.wireDirection(player.heading)
      snake.points = [Self.coord(head.x, head.y)]
      var run = Cell(0, 0)
      var direction = Cell(0, 0)
      for (from, to) in zip(player.body, player.body.dropFirst()) {
        let step = Cell(Self.unit(to.x - from.x), Self.unit(to.y - from.y))
        if step != direction, run != Cell(0, 0) {
          snake.points.append(Self.coord(run.x, run.y))
          run = Cell(0, 0)
        }
        direction = step
        run = Cell(run.x + step.x, run.y + step.y)
      }
      snake.points.append(Self.coord(run.x, run.y))
      return snake
    }
    return message
  }

  private static func unit(_ delta: Int) -> Int {
    abs(delta) > 1 ? -delta.signum() : delta
  }

  private static func coord(_ x: Int, _ y: Int) -> Snakes_V2_GameState.Coord {
    var point = Snakes_V2_GameState.Coord()
    if x != 0 { point.x = Int32(x) }
    if y != 0 { point.y = Int32(y) }
    return point
  }

  static func direction(_ direction: Snakes_V2_Direction) -> Direction {
    switch direction {
    case .up: return .up
    case .down: return .down
    case .left: return .left
    case .right: return .right
    }
  }

  static func wireDirection(_ direction: Direction) -> Snakes_V2_Direction {
    switch direction {
    case .up: return .up
    case .down: return .down
    case .left: return .left
    case .right: return .right
    }
  }
}
