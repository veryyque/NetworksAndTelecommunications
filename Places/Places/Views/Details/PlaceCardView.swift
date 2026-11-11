import SwiftUI
import AppKit

struct PlaceCardView: View {
  let number: Int
  let place: Place
  let onOpen: () -> Void
  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top) {
          Text("\(number). \(place.title)").font(.headline)
          Spacer()
          Text("\(place.distance, specifier: "%.0f") м").foregroundStyle(.secondary)
        }
        PlaceImageView(place: place, maxHeight: 260)
        Text(place.description).textSelection(.enabled)
        Button("Открыть полную статью", action: onOpen)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
    }
    .contentShape(Rectangle())
    .onTapGesture(perform: onOpen)
  }
}
