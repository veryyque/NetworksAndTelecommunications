import Foundation

struct Location: Decodable, Identifiable, Sendable {
  struct Point: Decodable, Sendable {
    let lat: Double
    let lng: Double
  }
  let name: String?
  let city: String?
  let country: String?
  let point: Point
  let osmValue: String?

  enum CodingKeys: String, CodingKey {
    case name, city, country, point
    case osmValue = "osm_value"
  }

  private static let typeNames: [String: String] = [
    "bus_stop": "Автобусная остановка",
    "tram_stop": "Трамвайная остановка",
    "platform": "Остановочная платформа",
    "station": "Станция",
    "square": "Площадь",
    "bar": "Бар",
    "pub": "Паб",
    "cafe": "Кафе",
    "restaurant": "Ресторан",
    "fast_food": "Быстрое питание",
    "park": "Парк",
    "garden": "Сад",
    "museum": "Музей",
    "theatre": "Театр",
    "cinema": "Кинотеатр",
    "hotel": "Отель",
    "attraction": "Достопримечательность",
    "monument": "Монумент",
    "memorial": "Мемориал",
    "viewpoint": "Смотровая площадка",
    "mall": "Торговый центр",
    "supermarket": "Супермаркет",
    "school": "Школа",
    "university": "Университет",
    "hospital": "Больница",
    "pharmacy": "Аптека",
    "place_of_worship": "Религиозный объект",
    "city": "Город",
    "town": "Город",
    "village": "Село / деревня",
    "suburb": "Район",
    "neighbourhood": "Квартал / микрорайон",
    "pedestrian": "Пешеходная улица / зона",
    "footway": "Пешеходная дорожка",
    "steps": "Лестница",
    "residential": "Жилая улица / территория",
  ]

  var typeLabel: String {
    guard let osmValue, !osmValue.isEmpty else {
      return "Тип не указан"
    }
    return Self.typeNames[osmValue] ?? "Другой тип объекта"
  }

  var title: String { name ?? city ?? "Без названия" }
  var subtitle: String { [city, country].compactMap { $0 }.joined(separator: ", ") }
  var id: String { "\(title)|\(point.lat)|\(point.lng)" }
}
