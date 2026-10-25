import Foundation

struct LocationDetails: Sendable {
  let location: Location
  let weather: Weather
  let places: [Place]
}
