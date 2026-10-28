import Foundation

struct Place: Identifiable, Sendable {
  let id: Int
  let title: String
  let distance: Double
  let description: String
  var imageData: Data? = nil
  var imagePageURL: URL? = nil
  var url: URL { URL(string: "https://ru.wikipedia.org/?curid=\(id)")! }
}
