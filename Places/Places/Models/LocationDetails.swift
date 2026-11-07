import Foundation

struct LocationDetails: Sendable {
  let location: Location
  let weather: Weather?
  let places: [Place]
  var weatherError: String? = nil
  var placesError: String? = nil
}
