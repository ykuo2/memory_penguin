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

@MainActor
enum PenguinIconFactory {
    private static var cachedIcons: [MemoryPressureLevel: NSImage] = [:]

    static func image(for level: MemoryPressureLevel) -> NSImage {
        if let cached = cachedIcons[level] {
            return cached
        }

        let icon = loadSpriteIcon(for: level) ?? fallbackIcon(for: level)
        cachedIcons[level] = icon
        return icon
    }

    private static func loadSpriteIcon(for level: MemoryPressureLevel) -> NSImage? {
        guard let source = loadMemoryIconSheet(),
              let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let index: Int
        switch level {
        case .calm:
            index = 0
        case .warm:
            index = 1
        case .hot:
            index = 2
        }

        let segmentWidth = cgImage.width / 3
        let cropRect = CGRect(x: segmentWidth * index, y: 0, width: segmentWidth, height: cgImage.height)
        guard let cropped = cgImage.cropping(to: cropRect) else {
            return nil
        }

        let transparent = removeEdgeBackground(from: cropped) ?? cropped
        let content = cropToVisibleContent(transparent) ?? transparent
        let targetSize = NSSize(width: 24, height: 22)
        let image = NSImage(size: targetSize)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .high

        let contentSize = NSSize(width: content.width, height: content.height)
        let drawRect = aspectFitRect(contentSize: contentSize, container: NSRect(origin: .zero, size: targetSize))
        NSImage(cgImage: content, size: contentSize).draw(
            in: drawRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        image.isTemplate = false
        return image
    }

    private static func removeEdgeBackground(from image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let protected = protectedForegroundMask(pixels: pixels, width: width, height: height, bytesPerPixel: bytesPerPixel)
        var queue: [(Int, Int)] = []
        var visited = [Bool](repeating: false, count: width * height)

        func offset(_ x: Int, _ y: Int) -> Int {
            (y * width + x) * bytesPerPixel
        }

        func isBackground(_ x: Int, _ y: Int) -> Bool {
            let visitIndex = y * width + x
            guard !protected[visitIndex] else {
                return false
            }

            let idx = offset(x, y)
            let red = Int(pixels[idx])
            let green = Int(pixels[idx + 1])
            let blue = Int(pixels[idx + 2])
            return max(red, green, blue) < 34
        }

        func enqueue(_ x: Int, _ y: Int) {
            guard x >= 0, x < width, y >= 0, y < height else {
                return
            }

            let visitIndex = y * width + x
            guard !visited[visitIndex], isBackground(x, y) else {
                return
            }

            visited[visitIndex] = true
            queue.append((x, y))
        }

        for x in 0..<width {
            enqueue(x, 0)
            enqueue(x, height - 1)
        }
        for y in 0..<height {
            enqueue(0, y)
            enqueue(width - 1, y)
        }

        var cursor = 0
        while cursor < queue.count {
            let (x, y) = queue[cursor]
            cursor += 1

            let idx = offset(x, y)
            pixels[idx + 3] = 0

            enqueue(x + 1, y)
            enqueue(x - 1, y)
            enqueue(x, y + 1)
            enqueue(x, y - 1)
        }

        guard let outputContext = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        return outputContext.makeImage()
    }

    private static func protectedForegroundMask(
        pixels: [UInt8],
        width: Int,
        height: Int,
        bytesPerPixel: Int
    ) -> [Bool] {
        let radius = 2
        var seed = [Bool](repeating: false, count: width * height)

        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * bytesPerPixel
                let red = Int(pixels[idx])
                let green = Int(pixels[idx + 1])
                let blue = Int(pixels[idx + 2])
                let brightest = max(red, green, blue)
                let darkest = min(red, green, blue)
                seed[y * width + x] = brightest > 46 || (brightest > 34 && brightest - darkest > 18)
            }
        }

