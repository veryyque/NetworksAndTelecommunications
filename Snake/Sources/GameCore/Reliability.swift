import Foundation

/// One window per game and sending endpoint. Only validated requests may commit.
struct ReplyWindow {
  enum Lookup: Equatable {
    case new
    case cached(Data)
    case expired
  }
  private var highest: Int64 = -1
  private var replies: [Int64: Data] = [:]
  func lookup(_ sequence: Int64) -> Lookup {
    guard sequence >= max(0, highest - 1023) else { return .expired }
    return replies[sequence].map(Lookup.cached) ?? .new
  }
  mutating func commit(_ sequence: Int64, response: Data) {
    guard lookup(sequence) == .new else { return }
    highest = max(highest, sequence)
    replies = replies.filter { $0.key >= highest - 1023 }
    replies[sequence] = response
  }
}

/// One queue per destination. A full queue applies backpressure to its caller.
struct RetryQueue {
  enum Kind { case control, steer, state }
  struct Pending {
    let bytes: Data
    let kind: Kind
    var sent: ContinuousClock.Instant
  }
  private(set) var packets: [Int64: Pending] = [:]
  mutating func record(_ sequence: Int64, bytes: Data, kind: Kind, at now: ContinuousClock.Instant)
    -> Bool
  {
    guard sequence >= 0 else { return false }
    let retained = packets.filter {
      $0.key > sequence - 1024 && (kind == .control || $0.value.kind != kind)
    }
    guard retained.count < 64 else { return false }
    packets = retained
    packets[sequence] = Pending(bytes: bytes, kind: kind, sent: now)
    return true
  }
  mutating func acknowledge(_ sequence: Int64) { packets.removeValue(forKey: sequence) }
  mutating func due(at now: ContinuousClock.Instant) -> [Data] {
    let due = packets.keys.filter { now - packets[$0]!.sent >= .milliseconds(100) }.sorted()
    return due.compactMap { seq in
      packets[seq]?.sent = now
      return packets[seq]?.bytes
    }
  }
}

struct SnapshotOrder {
  private(set) var latest: Int64 = -1
  mutating func accept(_ order: Int64) -> Bool {
    guard order > latest else { return false }
    latest = order
    return true
  }
}

struct GameDirectory<Announcement> {
  struct Key: Hashable {
    let game: String
    let master: Endpoint
  }
  private var entries: [Key: (ContinuousClock.Instant, Announcement)] = [:]
  mutating func observe(_ value: Announcement, key: Key, at now: ContinuousClock.Instant) {
    entries[key] = (now, value)
  }
  mutating func remove(_ key: Key) { entries.removeValue(forKey: key) }

  mutating func active(at now: ContinuousClock.Instant) -> [Key: Announcement] {
    entries = entries.filter { now - $0.value.0 < .seconds(3) }
    return entries.mapValues { $0.1 }
  }
}
