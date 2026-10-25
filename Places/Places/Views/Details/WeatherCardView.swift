import SwiftUI

struct WeatherCardView: View {
  let weather: Weather
  var body: some View {
    GroupBox("Погода сейчас") {
      VStack(alignment: .leading, spacing: 10) {
        Text("\(weather.main.temp, specifier: "%.1f") °C").font(
          .system(size: 38, weight: .semibold))
        Text(weather.weather.first?.description.capitalized ?? "")
        Text(
          "Ощущается: \(weather.main.feels_like, specifier: "%.1f") °C · Влажность: \(weather.main.humidity)%"
        )
        Text("Ветер: \(weather.wind.speed, specifier: "%.1f") м/с")
      }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
    }
  }
}
