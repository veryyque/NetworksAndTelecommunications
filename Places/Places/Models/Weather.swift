import Foundation

struct Weather: Decodable, Sendable {
  struct Main: Decodable, Sendable {
    let temp: Double
    let feels_like: Double
    let humidity: Int
    let pressure: Double

    var pressureMMHg: Double { pressure * 0.750061683 }
  }
  struct Wind: Decodable, Sendable { let speed: Double }
  struct Condition: Decodable, Sendable { let description: String }
  let main: Main
  let wind: Wind
  let weather: [Condition]
}
