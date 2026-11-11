import Foundation
import ImageIO

struct PlacesService: PlacesServicing {
  let graphKey: String
  let weatherKey: String
  var session: URLSession = .shared
  var reportTimeout: Duration = .seconds(15)
  var imageTimeout: Duration = .seconds(3)
  var imageByteLimit = 2 * 1024 * 1024
  private var deadline: ContinuousClock.Instant?

  init(graphKey: String, weatherKey: String, session: URLSession = .shared) {
    self.graphKey = graphKey
    self.weatherKey = weatherKey
    self.session = session
  }

  //тз 1 метод
  func searchLocations(query: String) async throws -> [Location] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }
    guard !graphKey.isEmpty else {
      throw APIError(message: "Введите ключ GraphHopper в настройках.")
    }
    struct Response: Decodable {
      let hits: [Location]
      enum CodingKeys: String, CodingKey { case hits }

      init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var array = try container.nestedUnkeyedContainer(forKey: .hits)
        var locations: [Location] = []
        while !array.isAtEnd {
          let item = try array.superDecoder()
          if let location = try? Location(from: item) {
            locations.append(location)
          }
        }
        hits = locations
      }
    }
    let response: Response = try await request("https://graphhopper.com/api/1/geocode", ["q": query, "locale": "ru", "limit": "10", "key":graphKey])
    var ids = Set<String>()
    return response.hits.filter {
      (-90...90).contains($0.point.lat) && (-180...180).contains($0.point.lng)
        && ids.insert($0.id).inserted
    }
  }

  //тз 2 метод
  func loadDetails(for location: Location) async throws -> LocationDetails {
    var configured = self
    configured.deadline = ContinuousClock.now.advanced(by: reportTimeout)
    let worker = configured
    async let weather = worker.partial { try await worker.loadWeather(location) }
    async let places = worker.partial { try await worker.loadPlaces(location) }
    let (weatherResult, placesResult) = try await (weather, places)
    try Task.checkCancellation()
    return LocationDetails(location: location, weather: weatherResult.value, places: placesResult.value ?? [], weatherError: weatherResult.error, placesError: placesResult.error)
  }

  private func partial<T: Sendable>(_ operation: () async throws -> T) async throws -> (value: T?, error: String?) {
    do { return (try await operation(), nil) }
    catch {
      try Task.checkCancellation()
      if error is CancellationError { throw error }
      return (nil, error.localizedDescription)
    }
  }
    
  func loadArticle(id: Int) async throws -> String {
    struct Response: Decodable {
      struct Query: Decodable {
        struct Page: Decodable { let extract: String? }
        let pages: [Page]
      }
      let query: Query?
    }
    let response: Response = try await wiki([
      "prop": "extracts", "pageids": String(id), "explaintext": "1"
    ])
    guard let text = response.query?.pages.first?.extract?
      .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
      throw APIError(message: "Текст этой статьи недоступен.")
    }
    return text
  }

  private func loadWeather(_ location: Location) async throws -> Weather {
    guard !weatherKey.isEmpty else {
      throw APIError(message: "Введите ключ OpenWeather в настройках.")
    }
    return try await request("https://api.openweathermap.org/data/2.5/weather",[ "lat": String(location.point.lat), "lon": String(location.point.lng), "appid": weatherKey, "units": "metric", "lang": "ru",])
  }
  private struct Nearby: Decodable, Sendable {
    let pageid: Int
    let title: String
    let dist: Double
  }
  private func loadPlaces(_ location: Location) async throws -> [Place] {
    struct Response: Decodable {
      struct Query: Decodable {
        let geosearch: [Nearby]
        enum CodingKeys: String, CodingKey { case geosearch }
        init(from decoder: Decoder) throws {
          let container = try decoder.container(keyedBy: CodingKeys.self)
          var array = try container.nestedUnkeyedContainer(forKey: .geosearch)
          var places: [Nearby] = []
          while !array.isAtEnd {
            let item = try array.superDecoder()
            if let place = try? Nearby(from: item) {
              places.append(place)
            }
          }
          geosearch = places
        }
      }
      let query: Query
    }
    let response: Response = try await wiki(["list": "geosearch", "gscoord": "\(location.point.lat)|\(location.point.lng)","gsradius": "5000", "gslimit": "10", "gsnamespace": "0",])

    return try await withThrowingTaskGroup(of: Place.self) { group in
      var ids = Set<Int>()
      for nearby in response.query.geosearch {
        guard nearby.pageid > 0, ids.insert(nearby.pageid).inserted else { continue }
        group.addTask {
          do { return try await loadDescription(nearby) }
          catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            return Place(id: nearby.pageid, title: nearby.title, distance: nearby.dist,
                         description: "Не удалось загрузить описание: " + error.localizedDescription)
          }
        }
      }
      var places: [Place] = []
      for try await place in group { places.append(place) }
      return places.sorted { ($0.distance, $0.id) < ($1.distance, $1.id) }
    }
  }
  private func loadDescription(_ nearby: Nearby) async throws -> Place {
    struct Response: Decodable {
      struct Query: Decodable {
        struct Page: Decodable {
          struct Thumbnail: Decodable { let source: URL }
          let extract: String?
          let thumbnail: Thumbnail?
          let pageimage: String?
        }
        let pages: [Page]
      }
      let query: Query
    }
    let response: Response = try await wiki(["prop": "extracts|pageimages", "piprop": "thumbnail|name", "pithumbsize": "640", "pilicense": "free", "pageids": String(nearby.pageid), "exintro": "1", "explaintext": "1",])
    let description = response.query.pages.first?.extract?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let page = response.query.pages.first
    var imagePageURL: URL?
    if let name = page?.pageimage {
      var components = URLComponents(string: "https://ru.wikipedia.org/w/index.php")!
      components.queryItems = [URLQueryItem(name: "title", value: "File:" + name)]
      imagePageURL = components.url
    }
    return Place(id: nearby.pageid, title: nearby.title, distance: nearby.dist,
                 description: description.isEmpty ? "Краткого описания нет." : description,
                 imageURL: page?.thumbnail?.source, imagePageURL: imagePageURL)
  }
  func loadImage(_ url: URL?) async throws -> Data? {
    try Task.checkCancellation()
    guard let url, url.scheme == "https" else { return nil }
    let imageDeadline = min(deadline ?? .now.advanced(by: imageTimeout),
                            .now.advanced(by: imageTimeout))
    do {
      return try await withDeadline(imageDeadline) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.setValue("PlacesStudentApp/1.0 (macOS educational project)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              response.mimeType?.hasPrefix("image/") == true,
              response.expectedContentLength <= Int64(imageByteLimit) else { return nil }
        var data = Data()
        for try await byte in bytes {
          try Task.checkCancellation()
          guard data.count < imageByteLimit else { return nil }
          data.append(byte)
        }
        
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096,
              width * height <= 4_000_000 else { return nil }
        return data
      }
    } catch {
      try Task.checkCancellation()
      if error is CancellationError { throw error }
      return nil
    }
  }

  private func withDeadline<T: Sendable>(_ end: ContinuousClock.Instant?, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try Task.checkCancellation()
    guard let end else { return try await operation() }
    guard ContinuousClock.now < end else {
      throw APIError(message: "Время ожидания истекло.")
    }
    return try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await ContinuousClock().sleep(until: end)
        throw APIError(message: "Время ожидания истекло.")
      }
      defer { group.cancelAll() }
      return try await group.next()!
    }
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
    let preparedRequest = request
    let (data, response) = try await withDeadline(deadline) {
      try await session.data(for: preparedRequest)
    }
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
