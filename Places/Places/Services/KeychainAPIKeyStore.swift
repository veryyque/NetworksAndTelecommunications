import Foundation
import Security

final class KeychainAPIKeyStore: APIKeyStoring {
  func read(_ account: String) -> String {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.veronikamoskalyuk.Places", kSecAttrAccount as String: account,
      kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var value: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
      let data = value as? Data
    else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
  }
  func save(_ value: String, account: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.veronikamoskalyuk.Places", kSecAttrAccount as String: account,
    ]
    let data = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    var status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(
        query.merging([kSecValueData as String: data]) { _, new in new } as CFDictionary, nil)
    }
    guard status == errSecSuccess else {
      throw APIError(message: "Не удалось сохранить ключ: \(status)")
    }
  }
}