        var horizontal = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            var count = 0
            for x in 0..<width {
                let entering = x + radius
                let leaving = x - radius - 1
                if entering < width, seed[y * width + entering] {
                    count += 1
                }
                if leaving >= 0, seed[y * width + leaving] {
                    count -= 1
                }
                horizontal[y * width + x] = count > 0
            }
        }

        var protected = [Bool](repeating: false, count: width * height)
        for x in 0..<width {
            var count = 0
            for y in 0..<height {
                let entering = y + radius
                let leaving = y - radius - 1
                if entering < height, horizontal[entering * width + x] {
                    count += 1
                }
                if leaving >= 0, horizontal[leaving * width + x] {
                    count -= 1
                }
                protected[y * width + x] = count > 0
            }
        }

        return protected
    }

    private static func cropToVisibleContent(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0
        var foundPixel = false

        for y in 0..<height {
            for x in 0..<width {
                let alpha = pixels[(y * width + x) * bytesPerPixel + 3]
                guard alpha > 8 else {
                    continue
                }

                foundPixel = true
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard foundPixel else {
            return nil
        }

        let padding = 10
        let cropX = max(0, minX - padding)
        let cropY = max(0, minY - padding)
        let cropMaxX = min(width - 1, maxX + padding)
        let cropMaxY = min(height - 1, maxY + padding)
        let cropRect = CGRect(x: cropX, y: cropY, width: cropMaxX - cropX + 1, height: cropMaxY - cropY + 1)
        return image.cropping(to: cropRect)
    }

    private static func aspectFitRect(contentSize: NSSize, container: NSRect) -> NSRect {
        guard contentSize.width > 0, contentSize.height > 0 else {
            return container
        }

        let scale = min(container.width / contentSize.width, container.height / contentSize.height)
        let width = contentSize.width * scale
        let height = contentSize.height * scale
        return NSRect(
            x: container.minX + (container.width - width) / 2,
            y: container.minY + (container.height - height) / 2,
            width: width,
            height: height
        )
    }

    private static func loadMemoryIconSheet() -> NSImage? {
        if let url = Bundle.main.url(forResource: "memory_icon", withExtension: "png") {
            return NSImage(contentsOf: url)
        }

        let developmentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/memory_icon.png")
        return NSImage(contentsOf: developmentURL)
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
    private let usedItem = AppDelegate.makeDisabledItem()
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
            usedItem,
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
        let percent = Int((snapshot.usageRatio * 100).rounded())
        statusItem.button?.title = showsPercentage ? " \(percent)%" : ""
        statusItem.button?.image = PenguinIconFactory.image(for: snapshot.pressureLevel)
        statusItem.button?.toolTip = "Memory Usage: \(percent)%"
    }

    private func updateMenu(with snapshot: MemorySnapshot) {
        let percent = Int((snapshot.usageRatio * 100).rounded())

        summaryItem.title = "Memory Penguin: \(snapshot.pressureLevel.title) Pressure / \(percent)% Used"
        totalItem.title = "Total Memory: \(ByteFormatter.string(snapshot.total))"
        usedItem.title = "Used: \(ByteFormatter.string(snapshot.used))"
        availableItem.title = "Available: \(ByteFormatter.string(snapshot.available))"
        appMemoryItem.title = "App Memory: \(ByteFormatter.string(snapshot.appMemory))"
        cacheItem.title = "Cache: \(ByteFormatter.string(snapshot.cache))"
        fileBackedItem.title = "File-Backed Cache: \(ByteFormatter.string(snapshot.fileBacked))"
        anonymousItem.title = "Anonymous: \(ByteFormatter.string(snapshot.anonymous))"
        freeItem.title = "Free: \(ByteFormatter.string(snapshot.free))"
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
                cpuProcessItems[index].title = "\(index + 1). \(process.name): \(ByteFormatter.percent(process.cpu))"
                cpuProcessItems[index].target = self
                cpuProcessItems[index].action = #selector(addCPUProcessToLimits(_:))
                cpuProcessItems[index].representedObject = ProcessMenuSelection(process: process)
                cpuProcessItems[index].isEnabled = true
                cpuProcessItems[index].state = limitedProcesses[process.pid] == nil ? .off : .on
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
            let snapshot = ProcessMemoryReader.snapshot(memoryLimit: 5, cpuLimit: 5)

            Task { @MainActor [weak self] in
                self?.finishProcessRefresh(snapshot, generation: generation)
            }
        }
    }

    private func finishProcessRefresh(_ snapshot: ProcessSnapshot, generation: Int) {
        isProcessRefreshInFlight = false

        guard isMenuOpen, generation == processRefreshGeneration else {
            return
        }

        updateProcesses(snapshot)
    }

    @objc private func addCPUProcessToLimits(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? ProcessMenuSelection else {
            return
        }

        let process = selection.process
        guard process.pid != Int(Darwin.getpid()) else {
            showErrorAlert(
                title: "Unable to Limit Process",
                message: "Memory Penguin cannot add itself to the limited process list."
            )
            return
        }

        guard ProcessLimiter.processExists(pid: process.pid) else {
            showErrorAlert(title: "Process Has Exited", message: "\(process.name) is no longer running.")
            return
        }

        if limitedProcesses[process.pid] != nil {
            removeProcessLimit(pid: process.pid, shouldResetPolicy: true, shouldRefreshMenu: true)
            return
        }

        do {
            try ProcessLimiter.setBackgroundPolicy(pid: process.pid, enabled: true)
            limitedProcesses[process.pid] = LimitedProcess(
                pid: process.pid,
                name: process.name,
                mode: .background,
                modeStartedAt: Date(),
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
                message: "\(process.name) could not be moved to background priority.\n\n\(error.localizedDescription)"
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
        guard ProcessLimiter.processExists(pid: pid) else {
            removeProcessLimit(pid: pid, shouldResetPolicy: false, shouldRefreshMenu: true)
            return
        }

        if !process.hasBackgroundPolicy {
            try ProcessLimiter.setBackgroundPolicy(pid: pid, enabled: true)
            process.hasBackgroundPolicy = true
        }

        switch mode {
        case .background:
            ProcessLimiter.resume(pid: pid)
            process.isRunning = true
        case .throttle:
            guard ProcessLimiter.resume(pid: pid) else {
                throw NSError(
                    domain: "MemoryPenguin.ProcessLimiter",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Memory Penguin cannot send control signals to PID \(pid)."]
                )
            }
            process.isRunning = true
        }

        process.mode = mode
        process.modeStartedAt = Date()
        limitedProcesses[pid] = process
        updateProcessLimitTimer()
    }

    private func removeProcessLimit(pid: Int, shouldResetPolicy: Bool, shouldRefreshMenu: Bool) {
        if let process = limitedProcesses[pid], !process.isRunning {
            ProcessLimiter.resume(pid: pid)
        }

        if shouldResetPolicy, limitedProcesses[pid]?.hasBackgroundPolicy == true {
            try? ProcessLimiter.setBackgroundPolicy(pid: pid, enabled: false)
        }

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

        for pid in Array(limitedProcessOrder) where !ProcessLimiter.processExists(pid: pid) {
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
        let now = Date()

        for pid in Array(limitedProcessOrder) {
            guard var process = limitedProcesses[pid] else {
                continue
            }

            guard ProcessLimiter.processExists(pid: pid) else {
                removeProcessLimit(pid: pid, shouldResetPolicy: false, shouldRefreshMenu: false)
                shouldRefreshMenu = true
                continue
            }

            guard case .throttle(let allowedCPU) = process.mode else {
                continue
            }

            let period: TimeInterval = 1
            let runDuration = period * min(1, max(0.05, allowedCPU))
            let phase = now.timeIntervalSince(process.modeStartedAt)
                .truncatingRemainder(dividingBy: period)
            let shouldRun = phase < runDuration

            guard shouldRun != process.isRunning else {
                continue
            }

            let didSendSignal = shouldRun
                ? ProcessLimiter.resume(pid: pid)
                : ProcessLimiter.suspend(pid: pid)

            if didSendSignal {
                process.isRunning = shouldRun
                limitedProcesses[pid] = process
            } else {
                removeProcessLimit(pid: pid, shouldResetPolicy: false, shouldRefreshMenu: false)
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
            if case .throttle = $0.mode {
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
            .throttle(0.75),
            .throttle(0.50),
            .throttle(0.25)
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
            usedItem,
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
