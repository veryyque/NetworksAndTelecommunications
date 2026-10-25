import Foundation

struct Place: Identifiable, Sendable {
  let id: Int
  let title: String
  let distance: Double
  let description: String
  var url: URL { URL(string: "https://ru.wikipedia.org/?curid=\(id)")! }
}
