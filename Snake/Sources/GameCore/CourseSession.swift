import Darwin
import Foundation

final class CourseSession {
  enum Event {
    case snapshot(Game, Int)
    case notice(String)
    case disconnected(String)
  }

  private struct Request {
    var message: Wire
    var bytes: Data
    var lastSent: UInt64
    let deadline: UInt64
  }

  private let queue = DispatchQueue(label: "snakes.course-session")
  private let gameName: String
  private let playerName: String
  private let playing: Bool
  private let target: Endpoint?
  private let needsLocalEndpointCheck: Bool
  private let notify: (Event) -> Void
  private let catalog: CourseCatalog?
  private var transport: UDPTransport?
  private var host: LANHost?
  private var lastGame: Game?
  private var addresses: [Int: Endpoint] = [:]
  private var types: [Int: Snakes_V2_PlayerType] = [:]
  private var incoming = ReplyWindow()
  private var handoff: (endpoint: Endpoint, sequence: Int64, sender: Int32, acknowledgement: Data)?
  private var joinRecoveryUntil: UInt64?
  private var triedEndpoints = Set<Endpoint>()
  private var server: Endpoint?
  private var timer: DispatchSourceTimer?
  private var sequence: Int64 = 0
  private var requests: [Int64: Request] = [:]
  private var steerSequence: Int64?
  private var joinSequence: Int64 = 0
  private var leaveSequence: Int64?
  private var playerID: Int32?
  private var masterID: Int32?
  private var earlyState: Wire?
  private var bufferedState: Wire.StateMsg?
  private var config: Snakes_V2_GameConfig?
  private var lastOrder: Int32 = -1
  private var deadline: UInt64 = 0
  private var lastReceived: UInt64 = 0
  private var lastSent: UInt64 = 0
  private var lastDiscover: UInt64 = 0
  private var stopped = false

