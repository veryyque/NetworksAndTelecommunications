import SwiftUI

struct RoseGroupBoxStyle: GroupBoxStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      configuration.label.font(.headline).foregroundStyle(Color.accentColor)
      configuration.content
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color("RoseSurface"), in: RoundedRectangle(cornerRadius: 16))
    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color("RoseBorder"), lineWidth: 1))
  }
}
