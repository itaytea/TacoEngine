import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct RGBA: Hashable, Sendable {
    public var r: UInt8, g: UInt8, b: UInt8, a: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) { self.r = r; self.g = g; self.b = b; self.a = a }
    public static let clear = RGBA(0, 0, 0, 0)
    public var isOpaque: Bool { a >= 128 }

    public init(rgb15 c: UInt16) {
        self.init(UInt8((c & 31) << 3), UInt8(((c >> 5) & 31) << 3), UInt8(((c >> 10) & 31) << 3))
    }

    public init(hex: UInt32) {
        self.init(UInt8((hex >> 16) & 255), UInt8((hex >> 8) & 255), UInt8(hex & 255))
    }

    /// GBA BGR555
    public var rgb15: UInt16 {
        UInt16(r >> 3) | (UInt16(g >> 3) << 5) | (UInt16(b >> 3) << 10)
    }
}

/// Simple non-premultiplied RGBA image.
public struct Bitmap: Sendable, Hashable {
    public var width: Int
    public var height: Int
    public var pixels: [RGBA]

    public init(width: Int, height: Int, pixels: [RGBA]) {
        self.width = width; self.height = height; self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: RGBA = .clear) {
        self.width = width; self.height = height
        pixels = Array(repeating: fill, count: width * height)
    }

    public subscript(x: Int, y: Int) -> RGBA {
        get { (x >= 0 && y >= 0 && x < width && y < height) ? pixels[y * width + x] : .clear }
        set { if x >= 0 && y >= 0 && x < width && y < height { pixels[y * width + x] = newValue } }
    }

    // MARK: IO

    public static func load(_ url: URL) throws -> Bitmap {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ArtError.unreadable(url.lastPathComponent)
        }
        return Bitmap(cgImage: img)
    }

    public init(cgImage img: CGImage) {
        width = img.width; height = img.height
        var raw = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &raw, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
        pixels = (0..<(width * height)).map { i in
            let a = raw[i * 4 + 3]
            if a == 0 { return .clear }
            func un(_ c: UInt8) -> UInt8 { UInt8(min(255, Int(c) * 255 / Int(a))) }
            return RGBA(un(raw[i * 4]), un(raw[i * 4 + 1]), un(raw[i * 4 + 2]), a)
        }
    }

    public func cgImage() -> CGImage {
        var raw = [UInt8](repeating: 0, count: width * height * 4)
        for (i, p) in pixels.enumerated() where p.isOpaque {
            raw[i * 4] = p.r; raw[i * 4 + 1] = p.g; raw[i * 4 + 2] = p.b; raw[i * 4 + 3] = 255
        }
        let provider = CGDataProvider(data: Data(raw) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    public func savePNG(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ArtError.unwritable(url.path)
        }
        CGImageDestinationAddImage(dest, cgImage(), nil)
        if !CGImageDestinationFinalize(dest) { throw ArtError.unwritable(url.path) }
    }

    // MARK: Frames & transforms

    /// Frames of a horizontal strip of square frames (frame width = image height).
    public var frames: [Bitmap] {
        let size = height
        guard size > 0 else { return [] }
        let count = max(1, width / size)
        return (0..<count).map { crop(x: $0 * size, y: 0, w: size, h: size) }
    }

    public func crop(x: Int, y: Int, w: Int, h: Int) -> Bitmap {
        var out = Bitmap(width: w, height: h)
        for yy in 0..<h { for xx in 0..<w { out[xx, yy] = self[x + xx, y + yy] } }
        return out
    }

    /// Nearest-neighbor resize.
    public func scaled(toWidth w: Int, height h: Int) -> Bitmap {
        if w == width && h == height { return self }
        var out = Bitmap(width: w, height: h)
        for y in 0..<h { for x in 0..<w { out[x, y] = self[x * width / w, y * height / h] } }
        return out
    }

    /// Fit a square frame into size x size: scale down if larger, pad (bottom-centered) if smaller.
    public func fitted(to size: Int) -> Bitmap {
        if width == size && height == size { return self }
        if width > size || height > size {
            let scale = max(width, height)
            return scaled(toWidth: width * size / scale, height: height * size / scale).fitted(to: size)
        }
        var out = Bitmap(width: size, height: size)
        let ox = (size - width) / 2, oy = size - height
        for y in 0..<height { for x in 0..<width { out[ox + x, oy + y] = self[x, y] } }
        return out
    }

    /// Horizontal strip from frames.
    public static func strip(_ frames: [Bitmap]) -> Bitmap {
        guard let first = frames.first else { return Bitmap(width: 0, height: 0) }
        var out = Bitmap(width: first.width * frames.count, height: first.height)
        for (i, f) in frames.enumerated() {
            for y in 0..<f.height { for x in 0..<f.width { out[i * first.width + x, y] = f[x, y] } }
        }
        return out
    }
}

public enum ArtError: LocalizedError {
    case unreadable(String)
    case unwritable(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let f): "Couldn't read image \(f)"
        case .unwritable(let f): "Couldn't write \(f)"
        case .invalid(let m): m
        }
    }
}
