import Foundation
import Darwin

enum TransferDashboard {
    private struct Row {
        let file: String
        let status: String
        let progress: Double
        let current: Double
        let average: Double
    }
    private static let lock = NSLock()
    private static var rows: [Int: Row] = [:]

    private static func column(_ value: String, _ width: Int) -> String {
        let safe = String(value.unicodeScalars.map { scalar -> Character in
            if scalar.value < 32 || scalar.value == 127 { return " " }
            // Keep terminal column widths predictable (ASCII and Cyrillic).
            if scalar.value > 126 && !(0x0400...0x04FF).contains(scalar.value) { return "?" }
            return Character(String(scalar))
        })
        let clipped = safe.count > width ? String(safe.prefix(width - 1)) + "~" : safe
        return clipped + String(repeating: " ", count: max(0, width - clipped.count))
    }

    static func update(number: Int, client: String, file: String, status: String,
                       received: UInt64, size: UInt64, current: Double, average: Double) {
        guard TransferLog.isTerminal else {
            TransferLog.write("[\(client)] \(status) | file=\(file.debugDescription) | received=\(received)/\(size) B | current=\(String(format: "%.3f", current)) MB/s | average=\(String(format: "%.3f", average)) MB/s")
            return
        }
        lock.lock()
        defer { lock.unlock() }
        let progress = size > 0 ? Double(received) / Double(size) * 100 : (status == "SAVED" ? 100 : 0)
        rows[number] = Row(file: file, status: status, progress: progress, current: current, average: average)
        // Retain recent completed rows without keeping unlimited history in memory.
        for id in rows.keys.sorted() where rows.count > 200 {
            if let row = rows[id], row.status == "SAVED" || row.status == "FAILED" { rows.removeValue(forKey: id) }
        }
        var terminal = winsize()
        _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &terminal)
        let width = terminal.ws_col > 0 ? Int(terminal.ws_col) - 1 : 79
        let capacity = max(1, (terminal.ws_row > 0 ? Int(terminal.ws_row) : 24) - 6)
        let ids = Array(rows.keys.sorted().suffix(capacity))
        let fileWidth = max(5, min(30, width - 55))
        var lines = ["TCP transfers | speed: MB/s | updated every 3 s",
                     column("Клиент", 10) + column("Статус", 11) + column("Файл", fileWidth) + column("%", 7) + column("Текущая", 12) + "Средняя"]
        for id in ids {
            let row = rows[id]!
            lines.append(column("клиент \(id)", 10) + column(row.status, 11) + column(row.file, fileWidth)
                + column(String(format: "%.1f", row.progress), 7)
                + column(String(format: "%.3f", row.current), 12) + String(format: "%.3f", row.average))
        }
        if ids.count < rows.count { lines.append("Показаны последние \(ids.count) из \(rows.count) записей.") }
        TransferLog.render(lines.map { String($0.prefix(max(1, width))) })
    }
}

final class TransferStatistics {
    private let client: String
    private let number: Int
    private let file: String
    private let fileSize: UInt64
    private let startTime = ProcessInfo.processInfo.systemUptime
    private var lastPrintTime: TimeInterval
    private(set) var totalReceivedBytes: UInt64 = 0 //изменение доступно только внутри класса, чтение всем
    private var bytesSinceLastPrint: UInt64 = 0

    init(number: Int, client: String, file: String, fileSize: UInt64) {
        self.number = number
        self.client = client
        self.file = file
        self.fileSize = fileSize
        lastPrintTime = startTime
    }

    func add(_ count: Int) {
        totalReceivedBytes += UInt64(count)
        bytesSinceLastPrint += UInt64(count)
    }

    func printIfNeeded(force: Bool = false, status: String = "RECEIVING") {
        let now = ProcessInfo.processInfo.systemUptime
        let interval = now - lastPrintTime
        guard force || interval >= 3 else { return }
        let intervalSeconds = max(interval, 0.000001)
        let totalSeconds = max(now - startTime, 0.000001)
        let instant = Double(bytesSinceLastPrint) / intervalSeconds / 1_000_000
        let average = Double(totalReceivedBytes) / totalSeconds / 1_000_000
        TransferDashboard.update(number: number, client: client, file: file, status: status,
                                 received: totalReceivedBytes, size: fileSize, current: instant, average: average)
        lastPrintTime = now
        bytesSinceLastPrint = 0
    }
}
