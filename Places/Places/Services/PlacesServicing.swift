import Foundation

protocol PlacesServicing: Sendable {
  func searchLocations(query: String) async throws -> [Location]
  func loadArticle(id: Int) async throws -> String
  func loadDetails(for location: Location) async throws -> LocationDetails
}
