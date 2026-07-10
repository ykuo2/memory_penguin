import AppKit
import Darwin
import Foundation
import MemoryPenguinCore
import ServiceManagement

private final class ProcessMenuSelection: NSObject {
    let process: ProcessMemorySnapshot

    init(process: ProcessMemorySnapshot) {
        self.process = process
    }
}

private final class ProcessLimitMenuSelection: NSObject {
    let pid: Int
    let mode: ProcessLimitMode?

    init(pid: Int, mode: ProcessLimitMode?) {
        self.pid = pid
        self.mode = mode
    }
}

private enum ResumeGuardCommand {
    private static let flag = "--resume-guard"
    private static let heartbeatTimeoutMilliseconds: Int32 = 2_000

    static func arguments(for identity: ProcessIdentity) -> [String] {
        [
            flag,
            "\(identity.pid)",
            "\(identity.userID)",
            "\(identity.startTimeSeconds)",
            "\(identity.startTimeMicroseconds)"
        ]
    }

    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Int32? {
        guard arguments.dropFirst().first == flag else {
            return nil
        }
        guard arguments.count == 6,
              let pid = Int(arguments[2]),
              let userID = UInt32(arguments[3]),
              let startTimeSeconds = UInt64(arguments[4]),
              let startTimeMicroseconds = UInt64(arguments[5]),
              pid > 1,
              startTimeMicroseconds < 1_000_000 else {
            return EXIT_FAILURE
        }

        waitForHeartbeatLoss()
        let identity = ProcessIdentity(
            pid: pid,
            userID: userID,
            startTimeSeconds: startTimeSeconds,
            startTimeMicroseconds: startTimeMicroseconds
        )
        guard ProcessLimiter.resume(identity: identity) else {
            fputs("Resume guard could not validate or resume PID \(pid).\n", stderr)
            return EXIT_FAILURE
        }
        try? ProcessLimiter.setBackgroundPolicy(identity: identity, enabled: false)
        return EXIT_SUCCESS
    }

    private static func waitForHeartbeatLoss() {
        let watchedEvents = Int16(POLLIN) | Int16(POLLHUP) | Int16(POLLERR) | Int16(POLLNVAL)
        var descriptor = pollfd(fd: STDIN_FILENO, events: watchedEvents, revents: 0)
        var buffer = [UInt8](repeating: 0, count: 64)

        while true {
            descriptor.revents = 0
            let result = Darwin.poll(&descriptor, 1, heartbeatTimeoutMilliseconds)
            if result == 0 {
                return
            }
            if result < 0 {
                if errno == EINTR {
                    continue
                }
                return
            }

            if descriptor.revents & Int16(POLLIN) != 0 {
                let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(STDIN_FILENO, bytes.baseAddress, bytes.count)
                }
                if bytesRead > 0 {
                    continue
                }
                return
            }

            if descriptor.revents & (Int16(POLLHUP) | Int16(POLLERR) | Int16(POLLNVAL)) != 0 {
                return
            }
        }
    }
}

@MainActor
private final class ProcessResumeGuard {
    private let process: Foundation.Process
    private let heartbeatPipe: Pipe
    private let writeDescriptor: Int32
    private var isClosed = false

    init(identity: ProcessIdentity) throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw NSError(
                domain: "MemoryPenguin.ResumeGuard",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to locate the Memory Penguin executable."]
            )
        }

        let heartbeatPipe = Pipe()
        let writeDescriptor = heartbeatPipe.fileHandleForWriting.fileDescriptor
        let descriptorFlags = Darwin.fcntl(writeDescriptor, F_GETFD)
        guard descriptorFlags >= 0,
              Darwin.fcntl(writeDescriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0,
              Darwin.fcntl(writeDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw NSError(
                domain: "MemoryPenguin.ResumeGuard",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unable to configure the resume guard heartbeat."]
            )
        }

        let process = Foundation.Process()
        process.executableURL = executableURL
        process.arguments = ResumeGuardCommand.arguments(for: identity)
        process.standardInput = heartbeatPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        heartbeatPipe.fileHandleForReading.closeFile()

        self.process = process
        self.heartbeatPipe = heartbeatPipe
        self.writeDescriptor = writeDescriptor
    }

    func heartbeat() -> Bool {
        guard !isClosed, process.isRunning else {
            return false
        }

        var byte: UInt8 = 1
        let bytesWritten = withUnsafePointer(to: &byte) { pointer in
            Darwin.write(writeDescriptor, pointer, 1)
        }
        return bytesWritten == 1
    }

    func close() {
        guard !isClosed else {
            return
        }
        isClosed = true
        heartbeatPipe.fileHandleForWriting.closeFile()
    }
}

