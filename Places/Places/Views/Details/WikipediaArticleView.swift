import SwiftUI
import AppKit

struct WikipediaArticleView: View {
  let place: Place
  let onBack: () -> Void
  @StateObject private var model = WikipediaArticleViewModel()
  @State private var reloadID = UUID()

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("О месте", systemImage: "book").font(.headline)
          .foregroundStyle(Color.accentColor)
        Spacer()
        Button("← К ближайшим местам", action: onBack)
          .keyboardShortcut(.cancelAction)
      }.padding(20)
      Divider()
      if model.loading {
        ProgressView("Загрузка статьи…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let error = model.errorMessage {
        VStack(spacing: 16) {
          Text("Не удалось загрузить статью").font(.headline)
          Text(error).foregroundStyle(.secondary)
          Button("Повторить") { reloadID = UUID() }
            .buttonStyle(.borderedProminent)
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            Text(place.title).font(.largeTitle.bold())
              .foregroundStyle(Color.accentColor)
            if let data = place.imageData, let image = NSImage(data: data) {
              Image(nsImage: image).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel(place.title)
              if let url = place.imagePageURL {
                Link("Источник фото, автор и лицензия ↗", destination: url).font(.caption)
              }
            }
            VStack(alignment: .leading, spacing: 14) {
              ForEach(Array(model.blocks.enumerated()), id: \.offset) { _, block in
                if block.headingLevel > 0 {
                  Text(block.text)
                    .font(block.headingLevel == 2 ? .title2.bold() : .headline)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                  Text(block.text).font(.body).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
              }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            .background(Color("RoseSurface"), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color("RoseBorder"), lineWidth: 1))
            Link("Источник: Википедия · авторы и лицензия ↗", destination: place.url)
              .font(.caption)
          }.padding(24).frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
      }
    }
    .background(Color("RoseSelection").opacity(0.25))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: reloadID) { await model.load(id: place.id) }
  }
}
