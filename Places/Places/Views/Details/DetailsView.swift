import SwiftUI

struct DetailsView: View {
  let details: LocationDetails
  let onSelectPlace: (Place) -> Void
  var body: some View {
    Text(details.location.title).font(.largeTitle.bold())
    Text(details.location.subtitle).foregroundStyle(.secondary)
    if let weather = details.weather { WeatherCardView(weather: weather) }
    if let error = details.weatherError {
      Label("Погода: " + error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
    }
    Text("Рядом · до 5 км").font(.title2.bold())
    if let error = details.placesError {
      Label("Места: " + error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
    }
    if details.placesError == nil && details.places.isEmpty { Text("Поблизости нет статей с координатами в русской Википедии.") }
    ForEach(Array(details.places.enumerated()), id: \.element.id) { index, place in
      PlaceCardView(number: index + 1, place: place, onOpen: { onSelectPlace(place) })
    }
  }
}
