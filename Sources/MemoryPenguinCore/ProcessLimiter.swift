import Darwin
import Foundation

public enum ProcessControlError: Error, LocalizedError, Sendable {
    case invalidPID(Int)
    case currentProcess
    case processUnavailable(Int)
    case identityChanged(Int)
    case differentUser(Int)
    case protectedProcess(String)
    case taskPolicyUnavailable(Int)
    case taskPolicyFailed(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidPID(let pid):
            return "PID \(pid) is not safe to control."
        case .currentProcess:
            return "Memory Penguin cannot limit itself."
        case .processUnavailable(let pid):
            return "PID \(pid) is no longer available."
        case .identityChanged(let pid):
            return "PID \(pid) now belongs to a different process."
        case .differentUser(let pid):
            return "PID \(pid) is owned by another user."
        case .protectedProcess(let name):
            return "\(name) is a protected system process and cannot be limited."
        case .taskPolicyUnavailable(let pid):
            return "Unable to run taskpolicy for PID \(pid)."
        case .taskPolicyFailed(let pid, let message):
            return message.isEmpty ? "taskpolicy failed for PID \(pid)." : message
        }
    }
}

public enum ProcessLimiter {
    private static let protectedProcessNames: Set<String> = [
        "controlcenter",
        "coreaudiod",
        "dock",
        "finder",
        "kernel",
        "kerneltask",
        "launchd",
        "loginwindow",
        "opendirectoryd",
        "powerd",
        "runningboardd",
        "securityd",
        "systemuiserver",
        "windowserver"
    ]

    public static func identity(pid: Int) -> ProcessIdentity? {
        guard pid > 0, pid <= Int(Int32.max) else {
            return nil
        }

        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let bytesRead = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                Int32(pid),
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(expectedSize)
            )
        }
        guard bytesRead == Int32(expectedSize) else {
            return nil
        }

        return ProcessIdentity(
            pid: Int(info.pbi_pid),
            userID: UInt32(info.pbi_uid),
            startTimeSeconds: info.pbi_start_tvsec,
            startTimeMicroseconds: info.pbi_start_tvusec
        )
    }

    public static func controllableIdentity(
        pid: Int,
        name: String,
        currentPID: Int = Int(Darwin.getpid())
    ) throws -> ProcessIdentity {
        guard pid > 1, pid <= Int(Int32.max) else {
            throw ProcessControlError.invalidPID(pid)
        }
        guard pid != currentPID else {
            throw ProcessControlError.currentProcess
        }
        guard let identity = identity(pid: pid) else {
            throw ProcessControlError.processUnavailable(pid)
        }
        guard identity.userID == UInt32(Darwin.geteuid()) else {
            throw ProcessControlError.differentUser(pid)
        }
        let kernelName = kernelProcessName(pid: pid)
        if isProtectedProcessName(name) {
            throw ProcessControlError.protectedProcess(name)
        }
        if let kernelName, isProtectedProcessName(kernelName) {
            throw ProcessControlError.protectedProcess(kernelName)
        }

        return identity
    }

    public static func isProtectedProcessName(_ name: String) -> Bool {
        let normalized = name
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        return normalized.hasPrefix("memorypenguin") || protectedProcessNames.contains(normalized)
    }

    public static func matches(_ identity: ProcessIdentity) -> Bool {
        self.identity(pid: identity.pid) == identity
    }

    public static func processExists(_ identity: ProcessIdentity) -> Bool {
        matches(identity)
    }

    public static func processExists(pid: Int) -> Bool {
        guard pid > 1 else {
            return false
        }
        return identity(pid: pid) != nil
    }

    public static func setBackgroundPolicy(identity: ProcessIdentity, enabled: Bool) throws {
        try validateIdentityForControl(identity)

        let task = Foundation.Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/taskpolicy")
        task.arguments = [enabled ? "-b" : "-B", "-p", "\(identity.pid)"]

        let errorPipe = Pipe()
        task.standardError = errorPipe

        do {
            try task.run()
        } catch {
            throw ProcessControlError.taskPolicyUnavailable(identity.pid)
        }

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        errorPipe.fileHandleForReading.closeFile()

        guard task.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ProcessControlError.taskPolicyFailed(identity.pid, message)
        }
        guard matches(identity) else {
            throw ProcessControlError.identityChanged(identity.pid)
        }
    }

    @discardableResult
    public static func resume(identity: ProcessIdentity) -> Bool {
        send(signal: SIGCONT, identity: identity)
    }

    @discardableResult
    public static func suspend(identity: ProcessIdentity) -> Bool {
        send(signal: SIGSTOP, identity: identity)
    }

    private static func validateIdentityForControl(_ identity: ProcessIdentity) throws {
        guard identity.pid > 1, identity.pid <= Int(Int32.max) else {
            throw ProcessControlError.invalidPID(identity.pid)
        }
        guard identity.userID == UInt32(Darwin.geteuid()) else {
            throw ProcessControlError.differentUser(identity.pid)
        }
        guard matches(identity) else {
            throw ProcessControlError.identityChanged(identity.pid)
        }
    }

    private static func kernelProcessName(pid: Int) -> String? {
        var buffer = [UInt8](repeating: 0, count: 1_024)
        let length = buffer.withUnsafeMutableBytes { bytes in
            proc_name(Int32(pid), bytes.baseAddress, UInt32(bytes.count))
        }
        guard length > 0 else {
            return nil
        }

        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    private static func send(signal: Int32, identity: ProcessIdentity) -> Bool {
        guard identity.pid > 1,
              identity.userID == UInt32(Darwin.geteuid()),
              matches(identity) else {
            return false
        }

        return Darwin.kill(pid_t(identity.pid), signal) == 0
    }
}
