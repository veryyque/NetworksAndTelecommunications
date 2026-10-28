import SwiftUI

struct DetailsPanelView: View {
  let details: LocationDetails?
  let loading: Bool
  let error: String?
  let canRetry: Bool
  let onRetry: () -> Void
  @State private var selectedPlace: Place?

  var body: some View {
    Group {
      if loading {
        ProgressView("Загружаем погоду, места и описания…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let place = selectedPlace {
        WikipediaArticleView(place: place, onBack: { selectedPlace = nil })
          .id(place.id)
      } else if details == nil && error == nil {
        ContentUnavailableView(
          "Выберите место", systemImage: "map",
          description: Text("Введите название, затем выберите локацию в списке слева."))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            if let error {
              Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
              if canRetry { Button("Повторить", action: onRetry) }
            }
            if let details {
              DetailsView(details: details, onSelectPlace: { selectedPlace = $0 })

            }
          }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
    .onChange(of: loading) { _, loading in
      if loading { selectedPlace = nil }
    }
    .onChange(of: details?.location.id) { _, _ in selectedPlace = nil }
  }
}