  private typealias Wire = Snakes_V2_GameMessage
  private var now: UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }

  init(gameName: String, playerName: String, playing: Bool = true, discovered: DiscoveredGame? = nil, catalog: CourseCatalog? = nil, notify: @escaping (Event) -> Void) {
    self.gameName = gameName
    self.playerName = playerName
    self.playing = playing
    target = discovered?.id.master
    needsLocalEndpointCheck = discovered?.isCourseServer == false
    if let config = discovered?.announcement.config, Self.validConfig(config) { self.config = config }
    self.notify = notify
    self.catalog = catalog
  }

  func start() {
    queue.async { [self] in
      do {
        server = try target ?? Self.resolveServer()
        try openTransport()
        try join()
        startTimer()
      } catch { finish(error.localizedDescription) }
    }
  }

  func startHosting(_ game: Game) {
    queue.async { [self] in
      do {
        try openTransport()
        becomeHost(game, id: 1)
        startTimer()
      } catch { finish(error.localizedDescription) }
    }
  }

  private func openTransport() throws {
    transport = try UDPTransport(queue: queue) { [weak self] bytes, endpoint, multicast in
      guard let self else { return }
      if multicast {
        let key = self.transport?.catalogueEndpoint(for: endpoint) ?? endpoint
        let isOwnGame = self.host != nil && self.transport?.matchesLocalEndpoint(endpoint) == true
        self.catalog?.observe(bytes, from: key, multicast: true, ownGame: isOwnGame)
      } else {
        self.catalog?.observe(bytes, from: endpoint, multicast: false)
      }
      if multicast { self.receiveRecoveryAnnouncement(bytes, from: endpoint) }
      else { self.receive(bytes, from: endpoint) }
    }
  }

  func requestCatalog(at endpoint: Endpoint, bytes: Data) {
    queue.async { [weak self] in
      try? self?.transport?.send(bytes, to: endpoint)
    }
  }

  private func join() throws {
    if let server { triedEndpoints.insert(server) }
    var payload = Wire.JoinMsg()
    payload.gameName = gameName
    payload.playerName = playerName
    payload.requestedStatus = playing ? .playing : .viewing
    deadline = now + 5000
    joinSequence = try send(.join(payload))
  }

  private func startTimer() {
    let ticker = DispatchSource.makeTimerSource(queue: queue)
    ticker.schedule(deadline: .now(), repeating: .milliseconds(25))
    ticker.setEventHandler { [weak self] in
      guard let self else { return }
      if let host = self.host { host.tick(now: self.now) }
      else { self.maintainConnection() }
    }
    timer = ticker
    ticker.resume()
  }

  private func becomeHost(_ game: Game, id: Int, inherited: Bool = false) {
    guard let transport else { return }
    let host = LANHost(game: game, id: id, order: inherited ? lastOrder : 0,
                       sequence: sequence, addresses: addresses, types: types,
                       transport: transport, now: now, notify: notify,
                       stop: { [weak self] in self?.finish($0) })
    self.host = host
    requests.removeAll()
    host.start(now: now, inherited: inherited)
  }

  func steer(_ direction: Direction) {
    queue.async { [self] in
      if let host { host.steer(direction); return }
      guard playerID != nil, leaveSequence == nil else { return }
      var command = Wire.SteerMsg()
      command.direction = LANHost.wireDirection(direction)
      if let steerSequence { requests.removeValue(forKey: steerSequence) }
      steerSequence = try? send(.steer(command))
    }
  }

  func changeStatus(playing: Bool) {
    queue.async { [self] in
      if let host { host.changeStatus(playing, now: now); return }
      guard playerID != nil, leaveSequence == nil else { return }
      var status = Wire.PlayerStatusChangeMsg()
      status.status = playing ? .playing : .viewing
      do { try send(.playerStatusChange(status)) }
      catch { notify(.notice(error.localizedDescription)) }
    }
  }

  func leave() {
    queue.async { [self] in
      guard !stopped, leaveSequence == nil else { return }
      if let host { host.leave(now: now); return }
      guard playerID != nil else { finish(""); return }
      do { leaveSequence = try send(.leave(.init())) }
      catch { finish(error.localizedDescription) }
    }
  }

  fileprivate static func resolveServer() throws -> Endpoint {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_DGRAM
    var addresses: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo("snakes.ippolitov.me", "9193", &hints, &addresses) == 0,
      let addresses, let address = addresses.pointee.ai_addr
    else { throw Failure("Не удалось найти IPv4-адрес сервера курса") }
    defer { freeaddrinfo(addresses) }
    var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    guard getnameinfo(address, addresses.pointee.ai_addrlen, &host, socklen_t(host.count),
                      nil, 0, NI_NUMERICHOST) == 0
    else { throw Failure("Не удалось прочитать IPv4-адрес сервера курса") }
    return Endpoint(address: String(cString: host), port: 9193)
  }

  @discardableResult
  private func send(_ type: Wire.OneOf_Type, ack: Int64? = nil,
                    sender: Int32? = nil, receiver: Int32? = nil, reliable: Bool = true) throws -> Int64 {
    guard let transport, let server, sequence < Int64.max else {
      throw Failure("Соединение закрыто")
    }
    if reliable { requests = requests.filter { sequence - $0.key < 1023 } }
    if reliable, requests.count >= 64 { throw Failure("Сервер не подтвердил предыдущие запросы") }
    if ack == nil { sequence += 1 }
    var message = Wire()
    message.protocolVersion = 2
    message.msgSeq = ack ?? sequence
    message.type = type
    switch type {
    case .discover: break
    case .join: message.gameName = gameName
    default:
      message.gameName = gameName
      if let sender = sender ?? playerID { message.senderID = sender }
      if let receiver = receiver ?? masterID { message.receiverID = receiver }
    }
    let bytes = try Envelope.encode(message)
    try transport.send(bytes, to: server)
    lastSent = now
    if reliable {
      let expires: UInt64
      switch type {
      case .join: expires = deadline
      case .leave: expires = now + 1000
      default: expires = .max
      }
      requests[message.msgSeq] = Request(message: message, bytes: bytes, lastSent: now, deadline: expires)
    }
    return message.msgSeq
  }

  private func receive(_ bytes: Data, from endpoint: Endpoint) {
    guard !stopped, let message = try? Envelope.decode(bytes), let type = message.type else { return }
    if let host {
      if let handoff, endpoint == handoff.endpoint, message.gameName == gameName,
        message.msgSeq == handoff.sequence, message.senderID == handoff.sender,
        message.receiverID == Int32(host.id), case .nodeRoleChange = type {
        try? transport?.send(handoff.acknowledgement, to: endpoint)
      } else {
        host.receive(message, from: endpoint, now: now)
      }
      return
    }
    if endpoint != server {
      acceptNewMaster(message, from: endpoint)
      return
    }
    if case let .announcement(catalog) = type {
      if config == nil, let game = catalog.games.first(where: { $0.gameName == gameName }),
        Self.validConfig(game.config) {
        config = game.config
        publish()
      }
      return
    }
    guard message.gameName == gameName else { return }
    if playerID == nil {
      if case .ack = type, message.msgSeq == joinSequence, message.hasSenderID,
         message.senderID > 0, message.hasReceiverID,
         message.receiverID > 0 {
        joinRecoveryUntil = nil
        masterID = message.senderID
        playerID = message.receiverID
        requests.removeValue(forKey: joinSequence)
        lastReceived = now
        if let earlyState, earlyState.senderID == masterID, earlyState.receiverID == playerID {
          bufferedState = earlyState.state
        }
        earlyState = nil
        publish()
      } else if case let .error(error) = type, error.requestSeq == joinSequence {
        try? send(.ack(.init()), ack: message.msgSeq, receiver: message.hasSenderID ? message.senderID : nil, reliable: false)
        finish(error.errorMessage)
      } else {
        receiveBeforeJoinAck(message)
      }
      return
    }
    guard message.hasSenderID, message.senderID == masterID, message.hasReceiverID,
      message.receiverID == playerID else { return }
    if case .ack = type {
      guard requests.removeValue(forKey: message.msgSeq) != nil else { return }
      lastReceived = now
      if message.msgSeq == leaveSequence { finish("") }
      return
    }
    switch incoming.lookup(message.msgSeq) {
    case let .cached(data):
      lastReceived = now
      try? transport?.send(data, to: endpoint)
      return
    case .expired: return
    case .new: break
    }
    switch type {
    case let .state(state):
      guard state.state.stateOrder >= 0 else { return }
      if let config, state.state.stateOrder > lastOrder,
        makeGame(config: config, state: state.state) == nil { return }
      acknowledge(message)
      if state.state.stateOrder > max(lastOrder, bufferedState?.state.stateOrder ?? -1) {
        bufferedState = state
        publish()
      }
    case .ping:
      acknowledge(message)
    case let .nodeRoleChange(role):
      guard role.hasSenderRole || role.hasReceiverRole, role.stateOrder >= 0 else { return }
      acknowledge(message)
      if role.hasSenderRole, role.senderRole == .normal, role.hasReceiverRole,
        role.receiverRole == .master, lastOrder < Int32.max, role.stateOrder == lastOrder + 1,
        let playerID, lastGame?.players[Int(playerID)]?.role == .deputy {
        saveHandoffAck(message, from: endpoint)
        promote()
      }
    case let .error(error):
      acknowledge(message)
      if requests.removeValue(forKey: error.requestSeq) != nil { notify(.notice(error.errorMessage)) }
    default: break
    }
  }

  private func saveHandoffAck(_ message: Wire, from endpoint: Endpoint) {
    if let data = acknowledgement(for: message) {
      handoff = (endpoint, message.msgSeq, message.senderID, data)
    }
  }

  private func receiveRecoveryAnnouncement(_ bytes: Data, from endpoint: Endpoint) {
    guard joinRecoveryUntil != nil, !triedEndpoints.contains(endpoint),
      let message = try? Envelope.decode(bytes), case let .announcement(list) = message.type,
      let advertised = list.games.first(where: { $0.gameName == gameName }),
      Self.validConfig(advertised.config) else { return }
    server = endpoint
    config = advertised.config
    earlyState = nil
    requests.removeAll()
    joinRecoveryUntil = nil
    do { try join() } catch { finish(error.localizedDescription) }
  }

  private func acceptNewMaster(_ message: Wire, from endpoint: Endpoint) {
    guard let playerID, message.gameName == gameName, message.hasReceiverID,
      message.receiverID == playerID, message.hasSenderID,
      addresses[Int(message.senderID)] == endpoint,
      lastGame?.players[Int(message.senderID)]?.role == .deputy,
      case let .nodeRoleChange(role) = message.type, role.hasSenderRole,
      role.senderRole == .master, role.stateOrder > lastOrder else { return }
    switchMaster(id: message.senderID, endpoint: endpoint)
    acknowledge(message)
  }

  private func switchMaster(id: Int32, endpoint: Endpoint) {
    server = endpoint
    masterID = id
    incoming = ReplyWindow()
    lastReceived = now
    bufferedState = nil
    for (seq, var request) in requests {
      request.message.receiverID = id
      guard let bytes = try? Envelope.encode(request.message) else { continue }
      request.bytes = bytes
      request.lastSent = now
      try? transport?.send(bytes, to: endpoint)
      requests[seq] = request
    }
  }

  private func promote() {
    guard var game = lastGame, let playerID, let masterID else {
      finish("Нет сохранённого состояния для смены ведущего")
      return
    }
    game.leave(Int(masterID))
    becomeHost(game, id: Int(playerID), inherited: true)
  }

  private func masterTimedOut() {
    guard let playerID, let game = lastGame,
      let deputy = game.players.first(where: { $0.value.role == .deputy })?.key else {
      finish("Связь с ведущим потеряна")
      return
    }
    if deputy == Int(playerID) { promote(); return }
    guard let endpoint = addresses[deputy], masterID != Int32(deputy) else {
      finish("Заместитель недоступен")
      return
    }
    switchMaster(id: Int32(deputy), endpoint: endpoint)
  }

  private func receiveBeforeJoinAck(_ message: Wire) {
    guard message.hasSenderID, message.hasReceiverID, message.senderID > 0,
      message.receiverID > 0 else { return }
    switch message.type {
    case let .state(snapshot):
      let players = snapshot.state.players.players
      guard snapshot.state.stateOrder >= 0,
        players.contains(where: { $0.id == message.senderID && $0.role == .master }),
        let player = players.first(where: { $0.id == message.receiverID && $0.name == playerName }),
        player.hasIpAddress, player.hasPort, (1...65535).contains(player.port),
        Self.validIPv4(player.ipAddress),
        !needsLocalEndpointCheck || transport?.matchesLocalEndpoint(
          Endpoint(address: player.ipAddress, port: UInt16(player.port))
        ) == true
      else { return }
      if snapshot.state.stateOrder > (earlyState?.state.state.stateOrder ?? -1) {
        earlyState = message
      }
    case .ping:
      guard let earlyState, earlyState.senderID == message.senderID,
        earlyState.receiverID == message.receiverID else { return }
    default: return
    }
    _ = try? send(.ack(.init()), ack: message.msgSeq, sender: message.receiverID,
                  receiver: message.senderID, reliable: false)
  }

  private func acknowledge(_ message: Wire) {
    guard let server, let data = acknowledgement(for: message) else { return }
    incoming.commit(message.msgSeq, response: data)
    lastReceived = now
    lastSent = now
    try? transport?.send(data, to: server)
  }

  private func acknowledgement(for message: Wire) -> Data? {
    var ack = Wire()
    ack.protocolVersion = 2
    ack.msgSeq = message.msgSeq
    ack.gameName = gameName
    ack.senderID = message.receiverID
    ack.receiverID = message.senderID
    ack.ack = .init()
    return try? Envelope.encode(ack)
  }

  private func maintainConnection() {
    guard let transport, let server else { return }
    let time = now
    if stopped { return }
    if let until = joinRecoveryUntil {
      if time >= until { finish("Не найден новый ведущий для этой игры") }
      return
    }
    if lastOrder < 0, time >= deadline {
      if playerID == nil, target != nil, triedEndpoints.count == 1 {
        joinRecoveryUntil = time + 3000
      } else {
        finish("Ведущий не прислал подтверждение, параметры игры или поле за 5 секунд")
      }
      return
    }
    if let leaveSequence, requests[leaveSequence]?.deadline ?? 0 <= time {
      finish("")
      return
    }
    if playerID != nil, time - lastReceived >= 1000 {
      if leaveSequence != nil { finish("") } else { masterTimedOut() }
      return
    }
    for (number, var request) in requests {
      if time >= request.deadline {
        requests.removeValue(forKey: number)
      } else if time - request.lastSent >= 100 {
        if (try? transport.send(request.bytes, to: server)) != nil {
          request.lastSent = time
          lastSent = time
          requests[number] = request
        }
      }
    }
    if playerID != nil, leaveSequence == nil {
      if config == nil, time - lastDiscover >= 500 {
        try? send(.discover(.init()), reliable: false)
        lastDiscover = time
      }
      if now - lastSent >= 100 { try? send(.ping(.init()), reliable: false) }
    }
  }

  private static func validConfig(_ config: Snakes_V2_GameConfig) -> Bool {
    (10...100).contains(config.width) && (10...100).contains(config.height)
      && (0...10).contains(config.foodStatic) && (100...3000).contains(config.stateDelayMs)
  }

  private func publish() {
    guard let config, let playerID, let bufferedState else { return }
    self.bufferedState = nil
    let state = bufferedState.state
    guard let game = makeGame(config: config, state: state),
      game.players[Int(playerID)] != nil else { return }
    guard state.players.players.filter({ $0.role == .master }).count == 1,
      state.players.players.filter({ $0.role == .deputy }).count == (game.players.count > 1 ? 1 : 0),
      masterID == state.players.players.first(where: { $0.role == .master })?.id else { return }
    var newAddresses: [Int: Endpoint] = [:]
    for player in state.players.players {
      let id = Int(player.id)
      if player.id == masterID {
        guard !player.hasIpAddress, !player.hasPort else { return }
        newAddresses[id] = server
      } else {
        guard player.hasIpAddress, player.hasPort, (1...65535).contains(player.port),
          Self.validIPv4(player.ipAddress) else { return }
        newAddresses[id] = Endpoint(address: player.ipAddress, port: UInt16(player.port))
      }
    }
    addresses = newAddresses
    types = Dictionary(uniqueKeysWithValues: state.players.players.map { (Int($0.id), $0.type) })
    lastGame = game
    lastOrder = state.stateOrder
    notify(.snapshot(game, Int(playerID)))
  }

  private static func validIPv4(_ address: String) -> Bool {
    let parts = address.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count == 4 && parts.allSatisfy { part in
      guard let number = UInt8(part) else { return false }
      return String(number) == part
    }
  }

  private func makeGame(config: Snakes_V2_GameConfig, state: Snakes_V2_GameState) -> Game? {
    guard (1...6).contains(state.players.players.count), state.snakes.count <= 4,
      state.foods.count <= Int(config.foodStatic) + 4,
      var game = try? Game(name: gameName, width: Int(config.width), height: Int(config.height),
                           reserve: Int(config.foodStatic), interval: Int(config.stateDelayMs))
    else { return nil }
    func cell(_ coord: Snakes_V2_GameState.Coord) -> Cell? {
      guard (0..<game.width).contains(Int(coord.x)), (0..<game.height).contains(Int(coord.y))
      else { return nil }
      return Cell(Int(coord.x), Int(coord.y))
    }

    game.nextID = Int(state.nextPlayerID)
    for player in state.players.players {
      let id = Int(player.id)
      guard id > 0, state.nextPlayerID > player.id, player.score >= 0,
        (1...24).contains(player.name.utf8.count), game.players[id] == nil else { return nil }
      let role: Role
      switch player.role {
      case .master: role = .master
      case .deputy: role = .deputy
      case .normal: role = .normal
      }
      game.players[id] = Participant(name: player.name, role: role, score: Int(player.score))
    }
    var occupied = Set<Cell>()
    for snake in state.snakes {
      let id = Int(snake.playerID)
      guard (2...32).contains(snake.points.count), let head = cell(snake.points[0]),
        var player = game.players[id], player.body.isEmpty, occupied.insert(head).inserted
      else { return nil }
      var tail = head
      player.heading = LANHost.direction(snake.headDirection)
      player.body.append(head)
      for point in snake.points.dropFirst() {
        let x = Int(point.x), y = Int(point.y)
        guard (x == 0) != (y == 0), player.body.count + abs(x) + abs(y) <= 32 else { return nil }
        for _ in 0..<(abs(x) + abs(y)) {
          tail = game.offset(tail, x.signum(), y.signum())
          guard occupied.insert(tail).inserted else { return nil }
          player.body.append(tail)
        }
      }
      game.players[id] = player
    }
    for player in state.players.players {
      guard (player.status == .playing) == !(game.players[Int(player.id)]?.body.isEmpty ?? true)
      else { return nil }
    }
    for coord in state.foods {
      guard let food = cell(coord), occupied.insert(food).inserted else { return nil }
      game.food.insert(food)
    }
    return game
  }

  private func finish(_ message: String) {
    guard !stopped else { return }
    stopped = true
    earlyState = nil
    bufferedState = nil
    timer?.cancel()
    timer = nil
    transport = nil
    host = nil
    requests.removeAll()
    notify(.disconnected(message))
  }

  private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
  }
}

