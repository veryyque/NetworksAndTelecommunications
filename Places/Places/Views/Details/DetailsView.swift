import SwiftUI

struct DetailsView: View {
  let details: LocationDetails
  let onSelectPlace: (Place) -> Void
  var body: some View {
    Text(details.location.title).font(.largeTitle.bold())
    Text(details.location.subtitle).foregroundStyle(.secondary)
    WeatherCardView(weather: details.weather)
    Text("Рядом · до 5 км").font(.title2.bold())
    if details.places.isEmpty { Text("Поблизости нет статей с координатами в русской Википедии.") }
    ForEach(Array(details.places.enumerated()), id: \.element.id) { index, place in
      PlaceCardView(number: index + 1, place: place, onOpen: { onSelectPlace(place) })
    }
    Text(
      "Данные: GraphHopper / OpenStreetMap, OpenWeather, Wikipedia. Описания — по лицензии статьи."
    )
    .font(.caption).foregroundStyle(.secondary)
  }
}
