import SwiftUI

struct SearchBarView: View {
  @Binding var query: String
  let canSearch: Bool
  let onSearch: () -> Void
  var body: some View {
    HStack {
      TextField("Город, улица или достопримечательность", text: $query)
        .textFieldStyle(.roundedBorder).onSubmit { onSearch() }
      Button("Найти") { onSearch() }.buttonStyle(.borderedProminent)
        .disabled(!canSearch)
    }.padding(.horizontal, 24).padding(.bottom, 20)
  }
}
