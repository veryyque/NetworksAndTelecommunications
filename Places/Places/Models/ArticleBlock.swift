import Foundation

struct ArticleBlock {
  let text: String
  let headingLevel: Int

  static func parse(_ text: String) -> [ArticleBlock] {
    var blocks: [ArticleBlock] = []
    var lines: [String] = []
    func flush() {
      if !lines.isEmpty {
        blocks.append(ArticleBlock(text: lines.joined(separator: "\n"), headingLevel: 0))
        lines.removeAll()
      }
    }
    for rawLine in text.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      let level = line.prefix(while: { $0 == "=" }).count
      if level >= 2 && line.hasSuffix(String(repeating: "=", count: level)) {
        flush()
        let title = line.trimmingCharacters(in: CharacterSet(charactersIn: "= "))
        if !title.isEmpty { blocks.append(ArticleBlock(text: title, headingLevel: level)) }
      } else if line.isEmpty {
        flush()
      } else {
        lines.append(line)
      }
    }
    flush()
    return blocks
  }
}
