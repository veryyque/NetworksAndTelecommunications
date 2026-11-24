import SwiftUI

@MainActor
struct SessionView: View {
  @StateObject private var model = SessionViewModel()
  @State private var showCreate = false
  @FocusState private var focused: Bool

  private let colors: [Color] = [.red, .teal, .yellow, .purple, .orange, .green]

  var body: some View {
    HStack(spacing: 0) {
      sidebar.frame(width: 232)
      Divider()
      if let game = model.game {
        playArea(game)
        Divider()
        inspector(game).frame(width: 285)
      } else {
        Group {
          if model.isNetworkSession {
            VStack(spacing: 14) {
              ProgressView("Подключаемся к «\(model.pendingGame)»…")
              Button("Отмена") { model.leave() }
            }
          } else {
            ContentUnavailableView("Выберите игру", systemImage: "square.grid.3x3",
                                   description: Text("Присоединитесь к игре из списка или создайте свою."))
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        Divider()
        VStack(alignment: .leading) {
          Text("Участники").font(.title2.bold())
          Text("Появятся после подключения").foregroundStyle(.secondary)
          Spacer()
        }
        .padding(18).frame(width: 285, alignment: .topLeading)
      }
    }
    .frame(minWidth: 980, minHeight: 620)
    .background(Color(nsColor: .windowBackgroundColor))
    .sheet(isPresented: $showCreate) { creationForm }
    .alert("Змейка по сети", isPresented: Binding(
      get: { !model.message.isEmpty }, set: { if !$0 { model.message = "" } }
    )) {
      Button("ОК") { model.message = ""; focused = true }
    } message: { Text(model.message) }
    .onAppear { model.startCatalog() }
    .onDisappear { model.close() }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Доступные игры").font(.title2.bold())
      HStack(spacing: 13) {
        source("Локальная сеть", status: "Multicast IPv4", color: .secondary)
        source("Сервер курса", status: model.serverAvailable ? "Доступен" : "Нет ответа",
               color: model.serverAvailable ? .green : .orange)
      }
      TextField("Имя игрока", text: $model.player)
      ScrollView {
        VStack(spacing: 10) {
          ForEach(model.games) { entry in
            let announcement = entry.announcement
            let people = announcement.players.players
            let ownsGame = model.game?.players[model.ownID]?.role == .master
            let selected = ownsGame ? entry.isOwnGame
              : (model.selectedGame.map { $0.id == entry.id }
                ?? (entry.isCourseServer && model.game?.name == entry.id.game))
            gameCard(name: entry.id.game, source: entry.isCourseServer ? "Сервер курса" : "LAN",
                     people: people.count, snakes: people.filter { $0.status == .playing }.count,
                     selected: selected, canJoin: announcement.canJoin, discovered: entry)
          }
          if model.games.isEmpty, model.game == nil {
            Text("Доступных игр пока нет")
              .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(1)
      }
      Button { showCreate = true } label: {
        Label("Создать игру", systemImage: "plus").frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent).controlSize(.large)
      .disabled(model.game != nil || model.isNetworkSession)
      Text("Список обновляется автоматически")
        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
    }
    .padding(16)
  }

  private func source(_ label: String, status: String, color: Color) -> some View {
    HStack(alignment: .top, spacing: 5) {
      Circle().fill(color).frame(width: 7, height: 7).padding(.top, 4)
      VStack(alignment: .leading, spacing: 3) {
        Text(label).font(.caption.weight(.semibold))
        Text(status).font(.caption2).foregroundStyle(.secondary)
      }
    }
  }

  private func gameCard(name: String, source: String, people: Int, snakes: Int,
                        selected: Bool, canJoin: Bool, discovered: DiscoveredGame? = nil) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(name).font(.headline).lineLimit(1).help(name)
        Spacer(minLength: 4)
        Text(source).font(.caption2).foregroundStyle(.secondary)
      }
      Text("\(people)/6 участников  ·  \(snakes)/4 змейки").font(.callout).foregroundStyle(.secondary)
      if selected {
        Text("Текущая игра").font(.callout.bold()).foregroundStyle(.white)
          .frame(maxWidth: .infinity).padding(7)
          .background(.blue, in: RoundedRectangle(cornerRadius: 6))
      } else {
        HStack {
          Button("Играть") { model.connect(name: name, playing: true, discovered: discovered) }
            .buttonStyle(.borderedProminent).disabled(!canJoin || people >= 6)
          Button("Смотреть") { model.connect(name: name, playing: false, discovered: discovered) }
            .buttonStyle(.bordered).disabled(people >= 6)
        }
        .disabled(model.game != nil || model.isNetworkSession)
      }
    }
    .padding(10)
    .background(selected ? Color.blue.opacity(0.10) : Color.secondary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
      selected ? Color.blue.opacity(0.55) : Color.secondary.opacity(0.18)))
  }

  private func playArea(_ game: Game) -> some View {
    let watching = game.players[model.ownID]?.body.isEmpty ?? true
    return VStack(alignment: .leading, spacing: 14) {
      Text(game.name).font(.system(size: 34, weight: .bold)).lineLimit(1)
      Text("Поле \(game.width)×\(game.height)  ·  Ход \(game.interval) мс")
        .foregroundStyle(.secondary)
      board(game)
        .aspectRatio(Double(game.width + 1) / Double(game.height + 1), contentMode: .fit)
        .focusable().focused($focused)
        .onKeyPress { press in
          let direction: Direction
          switch (press.key, press.characters.lowercased()) {
          case (.upArrow, _), (_, "w"): direction = .up
          case (.downArrow, _), (_, "s"): direction = .down
          case (.leftArrow, _), (_, "a"): direction = .left
          case (.rightArrow, _), (_, "d"): direction = .right
          default: return .ignored
          }
          model.steer(direction)
          return .handled
        }
      Label(watching ? "Вы наблюдаете" : "Управление стрелками или WASD",
            systemImage: watching ? "eye" : "keyboard")
        .font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
      Spacer(minLength: 0)
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task { focused = true }
  }

  private func board(_ game: Game) -> some View {
    Canvas { context, size in
      let margin = 23.0
      let scale = min((size.width - margin) / Double(game.width),
                      (size.height - margin) / Double(game.height))
      guard scale > 0 else { return }
      let width = Double(game.width) * scale, height = Double(game.height) * scale
      let x = (size.width - width + margin) / 2, y = (size.height - height + margin) / 2
      let bounds = CGRect(x: x, y: y, width: width, height: height)
      context.fill(Path(roundedRect: bounds, cornerRadius: 4),
                   with: .color(Color(red: 0.08, green: 0.15, blue: 0.23)))
      var grid = Path()
      for column in 0...game.width {
        let edge = x + Double(column) * scale
        grid.move(to: CGPoint(x: edge, y: y))
        grid.addLine(to: CGPoint(x: edge, y: y + height))
        if column < game.width, scale >= 14 || column.isMultiple(of: 5) {
          context.draw(Text("\(column + 1)").font(.system(size: 10)).foregroundStyle(.secondary),
                       at: CGPoint(x: edge + scale / 2, y: y - 11))
        }
      }
      for row in 0...game.height {
        let edge = y + Double(row) * scale
        grid.move(to: CGPoint(x: x, y: edge))
        grid.addLine(to: CGPoint(x: x + width, y: edge))
        if row < game.height, scale >= 14 || row.isMultiple(of: 5) {
          context.draw(Text("\(row + 1)").font(.system(size: 10)).foregroundStyle(.secondary),
                       at: CGPoint(x: x - 11, y: edge + scale / 2))
        }
      }
      context.stroke(grid, with: .color(.white.opacity(0.13)), lineWidth: 0.5)
      func rect(_ cell: Cell) -> CGRect {
        CGRect(x: x + Double(cell.x) * scale, y: y + Double(cell.y) * scale, width: scale, height: scale)
      }
      for food in game.food {
        context.fill(Path(ellipseIn: rect(food).insetBy(dx: scale * 0.28, dy: scale * 0.28)), with: .color(.red))
      }
      for (id, player) in game.players {
        for (index, cell) in player.body.enumerated() {
          let inset = rect(cell).insetBy(dx: scale * 0.045, dy: scale * 0.045)
          context.fill(Path(roundedRect: inset, cornerRadius: index == 0 ? scale * 0.24 : 0),
                       with: .color(color(id)))
          if index == 0 {
            let eye = CGRect(x: inset.midX - scale * 0.08, y: inset.midY - scale * 0.08,
                             width: scale * 0.16, height: scale * 0.16)
            context.fill(Path(ellipseIn: eye), with: .color(.black))
          }
        }
      }
    }
    .accessibilityLabel("Игровое поле")
  }

  private func inspector(_ game: Game) -> some View {
    let watching = game.players[model.ownID]?.body.isEmpty ?? true
    let snakes = playingCount(game)
    return VStack(alignment: .leading, spacing: 16) {
      Text("Участники · \(game.players.count)/6").font(.title2.bold())
      VStack(spacing: 0) {
        playerRow(name: "Имя", score: "Очки", role: "Роль", status: "Статус")
          .fontWeight(.semibold).background(Color.secondary.opacity(0.10))
        ForEach(game.players.keys.sorted(), id: \.self) { id in
          if let p = game.players[id] {
            Divider()
            playerRow(name: p.name + (id == model.ownID ? " (вы)" : ""), score: String(p.score),
                      role: p.role.rawValue, status: p.body.isEmpty ? "Смотрит" : "Играет",
                      marker: p.body.isEmpty ? .gray : color(id))
              .background(id == model.ownID ? Color.blue.opacity(0.10) : .clear)
          }
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 7))
      .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.2)))
      GroupBox("Параметры игры") {
        VStack(alignment: .leading, spacing: 10) {
          LabeledContent("Змейки", value: "\(snakes)/4")
          LabeledContent("Запас еды", value: String(game.reserve))
          LabeledContent("Цель еды", value: "\(game.reserve) + \(snakes) = \(game.targetFood)")
          LabeledContent("Еды на поле", value: String(game.food.count))
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      if game.players[model.ownID]?.role != .master,
        model.isNetworkSession, model.selectedGame?.isCourseServer != false {
        Link("Открыть веб-наблюдатель", destination: URL(string: "https://snakes.ippolitov.me/")!)
      }
      Spacer()
      Button {
        model.changeStatus(playing: watching)
        focused = true
      } label: {
        Text(watching ? "Вернуться в игру" : "Смотреть").frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent).controlSize(.large).disabled(watching && snakes >= 4)
      Button(role: .destructive) {
        model.leave()
      } label: {
        Text("Выйти из игры").font(.callout.bold()).foregroundStyle(.red)
          .frame(maxWidth: .infinity).padding(.vertical, 9)
          .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.75)))
      }
      .buttonStyle(.plain)
    }
    .padding(16)
  }

  private func playerRow(name: String, score: String, role: String, status: String,
                         marker: Color? = nil) -> some View {
    HStack(spacing: 6) {
      HStack(spacing: 5) {
        if let marker { RoundedRectangle(cornerRadius: 2).fill(marker).frame(width: 10, height: 10) }
        Text(name).lineLimit(1).help(name)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Text(score).monospacedDigit().frame(width: 42)
      Text(role).frame(width: 52)
      Text(status).foregroundStyle(status == "Играет" ? Color.green : .secondary).frame(width: 50)
    }
    .font(.caption).padding(8)
  }

  private var creationForm: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Создать игру").font(.title2.bold())
      Form {
        TextField("Имя игрока", text: $model.player)
        TextField("Название игры", text: $model.title)
        Stepper("Ширина \(model.width)", value: $model.width, in: 10...100)
        Stepper("Высота \(model.height)", value: $model.height, in: 10...100)
        Stepper("Запас еды \(model.reserve)", value: $model.reserve, in: 0...10)
        Stepper("Интервал \(model.interval) мс", value: $model.interval, in: 100...3000, step: 50)
      }
      Text("При создании на сервере параметры поля выбирает сервер курса.")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Отмена") { showCreate = false }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("На сервере курса") {
          showCreate = false
          model.connect(name: model.title, playing: true)
        }
        Button("В локальной сети") {
          showCreate = false
          model.createLocalGame()
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(22).frame(width: 490)
  }

  private func playingCount(_ game: Game) -> Int {
    game.players.values.filter { !$0.body.isEmpty }.count
  }

  private func color(_ id: Int) -> Color { colors[(id - 1) % colors.count] }
}
