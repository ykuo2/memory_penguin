import Darwin
import Foundation
import MemoryPenguinCore

private struct TestCase {
    let name: String
    let run: () throws -> Void
}

private struct TestFailure: Error, CustomStringConvertible {
    let message: String
    let file: StaticString
    let line: UInt

    var description: String {
        "\(file):\(line): \(message)"
    }
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard condition() else {
        throw TestFailure(message: message, file: file, line: line)
    }
}

private func require<T>(
    _ value: T?,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    guard let value else {
        throw TestFailure(message: message, file: file, line: line)
    }
    return value
}

private let tests: [TestCase] = [
    TestCase(name: "effective used memory subtracts normalized reclaimable memory") {
        let snapshot = makeSnapshot(
            total: 1_000,
            free: 100,
            active: 400,
            inactive: 300,
            wired: 200,
            compressed: 100,
            purgeable: 150,
            speculative: 100,
            fileBacked: 300,
            anonymous: 600
        )

        try expect(snapshot.physicalOccupied == 900, "expected occupied memory to be total minus free memory")
        try expect(snapshot.used == snapshot.physicalOccupied, "expected used compatibility alias")
        try expect(snapshot.available == 100, "expected available memory to equal capped kernel free memory")
        try expect(snapshot.appMemory == 600, "expected bounded anonymous memory estimate")
        try expect(snapshot.cache == 300, "expected bounded file-backed memory estimate")
        try expect(snapshot.nonFreeFileBackedEstimate == 200, "expected speculative pages to be removed from file-backed estimate")
        try expect(snapshot.reclaimableEstimate == 350, "expected reclaimable file-backed and purgeable memory")
        try expect(snapshot.effectiveUsedEstimate == 550, "expected physical occupied memory to exclude reclaimable estimate")
        try expect(abs(snapshot.physicalUsageRatio - 0.9) < 0.0001, "expected physical usage ratio to be 0.9")
        try expect(abs(snapshot.effectiveUsageRatio - 0.55) < 0.0001, "expected effective usage ratio to be 0.55")
        try expect(abs(snapshot.usageRatio - 0.9) < 0.0001, "expected usage ratio to be 0.9")
    },
    TestCase(name: "effective used memory floors file-backed estimate after speculative removal") {
        let snapshot = makeSnapshot(
            total: 1_000,
            free: 100,
            purgeable: 150,
            speculative: 500,
            fileBacked: 200
        )

        try expect(snapshot.nonFreeFileBackedEstimate == 0, "expected speculative subtraction to floor at zero")
        try expect(snapshot.reclaimableEstimate == 150, "expected only purgeable memory to remain reclaimable")
        try expect(snapshot.effectiveUsedEstimate == 750, "expected effective used memory after conservative reclaimable estimate")
        try expect(abs(snapshot.effectiveUsageRatio - 0.75) < 0.0001, "expected effective usage ratio to be 0.75")
    },
    TestCase(name: "reclaimable estimate handles overflow and caps at physical occupied memory") {
        let snapshot = makeSnapshot(
            total: 1_000,
            free: 100,
            purgeable: 1,
            fileBacked: UInt64.max
        )

        try expect(snapshot.reclaimableEstimate == 900, "expected reclaimable estimate to cap at occupied memory")
        try expect(snapshot.effectiveUsedEstimate == 0, "expected effective used memory to floor at zero")
        try expect(snapshot.effectiveUsageRatio == 0, "expected effective usage ratio to floor at zero")
    },
    TestCase(name: "kernel free memory is capped at total memory") {
        let snapshot = makeSnapshot(
            total: 1_000,
            free: 1_200,
            active: 800
        )

        try expect(snapshot.used == 0, "expected occupied memory to floor at zero")
        try expect(snapshot.available == 1_000, "expected free memory to cap at total memory")
        try expect(snapshot.physicalUsageRatio == 0, "expected physical usage ratio to floor at zero")
        try expect(snapshot.effectiveUsageRatio == 0, "expected effective usage ratio to floor at zero")
        try expect(snapshot.usageRatio == 0, "expected usage ratio to floor at zero")
    },
    TestCase(name: "usage ratio is zero when total memory is zero") {
        let snapshot = makeSnapshot(total: 0, active: 100)

        try expect(snapshot.used == 0, "expected used memory to be zero")
        try expect(snapshot.available == 0, "expected available memory to be zero")
        try expect(snapshot.physicalUsageRatio == 0, "expected physical usage ratio to be zero")
        try expect(snapshot.effectiveUsageRatio == 0, "expected effective usage ratio to be zero")
        try expect(snapshot.usageRatio == 0, "expected usage ratio to be zero")
    },
    TestCase(name: "activity rates use page deltas over elapsed time") {
        let previous = makeSnapshot(
            capturedAt: Date(timeIntervalSince1970: 10),
            pageSize: 4_096,
            pageOuts: 10,
            swapIns: 5,
            swapOuts: 7
        )
        let current = makeSnapshot(
            capturedAt: Date(timeIntervalSince1970: 12),
            pageSize: 4_096,
            pageOuts: 14,
            swapIns: 9,
            swapOuts: 8
        )

        let rates = try require(
            current.withActivityRates(comparedTo: previous).activityRates,
            "expected activity rates to be calculated"
        )
        try expect(abs(rates.pageOutBytesPerSecond - 8_192) < 0.001, "expected page-out rate")
        try expect(abs(rates.swapInBytesPerSecond - 8_192) < 0.001, "expected swap-in rate")
        try expect(abs(rates.swapOutBytesPerSecond - 2_048) < 0.001, "expected swap-out rate")
        try expect(abs(rates.swapTrafficBytesPerSecond - 10_240) < 0.001, "expected swap traffic rate")
    },
    TestCase(name: "activity rates treat counter reset as no delta") {
        let previous = makeSnapshot(
            capturedAt: Date(timeIntervalSince1970: 10),
            pageSize: 4_096,
            pageOuts: 20,
            swapIns: 20,
            swapOuts: 20
        )
        let current = makeSnapshot(
            capturedAt: Date(timeIntervalSince1970: 12),
            pageSize: 4_096,
            pageOuts: 10,
            swapIns: 10,
            swapOuts: 10
        )

        let rates = try require(
            current.withActivityRates(comparedTo: previous).activityRates,
            "expected activity rates to be calculated"
        )
        try expect(rates.pageOutBytesPerSecond == 0, "expected page-out reset to count as zero")
        try expect(rates.swapTrafficBytesPerSecond == 0, "expected swap reset to count as zero")
    },
    TestCase(name: "kernel memory pressure levels map to app states") {
        try expect(MemoryReader.pressureLevel(fromVMPressureLevel: 0) == .calm, "expected level 0 to be calm")
        try expect(MemoryReader.pressureLevel(fromVMPressureLevel: 1) == .calm, "expected level 1 to be calm")
        try expect(MemoryReader.pressureLevel(fromVMPressureLevel: 2) == .warm, "expected level 2 to be warm")
        try expect(MemoryReader.pressureLevel(fromVMPressureLevel: 4) == .hot, "expected level 4 to be hot")
        try expect(MemoryReader.pressureLevel(fromVMPressureLevel: 99) == .calm, "expected unknown level to be calm")
    },
    TestCase(name: "duty-cycle mode titles describe run time rather than CPU percentage") {
        try expect(ProcessLimitMode.background.title == "Background Priority", "expected background title")
        try expect(ProcessLimitMode.dutyCycle(0.75).title == "Run 75% of Time", "expected 75 percent title")
        try expect(ProcessLimitMode.dutyCycle(0.50).title == "Run 50% of Time", "expected 50 percent title")
        try expect(ProcessLimitMode.dutyCycle(0.25).title == "Run 25% of Time", "expected 25 percent title")
        try expect(ProcessLimitMode.dutyCycle(0).title == "Run 5% of Time", "expected safe minimum title")
    },
    TestCase(name: "ps line parser keeps command names containing spaces") {
        let process = try require(
            ProcessMemoryReader.parsePSLine(
                "  123  2048  12.5 /Applications/Test App.app/Contents/MacOS/Test App",
                processName: { _, fallback in fallback }
            ),
            "expected valid ps row to parse"
        )

        try expect(process.pid == 123, "expected parsed pid")
        try expect(process.name == "Test App", "expected parsed process name")
        try expect(process.memory == 2_097_152, "expected resident memory in bytes")
        try expect(process.cpu == 12.5, "expected parsed CPU percentage")
    },
    TestCase(name: "ps line parser rejects malformed rows") {
        try expect(ProcessMemoryReader.parsePSLine("") == nil, "expected empty row to be rejected")
        try expect(ProcessMemoryReader.parsePSLine("PID RSS CPU COMMAND") == nil, "expected header row to be rejected")
        try expect(ProcessMemoryReader.parsePSLine("abc 1024 3.0 /bin/example") == nil, "expected invalid pid to be rejected")
        try expect(ProcessMemoryReader.parsePSLine("123 nope 3.0 /bin/example") == nil, "expected invalid rss to be rejected")
        try expect(ProcessMemoryReader.parsePSLine("123 1024 nope /bin/example") == nil, "expected invalid cpu to be rejected")
    },
    TestCase(name: "ps output parser uses injected process names") {
        let output = """
            42 1024 1.5 /bin/example
            43 2048 2.5 /Applications/Other.app/Contents/MacOS/Other
            invalid row
            """

        let processes = ProcessMemoryReader.parsePSOutput(output) { pid, fallback in
            pid == 42 ? "Pretty Example" : fallback
        }

        try expect(processes.map(\.pid) == [42, 43], "expected valid rows only")
        try expect(processes.map(\.name) == ["Pretty Example", "Other"], "expected injected and fallback names")
        try expect(processes.map(\.memory) == [1_048_576, 2_097_152], "expected rss values converted to bytes")
    },
    TestCase(name: "process snapshot sorts processes and excludes unsafe entries") {
        let processes = [
            ProcessMemorySnapshot(pid: 999, name: "Memory Penguin", memory: 9_000, cpu: 99),
            ProcessMemorySnapshot(pid: 10, name: "WindowServer", memory: 8_000, cpu: 98),
            ProcessMemorySnapshot(pid: 11, name: "kernel_task", memory: 7_000, cpu: 97),
            ProcessMemorySnapshot(pid: 1, name: "Alpha", memory: 2_000, cpu: 10),
            ProcessMemorySnapshot(pid: 2, name: "Beta", memory: 5_000, cpu: 5),
            ProcessMemorySnapshot(pid: 3, name: "Gamma", memory: 5_000, cpu: 6)
        ]

        let snapshot = ProcessMemoryReader.snapshot(
            from: processes,
            memoryLimit: 2,
            cpuLimit: 2,
            currentPID: 999
        )

        try expect(snapshot.topMemoryProcesses.map(\.name) == ["Gamma", "Beta"], "expected memory sort with CPU tie-breaker")
        try expect(snapshot.topCPUProcesses.map(\.name) == ["Alpha", "Gamma"], "expected CPU sort")
    },
    TestCase(name: "process exclusion normalizes system process names") {
        try expect(
            ProcessMemoryReader.isExcluded(
                ProcessMemorySnapshot(pid: 1, name: "kernel task", memory: 0, cpu: 0),
                currentPID: 999
            ),
            "expected kernel task variant to be excluded"
        )
        try expect(
            ProcessMemoryReader.isExcluded(
                ProcessMemorySnapshot(pid: 2, name: "Window_Server", memory: 0, cpu: 0),
                currentPID: 999
            ),
            "expected WindowServer variant to be excluded"
        )
        try expect(
            !ProcessMemoryReader.isExcluded(
                ProcessMemorySnapshot(pid: 3, name: "User App", memory: 0, cpu: 0),
                currentPID: 999
            ),
            "expected ordinary app to stay visible"
        )
    },
    TestCase(name: "process snapshot limit validation cannot trap on negative values") {
        let process = ProcessMemorySnapshot(pid: 42, name: "Example", memory: 1_024, cpu: 1)
        let internalSnapshot = ProcessMemoryReader.snapshot(
            from: [process],
            memoryLimit: -1,
            cpuLimit: -1,
            currentPID: 999
        )
        try expect(internalSnapshot.topMemoryProcesses.isEmpty, "expected negative internal memory limit to clamp to zero")
        try expect(internalSnapshot.topCPUProcesses.isEmpty, "expected negative internal CPU limit to clamp to zero")

        var rejectedPublicLimit = false
        do {
            _ = try ProcessMemoryReader.snapshot(memoryLimit: -1, cpuLimit: 1)
        } catch ProcessSnapshotError.invalidLimit {
            rejectedPublicLimit = true
        }
        try expect(rejectedPublicLimit, "expected public snapshot API to reject negative limits")
    },
    TestCase(name: "live process snapshot succeeds within requested limits") {
        let snapshot = try ProcessMemoryReader.snapshot(memoryLimit: 3, cpuLimit: 4)
        try expect(snapshot.topMemoryProcesses.count <= 3, "expected memory result limit")
        try expect(snapshot.topCPUProcesses.count <= 4, "expected CPU result limit")
        try expect(
            !snapshot.topMemoryProcesses.isEmpty || !snapshot.topCPUProcesses.isEmpty,
            "expected live process snapshot to contain visible processes"
        )
    },
    TestCase(name: "process identity detects PID reuse through start time") {
        let pid = Int(Darwin.getpid())
        let identity = try require(ProcessLimiter.identity(pid: pid), "expected current process identity")
        try expect(identity.pid == pid, "expected identity PID")
        try expect(identity.userID == UInt32(Darwin.geteuid()), "expected identity owner")
        try expect(ProcessLimiter.matches(identity), "expected captured identity to match")

        let changedMicroseconds = (identity.startTimeMicroseconds + 1) % 1_000_000
        let reusedPIDIdentity = ProcessIdentity(
            pid: identity.pid,
            userID: identity.userID,
            startTimeSeconds: identity.startTimeSeconds,
            startTimeMicroseconds: changedMicroseconds
        )
        try expect(!ProcessLimiter.matches(reusedPIDIdentity), "expected changed start time to reject reused PID")
        try expect(!ProcessLimiter.resume(identity: reusedPIDIdentity), "expected signal API to reject stale identity")
    },
    TestCase(name: "process signal API rejects unsafe PIDs and different owners") {
        try expect(ProcessLimiter.identity(pid: 0) == nil, "expected PID zero to be invalid")
        try expect(!ProcessLimiter.processExists(pid: 0), "expected PID zero to be uncontrollable")
        try expect(!ProcessLimiter.processExists(pid: 1), "expected launchd PID to be uncontrollable")

        let current = try require(
            ProcessLimiter.identity(pid: Int(Darwin.getpid())),
            "expected current process identity"
        )
        let otherUserID = current.userID == UInt32.max ? current.userID - 1 : current.userID + 1
        let otherOwner = ProcessIdentity(
            pid: current.pid,
            userID: otherUserID,
            startTimeSeconds: current.startTimeSeconds,
            startTimeMicroseconds: current.startTimeMicroseconds
        )
        try expect(!ProcessLimiter.resume(identity: otherOwner), "expected different owner to be rejected before signaling")
    },
    TestCase(name: "protected process names cannot enter the limiter") {
        for name in ["WindowServer", "kernel_task", "System UI Server", "Finder", "Memory Penguin"] {
            try expect(ProcessLimiter.isProtectedProcessName(name), "expected \(name) to be protected")
        }
        try expect(!ProcessLimiter.isProtectedProcessName("Xcode"), "expected ordinary user app to remain controllable")

        let pid = Int(Darwin.getpid())
        var rejectedCurrentProcess = false
        do {
            _ = try ProcessLimiter.controllableIdentity(pid: pid, name: "Test Process")
        } catch ProcessControlError.currentProcess {
            rejectedCurrentProcess = true
        }
        try expect(rejectedCurrentProcess, "expected current process to be protected")

        var rejectedProtectedName = false
        do {
            _ = try ProcessLimiter.controllableIdentity(pid: pid, name: "Finder", currentPID: -1)
        } catch ProcessControlError.protectedProcess {
            rejectedProtectedName = true
        }
        try expect(rejectedProtectedName, "expected protected name to be rejected")

        var rejectedKernelName = false
        do {
            _ = try ProcessLimiter.controllableIdentity(pid: pid, name: "Xcode", currentPID: -1)
        } catch ProcessControlError.protectedProcess {
            rejectedKernelName = true
        }
        try expect(rejectedKernelName, "expected kernel process name to enforce protection")
    }
]

