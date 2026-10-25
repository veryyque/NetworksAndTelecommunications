import Foundation

struct Location: Decodable, Identifiable, Sendable {
  struct Point: Decodable, Sendable {
    let lat: Double
    let lng: Double
  }
  let name: String?
  let city: String?
  let country: String?
  let point: Point
  var title: String { name ?? city ?? "Без названия" }
  var subtitle: String { [city, country].compactMap { $0 }.joined(separator: ", ") }
  var id: String { "\(title)|\(point.lat)|\(point.lng)" }
}
