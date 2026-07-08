import Foundation

public enum MemoryPressureLevel: String {
    case calm
    case warm
    case hot

    public var title: String {
        switch self {
        case .calm:
            return "Calm"
        case .warm:
            return "Elevated"
        case .hot:
            return "High"
        }
    }
}

public struct ProcessMemorySnapshot: Sendable {
    public let pid: Int
    public let name: String
    public let memory: UInt64
    public let cpu: Double

    public init(pid: Int, name: String, memory: UInt64, cpu: Double) {
        self.pid = pid
        self.name = name
        self.memory = memory
        self.cpu = cpu
    }
}

public struct ProcessSnapshot: Sendable {
    public let topMemoryProcesses: [ProcessMemorySnapshot]
    public let topCPUProcesses: [ProcessMemorySnapshot]

    public init(topMemoryProcesses: [ProcessMemorySnapshot], topCPUProcesses: [ProcessMemorySnapshot]) {
        self.topMemoryProcesses = topMemoryProcesses
        self.topCPUProcesses = topCPUProcesses
    }
}

public enum ProcessLimitMode: Equatable {
    case background
    case throttle(Double)

    public var title: String {
        switch self {
        case .background:
            return "Background Priority"
        case .throttle(let allowedCPU):
            return "Throttle to \(Int((allowedCPU * 100).rounded()))%"
        }
    }
}

public struct LimitedProcess {
    public let pid: Int
    public let name: String
    public var mode: ProcessLimitMode
    public var modeStartedAt: Date
    public var isRunning: Bool
    public var hasBackgroundPolicy: Bool

    public init(
        pid: Int,
        name: String,
        mode: ProcessLimitMode,
        modeStartedAt: Date,
        isRunning: Bool,
        hasBackgroundPolicy: Bool
    ) {
        self.pid = pid
        self.name = name
        self.mode = mode
        self.modeStartedAt = modeStartedAt
        self.isRunning = isRunning
        self.hasBackgroundPolicy = hasBackgroundPolicy
    }
}

public struct SwapSnapshot {
    public let total: UInt64
    public let used: UInt64
    public let available: UInt64

    public init(total: UInt64, used: UInt64, available: UInt64) {
        self.total = total
        self.used = used
        self.available = available
    }
}

public struct MemoryActivityRates {
    public let pageOutBytesPerSecond: Double
    public let swapInBytesPerSecond: Double
    public let swapOutBytesPerSecond: Double

    public init(pageOutBytesPerSecond: Double, swapInBytesPerSecond: Double, swapOutBytesPerSecond: Double) {
        self.pageOutBytesPerSecond = pageOutBytesPerSecond
        self.swapInBytesPerSecond = swapInBytesPerSecond
        self.swapOutBytesPerSecond = swapOutBytesPerSecond
    }

    public var swapTrafficBytesPerSecond: Double {
        swapInBytesPerSecond + swapOutBytesPerSecond
    }
}

public struct MemorySnapshot {
    public let capturedAt: Date
    public let pageSize: UInt64
    public let total: UInt64
    public let free: UInt64
    public let active: UInt64
    public let inactive: UInt64
    public let wired: UInt64
    public let compressed: UInt64
    public let purgeable: UInt64
    public let speculative: UInt64
    public let fileBacked: UInt64
    public let anonymous: UInt64
    public let pageOuts: UInt64
    public let swapIns: UInt64
    public let swapOuts: UInt64
    public let swap: SwapSnapshot?
    public let activityRates: MemoryActivityRates?
    public let systemPressureLevel: MemoryPressureLevel

    public init(
        capturedAt: Date,
        pageSize: UInt64,
        total: UInt64,
        free: UInt64,
        active: UInt64,
        inactive: UInt64,
        wired: UInt64,
        compressed: UInt64,
        purgeable: UInt64,
        speculative: UInt64,
        fileBacked: UInt64,
        anonymous: UInt64,
        pageOuts: UInt64,
        swapIns: UInt64,
        swapOuts: UInt64,
        swap: SwapSnapshot?,
        activityRates: MemoryActivityRates?,
        systemPressureLevel: MemoryPressureLevel
    ) {
        self.capturedAt = capturedAt
        self.pageSize = pageSize
        self.total = total
        self.free = free
        self.active = active
        self.inactive = inactive
        self.wired = wired
        self.compressed = compressed
        self.purgeable = purgeable
        self.speculative = speculative
        self.fileBacked = fileBacked
        self.anonymous = anonymous
        self.pageOuts = pageOuts
        self.swapIns = swapIns
        self.swapOuts = swapOuts
        self.swap = swap
        self.activityRates = activityRates
        self.systemPressureLevel = systemPressureLevel
    }

    public var appMemory: UInt64 {
        let protectedMemory = wired + compressed
        return used > protectedMemory ? used - protectedMemory : 0
    }

    public var cache: UInt64 {
        purgeable + fileBacked
    }

    public var used: UInt64 {
        let rawUsed = active + inactive + speculative + wired + compressed
        let reclaimable = purgeable + fileBacked
        return rawUsed > reclaimable ? min(total, rawUsed - reclaimable) : 0
    }

    public var available: UInt64 {
        total > used ? total - used : 0
    }

    public var usageRatio: Double {
        guard total > 0 else {
            return 0
        }

        return min(1, max(0, Double(used) / Double(total)))
    }

    public var pressureLevel: MemoryPressureLevel {
        systemPressureLevel
    }

    public func withActivityRates(comparedTo previous: MemorySnapshot?) -> MemorySnapshot {
        guard let previous else {
            return self
        }

        let elapsed = capturedAt.timeIntervalSince(previous.capturedAt)
        guard elapsed > 0 else {
            return self
        }

        let rates = MemoryActivityRates(
            pageOutBytesPerSecond: bytesPerSecond(delta(from: previous.pageOuts, to: pageOuts), elapsed: elapsed),
            swapInBytesPerSecond: bytesPerSecond(delta(from: previous.swapIns, to: swapIns), elapsed: elapsed),
            swapOutBytesPerSecond: bytesPerSecond(delta(from: previous.swapOuts, to: swapOuts), elapsed: elapsed)
        )

        return MemorySnapshot(
            capturedAt: capturedAt,
            pageSize: pageSize,
            total: total,
            free: free,
            active: active,
            inactive: inactive,
            wired: wired,
            compressed: compressed,
            purgeable: purgeable,
            speculative: speculative,
            fileBacked: fileBacked,
            anonymous: anonymous,
            pageOuts: pageOuts,
            swapIns: swapIns,
            swapOuts: swapOuts,
            swap: swap,
            activityRates: rates,
            systemPressureLevel: systemPressureLevel
        )
    }

    private func delta(from previous: UInt64, to current: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }

    private func bytesPerSecond(_ pageDelta: UInt64, elapsed: TimeInterval) -> Double {
        Double(pageDelta * pageSize) / elapsed
    }
}
