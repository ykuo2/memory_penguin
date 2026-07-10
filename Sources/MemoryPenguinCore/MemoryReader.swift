import Darwin
import Foundation

public enum MemoryReader {
    public static func current() throws -> MemorySnapshot {
        var pageSize: vm_size_t = 0
        let pageResult = host_page_size(mach_host_self(), &pageSize)
        guard pageResult == KERN_SUCCESS else {
            throw NSError(
                domain: "MemoryPenguin",
                code: Int(pageResult),
                userInfo: [NSLocalizedDescriptionKey: "Unable to read host page size."]
            )
        }

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let statsResult = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
            }
        }
        guard statsResult == KERN_SUCCESS else {
            throw NSError(
                domain: "MemoryPenguin",
                code: Int(statsResult),
                userInfo: [NSLocalizedDescriptionKey: "Unable to read VM statistics."]
            )
        }

        let multiplier = UInt64(pageSize)
        return MemorySnapshot(
            capturedAt: Date(),
            pageSize: multiplier,
            total: try readTotalPhysicalMemory(),
            free: UInt64(stats.free_count) * multiplier,
            active: UInt64(stats.active_count) * multiplier,
            inactive: UInt64(stats.inactive_count) * multiplier,
            wired: UInt64(stats.wire_count) * multiplier,
            compressed: UInt64(stats.compressor_page_count) * multiplier,
            purgeable: UInt64(stats.purgeable_count) * multiplier,
            speculative: UInt64(stats.speculative_count) * multiplier,
            fileBacked: UInt64(stats.external_page_count) * multiplier,
            anonymous: UInt64(stats.internal_page_count) * multiplier,
            pageOuts: stats.pageouts,
            swapIns: stats.swapins,
            swapOuts: stats.swapouts,
            swap: readSwapUsage(),
            activityRates: nil,
            systemPressureLevel: readSystemPressureLevel()
        )
    }

    private static func readTotalPhysicalMemory() throws -> UInt64 {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        let result = sysctlbyname("hw.memsize", &total, &size, nil, 0)
        guard result == 0, total > 0 else {
            throw NSError(
                domain: "MemoryPenguin",
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Unable to read total physical memory."]
            )
        }
        return total
    }

    private static func readSwapUsage() -> SwapSnapshot? {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let result = sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        guard result == 0 else {
            return nil
        }

        return SwapSnapshot(total: swap.xsu_total, used: swap.xsu_used, available: swap.xsu_avail)
    }

    private static func readSystemPressureLevel() -> MemoryPressureLevel {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        guard result == 0 else {
            return .calm
        }

        return pressureLevel(fromVMPressureLevel: level)
    }

    package static func pressureLevel(fromVMPressureLevel level: Int32) -> MemoryPressureLevel {
        switch level {
        case 2:
            return .warm
        case 4:
            return .hot
        default:
            return .calm
        }
    }
}
