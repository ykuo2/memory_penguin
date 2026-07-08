import Foundation

@MainActor
public enum ByteFormatter {
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .memory
        formatter.includesActualByteCount = false
        formatter.isAdaptive = true
        return formatter
    }()

    public static func string(_ bytes: UInt64) -> String {
        formatter.string(fromByteCount: Int64(bytes))
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        let rounded = max(0, Int64(bytesPerSecond.rounded()))
        return "\(formatter.string(fromByteCount: rounded))/s"
    }

    public static func percent(_ value: Double) -> String {
        if value >= 100 {
            return String(format: "%.0f%%", value)
        }
        return String(format: "%.1f%%", value)
    }
}
