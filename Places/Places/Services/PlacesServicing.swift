import Foundation

protocol PlacesServicing: Sendable {
  func searchLocations(query: String) async throws -> [Location]
  func loadDetails(for location: Location) async throws -> LocationDetails
}
