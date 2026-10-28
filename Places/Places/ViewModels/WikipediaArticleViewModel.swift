import Foundation
import Combine

@MainActor
final class WikipediaArticleViewModel: ObservableObject {
  @Published private(set) var loading = true
  @Published private(set) var blocks: [ArticleBlock] = []
  @Published private(set) var errorMessage: String?
  private let service: any PlacesServicing

  init(service: any PlacesServicing = PlacesService(graphKey: "", weatherKey: "")) {
    self.service = service
  }

  func load(id: Int) async {
    loading = true
    errorMessage = nil
    do {
      let result = try await service.loadArticle(id: id)
      try Task.checkCancellation()
      blocks = ArticleBlock.parse(result)
      loading = false
    } catch {
      guard !Task.isCancelled else { return }
      errorMessage = error.localizedDescription
      loading = false
    }
  }
}
