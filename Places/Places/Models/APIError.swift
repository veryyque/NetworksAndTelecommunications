import Foundation

struct APIError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
