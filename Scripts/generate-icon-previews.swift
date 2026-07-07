import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum IconLevel: Int, CaseIterable {
    case calm = 0
    case elevated = 1
    case high = 2

    var filename: String {
        switch self {
        case .calm:
            return "memory_preview_calm.png"
        case .elevated:
            return "memory_preview_elevated.png"
        case .high:
            return "memory_preview_high.png"
        }
    }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("Resources/memory_icon.png")
let outputDirectory = root.appendingPathComponent("Resources/Generated")
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

guard let sourceImage = NSImage(contentsOf: sourceURL),
      let sourceCG = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Unable to load Resources/memory_icon.png")
}

for level in IconLevel.allCases {
    let segmentWidth = sourceCG.width / 3
    let cropRect = CGRect(x: segmentWidth * level.rawValue, y: 0, width: segmentWidth, height: sourceCG.height)
    guard let cropped = sourceCG.cropping(to: cropRect),
          let transparent = removeEdgeBackground(from: cropped),
          let content = cropToVisibleContent(transparent),
          let preview = render(content, size: CGSize(width: 256, height: 235)) else {
        fatalError("Unable to render \(level.filename)")
    }

    let outputURL = outputDirectory.appendingPathComponent(level.filename)
    try writePNG(preview, to: outputURL)
    print(outputURL.path)
}

func removeEdgeBackground(from image: CGImage) -> CGImage? {
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

func protectedForegroundMask(
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

func cropToVisibleContent(_ image: CGImage) -> CGImage? {
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

func render(_ image: CGImage, size: CGSize) -> CGImage? {
    let bytesPerPixel = 4
    let bytesPerRow = Int(size.width) * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: Int(size.height) * bytesPerRow)

    guard let context = CGContext(
        data: &pixels,
        width: Int(size.width),
        height: Int(size.height),
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }

    context.interpolationQuality = .high
    context.clear(CGRect(origin: .zero, size: size))
    context.draw(image, in: aspectFitRect(contentSize: CGSize(width: image.width, height: image.height), container: CGRect(origin: .zero, size: size)))
    return context.makeImage()
}

func aspectFitRect(contentSize: CGSize, container: CGRect) -> CGRect {
    guard contentSize.width > 0, contentSize.height > 0 else {
        return container
    }

    let scale = min(container.width / contentSize.width, container.height / contentSize.height)
    let width = contentSize.width * scale
    let height = contentSize.height * scale
    return CGRect(
        x: container.minX + (container.width - width) / 2,
        y: container.minY + (container.height - height) / 2,
        width: width,
        height: height
    )
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "MemoryPenguinIconPreview", code: 1)
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "MemoryPenguinIconPreview", code: 2)
    }
}
