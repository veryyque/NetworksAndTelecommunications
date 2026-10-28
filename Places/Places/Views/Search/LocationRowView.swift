import SwiftUI

struct LocationRowView: View {
  let number: Int
  let location: Location
  let isSelected: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("\(number). \(location.title)").font(.headline)
      Text(location.typeLabel).font(.caption).foregroundStyle(.secondary)
      Text(location.subtitle).font(.caption).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
      .background(isSelected ? Color("RoseSelection") : Color("RoseSurface"))
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color("RoseBorder"), lineWidth: 1))
  }
}