struct DiscoveredGame: Identifiable {
  let id: GameDirectory<Snakes_V2_GameAnnouncement>.Key
  let announcement: Snakes_V2_GameAnnouncement
  let isCourseServer: Bool
  let isOwnGame: Bool
}

/// Collects announcements from LAN and the fixed course server.
final class CourseCatalog {
  private let queue = DispatchQueue(label: "snakes.course-catalog")
  private let update: ([DiscoveredGame], Bool) -> Void
  private var transport: UDPTransport?
  private weak var session: CourseSession?
  private var server: Endpoint?
  private var timer: DispatchSourceTimer?
  private var entries = GameDirectory<Snakes_V2_GameAnnouncement>()
  private var ownGameKey: DiscoveredGame.ID?
  private var localProbes: [Endpoint: ContinuousClock.Instant] = [:]
  private var confirmedLocal: [Endpoint: ContinuousClock.Instant] = [:]
  private var lastReply: ContinuousClock.Instant?
  private var resolvingServer = false
  private var sequence: Int64 = 0

  init(update: @escaping ([DiscoveredGame], Bool) -> Void) {
    self.update = update
  }

  func start() {
    queue.async { [self] in
      guard timer == nil else { return }
      openTransport()
      let ticker = DispatchSource.makeTimerSource(queue: queue)
      ticker.schedule(deadline: .now(), repeating: .seconds(1))
      ticker.setEventHandler { [weak self] in self?.poll() }
      timer = ticker
      ticker.resume()
    }
  }

