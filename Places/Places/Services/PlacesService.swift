import Foundation

struct PlacesService: PlacesServicing {
  let graphKey: String
  let weatherKey: String
  var session: URLSession = .shared

  //тз 1 метод
  func searchLocations(query: String) async throws -> [Location] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }
    guard !graphKey.isEmpty else {
      throw APIError(message: "Введите ключ GraphHopper в настройках.")
    }
    struct Response: Decodable { let hits: [Location] }
    let response: Response = try await request("https://graphhopper.com/api/1/geocode", ["q": query, "locale": "ru", "limit": "10", "key": graphKey])
    var ids = Set<String>()
    return response.hits.filter { ids.insert($0.id).inserted }
  }

  //тз 2 метод
  func loadDetails(for location: Location) async throws -> LocationDetails {
    guard !weatherKey.isEmpty else {throw APIError(message: "Введите ключ OpenWeather в настройках.")}
    async let weather = loadWeather(location)
    async let places = loadPlaces(location)
    return try await LocationDetails(location: location, weather: weather, places: places)
  }
    
  private func loadWeather(_ location: Location) async throws -> Weather {
    try await request("https://api.openweathermap.org/data/2.5/weather",[ "lat": String(location.point.lat), "lon": String(location.point.lng), "appid": weatherKey, "units": "metric", "lang": "ru",])
  }
  private struct Nearby: Decodable, Sendable {
    let pageid: Int
    let title: String
    let dist: Double
  }
  private func loadPlaces(_ location: Location) async throws -> [Place] {
    struct Response: Decodable {
      struct Query: Decodable { let geosearch: [Nearby] }
      let query: Query
    }
    let response: Response = try await wiki(["list": "geosearch", "gscoord": "\(location.point.lat)|\(location.point.lng)","gsradius": "5000", "gslimit": "10", "gsnamespace": "0",])

    return try await withThrowingTaskGroup(of: Place.self) { group in
      for nearby in response.query.geosearch {
        group.addTask { try await loadDescription(nearby) }
      }
      var places: [Place] = []
      for try await place in group { places.append(place) }
      return places.sorted { ($0.distance, $0.id) < ($1.distance, $1.id) }
    }
  }
  private func loadDescription(_ nearby: Nearby) async throws -> Place {
    struct Response: Decodable {
      struct Query: Decodable {
        struct Page: Decodable { let extract: String? }
        let pages: [Page]
      }
      let query: Query
    }
    let response: Response = try await wiki(["prop": "extracts", "pageids": String(nearby.pageid), "exintro": "1", "explaintext": "1",])
    let description = response.query.pages.first?.extract?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return Place(id: nearby.pageid, title: nearby.title, distance: nearby.dist, description: description.isEmpty ? "Краткого описания нет." : description)
  }
  private func wiki<T: Decodable>(_ parameters: [String: String]) async throws -> T {
    try await request("https://ru.wikipedia.org/w/api.php", parameters.merging(["action": "query", "format": "json", "formatversion": "2",]) { first, _ in first })
  }
  private func request<T: Decodable>(_ endpoint: String, _ parameters: [String: String])
    async throws -> T {
    try Task.checkCancellation()
    var url = URLComponents(string: endpoint)!
    url.queryItems = parameters.sorted { $0.key < $1.key }.map {
      URLQueryItem(name: $0.key, value: $0.value)
    }
    var request = URLRequest(url: url.url!)
    request.timeoutInterval = 30
    request.setValue("PlacesStudentApp/1.0 (macOS educational project)", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await session.data(for: request)
    try Task.checkCancellation()
    guard let response = response as? HTTPURLResponse else {
      throw APIError(message: "Нет HTTP-ответа.")
    }
    guard (200..<300).contains(response.statusCode) else {
      let hint = [401, 403].contains(response.statusCode) ? "Проверьте API-ключ и доступ к сервису." : response.statusCode == 429 ? "Превышен лимит запросов." : "Повторите позже."
      throw APIError(message: "\(url.host ?? "API"): HTTP \(response.statusCode). \(hint)")
    }
    if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let error = object["error"] as? [String: Any] {
      throw APIError(message: "Wikipedia: \(error["info"] as? String ?? "ошибка API")")
    }
    do { return try JSONDecoder().decode(T.self, from: data) } catch {
      throw APIError(message: "\(url.host ?? "API"): неожиданный формат ответа.")
    }
  }
}
