import SwiftUI
import AppKit

struct PlaceImageView: View {
  let place: Place
  let maxHeight: CGFloat
  @StateObject private var model = PlaceImageViewModel()

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let data = model.imageData, let image = NSImage(data: data) {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: .infinity, maxHeight: maxHeight)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .accessibilityLabel("Изображение: " + place.title)
        if let url = place.imagePageURL {
          Link("Источник фото, автор и лицензия ↗", destination: url)
            .font(.caption).foregroundStyle(.secondary)
        }
      } else if model.loading {
        ProgressView("Загрузка фото…")
          .frame(maxWidth: .infinity, minHeight: 80)
      } else {
        Label("Фото недоступно", systemImage: "photo")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .task(id: place.imageURL) { await model.load(url: place.imageURL) }
  }
}