  func useSession(_ session: CourseSession?, start: (() -> Void)? = nil) {
    queue.async { [self] in
      self.session = session
      if session != nil { transport = nil }
      else if timer != nil {
        if let ownGameKey { entries.remove(ownGameKey) }
        ownGameKey = nil
        openTransport()
        publish(at: .now)
      }
      start?()
    }
  }

  func observe(_ bytes: Data, from endpoint: Endpoint, multicast: Bool, ownGame: Bool = false) {
    queue.async { [weak self] in
      guard let self, self.timer != nil else { return }
      self.receive(bytes, from: endpoint, multicast: multicast, ownGame: ownGame)
    }
  }

  private func openTransport() {
    guard transport == nil, session == nil else { return }
    transport = try? UDPTransport(queue: queue) { [weak self] data, endpoint, multicast in
      guard let self else { return }
      let key = multicast ? self.transport?.catalogueEndpoint(for: endpoint) ?? endpoint : endpoint
      self.receive(data, from: key, multicast: multicast)
    }
  }

  func stop() {
    queue.async { [self] in
      timer?.cancel()
      timer = nil
      transport = nil
      server = nil
      lastReply = nil
      entries = GameDirectory()
      ownGameKey = nil
      localProbes.removeAll()
      confirmedLocal.removeAll()
    }
  }

