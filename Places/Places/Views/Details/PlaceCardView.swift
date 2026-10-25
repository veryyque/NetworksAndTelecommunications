import SwiftUI

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
        Text(place.description).textSelection(.enabled)
        Link("Читать в Википедии ↗", destination: place.url)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
    }
  }
}
