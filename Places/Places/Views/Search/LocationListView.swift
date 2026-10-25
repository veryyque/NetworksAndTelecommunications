import SwiftUI

struct LocationListView: View {
  let locations: [Location]
  let selectedID: String?
  let searching: Bool
  let searched: Bool
  let onSelect: (Location) -> Void
  var body: some View {
    VStack(alignment: .leading) {
      Text("Варианты локации").font(.caption.bold()).foregroundStyle(.secondary).padding()
      if searching { ProgressView("Поиск…").padding() }
      if searched && locations.isEmpty {
        Text("Ничего не найдено. Попробуйте другое название.").padding()
      }
      ScrollView {
        VStack(spacing: 8) {
          ForEach(locations) { location in
            Button {
              onSelect(location)
            } label: {
              LocationRowView(location: location, isSelected: selectedID == location.id)
            }.buttonStyle(.plain)
          }
        }.padding(.horizontal)
      }
    }.frame(minWidth: 250, idealWidth: 290, maxWidth: 360)
  }
}
