import Combine
import Foundation

@MainActor
final class SessionViewModel: ObservableObject {
  @Published private(set) var game: Game?
  @Published private(set) var games: [DiscoveredGame] = []
  @Published private(set) var serverAvailable = false
  @Published private(set) var isNetworkSession = false
  @Published private(set) var ownID = 1
  @Published private(set) var pendingGame = ""
  @Published private(set) var selectedGame: DiscoveredGame?
  @Published var player = "Игрок"
  @Published var title = "Змейки"
  @Published var width = 20
  @Published var height = 15
  @Published var reserve = 2
  @Published var interval = 300
  @Published var message = ""

  private var course: CourseSession?
  private var catalog: CourseCatalog?

  func startCatalog() {
    guard catalog == nil else { return }
    let directory = CourseCatalog { [weak self] games, available in
      DispatchQueue.main.async { [weak self] in
        guard let self, self.catalog != nil else { return }
        self.games = games
        self.serverAvailable = available
      }
    }
    catalog = directory
    directory.start()
  }

  func close() {
    catalog?.stop()
    catalog = nil
    leave()
  }

  func createLocalGame() {
    guard game == nil, course == nil else { return }
    do {
      var local = try Game(name: title, width: width, height: height, reserve: reserve, interval: interval)
      try local.join(name: player, playing: true)
      pendingGame = title
      let session = CourseSession(gameName: title, playerName: player, catalog: catalog) { [weak self] event in
        DispatchQueue.main.async { [weak self] in self?.receive(event) }
      }
      course = session
      isNetworkSession = true
      let initialGame = local
      if let catalog { catalog.useSession(session) { session.startHosting(initialGame) } }
      else { session.startHosting(initialGame) }
    } catch { message = error.localizedDescription }
  }

  func connect(name: String, playing: Bool, discovered: DiscoveredGame? = nil) {
    guard game == nil, course == nil else { return }
    guard (1...24).contains(player.utf8.count), (1...32).contains(name.utf8.count) else {
      message = "Имя игрока должно занимать 1–24 байта, название игры — 1–32 байта"
      return
    }
    pendingGame = name
    selectedGame = discovered
    let session = CourseSession(gameName: name, playerName: player, playing: playing, discovered: discovered, catalog: catalog) { [weak self] event in
      DispatchQueue.main.async { [weak self] in self?.receive(event) }
    }
    course = session
    isNetworkSession = true
    if let catalog { catalog.useSession(session) { session.start() } }
    else { session.start() }
  }

  func steer(_ direction: Direction) {
    guard game?.players[ownID]?.body.isEmpty == false else { return }
    course?.steer(direction)
  }

  func changeStatus(playing: Bool) { course?.changeStatus(playing: playing) }

  func leave() { course?.leave() }

  private func receive(_ event: CourseSession.Event) {
    switch event {
    case let .snapshot(snapshot, id):
      ownID = id
      game = snapshot
    case let .notice(text):
      message = text
    case let .disconnected(text):
      game = nil
      course = nil
      catalog?.useSession(nil)
      isNetworkSession = false
      ownID = 1
      pendingGame = ""
      selectedGame = nil
      message = text
    }
  }
}
