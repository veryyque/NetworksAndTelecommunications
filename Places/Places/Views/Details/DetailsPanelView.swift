import SwiftUI

struct DetailsPanelView: View {
  let details: LocationDetails?
  let loading: Bool
  let error: String?
  let canRetry: Bool
  let onRetry: () -> Void
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        if let error = error {
          Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
          if canRetry { Button("Повторить", action: onRetry) }
        }
        if loading {
          ProgressView("Загружаем погоду, места и описания…").padding(.vertical, 60)
        } else if let details = details {
          DetailsView(details: details)
        } else if error == nil {
          ContentUnavailableView(
            "Выберите место", systemImage: "map",
            description: Text("Введите название, затем выберите локацию в списке слева."))
        }
      }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
    }.frame(minWidth: 480)
  }
}
