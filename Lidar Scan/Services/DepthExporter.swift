//
//  DepthExporter.swift
//  Lidar Scan (二次开发)
//
//  深度图导出：16-bit 灰度 PNG（单位毫米）+ 置信度 8-bit PNG。
//

import Foundation
import CoreVideo
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum DepthExporter {

    enum DepthError: LocalizedError {
        case invalidBuffer
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .invalidBuffer: return "深度图数据无效（像素缓冲为空）"
            case .unsupportedFormat: return "当前设备的深度图格式不支持导出"
            }
        }
    }

    /// 导出深度图为 16-bit 灰度 PNG（毫米）
    static func writeDepthMap(_ buffer: CVPixelBuffer, to url: URL) throws {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { throw DepthError.invalidBuffer }

        let format = CVPixelBufferGetPixelFormatType(buffer)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw DepthError.invalidBuffer }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        var output = [UInt16](repeating: 0, count: width * height)

        switch format {
        case kCVPixelFormatType_DepthFloat16:
            let ptr = base.assumingMemoryBound(to: UInt16.self)
            for y in 0..<height {
                for x in 0..<width {
                    let raw = ptr[y * (bytesPerRow / 2) + x]
                    let depth = Float(Float16(bitPattern: raw))
                    output[y * width + x] = millimeters(from: depth)
                }
            }

        case kCVPixelFormatType_DepthFloat32:
            let ptr = base.assumingMemoryBound(to: Float.self)
            for y in 0..<height {
                for x in 0..<width {
                    let depth = ptr[y * (bytesPerRow / 4) + x]
                    output[y * width + x] = millimeters(from: depth)
                }
            }

        default:
            throw DepthError.unsupportedFormat
        }

        let cgImage = try makeGray16Image(output, width: width, height: height)
        try writePNG(cgImage, to: url)
    }

    /// 导出置信度图为 8-bit 灰度 PNG
    static func writeConfidenceMap(_ buffer: CVPixelBuffer, to url: URL) throws {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { throw DepthError.invalidBuffer }

        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_Confidence8 else { throw DepthError.unsupportedFormat }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw DepthError.invalidBuffer }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        // ARKit 置信度：0-3，放大到 0-255 便于查看
        var output = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let v = ptr[y * bytesPerRow + x]
                output[y * width + x] = UInt8(min(255, Int(v) * 85))
            }
        }

        let cgImage = makeGray8Image(output, width: width, height: height)
        guard let cgImage = cgImage else { throw DepthError.invalidBuffer }
        try writePNG(cgImage, to: url)
    }

    // MARK: - 私有工具

    private static func millimeters(from meters: Float) -> UInt16 {
        guard meters.isFinite, meters > 0 else { return 0 }
        let mm = meters * 1000
        return mm >= 65535 ? 65535 : UInt16(mm)
    }

    private static func makeGray16Image(_ pixels: [UInt16],
                                        width: Int,
                                        height: Int) throws -> CGImage {
        var data = Data()
        for v in pixels { data.appendLE(v) }
        let provider = CGDataProvider(data: data as CFData)
        guard let provider = provider,
              let image = CGImage(width: width,
                                  height: height,
                                  bitsPerComponent: 16,
                                  bitsPerPixel: 16,
                                  bytesPerRow: width * 2,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
                                    .union(.byteOrder16Little),
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw DepthError.invalidBuffer
        }
        return image
    }

    private static func makeGray8Image(_ pixels: [UInt8],
                                       width: Int,
                                       height: Int) -> CGImage? {
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 8,
                       bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                UTType.png.identifier as CFString,
                                                                1, nil) else {
            throw DepthError.invalidBuffer
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw DepthError.invalidBuffer
        }
    }
}