#!/usr/bin/env swift

import Darwin
import Dispatch
import Foundation

struct Options {
    var workers = max(1, ProcessInfo.processInfo.activeProcessorCount)
    var seconds: TimeInterval = 120
}

func printUsageAndExit() -> Never {
    let program = ((CommandLine.arguments.first ?? "CPUStressTest.swift") as NSString).lastPathComponent
    print("""
    Usage:
      \(program) [--workers N] [--seconds N]

    Examples:
      swift Scripts/CPUStressTest.swift --workers 2 --seconds 60
      swiftc Scripts/CPUStressTest.swift -o /tmp/CPUStressTest && /tmp/CPUStressTest --workers 4
    """)
    exit(0)
}

func parseOptions() -> Options {
    var options = Options()
    var index = 1

    while index < CommandLine.arguments.count {
        let argument = CommandLine.arguments[index]

        switch argument {
        case "--help", "-h":
            printUsageAndExit()
        case "--workers", "-w":
            index += 1
            guard index < CommandLine.arguments.count,
                  let workers = Int(CommandLine.arguments[index]),
                  workers > 0 else {
                fputs("Invalid --workers value.\n", stderr)
                exit(2)
            }
            options.workers = workers
        case "--seconds", "-s":
            index += 1
            guard index < CommandLine.arguments.count,
                  let seconds = Double(CommandLine.arguments[index]),
                  seconds > 0 else {
                fputs("Invalid --seconds value.\n", stderr)
                exit(2)
            }
            options.seconds = seconds
        default:
            fputs("Unknown argument: \(argument)\n", stderr)
            printUsageAndExit()
        }

        index += 1
    }

    return options
}

let options = parseOptions()
let deadline = Date().addingTimeInterval(options.seconds)
let group = DispatchGroup()
let lock = NSLock()
var checksums = Array(repeating: 0.0, count: options.workers)

print("CPUStressTest pid \(Darwin.getpid())")
print("Running \(options.workers) worker(s) for \(Int(options.seconds.rounded())) second(s). Press Ctrl-C to stop.")
fflush(stdout)

for workerIndex in 0..<options.workers {
    group.enter()

    DispatchQueue.global(qos: .userInitiated).async {
        var value = Double(workerIndex + 1)
        var checksum = 0.0

        while Date() < deadline {
            for iteration in 0..<20_000 {
                let input = value + Double(iteration % 97) + 1
                value = sin(input).magnitude + sqrt(input.magnitude)
                checksum += value
            }
        }

        lock.lock()
        checksums[workerIndex] = checksum
        lock.unlock()
        group.leave()
    }
}

while group.wait(timeout: .now() + 1) == .timedOut {
    let remaining = max(0, Int(deadline.timeIntervalSinceNow.rounded()))
    print("CPUStressTest running... \(remaining)s remaining")
    fflush(stdout)
}

let totalChecksum = checksums.reduce(0, +)
print(String(format: "Done. checksum %.3f", totalChecksum))
