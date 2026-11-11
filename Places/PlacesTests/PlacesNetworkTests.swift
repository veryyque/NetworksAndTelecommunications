import XCTest
@testable import Places
import Foundation
import CoreGraphics
import ImageIO

final class MockProtocol: URLProtocol {
  static var mode = "normal"
  static var requestedIDs: [String] = []
  static let lock = NSLock()
  static var imageRequests = 0
  static var imageStopped = false
  static var image = Data()
  static func png(width: Int, height: Int) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
    return output as Data
  }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {
    Self.lock.lock()
    if request.url?.host == "images.example" { Self.imageStopped = true }
    Self.lock.unlock()
  }
  override func startLoading() {
    let url = request.url!
    let params = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    var status = 200
    var body = "{}"
    if url.host == "graphhopper.com" {
      if Self.mode == "badJSON" { body = "not json" }
      else { body = #"{"hits":[{"name":"OK","point":{"lat":55,"lng":83}},null,{"point":{"lat":"bad","lng":83}},{"point":{"lat":999,"lng":83}},{"name":"OK2","point":{"lat":56,"lng":84}}]}"# }
    } else if url.host == "api.openweathermap.org" {
      if Self.mode == "weatherHang" { return }
      if Self.mode == "weatherError" || Self.mode == "bothError" { status = 401 }
      body = #"{"main":{"temp":1,"feels_like":0,"humidity":50,"pressure":1000},"wind":{"speed":2},"weather":[{"description":"ясно"}]}"#
    } else if params["list"] == "geosearch" {
      if Self.mode == "placesError" || Self.mode == "bothError" { status = 500 }
      body = #"{"query":{"geosearch":[{"pageid":1,"title":"One","dist":10},{"pageid":2,"title":"Two","dist":20},{"pageid":-1,"title":"Bad","dist":1},{"pageid":1,"title":"Duplicate","dist":10},{"pageid":"bad"}]}}"#
    } else if let id = params["pageids"] {
      Self.lock.lock()
      Self.requestedIDs.append(id)
      Self.lock.unlock()
      if id == "2" && Self.mode != "success" && Self.mode != "pixels" {
        if Self.mode == "descriptionHang" { return }
        status = 500
      }
      body = #"{"query":{"pages":[{"extract":"Description","thumbnail":{"source":"https://images.example/photo"}}]}}"#
    } else if url.host == "images.example" {
      Self.lock.lock()
      Self.imageRequests += 1
      Self.lock.unlock()
      if Self.mode == "imageHang" { return }
      let headers = Self.mode == "oversize" ? ["Content-Type":"image/png", "Content-Length":"99999999"] : ["Content-Type":"image/png"]
      client?.urlProtocol(self, didReceive: HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:headers)!, cacheStoragePolicy:.notAllowed)
      client?.urlProtocol(self, didLoad: Self.mode == "streamOversize" ? Self.image + Data(repeating: 0, count: 2048) : Self.image)
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url:url,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!, cacheStoragePolicy:.notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
}


final class PlacesNetworkTests: XCTestCase {
  func testSuccessfulReport() async throws { try await checkReport("success") }
  func testDescriptionFailureKeepsOtherPlaces() async throws { try await checkReport("normal") }
  func testWeatherFailureKeepsPlaces() async throws { try await checkReport("weatherError") }
  func testPlacesFailureKeepsWeather() async throws { try await checkReport("placesError") }
  func testBothFailuresReturnReport() async throws { try await checkReport("bothError") }
  func testWeatherDeadline() async throws { try await checkReport("weatherHang") }
  func testDescriptionDeadline() async throws { try await checkReport("descriptionHang") }
  func testImageDeadline() async throws { try await checkReport("imageHang") }
  func testImageContentLengthLimit() async throws { try await checkReport("oversize") }
  func testImageStreamingLimit() async throws { try await checkReport("streamOversize") }
  func testImagePixelLimit() async throws { try await checkReport("pixels") }
  private func checkReport(_ mode: String) async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    var service = PlacesService(graphKey: "test", weatherKey: "test", session: session)
    MockProtocol.mode = "normal"
    MockProtocol.image = MockProtocol.png(width: 2, height: 2)
    service.reportTimeout = .milliseconds(250)
    service.imageTimeout = .milliseconds(50)
    service.imageByteLimit = 1024
    let locations = try await service.searchLocations(query: "test")
      MockProtocol.mode = mode
      MockProtocol.requestedIDs = []
      MockProtocol.imageStopped = false
      MockProtocol.imageRequests = 0
      MockProtocol.image = MockProtocol.png(width: mode == "pixels" ? 4097 : 2, height: 2)
      let start = ContinuousClock.now
      let result = try await service.loadDetails(for:locations[0])
      XCTAssertTrue(start.duration(to:.now) < .seconds(2))
      if mode == "placesError" || mode == "bothError" {
        XCTAssertTrue(result.places.isEmpty && result.placesError != nil)
        if mode == "placesError" { XCTAssertTrue(result.weather != nil) }
      } else {
        XCTAssertTrue(result.places.count == 2)
        XCTAssertTrue(result.places[0].description == "Description")
        XCTAssertEqual(result.places[0].imageURL?.host, "images.example")
        XCTAssertEqual(MockProtocol.imageRequests, 0, "Отчёт не должен скачивать фотографии")
        if mode == "success" || mode == "pixels" {
          XCTAssertTrue(result.places[1].description == "Description")
        } else {
          XCTAssertTrue(result.places[1].description.contains("Не удалось"))
        }
        XCTAssertTrue(MockProtocol.requestedIDs.sorted() == ["1","2"])
      }
      if mode == "weatherError" || mode == "weatherHang" || mode == "bothError" {
        XCTAssertTrue(result.weather == nil && result.weatherError != nil)
      }
      if ["imageHang", "oversize", "streamOversize", "pixels", "success"].contains(mode) {
        let data = try await service.loadImage(result.places[0].imageURL)
        if mode == "success" {
          XCTAssertEqual(data, MockProtocol.image)
        } else {
          XCTAssertNil(data)
        }
        if mode == "imageHang" {
          let stopDeadline = ContinuousClock.now.advanced(by: .seconds(1))
          while !MockProtocol.imageStopped && ContinuousClock.now < stopDeadline {
            try await Task.sleep(for: .milliseconds(5))
          }
          XCTAssertTrue(MockProtocol.imageStopped)
        }
      }
      if mode == "weatherHang" || mode == "descriptionHang" {
        XCTAssertTrue(start.duration(to: .now) >= .milliseconds(200))
      }
      print("PASS: \(mode)")
  }
  func testImageCancellationStopsDownload() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let service = PlacesService(graphKey: "", weatherKey: "", session: session)
    MockProtocol.mode = "imageHang"
    MockProtocol.imageRequests = 0
    MockProtocol.imageStopped = false
    let task = Task { try await service.loadImage(URL(string: "https://images.example/photo")) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while MockProtocol.imageRequests == 0 && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(MockProtocol.imageRequests, 1)
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Отмена должна прервать загрузку фото")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    let stopDeadline = ContinuousClock.now.advanced(by: .seconds(1))
    while !MockProtocol.imageStopped && ContinuousClock.now < stopDeadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(MockProtocol.imageStopped)
  }

  func testDamagedLocationsAreSkipped() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    var service = PlacesService(graphKey: "test", weatherKey: "test", session: session)
    MockProtocol.mode = "normal"
    MockProtocol.image = MockProtocol.png(width: 2, height: 2)
    service.reportTimeout = .milliseconds(250)
    service.imageTimeout = .milliseconds(50)
    service.imageByteLimit = 1024
    let locations = try await service.searchLocations(query: "test")
    XCTAssertEqual(locations.map(\.title), ["OK", "OK2"])
  }
  func testInvalidWholeJSONThrows() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    var service = PlacesService(graphKey: "test", weatherKey: "test", session: session)
    MockProtocol.mode = "normal"
    MockProtocol.image = MockProtocol.png(width: 2, height: 2)
    service.reportTimeout = .milliseconds(250)
    service.imageTimeout = .milliseconds(50)
    service.imageByteLimit = 1024
    MockProtocol.mode = "badJSON"
    do {
      _ = try await service.searchLocations(query: "test")
      XCTFail("Expected decoding error")
    } catch { }
  }
  func testCancellationPropagates() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    var service = PlacesService(graphKey: "test", weatherKey: "test", session: session)
    MockProtocol.mode = "normal"
    MockProtocol.image = MockProtocol.png(width: 2, height: 2)
    service.reportTimeout = .milliseconds(250)
    service.imageTimeout = .milliseconds(50)
    service.imageByteLimit = 1024
    let locations = try await service.searchLocations(query: "test")
    MockProtocol.mode = "weatherHang"
    let task = Task { try await service.loadDetails(for:locations[0]) }
    try await Task.sleep(for:.milliseconds(20))
    task.cancel()
    do { _ = try await task.value; XCTFail("Cancellation swallowed") }
    catch is CancellationError { print("PASS: cancellation propagated") }
  }
  @MainActor func testErrorsAreSeparatedInViewModel() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    var service = PlacesService(graphKey: "test", weatherKey: "test", session: session)
    MockProtocol.mode = "normal"
    MockProtocol.image = MockProtocol.png(width: 2, height: 2)
    service.reportTimeout = .milliseconds(250)
    service.imageTimeout = .milliseconds(50)
    service.imageByteLimit = 1024
    let locations = try await service.searchLocations(query: "test")
    try await checkViewModel(location: locations[0])
  }
  func testDefaultLimits() {
    let service = PlacesService(graphKey: "", weatherKey: "")
    XCTAssertEqual(service.reportTimeout, .seconds(15))
    XCTAssertEqual(service.imageTimeout, .seconds(3))
    XCTAssertEqual(service.imageByteLimit, 2 * 1024 * 1024)
  }
}
private struct FailingService: PlacesServicing {
  func searchLocations(query: String) async throws -> [Location] {
    throw APIError(message: "Ошибка поиска")
  }
  func loadDetails(for location: Location) async throws -> LocationDetails {
    throw APIError(message: "Ошибка подробностей")
  }
  func loadArticle(id: Int) async throws -> String { "" }
}

@MainActor
private func checkViewModel(location: Location) async throws {
  let model = PlacesViewModel { FailingService() }
  model.query = "test"
  model.search()
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while model.searching && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(5))
  }
  XCTAssertTrue(!model.searching)
  XCTAssertTrue(model.searchError == "Ошибка поиска" && model.detailsError == nil)
  print("PASS: search error is separate from details")
  model.select(location)
  while model.loading && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(5))
  }
  XCTAssertTrue(!model.loading)
  XCTAssertTrue(model.detailsError == "Ошибка подробностей" && model.searchError == nil)
  print("PASS: details error is separate; old search error cleared")
}
