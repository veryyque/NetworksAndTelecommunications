import Foundation

@MainActor
final class AppDependencies {
  private let keyStore: any APIKeyStoring

  init(keyStore: (any APIKeyStoring)? = nil) {
    self.keyStore = keyStore ?? KeychainAPIKeyStore()
  }

  func makePlacesViewModel() -> PlacesViewModel {
    PlacesViewModel { [keyStore] in
      PlacesService(
        graphKey: keyStore.read("graphhopper"), weatherKey: keyStore.read("openweather"))
    }
  }

  func makeSettingsViewModel() -> APISettingsViewModel {
    APISettingsViewModel(store: keyStore)
  }
}
