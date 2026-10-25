import SwiftUI

struct DetailsView: View {
  let details: LocationDetails
  var body: some View {
    Text(details.location.title).font(.largeTitle.bold())
    Text(details.location.subtitle).foregroundStyle(.secondary)
    WeatherCardView(weather: details.weather)
    Text("Рядом · до 5 км").font(.title2.bold())
    if details.places.isEmpty { Text("Поблизости нет статей с координатами в русской Википедии.") }
    ForEach(details.places) { place in
      PlaceCardView(place: place)
    }
    Text(
      "Данные: GraphHopper / OpenStreetMap, OpenWeather, Wikipedia. Описания — по лицензии статьи."
    )
    .font(.caption).foregroundStyle(.secondary)
  }
}