  private func poll() {
    let now = ContinuousClock.now
    localProbes = localProbes.filter { now - $0.value < .seconds(1) }
    confirmedLocal = confirmedLocal.filter { now - $0.value < .seconds(3) }
    publish(at: now)
    if server == nil, !resolvingServer {
      resolvingServer = true
      DispatchQueue.global(qos: .utility).async { [weak self] in
        let endpoint = try? CourseSession.resolveServer()
        self?.queue.async { [weak self] in
          guard let self else { return }
          self.resolvingServer = false
          if self.timer != nil { self.server = endpoint }
        }
      }
    }
    if let server { discover(at: server) }
  }

  private func discover(at endpoint: Endpoint) {
    var request = Snakes_V2_GameMessage()
    request.protocolVersion = 2
    sequence += 1
    request.msgSeq = sequence
    request.discover = .init()
    guard let data = try? Envelope.encode(request) else { return }
    if let session { session.requestCatalog(at: endpoint, bytes: data) }
    else { try? transport?.send(data, to: endpoint) }
  }

  private func receive(_ data: Data, from endpoint: Endpoint, multicast: Bool, ownGame: Bool = false) {
    guard multicast || endpoint == server || localProbes[endpoint] != nil,
      let message = try? Envelope.decode(data),
      case let .announcement(announcement) = message.type else { return }
    let now = ContinuousClock.now
    if !multicast, endpoint == server {
      lastReply = now
    } else if !multicast {
      localProbes.removeValue(forKey: endpoint)
      confirmedLocal[endpoint] = now
    } else if endpoint.address == "127.0.0.1", !ownGame, confirmedLocal[endpoint] == nil {
      // A proxy may loop our multicast back with a different source port.
      // Only add that local port if the real listener answers a unicast Discover.
      if localProbes[endpoint] == nil, localProbes.count < 128 {
        localProbes[endpoint] = now
        discover(at: endpoint)
      }
      return
    } else if endpoint.address == "127.0.0.1", !ownGame {
      confirmedLocal[endpoint] = now
    }
    for game in announcement.games where (1...32).contains(game.gameName.utf8.count) {
      let key = DiscoveredGame.ID(game: game.gameName, master: endpoint)
      if ownGame { ownGameKey = key }
      entries.observe(game, key: key, at: now)
    }
    publish(at: now)
  }

  private func publish(at now: ContinuousClock.Instant) {
    let games = entries.active(at: now).map { key, announcement in
      DiscoveredGame(id: key, announcement: announcement, isCourseServer: key.master == server,
                     isOwnGame: key == ownGameKey)
    }.sorted {
      if $0.id.game != $1.id.game {
        return $0.id.game.localizedStandardCompare($1.id.game) == .orderedAscending
      }
      return ($0.id.master.address, $0.id.master.port) < ($1.id.master.address, $1.id.master.port)
    }
    update(games, lastReply.map { now - $0 < .seconds(3) } ?? false)
  }
}
