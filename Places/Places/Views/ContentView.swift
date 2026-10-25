import SwiftUI

struct ContentView: View {
  @StateObject private var model: PlacesViewModel
  @State private var settings = false
  private let makeSettingsModel: () -> APISettingsViewModel

  init(model: PlacesViewModel, makeSettingsModel: @escaping () -> APISettingsViewModel) {
    _model = StateObject(wrappedValue: model)
    self.makeSettingsModel = makeSettingsModel
  }

  var body: some View {
    VStack(spacing: 0) {
      PlacesHeaderView { settings = true }
      SearchBarView(query: $model.query, canSearch: model.canSearch, onSearch: model.search)
      Divider()
      HSplitView {
        LocationListView(
          locations: model.locations, selectedID: model.selected?.id,
          searching: model.searching, searched: model.searched, onSelect: model.select)
        DetailsPanelView(
          details: model.details, loading: model.loading, error: model.error,
          canRetry: model.selected != nil
        ) {
          if let selected = model.selected { model.select(selected) }
        }
      }
    }
    .background(Color("RoseBackground"))
    .foregroundStyle(Color("RoseText"))
    .tint(Color.accentColor)
    .groupBoxStyle(RoseGroupBoxStyle())
    .sheet(isPresented: $settings) { APISettingsView(model: makeSettingsModel()) }
    .onDisappear { model.cancel() }
  }
}
