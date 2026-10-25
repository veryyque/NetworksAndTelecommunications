import SwiftUI

struct APISettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var model: APISettingsViewModel

  init(model: APISettingsViewModel) {
    _model = StateObject(wrappedValue: model)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("API-ключи").font(.title.bold())
      Text("Ключи сохраняются в системной Связке ключей этого Mac.").foregroundStyle(.secondary)
      SecureField("GraphHopper API key", text: $model.graphKey)
      Link(
        "Получить ключ GraphHopper", destination: URL(string: "https://graphhopper.com/dashboard/")!
      )
      SecureField("OpenWeather API key", text: $model.weatherKey)
      Link(
        "Получить ключ OpenWeather",
        destination: URL(string: "https://home.openweathermap.org/api_keys")!)
      Text("Для Wikipedia ключ не нужен.").font(.caption)
      if let error = model.error { Text(error).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("Отмена") { dismiss() }
        Button("Сохранить") {
          if model.save() { dismiss() }
        }.buttonStyle(.borderedProminent)
      }
    }.textFieldStyle(.roundedBorder).padding(24).frame(width: 460)
      .background(Color("RoseBackground"))
      .foregroundStyle(Color("RoseText"))
      .tint(Color.accentColor)
  }
}
