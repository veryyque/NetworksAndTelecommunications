import Combine
import Foundation

@MainActor
final class PlacesViewModel: ObservableObject {
  @Published var query = ""
  @Published private(set) var locations: [Location] = []
  @Published private(set) var selected: Location?
  @Published private(set) var details: LocationDetails?
  @Published private(set) var searching = false
  @Published private(set) var loading = false
  @Published private(set) var searched = false
  @Published private(set) var error: String?
  private var task: Task<Void, Never>?
  private var revision = 0
  private let makeService: () -> any PlacesServicing

  init(makeService: @escaping () -> any PlacesServicing) {
    self.makeService = makeService
  }

  var canSearch: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  func cancel() {
    task?.cancel()
    revision += 1
    searching = false
    loading = false
  }

  func search() {
    task?.cancel()
    revision += 1
    let revision = revision
    let service = makeService()
    let query = query
    locations = []
    details = nil
    selected = nil
    error = nil
    searching = true
    loading = false
    searched = false
    task = Task {
      defer { if self.revision == revision { searching = false } }
      do {
        let result = try await service.searchLocations(query: query)
        guard !Task.isCancelled, self.revision == revision else { return }
        locations = result
        searched = true
      } catch {
        guard !Task.isCancelled, self.revision == revision else { return }
        self.error = error.localizedDescription
      }
    }
  }
  func select(_ location: Location) {
    task?.cancel()
    revision += 1
    let revision = revision
    let service = makeService()
    selected = location
    details = nil
    error = nil
    loading = true
    searching = false
    task = Task {
      defer { if self.revision == revision { loading = false } }
      do {
        let result = try await service.loadDetails(for: location)
        guard !Task.isCancelled, self.revision == revision else { return }
        details = result
      } catch {
        guard !Task.isCancelled, self.revision == revision else { return }
        self.error = error.localizedDescription
      }
    }
  }
}
