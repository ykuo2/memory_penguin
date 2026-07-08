import AppKit
import Darwin
import Foundation

public enum ProcessMemoryReader {
    public static func snapshot(memoryLimit: Int = 5, cpuLimit: Int = 5) -> ProcessSnapshot {
        snapshot(
            from: readProcesses(),
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
            .prefix(memoryLimit)
        let topCPUProcesses = visibleProcesses
            .sorted {
                if $0.cpu == $1.cpu {
                    return $0.memory > $1.memory
                }
                return $0.cpu > $1.cpu
            }
            .prefix(cpuLimit)

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

    private static func readProcesses() -> [ProcessMemorySnapshot] {
        let task = Foundation.Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,rss=,pcpu=,comm="]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        do {
            try task.run()
        } catch {
            return []
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        _ = errorPipe.fileHandleForReading.readDataToEndOfFile()
        outputPipe.fileHandleForReading.closeFile()
        errorPipe.fileHandleForReading.closeFile()

        guard let output = String(data: outputData, encoding: .utf8) else {
            return []
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
