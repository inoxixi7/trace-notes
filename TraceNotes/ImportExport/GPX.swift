import Foundation

/// F9 · GPX 1.1 export (D53 ②): one track per local day, a new track segment after each silence
/// longer than the gap interval. Accuracy, time zone, speed and course go into Trace Notes'
/// extension elements, so importing the file again keeps them.
nonisolated enum GPXWriter {
  /// The namespace of Trace Notes' extension elements.
  static let namespace = "urn:tracenotes:gpx:1"

  /// `points` must be oldest first.
  static func document(of points: [RawPoint], gapInterval: TimeInterval, creator: String = "Trace Notes") -> Data {
    var xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <gpx version="1.1" creator="\(escaped(creator))" xmlns="http://www.topografix.com/GPX/1/1" \
      xmlns:tn="\(namespace)">

      """
    var day: LocalDay?
    var previous: RawPoint?
    for point in points {
      let pointDay = LocalDay(point.timestamp, timeZoneID: point.timeZoneID)
      if pointDay != day {
        if day != nil { xml += "    </trkseg>\n  </trk>\n" }
        xml += "  <trk>\n    <name>\(pointDay)</name>\n    <trkseg>\n"
        day = pointDay
      } else if let previous, point.timestamp.timeIntervalSince(previous.timestamp) > gapInterval {
        xml += "    </trkseg>\n    <trkseg>\n"
      }
      xml += trackPoint(point)
      previous = point
    }
    if day != nil { xml += "    </trkseg>\n  </trk>\n" }
    xml += "</gpx>\n"
    return Data(xml.utf8)
  }

  private static func trackPoint(_ point: RawPoint) -> String {
    var element = "      <trkpt lat=\"\(decimal(point.latitude, places: 7))\" lon=\"\(decimal(point.longitude, places: 7))\">"
    if let altitude = point.altitude { element += "<ele>\(decimal(altitude, places: 1))</ele>" }
    element += "<time>\(point.timestamp.formatted(timeStyle))</time><extensions>"
    element += "<tn:accuracy>\(decimal(point.horizontalAccuracy, places: 1))</tn:accuracy>"
    element += "<tn:timeZone>\(escaped(point.timeZoneID))</tn:timeZone>"
    if let speed = point.speed, speed >= 0 { element += "<tn:speed>\(decimal(speed, places: 2))</tn:speed>" }
    if let course = point.course, course >= 0 { element += "<tn:course>\(decimal(course, places: 1))</tn:course>" }
    return element + "</extensions></trkpt>\n"
  }

  /// UTC with milliseconds, which is how points are stored.
  static let timeStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  /// Always with a full stop, whatever the user's locale.
  private static func decimal(_ value: Double, places: Int) -> String {
    String(format: "%.\(places)f", locale: Locale(identifier: "en_US_POSIX"), value)
  }

  private static func escaped(_ text: String) -> String {
    text.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;")
      .replacing("\"", with: "&quot;")
  }
}

/// F9 · GPX import: the points of every track (`trkpt`) and route (`rtept`); waypoints are ignored.
/// A point needs a position and a time to be placed on the timeline; points without either are
/// counted and skipped.
nonisolated enum GPXReader {
  struct Result: Sendable {
    var points: [RawPoint]
    /// Track and route points without a valid position or time.
    var skipped: Int
  }

  enum Failure: Error, Equatable {
    /// Not XML, or not a GPX file.
    case notGPX
    /// A GPX file without track or route points.
    case noPoints
    /// Track or route points, but none with both a valid position and a time.
    case noUsablePoints
  }

  /// `timeZoneID` is used for points the file does not give a zone for. Points without an
  /// accuracy get 0, i.e. they are taken as exact, as GPX has no accuracy of its own.
  static func read(_ data: Data, timeZoneID: String) throws(Failure) -> Result {
    let delegate = Delegate()
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true
    parser.delegate = delegate
    guard parser.parse(), delegate.isGPX else { throw .notGPX }
    guard delegate.found > 0 else { throw .noPoints }
    let points = delegate.points.compactMap { parsed -> RawPoint? in
      guard let time = parsed.time else { return nil }
      let zone = parsed.timeZoneID.flatMap { TimeZone(identifier: $0) != nil ? $0 : nil } ?? timeZoneID
      return RawPoint(
        id: nil, timestamp: time, latitude: parsed.latitude, longitude: parsed.longitude,
        horizontalAccuracy: parsed.accuracy ?? 0, altitude: parsed.altitude, verticalAccuracy: nil, speed: parsed.speed,
        course: parsed.course, timeZoneID: zone, source: .gpxImport, importBatchID: nil, flags: [])
    }
    guard !points.isEmpty else { throw .noUsablePoints }
    return Result(points: points.sorted { $0.timestamp < $1.timestamp }, skipped: delegate.found - points.count)
  }

  private struct Parsed {
    var latitude: Double
    var longitude: Double
    var time: Date?
    var altitude: Double?
    var accuracy: Double?
    var timeZoneID: String?
    var speed: Double?
    var course: Double?
  }

  private final class Delegate: NSObject, XMLParserDelegate {
    var isGPX = false
    /// Track and route points seen, valid or not.
    var found = 0
    var points: [Parsed] = []
    private var current: Parsed?
    private var text = ""
    private var depth = 0
    private let fractional = ISO8601DateFormatter.with([.withInternetDateTime, .withFractionalSeconds])
    private let whole = ISO8601DateFormatter.with([.withInternetDateTime])

    func parser(
      _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
      attributes: [String: String] = [:]
    ) {
      depth += 1
      if depth == 1 { isGPX = name == "gpx" }
      text = ""
      guard name == "trkpt" || name == "rtept" else { return }
      found += 1
      if let latitude = attributes["lat"].flatMap(Double.init), let longitude = attributes["lon"].flatMap(Double.init),
        (-90...90).contains(latitude), (-180...180).contains(longitude)
      {
        current = Parsed(latitude: latitude, longitude: longitude)
      }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
      text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
      depth -= 1
      let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
      text = ""
      guard current != nil else { return }
      let ours = namespaceURI == GPXWriter.namespace
      switch name {
      case "trkpt", "rtept":
        if let current { points.append(current) }
        current = nil
      case "time" where !ours:
        current?.time = fractional.date(from: value) ?? whole.date(from: value)
      case "ele" where !ours:
        current?.altitude = Double(value)
      case "accuracy" where ours:
        current?.accuracy = Double(value).flatMap { $0 >= 0 ? $0 : nil }
      case "timeZone" where ours:
        current?.timeZoneID = value
      case "speed" where ours:
        current?.speed = Double(value)
      case "course" where ours:
        current?.course = Double(value)
      default:
        break
      }
    }
  }
}

nonisolated extension ISO8601DateFormatter {
  fileprivate static func with(_ options: ISO8601DateFormatter.Options) -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = options
    return formatter
  }
}
