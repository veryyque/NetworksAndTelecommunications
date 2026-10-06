import Foundation

final class TransferStatistics {
    private let client: String
    private let startTime = Date()
    private var lastPrintTime: Date
    private(set) var totalReceivedBytes: UInt64 = 0 //изменение доступно только внутри класса, чтение всем
    private var bytesSinceLastPrint: UInt64 = 0

    init(client: String) {
        self.client = client
        lastPrintTime = startTime
    }

    func add(_ count: Int) {
        totalReceivedBytes += UInt64(count)
        bytesSinceLastPrint += UInt64(count)
    }

    func printIfNeeded(force: Bool = false) {
        let now = Date()
        let interval = now.timeIntervalSince(lastPrintTime)
        guard force || interval >= 3 else { return }
        let intervalSeconds = max(interval, 0.000001)
        let totalSeconds = max(now.timeIntervalSince(startTime), 0.000001)
        let instant = Double(bytesSinceLastPrint) / intervalSeconds
        let average = Double(totalReceivedBytes) / totalSeconds
        print("Client \(client)\nInstant speed: \(String(format: "%.0f", instant)) bytes/s\nAverage speed: \(String(format: "%.0f", average)) bytes/s")
        lastPrintTime = now
        bytesSinceLastPrint = 0
    }
}
