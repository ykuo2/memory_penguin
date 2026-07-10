import AppKit
import Darwin
import Foundation

public enum ProcessSnapshotError: Error, LocalizedError, Sendable {
    case invalidLimit
    case unableToLaunch(String)
    case commandFailed(Int32, String)
    case invalidOutput

    public var errorDescription: String? {
        switch self {
        case .invalidLimit:
            return "Process list limits cannot be negative."
        case .unableToLaunch(let message):
            return "Unable to start ps: \(message)"
        case .commandFailed(let status, let message):
            return message.isEmpty ? "ps exited with status \(status)." : "ps failed: \(message)"
        case .invalidOutput:
            return "ps returned output that is not valid UTF-8."
        }
    }
}

public enum ProcessMemoryReader {
    public static func snapshot(memoryLimit: Int = 5, cpuLimit: Int = 5) throws -> ProcessSnapshot {
        guard memoryLimit >= 0, cpuLimit >= 0 else {
            throw ProcessSnapshotError.invalidLimit
        }

        return snapshot(
            from: try readProcesses(),
            memoryLimit: memoryLimit,
            cpuLimit: cpuLimit,
            currentPID: Int(Darwin.getpid())
        )
    }

    package static func snapshot(
        from processes: [ProcessMemorySnapshot],
        memoryLimit: Int,
        cpuLimit: Int,
        currentPID: Int
    ) -> ProcessSnapshot {
        let visibleProcesses = processes.filter { !isExcluded($0, currentPID: currentPID) }
        let topMemoryProcesses = visibleProcesses
            .sorted {
                if $0.memory == $1.memory {
                    return $0.cpu > $1.cpu
                }
                return $0.memory > $1.memory
            }
            .prefix(max(0, memoryLimit))
        let topCPUProcesses = visibleProcesses
            .sorted {
                if $0.cpu == $1.cpu {
                    return $0.memory > $1.memory
                }
                return $0.cpu > $1.cpu
            }
            .prefix(max(0, cpuLimit))

        return ProcessSnapshot(
            topMemoryProcesses: Array(topMemoryProcesses),
            topCPUProcesses: Array(topCPUProcesses)
        )
    }

    package static func parsePSOutput(
        _ output: String,
        processName: @escaping (Int, String) -> String = defaultProcessName(pid:fallback:)
    ) -> [ProcessMemorySnapshot] {
        var processes: [ProcessMemorySnapshot] = []
        output.enumerateLines { line, _ in
            guard let process = parsePSLine(line, processName: processName) else {
                return
            }
            processes.append(process)
        }

        return processes
    }

    package static func parsePSLine(
        _ raw: String,
        processName: (Int, String) -> String = defaultProcessName(pid:fallback:)
    ) -> ProcessMemorySnapshot? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(maxSplits: 3, omittingEmptySubsequences: true) { $0.isWhitespace }
        guard parts.count == 4,
              let pid = Int(parts[0]),
              let residentKilobytes = UInt64(parts[1]),
              let cpu = Double(parts[2]) else {
            return nil
        }

        let command = String(parts[3])
        let fallback = (command as NSString).lastPathComponent
        let name = processName(pid, fallback.isEmpty ? "Process \(pid)" : fallback)

        return ProcessMemorySnapshot(
            pid: pid,
            name: name,
            memory: residentKilobytes * 1024,
            cpu: cpu
        )
    }

    package static func isExcluded(_ process: ProcessMemorySnapshot, currentPID: Int) -> Bool {
        if process.pid == currentPID {
            return true
        }

        let normalizedName = process.name
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")

        return normalizedName == "windowserver"
            || normalizedName == "kerneltask"
            || normalizedName == "kernel"
    }

    private static func readProcesses() throws -> [ProcessMemorySnapshot] {
        let task = Foundation.Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,rss=,pcpu=,comm="]

        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = outputPipe

        do {
            try task.run()
        } catch {
            throw ProcessSnapshotError.unableToLaunch(error.localizedDescription)
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        outputPipe.fileHandleForReading.closeFile()

        guard let output = String(data: outputData, encoding: .utf8) else {
            throw ProcessSnapshotError.invalidOutput
        }
        guard task.terminationStatus == 0 else {
            throw ProcessSnapshotError.commandFailed(
                task.terminationStatus,
                output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return parsePSOutput(output)
    }

    private static func defaultProcessName(pid: Int, fallback: String) -> String {
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)), let name = app.localizedName {
            return name
        }
        return fallback
    }
}
