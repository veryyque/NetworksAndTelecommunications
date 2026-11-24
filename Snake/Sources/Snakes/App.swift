import SwiftUI

@main struct SnakesApp: App {
  var body: some Scene {
    WindowGroup("Змейка по сети") { SessionView() }
      .defaultSize(width: 1320, height: 850)
  }
}
