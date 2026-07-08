import Darwin
import Foundation

public enum ProcessLimiter {
    public static func setBackgroundPolicy(pid: Int, enabled: Bool) throws {
        let task = Foundation.Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/taskpolicy")
        task.arguments = [enabled ? "-b" : "-B", "-p", "\(pid)"]

        let errorPipe = Pipe()
        task.standardError = errorPipe

        do {
            try task.run()
        } catch {
            throw NSError(
                domain: "MemoryPenguin.ProcessLimiter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to run taskpolicy for PID \(pid)."]
            )
        }

        task.waitUntilExit()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        errorPipe.fileHandleForReading.closeFile()

        guard task.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "MemoryPenguin.ProcessLimiter",
                code: Int(task.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: message?.isEmpty == false
                        ? message!
                        : "taskpolicy failed for PID \(pid)."
                ]
            )
        }
    }

    public static func processExists(pid: Int) -> Bool {
        Darwin.kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    @discardableResult
    public static func resume(pid: Int) -> Bool {
        send(signal: SIGCONT, pid: pid)
    }

    @discardableResult
    public static func suspend(pid: Int) -> Bool {
        send(signal: SIGSTOP, pid: pid)
    }

    private static func send(signal: Int32, pid: Int) -> Bool {
        Darwin.kill(pid_t(pid), signal) == 0
    }
}
