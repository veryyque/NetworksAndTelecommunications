import Foundation

@MainActor
protocol APIKeyStoring {
  func read(_ account: String) -> String
  func save(_ value: String, account: String) throws
}