private func makeSnapshot(
    capturedAt: Date = Date(timeIntervalSince1970: 0),
    pageSize: UInt64 = 4_096,
    total: UInt64 = 1_000,
    free: UInt64 = 0,
    active: UInt64 = 0,
    inactive: UInt64 = 0,
    wired: UInt64 = 0,
    compressed: UInt64 = 0,
    purgeable: UInt64 = 0,
    speculative: UInt64 = 0,
    fileBacked: UInt64 = 0,
    anonymous: UInt64 = 0,
    pageOuts: UInt64 = 0,
    swapIns: UInt64 = 0,
    swapOuts: UInt64 = 0,
    swap: SwapSnapshot? = nil,
    activityRates: MemoryActivityRates? = nil,
    systemPressureLevel: MemoryPressureLevel = .calm
) -> MemorySnapshot {
    MemorySnapshot(
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
        activityRates: activityRates,
        systemPressureLevel: systemPressureLevel
    )
}

var failureCount = 0

for test in tests {
    do {
        try test.run()
        print("PASS \(test.name)")
    } catch {
        failureCount += 1
        print("FAIL \(test.name)")
        print("  \(error)")
    }
}

if failureCount > 0 {
    print("Failed \(failureCount) of \(tests.count) tests.")
    exit(EXIT_FAILURE)
}

print("Passed \(tests.count) tests.")
