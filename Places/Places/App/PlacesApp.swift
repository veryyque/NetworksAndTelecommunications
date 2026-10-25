import SwiftUI

@main
struct PlacesApp: App {
  private let dependencies = AppDependencies()

  var body: some Scene {
    WindowGroup("Places") {
      ContentView(
        model: dependencies.makePlacesViewModel(),
        makeSettingsModel: dependencies.makeSettingsViewModel
      ).frame(minWidth: 850, minHeight: 600)
    }
  }
}
