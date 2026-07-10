#!/usr/bin/env swift

import Darwin
import Foundation

private struct Identity {
    let pid: Int32
    let userID: UInt32
    let startTimeSeconds: UInt64
    let startTimeMicroseconds: UInt64
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private enum HeartbeatLossMode {
    case closedPipe
    case timeout

    var title: String {
        switch self {
        case .closedPipe:
            return "closed pipe"
        case .timeout:
            return "heartbeat timeout"
        }
    }

    var guardExitTimeout: TimeInterval {
        switch self {
        case .closedPipe:
            return 3
        case .timeout:
            return 4
        }
    }
}

private func processInfo(pid: Int32) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let expectedSize = MemoryLayout<proc_bsdinfo>.stride
    let bytesRead = withUnsafeMutablePointer(to: &info) { pointer in
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(expectedSize))
    }
    return bytesRead == Int32(expectedSize) ? info : nil
}

private func waitUntil(
    timeout: TimeInterval,
    condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        usleep(20_000)
    }
    return condition()
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TestFailure(description: message)
    }
}

private func runScenario(executableURL: URL, mode: HeartbeatLossMode) throws {
    let target = Process()
    target.executableURL = URL(fileURLWithPath: "/bin/sleep")
    target.arguments = ["30"]
    target.standardOutput = FileHandle.nullDevice
    target.standardError = FileHandle.nullDevice
    try target.run()

    let targetPID = target.processIdentifier
    defer {
        _ = Darwin.kill(targetPID, SIGCONT)
        if target.isRunning {
            target.terminate()
            target.waitUntilExit()
        }
    }

    guard let initialInfo = processInfo(pid: targetPID) else {
        throw TestFailure(description: "unable to capture target identity")
    }
    let identity = Identity(
        pid: targetPID,
        userID: UInt32(initialInfo.pbi_uid),
        startTimeSeconds: initialInfo.pbi_start_tvsec,
        startTimeMicroseconds: initialInfo.pbi_start_tvusec
    )

    let heartbeatPipe = Pipe()
    let heartbeatWriteDescriptor = heartbeatPipe.fileHandleForWriting.fileDescriptor
    let descriptorFlags = Darwin.fcntl(heartbeatWriteDescriptor, F_GETFD)
    try require(
        descriptorFlags >= 0
            && Darwin.fcntl(heartbeatWriteDescriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0,
        "unable to configure close-on-exec for the heartbeat pipe"
    )

    let guardErrorPipe = Pipe()
    let guardProcess = Process()
    guardProcess.executableURL = executableURL
    guardProcess.arguments = [
        "--resume-guard",
        "\(identity.pid)",
        "\(identity.userID)",
        "\(identity.startTimeSeconds)",
        "\(identity.startTimeMicroseconds)"
    ]
    guardProcess.standardInput = heartbeatPipe
    guardProcess.standardOutput = FileHandle.nullDevice
    guardProcess.standardError = guardErrorPipe
    try guardProcess.run()
    heartbeatPipe.fileHandleForReading.closeFile()

    var heartbeatPipeIsClosed = false
    defer {
        if !heartbeatPipeIsClosed {
            heartbeatPipe.fileHandleForWriting.closeFile()
        }
        if guardProcess.isRunning {
            guardProcess.terminate()
            guardProcess.waitUntilExit()
        }
    }

    try require(Darwin.kill(targetPID, SIGSTOP) == 0, "unable to suspend target")
    try require(
        waitUntil(
            timeout: 1,
            condition: { processInfo(pid: targetPID)?.pbi_status == UInt32(SSTOP) }
        ),
        "target never entered the stopped state"
    )

    if mode == .closedPipe {
        heartbeatPipe.fileHandleForWriting.closeFile()
        heartbeatPipeIsClosed = true
    }

    try require(
        waitUntil(timeout: mode.guardExitTimeout, condition: { !guardProcess.isRunning }),
        "resume guard did not exit after \(mode.title)"
    )
    let guardErrorData = guardErrorPipe.fileHandleForReading.readDataToEndOfFile()
    let guardError = String(data: guardErrorData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    try require(
        guardProcess.terminationStatus == 0,
        "resume guard exited with status \(guardProcess.terminationStatus): \(guardError)"
    )
    try require(
        waitUntil(
            timeout: 1,
            condition: { processInfo(pid: targetPID)?.pbi_status != UInt32(SSTOP) }
        ),
        "resume guard exited successfully but the target remained stopped"
    )

    print("PASS resume guard restores a stopped process after \(mode.title)")
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let defaultExecutable = root.appendingPathComponent(".build/debug/MemoryPenguin")
let executableURL = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : defaultExecutable

guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
    fputs("FAIL MemoryPenguin executable not found at \(executableURL.path)\n", stderr)
    exit(EXIT_FAILURE)
}

do {
    try runScenario(executableURL: executableURL, mode: .closedPipe)
    try runScenario(executableURL: executableURL, mode: .timeout)
} catch {
    fputs("FAIL \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
