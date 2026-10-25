import Foundation

struct Weather: Decodable, Sendable {
  struct Main: Decodable, Sendable {
    let temp: Double
    let feels_like: Double
    let humidity: Int
  }
  struct Wind: Decodable, Sendable { let speed: Double }
  struct Condition: Decodable, Sendable { let description: String }
  let main: Main
  let wind: Wind
  let weather: [Condition]
}
