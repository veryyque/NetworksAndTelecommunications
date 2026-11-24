import Foundation

public struct Cell: Hashable {
    public let x, y: Int
    public init(_ x: Int, _ y: Int) {
        self.x = x
        self.y = y
    }
}
public enum Direction: CaseIterable {
    case up, down, left, right
    var delta: Cell {
        switch self {
            case .up: return Cell(0, -1)
            case .down: return Cell(0, 1)
            case .left: return Cell(-1, 0)
            case .right: return Cell(1, 0)
        }
    }
}
public enum Role: String {
    case master = "MASTER"
    case deputy = "DEPUTY"
    case normal = "NORMAL"
}
public struct Participant {
    public let name: String
    public internal(set) var role: Role
    public internal(set) var score = 0
    public internal(set) var body: [Cell] = []
    var heading = Direction.up
    var command: (Int64, Direction)?
    var latestSteer: Int64 = -1
}
public enum GameError: String, LocalizedError {
    case configuration = "Недопустимые параметры игры"
    case capacity = "Лимит участников исчерпан"
    case spawn = "Нет места для новой змейки"
    case player = "Участник не найден"
    public var errorDescription: String? { rawValue }
}
public struct Game {
    public let width, height, reserve, interval: Int
    public let name: String
    public internal(set) var players: [Int: Participant] = [:]
    public internal(set) var food = Set<Cell>()
    public internal(set) var nextID = 1
    public var targetFood: Int { reserve + players.values.filter { !$0.body.isEmpty }.count }
    public init(name: String, width: Int, height: Int, reserve: Int, interval: Int) throws {
    guard (1...32).contains(name.utf8.count), (10...100).contains(width),
      (10...100).contains(height), (0...10).contains(reserve),
      (100...3000).contains(interval)
    else { throw GameError.configuration }
    self.name = name
    self.width = width
    self.height = height
    self.reserve = reserve
    self.interval = interval
    }

    func offset(_ p: Cell, _ dx: Int, _ dy: Int) -> Cell {
        Cell((p.x + dx + width) % width, (p.y + dy + height) % height)
    }

    var cells: [Cell] { (0..<height).flatMap { y in (0..<width).map { Cell($0, y) } } }

    mutating func replenish() { // добавить недостающую еду
        let missing = targetFood - food.count
        guard missing > 0 else { return }
        let occupied = Set(players.values.flatMap(\.body)).union(food)
        food.formUnion(cells.filter { !occupied.contains($0) }.shuffled().prefix(missing))
    }
    
    func spawn(_ participant: inout Participant) throws {
        let occupied = Set(players.values.flatMap(\.body))
        guard players.values.filter({ !$0.body.isEmpty }).count < 4 else { throw GameError.spawn }
        for head in cells.shuffled() where !food.contains(head) {
          guard (-2...2).allSatisfy({ dx in (-2...2).allSatisfy { !occupied.contains(offset(head, dx, $0)) }})
          else { continue }
          for direction in Direction.allCases.shuffled() {
            let tail = offset(head, -direction.delta.x, -direction.delta.y)
            if food.contains(tail) { continue }
            participant.body = [head, tail]
            participant.heading = direction
            return
          }
        }
        throw GameError.spawn
    }
    
    public mutating func join(name: String, playing: Bool) throws -> Int { //добавление участника
    guard (1...24).contains(name.utf8.count) else { throw GameError.configuration }
    guard players.count < 6, nextID < Int32.max else { throw GameError.capacity }
    let role: Role = players.isEmpty ? .master : (players.count == 1 ? .deputy : .normal)
    var participant = Participant(name: name, role: role)
    if playing { try spawn(&participant) }
    let id = nextID
    players[id] = participant
    nextID += 1
    replenish()
    return id
  }
  public mutating func setPlaying(_ playing: Bool, id: Int) throws { //переключение играть/смотреть
    guard var p = players[id] else { throw GameError.player }
    guard playing == p.body.isEmpty else { return }
    if playing { try spawn(&p) } else { p.body.removeAll() }
    p.command = nil
    players[id] = p
    replenish()
  }
  public mutating func leave(_ id: Int) {
    players.removeValue(forKey: id)
    if !players.values.contains(where: { $0.role == .master }),
      let deputy = players.first(where: { $0.value.role == .deputy })?.key
    {
      players[deputy]?.role = .master
    }
    if !players.values.contains(where: { $0.role == .deputy }),
      let candidate = players.keys.sorted().first(where: { players[$0]?.role == .normal })
    {
      players[candidate]?.role = .deputy
    }
    replenish()
  }
  public mutating func steer(_ d: Direction, id: Int, sequence: Int64) {
    guard let p = players[id], p.body.count >= 2, sequence > p.latestSteer,
      offset(p.body[0], d.delta.x, d.delta.y) != p.body[1]
    else { return }
    players[id]?.command = (sequence, d)
    players[id]?.latestSteer = sequence
  }
  public mutating func tick() {
    var eaten = Set<Cell>()
    for (id, var p) in players where !p.body.isEmpty {
      p.heading = p.command?.1 ?? p.heading
      p.command = nil
      let d = p.heading.delta
      let head = offset(p.body[0], d.x, d.y)
      let feeding = food.contains(head)
      if feeding {
        eaten.insert(head)
        p.score = min(Int(Int32.max), p.score + 1)
      }
      if !feeding || p.body.count == 32 { p.body.removeLast() }
      p.body.insert(head, at: 0)
      players[id] = p
    }
    var dead = Set<Int>()
    let moved = players
    for (id, p) in moved {
      guard let head = p.body.first else { continue }
      if p.body.dropFirst().contains(head) { dead.insert(id) }
      for (owner, other) in moved where owner != id && other.body.contains(head) {
        dead.insert(id)
        let score = min(Int(Int32.max), (players[owner]?.score ?? 0) + 1)
        players[owner]?.score = score
      }
    }
    for id in dead { players[id]?.body = [] }
    food.subtract(eaten)
    replenish()
  }
}
