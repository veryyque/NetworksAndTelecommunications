import Foundation
import Combine

@MainActor
final class PlaceImageViewModel: ObservableObject {
  @Published private(set) var imageData: Data?
  @Published private(set) var loading = false
  private let service: PlacesService

  init(service: PlacesService = PlacesService(graphKey: "", weatherKey: "")) {
    self.service = service
  }

  func load(url: URL?) async {
    imageData = nil
    loading = url != nil
    defer { loading = false }
    do {
      let data = try await service.loadImage(url)
      try Task.checkCancellation()
      imageData = data
    } catch {
      // Фото необязательно: ошибка или отмена не влияют на отчёт.
    }
  }
}
