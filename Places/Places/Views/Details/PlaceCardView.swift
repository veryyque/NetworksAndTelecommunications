import SwiftUI
import AppKit

struct PlaceCardView: View {
  let place: Place
  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top) {
          Text(place.title).font(.headline)
          Spacer()
          Text("\(place.distance, specifier: "%.0f") м").foregroundStyle(.secondary)
        }
        if let data = place.imageData, let image = NSImage(data: data) {
          Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: 260)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("Изображение: " + place.title)
          if let url = place.imagePageURL {
            Link("Источник фото, автор и лицензия ↗", destination: url)
              .font(.caption).foregroundStyle(.secondary)
          }
        } else {
          Label("Фото недоступно", systemImage: "photo")
            .font(.caption).foregroundStyle(.secondary)
        }
        Text(place.description).textSelection(.enabled)
        Link("Читать в Википедии ↗", destination: place.url)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
    }
  }
}
