import Combine
import Foundation

@MainActor
final class APISettingsViewModel: ObservableObject {
  @Published var graphKey: String
  @Published var weatherKey: String
  @Published private(set) var error: String?
  private let store: any APIKeyStoring

  init(store: any APIKeyStoring) {
    self.store = store
    graphKey = store.read("graphhopper")
    weatherKey = store.read("openweather")
  }

  func save() -> Bool {
    error = nil
    do {
      try store.save(graphKey, account: "graphhopper")
      try store.save(weatherKey, account: "openweather")
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }
}
