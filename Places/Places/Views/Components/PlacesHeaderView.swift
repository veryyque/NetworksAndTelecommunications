import SwiftUI

struct PlacesHeaderView: View {
  let onSettings: () -> Void
  var body: some View {
    HStack {
      Image("PlacesMark").resizable().scaledToFit().frame(width: 60, height: 60)
      VStack(alignment: .leading) {
        Text("Места").font(.largeTitle.bold())
        Text("Погода и интересное рядом").foregroundStyle(.secondary)
      }
      Spacer()
      Button("API-ключи", systemImage: "key") { onSettings() }
    }.padding(24)
  }
}