@MainActor
enum PenguinIconFactory {
    private static var cachedIcons: [MemoryPressureLevel: NSImage] = [:]

    static func image(for level: MemoryPressureLevel) -> NSImage {
        if let cached = cachedIcons[level] {
            return cached
        }

        let icon = loadStatusIcon(for: level) ?? fallbackIcon(for: level)
        cachedIcons[level] = icon
        return icon
    }

    private static func loadStatusIcon(for level: MemoryPressureLevel) -> NSImage? {
        let resourceName: String
        switch level {
        case .calm:
            resourceName = "memory_status_calm"
        case .warm:
            resourceName = "memory_status_elevated"
        case .hot:
            resourceName = "memory_status_high"
        }

        let bundledURL = Bundle.main.url(forResource: resourceName, withExtension: "png")
        let developmentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Generated/StatusIcons/\(resourceName).png")
        guard let image = NSImage(contentsOf: bundledURL ?? developmentURL) else {
            return nil
        }

        image.size = NSSize(width: 24, height: 22)
        image.isTemplate = false
        return image
    }

    private static func fallbackIcon(for level: MemoryPressureLevel) -> NSImage {
        let image = NSImage(size: NSSize(width: 26, height: 22))
        image.lockFocus()
        defer { image.unlockFocus() }

        switch level {
        case .calm:
            NSColor.systemGreen.setFill()
        case .warm:
            NSColor.systemYellow.setFill()
        case .hot:
            NSColor.systemRed.setFill()
        }

        NSBezierPath(ovalIn: NSRect(x: 5, y: 3, width: 16, height: 16)).fill()
        image.isTemplate = false
        return image
    }
}

enum LoginItemController {
    private static let launchAgentLabel = "local.memory-penguin.app.launch-at-login"

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled || FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func enable() throws {
        do {
            try SMAppService.mainApp.register()
            try removeLaunchAgent()
        } catch {
            try installLaunchAgent()
        }
    }

    static func disable() throws {
        if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
        try removeLaunchAgent()
    }

    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    private static func installLaunchAgent() throws {
        let launchAgentsDirectory = launchAgentURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": [
                "/usr/bin/open",
                "-g",
                Bundle.main.bundlePath
            ],
            "RunAtLoad": true
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: launchAgentURL, options: .atomic)
    }

    private static func removeLaunchAgent() throws {
        guard FileManager.default.fileExists(atPath: launchAgentURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: launchAgentURL)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum DefaultsKey {
        static let showsPercentage = "showsPercentage"
        static let showsDetailedMemoryInfo = "showsDetailedMemoryInfo"
    }

    private enum RefreshInterval {
        static let menuClosed: TimeInterval = 2
        static let menuOpen: TimeInterval = 1
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let summaryItem = AppDelegate.makeDisabledItem()
    private let totalItem = AppDelegate.makeDisabledItem()
    private let effectiveUsedItem = AppDelegate.makeDisabledItem()
    private let physicalOccupiedItem = AppDelegate.makeDisabledItem()
    private let reclaimableItem = AppDelegate.makeDisabledItem()
    private let availableItem = AppDelegate.makeDisabledItem()
    private let appMemoryItem = AppDelegate.makeDisabledItem()
    private let cacheItem = AppDelegate.makeDisabledItem()
    private let fileBackedItem = AppDelegate.makeDisabledItem()
    private let anonymousItem = AppDelegate.makeDisabledItem()
    private let freeItem = AppDelegate.makeDisabledItem()
    private let activeItem = AppDelegate.makeDisabledItem()
    private let inactiveItem = AppDelegate.makeDisabledItem()
    private let wiredItem = AppDelegate.makeDisabledItem()
    private let compressedItem = AppDelegate.makeDisabledItem()
    private let purgeableItem = AppDelegate.makeDisabledItem()
    private let speculativeItem = AppDelegate.makeDisabledItem()
    private let pageOutRateItem = AppDelegate.makeDisabledItem()
    private let swapTrafficRateItem = AppDelegate.makeDisabledItem()
    private let swapUsedItem = AppDelegate.makeDisabledItem()
    private let swapAvailableItem = AppDelegate.makeDisabledItem()
    private let swapTotalItem = AppDelegate.makeDisabledItem()
    private let overviewSeparatorItem = NSMenuItem.separator()
    private let stateSeparatorItem = NSMenuItem.separator()
    private let activitySeparatorItem = NSMenuItem.separator()
    private let processesSeparatorItem = NSMenuItem.separator()
    private let cpuProcessesSeparatorItem = NSMenuItem.separator()
    private let limitedProcessesSeparatorItem = NSMenuItem.separator()
    private let controlsSeparatorItem = NSMenuItem.separator()
    private let topProcessesTitleItem = AppDelegate.makeDisabledItem("Top Memory Processes")
    private let processItems = (0..<5).map { _ in AppDelegate.makeDisabledItem() }
    private let topCPUProcessesTitleItem = AppDelegate.makeDisabledItem("Top CPU Processes")
    private let cpuProcessItems = (0..<5).map { _ in AppDelegate.makeDisabledItem() }
    private let limitedProcessesTitleItem = AppDelegate.makeDisabledItem("Limited Processes")
    private let noLimitedProcessesItem = AppDelegate.makeDisabledItem("No limited processes")
    private let togglePercentageItem = NSMenuItem(
        title: "Show Percentage",
        action: #selector(togglePercentageVisibility),
        keyEquivalent: ""
    )
    private let toggleDetailedMemoryItem = NSMenuItem(
        title: "Show Detailed Memory Info",
        action: #selector(toggleDetailedMemoryInfo),
        keyEquivalent: ""
    )
    private let launchAtLoginItem = NSMenuItem(
        title: "Launch at Login",
        action: #selector(toggleLaunchAtLogin),
        keyEquivalent: ""
    )
    private let activityMonitorItem = NSMenuItem(
        title: "Open Activity Monitor",
        action: #selector(openActivityMonitor),
        keyEquivalent: ""
    )
    private let aboutItem = NSMenuItem(title: "About Memory Penguin", action: #selector(showAbout), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit Memory Penguin", action: #selector(quit), keyEquivalent: "q")
    private let processQueue = DispatchQueue(label: "MemoryPenguin.ProcessReader", qos: .utility)
    private var timer: Timer?
    private var refreshInterval: TimeInterval = RefreshInterval.menuClosed
    private var isMenuOpen = false
    private var isProcessRefreshInFlight = false
    private var processRefreshGeneration = 0
    private var hasProcessSnapshot = false
    private var limitedProcesses: [Int: LimitedProcess] = [:]
    private var limitedProcessOrder: [Int] = []
    private var limitedProcessMenuItems: [NSMenuItem] = []
    private var resumeGuards: [Int: ProcessResumeGuard] = [:]
    private var processLimitTimer: Timer?
    private var latestSnapshot: MemorySnapshot?
    private var showsPercentage: Bool {
        get {
            guard UserDefaults.standard.object(forKey: DefaultsKey.showsPercentage) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: DefaultsKey.showsPercentage)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.showsPercentage)
        }
    }
    private var showsDetailedMemoryInfo: Bool {
        get {
            guard UserDefaults.standard.object(forKey: DefaultsKey.showsDetailedMemoryInfo) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: DefaultsKey.showsDetailedMemoryInfo)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.showsDetailedMemoryInfo)
        }
    }
    private var detailedMemoryItems: [NSMenuItem] {
        [
            overviewSeparatorItem,
            totalItem,
            effectiveUsedItem,
            physicalOccupiedItem,
            reclaimableItem,
            availableItem,
            appMemoryItem,
            cacheItem,
            fileBackedItem,
            anonymousItem,
            stateSeparatorItem,
            freeItem,
            activeItem,
            inactiveItem,
            wiredItem,
            compressedItem,
            purgeableItem,
            speculativeItem,
            activitySeparatorItem,
            pageOutRateItem,
            swapTrafficRateItem,
            swapUsedItem,
            swapAvailableItem,
            swapTotalItem
        ]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }

        configureMenu()
        refresh()
        startTimer(interval: RefreshInterval.menuClosed)
    }

    func applicationWillTerminate(_ notification: Notification) {
        for pid in Array(limitedProcessOrder) {
            removeProcessLimit(pid: pid, shouldResetPolicy: true, shouldRefreshMenu: false)
        }
        resumeGuards.values.forEach { $0.close() }
        resumeGuards.removeAll()
        processLimitTimer?.invalidate()
        processLimitTimer = nil
    }

    @objc private func refresh() {
        do {
            let snapshot = try MemoryReader.current().withActivityRates(comparedTo: latestSnapshot)
            latestSnapshot = snapshot
            updateStatusItem(with: snapshot)
            updateMenu(with: snapshot)
            pruneExitedLimitedProcesses()
            if isMenuOpen {
                requestProcessRefresh()
            }
        } catch {
            statusItem.button?.title = showsPercentage ? " --%" : ""
            statusItem.button?.image = PenguinIconFactory.image(for: .warm)
            summaryItem.title = "Unable to read memory information"
        }
    }

    private func updateStatusItem(with snapshot: MemorySnapshot) {
        let percent = Int((snapshot.effectiveUsageRatio * 100).rounded())
        statusItem.button?.title = showsPercentage ? " \(percent)%" : ""
        statusItem.button?.image = PenguinIconFactory.image(for: snapshot.pressureLevel)
        statusItem.button?.toolTip = "Effective Used Estimate: \(percent)% (\(ByteFormatter.string(snapshot.effectiveUsedEstimate)))"
    }

    private func updateMenu(with snapshot: MemorySnapshot) {
        let percent = Int((snapshot.effectiveUsageRatio * 100).rounded())

        summaryItem.title = "Memory Penguin: \(snapshot.pressureLevel.title) Pressure / \(percent)% Effective Used Estimate"
        totalItem.title = "Total Memory: \(ByteFormatter.string(snapshot.total))"
        effectiveUsedItem.title = "Effective Used Estimate: \(ByteFormatter.string(snapshot.effectiveUsedEstimate))"
        physicalOccupiedItem.title = "Physical Occupied: \(ByteFormatter.string(snapshot.physicalOccupied))"
        reclaimableItem.title = "Reclaimable Estimate: \(ByteFormatter.string(snapshot.reclaimableEstimate))"
        availableItem.title = "Free (Includes Speculative): \(ByteFormatter.string(snapshot.available))"
        appMemoryItem.title = "Anonymous Estimate: \(ByteFormatter.string(snapshot.appMemory))"
        cacheItem.title = "File-Backed Estimate: \(ByteFormatter.string(snapshot.cache))"
        fileBackedItem.title = "File-Backed Counter: \(ByteFormatter.string(snapshot.fileBacked))"
        anonymousItem.title = "Anonymous Counter: \(ByteFormatter.string(snapshot.anonymous))"
        freeItem.title = "Kernel Free Counter: \(ByteFormatter.string(snapshot.free))"
        activeItem.title = "Active: \(ByteFormatter.string(snapshot.active))"
        inactiveItem.title = "Inactive: \(ByteFormatter.string(snapshot.inactive))"
        wiredItem.title = "Wired: \(ByteFormatter.string(snapshot.wired))"
        compressedItem.title = "Compressed: \(ByteFormatter.string(snapshot.compressed))"
        purgeableItem.title = "Purgeable: \(ByteFormatter.string(snapshot.purgeable))"
        speculativeItem.title = "Speculative: \(ByteFormatter.string(snapshot.speculative))"
        pageOutRateItem.title = "Page-Out Rate: \(ByteFormatter.rate(snapshot.activityRates?.pageOutBytesPerSecond ?? 0))"
        swapTrafficRateItem.title = "Swap Traffic Rate: \(ByteFormatter.rate(snapshot.activityRates?.swapTrafficBytesPerSecond ?? 0))"

        if let swap = snapshot.swap {
            swapUsedItem.title = "Swap Used: \(ByteFormatter.string(swap.used))"
            swapAvailableItem.title = "Swap Available: \(ByteFormatter.string(swap.available))"
            swapTotalItem.title = "Swap Total: \(ByteFormatter.string(swap.total))"
        } else {
            swapUsedItem.title = "Swap Used: --"
            swapAvailableItem.title = "Swap Available: --"
            swapTotalItem.title = "Swap Total: --"
        }

        togglePercentageItem.state = showsPercentage ? .on : .off
        toggleDetailedMemoryItem.state = showsDetailedMemoryInfo ? .on : .off
        applyDetailedMemoryVisibility()
        updateLaunchAtLoginItem()
    }

    private func updateProcesses(_ snapshot: ProcessSnapshot) {
        hasProcessSnapshot = true
        processItems.forEach { $0.toolTip = nil }
        cpuProcessItems.forEach { $0.toolTip = nil }
        updateMemoryProcesses(snapshot.topMemoryProcesses)
        updateCPUProcesses(snapshot.topCPUProcesses)
    }

    private func updateMemoryProcesses(_ processes: [ProcessMemorySnapshot]) {
        for index in processItems.indices {
            if index < processes.count {
                let process = processes[index]
                processItems[index].title = "\(index + 1). \(process.name): \(ByteFormatter.string(process.memory))"
            } else {
                processItems[index].title = "\(index + 1). --"
            }
        }
    }

    private func updateCPUProcesses(_ processes: [ProcessMemorySnapshot]) {
        for index in cpuProcessItems.indices {
            if index < processes.count {
                let process = processes[index]
                let isProtected = ProcessLimiter.isProtectedProcessName(process.name)
                let protectionLabel = isProtected ? " (Protected)" : ""
                cpuProcessItems[index].title = "\(index + 1). \(process.name): \(ByteFormatter.percent(process.cpu))\(protectionLabel)"
                cpuProcessItems[index].target = isProtected ? nil : self
                cpuProcessItems[index].action = isProtected ? nil : #selector(addCPUProcessToLimits(_:))
                cpuProcessItems[index].representedObject = ProcessMenuSelection(process: process)
                cpuProcessItems[index].isEnabled = !isProtected
                let limitedProcess = limitedProcesses[process.pid]
                cpuProcessItems[index].state = limitedProcess.map { ProcessLimiter.matches($0.identity) } == true ? .on : .off
            } else {
                cpuProcessItems[index].title = "\(index + 1). --"
                cpuProcessItems[index].target = nil
                cpuProcessItems[index].action = nil
                cpuProcessItems[index].representedObject = nil
                cpuProcessItems[index].isEnabled = false
                cpuProcessItems[index].state = .off
            }
        }
    }

    private func applyDetailedMemoryVisibility() {
        let shouldHide = !showsDetailedMemoryInfo
        detailedMemoryItems.forEach { $0.isHidden = shouldHide }
    }

    private func requestProcessRefresh() {
        guard isMenuOpen, !isProcessRefreshInFlight else {
            return
        }

        isProcessRefreshInFlight = true
        processRefreshGeneration += 1
        let generation = processRefreshGeneration

        if !hasProcessSnapshot {
            processItems.first?.title = "Loading..."
            cpuProcessItems.first?.title = "Loading..."
        }

        processQueue.async { [weak self] in
            let result: Result<ProcessSnapshot, ProcessSnapshotError>
            do {
                result = .success(try ProcessMemoryReader.snapshot(memoryLimit: 5, cpuLimit: 5))
            } catch let error as ProcessSnapshotError {
                result = .failure(error)
            } catch {
                result = .failure(.unableToLaunch(error.localizedDescription))
            }

            Task { @MainActor [weak self] in
                self?.finishProcessRefresh(result, generation: generation)
            }
        }
    }

    private func finishProcessRefresh(
        _ result: Result<ProcessSnapshot, ProcessSnapshotError>,
        generation: Int
    ) {
        isProcessRefreshInFlight = false

        guard isMenuOpen, generation == processRefreshGeneration else {
            return
        }

        switch result {
        case .success(let snapshot):
            updateProcesses(snapshot)
        case .failure(let error):
            showProcessRefreshError(error)
        }
    }

    private func showProcessRefreshError(_ error: ProcessSnapshotError) {
        hasProcessSnapshot = false
        updateMemoryProcesses([])
        updateCPUProcesses([])
        let message = error.localizedDescription
        processItems.first?.title = "Process list unavailable"
        processItems.first?.toolTip = message
        cpuProcessItems.first?.title = "Process list unavailable"
        cpuProcessItems.first?.toolTip = message
    }

    @objc private func addCPUProcessToLimits(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? ProcessMenuSelection else {
            return
        }

        let process = selection.process
        if let limitedProcess = limitedProcesses[process.pid], ProcessLimiter.matches(limitedProcess.identity) {
            removeProcessLimit(pid: process.pid, shouldResetPolicy: true, shouldRefreshMenu: true)
            return
        }
        if limitedProcesses[process.pid] != nil {
            removeProcessLimit(pid: process.pid, shouldResetPolicy: false, shouldRefreshMenu: false)
        }

        do {
            let identity = try ProcessLimiter.controllableIdentity(pid: process.pid, name: process.name)
            try ProcessLimiter.setBackgroundPolicy(identity: identity, enabled: true)
            limitedProcesses[process.pid] = LimitedProcess(
                identity: identity,
                name: process.name,
                mode: .background,
                modeStartedUptime: ProcessInfo.processInfo.systemUptime,
                isRunning: true,
                hasBackgroundPolicy: true
            )
            limitedProcessOrder.append(process.pid)
            rebuildLimitedProcessItems()
            updateCPUProcesses(
                cpuProcessItems.compactMap { ($0.representedObject as? ProcessMenuSelection)?.process }
            )
        } catch {
            showErrorAlert(
                title: "Unable to Limit Process",
                message: "\(process.name) could not be limited.\n\n\(error.localizedDescription)"
            )
        }
    }

    @objc private func changeProcessLimitMode(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? ProcessLimitMenuSelection,
              let mode = selection.mode else {
            return
        }

        do {
            try applyLimitMode(mode, to: selection.pid)
            rebuildLimitedProcessItems()
        } catch {
            showErrorAlert(
                title: "Unable to Change Process Limit",
                message: error.localizedDescription
            )
        }
    }

    @objc private func removeProcessLimit(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? ProcessLimitMenuSelection else {
            return
        }

        removeProcessLimit(pid: selection.pid, shouldResetPolicy: true, shouldRefreshMenu: true)
    }

    private func applyLimitMode(_ mode: ProcessLimitMode, to pid: Int) throws {
        guard var process = limitedProcesses[pid] else {
            return
        }
        guard ProcessLimiter.matches(process.identity) else {
            removeProcessLimit(pid: pid, shouldResetPolicy: false, shouldRefreshMenu: true)
            throw ProcessControlError.identityChanged(pid)
        }

        if !process.hasBackgroundPolicy {
            try ProcessLimiter.setBackgroundPolicy(identity: process.identity, enabled: true)
            process.hasBackgroundPolicy = true
        }

        switch mode {
        case .background:
            guard ProcessLimiter.resume(identity: process.identity) else {
                throw ProcessControlError.identityChanged(pid)
            }
            closeResumeGuard(pid: pid)
            process.isRunning = true
        case .dutyCycle:
            if resumeGuards[pid] == nil {
                resumeGuards[pid] = try ProcessResumeGuard(identity: process.identity)
            }
            guard resumeGuards[pid]?.heartbeat() == true,
                  ProcessLimiter.resume(identity: process.identity) else {
                closeResumeGuard(pid: pid)
                throw NSError(
                    domain: "MemoryPenguin.ProcessLimiter",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The resume guard could not protect PID \(pid)."]
                )
            }
            process.isRunning = true
        }

        process.mode = mode
        process.modeStartedUptime = ProcessInfo.processInfo.systemUptime
        limitedProcesses[pid] = process
        updateProcessLimitTimer()
    }

    private func closeResumeGuard(pid: Int) {
        resumeGuards.removeValue(forKey: pid)?.close()
    }

    private func removeProcessLimit(pid: Int, shouldResetPolicy: Bool, shouldRefreshMenu: Bool) {
        if let process = limitedProcesses[pid], ProcessLimiter.matches(process.identity) {
            _ = ProcessLimiter.resume(identity: process.identity)
            if shouldResetPolicy, process.hasBackgroundPolicy {
                try? ProcessLimiter.setBackgroundPolicy(identity: process.identity, enabled: false)
            }
        }

        closeResumeGuard(pid: pid)
        limitedProcesses.removeValue(forKey: pid)
        limitedProcessOrder.removeAll { $0 == pid }
        updateProcessLimitTimer()

        if shouldRefreshMenu {
            rebuildLimitedProcessItems()
            updateCPUProcesses(
                cpuProcessItems.compactMap { ($0.representedObject as? ProcessMenuSelection)?.process }
            )
        }
    }

    private func pruneExitedLimitedProcesses() {
        var didRemoveProcess = false

        for pid in Array(limitedProcessOrder) {
            guard let process = limitedProcesses[pid], !ProcessLimiter.matches(process.identity) else {
                continue
            }
            removeProcessLimit(pid: pid, shouldResetPolicy: false, shouldRefreshMenu: false)
            didRemoveProcess = true
        }

        if didRemoveProcess {
            rebuildLimitedProcessItems()
            updateCPUProcesses(
                cpuProcessItems.compactMap { ($0.representedObject as? ProcessMenuSelection)?.process }
            )
        }
    }

    @objc private func enforceProcessLimits() {
        var shouldRefreshMenu = false
        let now = ProcessInfo.processInfo.systemUptime

        for pid in Array(limitedProcessOrder) {
            guard var process = limitedProcesses[pid] else {
                continue
            }

            guard ProcessLimiter.matches(process.identity) else {
                removeProcessLimit(pid: pid, shouldResetPolicy: false, shouldRefreshMenu: false)
                shouldRefreshMenu = true
                continue
            }

            guard case .dutyCycle(let runFraction) = process.mode else {
                continue
            }
            guard resumeGuards[pid]?.heartbeat() == true else {
                removeProcessLimit(pid: pid, shouldResetPolicy: true, shouldRefreshMenu: false)
                shouldRefreshMenu = true
                continue
            }

            let period: TimeInterval = 1
            let runDuration = period * min(1, max(0.05, runFraction))
            let elapsed = max(0, now - process.modeStartedUptime)
            let phase = elapsed.truncatingRemainder(dividingBy: period)
            let shouldRun = phase < runDuration

            guard shouldRun != process.isRunning else {
                continue
            }

            let didSendSignal = shouldRun
                ? ProcessLimiter.resume(identity: process.identity)
                : ProcessLimiter.suspend(identity: process.identity)

            if didSendSignal {
                process.isRunning = shouldRun
                limitedProcesses[pid] = process
            } else {
                removeProcessLimit(pid: pid, shouldResetPolicy: true, shouldRefreshMenu: false)
                shouldRefreshMenu = true
            }
        }

        if shouldRefreshMenu {
            rebuildLimitedProcessItems()
            updateCPUProcesses(
                cpuProcessItems.compactMap { ($0.representedObject as? ProcessMenuSelection)?.process }
            )
        }
    }

    private func updateProcessLimitTimer() {
        let needsTimer = limitedProcesses.values.contains {
            if case .dutyCycle = $0.mode {
                return true
            }
            return false
        }

        if needsTimer, processLimitTimer == nil {
            processLimitTimer = Timer.scheduledTimer(
                timeInterval: 0.25,
                target: self,
                selector: #selector(enforceProcessLimits),
                userInfo: nil,
                repeats: true
            )
            if let processLimitTimer {
                RunLoop.main.add(processLimitTimer, forMode: .common)
            }
        } else if !needsTimer {
            processLimitTimer?.invalidate()
            processLimitTimer = nil
        }
    }

    private func rebuildLimitedProcessItems() {
        limitedProcessMenuItems.forEach { menu.removeItem($0) }
        limitedProcessMenuItems.removeAll()
        noLimitedProcessesItem.isHidden = !limitedProcesses.isEmpty

        guard let insertionIndex = menu.items.firstIndex(where: { $0 === controlsSeparatorItem }) else {
            return
        }

        for pid in limitedProcessOrder {
            guard let process = limitedProcesses[pid] else {
                continue
            }

            let item = NSMenuItem(
                title: "\(process.name) (\(process.pid)): \(process.mode.title)",
                action: nil,
                keyEquivalent: ""
            )
            item.submenu = makeProcessLimitSubmenu(for: process)
            menu.insertItem(item, at: insertionIndex + limitedProcessMenuItems.count)
            limitedProcessMenuItems.append(item)
        }
    }

    private func makeProcessLimitSubmenu(for process: LimitedProcess) -> NSMenu {
        let submenu = NSMenu()
        let modes: [ProcessLimitMode] = [
            .background,
            .dutyCycle(0.75),
            .dutyCycle(0.50),
            .dutyCycle(0.25)
        ]

        for mode in modes {
            let item = NSMenuItem(
                title: mode.title,
                action: #selector(changeProcessLimitMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = ProcessLimitMenuSelection(pid: process.pid, mode: mode)
            item.state = process.mode == mode ? .on : .off
            submenu.addItem(item)
        }

        submenu.addItem(NSMenuItem.separator())

        let removeItem = NSMenuItem(
            title: "Remove Limit",
            action: #selector(removeProcessLimit(_:)),
            keyEquivalent: ""
        )
        removeItem.target = self
        removeItem.representedObject = ProcessLimitMenuSelection(pid: process.pid, mode: nil)
        submenu.addItem(removeItem)

        return submenu
    }

    private func configureMenu() {
        menu.delegate = self

        for item in [
            summaryItem,
            overviewSeparatorItem,
            totalItem,
            effectiveUsedItem,
            physicalOccupiedItem,
            reclaimableItem,
            availableItem,
            appMemoryItem,
            cacheItem,
            fileBackedItem,
            anonymousItem,
            stateSeparatorItem,
            freeItem,
            activeItem,
            inactiveItem,
            wiredItem,
            compressedItem,
            purgeableItem,
            speculativeItem,
            activitySeparatorItem,
            pageOutRateItem,
            swapTrafficRateItem,
            swapUsedItem,
            swapAvailableItem,
            swapTotalItem,
            processesSeparatorItem,
            topProcessesTitleItem
        ] {
            menu.addItem(item)
        }

        processItems.forEach { menu.addItem($0) }

        menu.addItem(cpuProcessesSeparatorItem)
        menu.addItem(topCPUProcessesTitleItem)
        cpuProcessItems.forEach { menu.addItem($0) }

        menu.addItem(limitedProcessesSeparatorItem)
        menu.addItem(limitedProcessesTitleItem)
        menu.addItem(noLimitedProcessesItem)

        menu.addItem(controlsSeparatorItem)

        togglePercentageItem.target = self
        menu.addItem(togglePercentageItem)

        toggleDetailedMemoryItem.target = self
        menu.addItem(toggleDetailedMemoryItem)
        applyDetailedMemoryVisibility()

        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        updateLaunchAtLoginItem()

        activityMonitorItem.target = self
        menu.addItem(activityMonitorItem)

        aboutItem.target = self
        menu.addItem(aboutItem)

        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        startTimer(interval: RefreshInterval.menuOpen)
        refresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        processRefreshGeneration += 1
        startTimer(interval: RefreshInterval.menuClosed)
    }

    private func startTimer(interval: TimeInterval) {
        guard timer == nil || refreshInterval != interval else {
            return
        }

        timer?.invalidate()
        refreshInterval = interval
        timer = Timer.scheduledTimer(
            timeInterval: interval,
            target: self,
            selector: #selector(refresh),
            userInfo: nil,
            repeats: true
        )
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private static func makeDisabledItem(_ title: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func openActivityMonitor() {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    @objc private func togglePercentageVisibility() {
        showsPercentage.toggle()
        if let latestSnapshot {
            updateStatusItem(with: latestSnapshot)
            updateMenu(with: latestSnapshot)
        }
    }

    @objc private func toggleDetailedMemoryInfo() {
        showsDetailedMemoryInfo.toggle()
        toggleDetailedMemoryItem.state = showsDetailedMemoryInfo ? .on : .off
        applyDetailedMemoryVisibility()
    }

    private func updateLaunchAtLoginItem() {
        if LoginItemController.isEnabled {
            launchAtLoginItem.title = "Launch at Login"
            launchAtLoginItem.state = .on
            launchAtLoginItem.isEnabled = true
            return
        }

        if LoginItemController.requiresApproval {
            launchAtLoginItem.title = "Launch at Login (Needs Approval)"
            launchAtLoginItem.state = .mixed
            launchAtLoginItem.isEnabled = true
            return
        }

        launchAtLoginItem.title = "Launch at Login"
        launchAtLoginItem.state = .off
        launchAtLoginItem.isEnabled = true
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if LoginItemController.isEnabled {
                try LoginItemController.disable()
            } else if LoginItemController.requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else {
                try LoginItemController.enable()
            }
            updateLaunchAtLoginItem()
        } catch {
            updateLaunchAtLoginItem()
            showErrorAlert(
                title: "Unable to Update Login Item",
                message: "Move Memory Penguin to Applications, then try again."
                    + "\n\n\(error.localizedDescription)"
            )
        }
    }

    private func showErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func showAbout() {
        let applicationIcon: NSImage = NSImage(named: "AppIcon")
            ?? NSImage(contentsOfFile: Bundle.main.path(forResource: "icon", ofType: "png") ?? "")
            ?? NSApp.applicationIconImage
            ?? NSImage(size: NSSize(width: 128, height: 128))
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Memory Penguin",
            .applicationIcon: applicationIcon,
            .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
            .version: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1",
            .credits: NSAttributedString(
                string: "A tiny macOS menu bar companion for watching memory usage, pressure state, swap activity, top processes, and temporary CPU controls.",
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
            )
        ]
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

if let resumeGuardExitCode = ResumeGuardCommand.runIfRequested() {
    exit(resumeGuardExitCode)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
