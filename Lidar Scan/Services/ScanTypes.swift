//
//  ScanTypes.swift
//  Lidar Scan (二次开发)
//
//  扫描数据模型：格式、内容类型、网格数据、帧快照。
//

import Foundation
import ARKit
import CoreVideo
import CoreGraphics
import UIKit
import simd

// MARK: - 导出格式

enum ScanExportFormat: String, CaseIterable, Identifiable {
    case obj = "OBJ"
    case ply = "PLY"
    case stl = "STL"
    case glb = "GLB"
    case usdz = "USDZ"

    var id: String { rawValue }

    var fileExtension: String { rawValue.lowercased() }

    /// 该格式是否支持带颜色输出
    var supportsColor: Bool {
        switch self {
        case .obj, .ply, .glb: return true
        case .stl, .usdz: return false
        }
    }

    /// 该格式是否支持纯点云（无面）
    var supportsPointCloud: Bool {
        self == .obj || self == .ply
    }

    /// 列表页/预览页是否可直接用 SceneKit 打开
    var previewSupported: Bool {
        self == .obj || self == .usdz || self == .ply
    }
}

// MARK: - 内容类型

enum ScanContentKind: String, CaseIterable, Identifiable {
    case mesh = "网格模型"
    case pointCloud = "点云"

    var id: String { rawValue }
}

// MARK: - 网格数据

struct ScanMeshData {
    var vertices: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    /// 逐顶点颜色(0...1)，nil 表示未上色
    var colors: [SIMD3<Float>]?

    /// 每 3 个一组构成三角形
    var faces: [UInt32] = []

    var vertexCount: Int { vertices.count }
    var faceCount: Int { faces.count / 3 }

    var isEmpty: Bool { vertices.isEmpty }

    /// 带颜色的顶点数组（无颜色时用灰色兜底）
    var coloredVertices: [(vertex: SIMD3<Float>, normal: SIMD3<Float>, color: SIMD3<Float>)] {
        var result: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        result.reserveCapacity(vertexCount)
        for i in 0..<vertexCount {
            let c = colors?[i] ?? .meshGray
            let n = i < normals.count ? normals[i] : .zero
            result.append((vertices[i], n, c))
        }
        return result
    }
}

// MARK: - 帧快照（导出纹理时用于给顶点取色）
//
// 注意：此快照必须在 `ARSession.pause()` 之前、主线程上创建，
// 并且只保留“值类型”数据（矩阵/像素缓冲的强引用）。
// 禁止在暂停后继续访问 ARCamera / ARMeshAnchor 对象，否则会触发 UAF 闪退。

struct FrameSnapshot {
    /// 按界面方向物化好的「世界→相机」视图矩阵（值拷贝，与 ARCamera 生命周期解耦）
    let viewMatrix: simd_float4x4
    /// 相机内参（fx/fy/cx/cy）
    let intrinsics: simd_float3x3
    /// 深拷贝的相机图像像素（BGRA8，按行紧凑）——回调线程内物化，后台读取安全
    let imageData: [UInt8]?
    /// 图像像素尺寸
    let imageWidth: Int
    let imageHeight: Int
    /// 深拷贝的 LiDAR 深度（米）与置信度（0-255）
    let depthData: [Float]?
    let confidenceData: [UInt8]?
    /// 深度图尺寸
    let depthWidth: Int
    let depthHeight: Int

    static func make(from frame: ARFrame?, orientation: UIInterfaceOrientation) -> FrameSnapshot? {
        guard let frame = frame else { return nil }
        let img = frame.capturedImage   // capturedImage 为非可选类型
        let imageData = CameraPixelCopier.copyBGRA(from: img)

        var depthData: [Float]? = nil
        var confData: [UInt8]? = nil
        var dw = 0, dh = 0
        if let depth = frame.sceneDepth {
            depthData = CameraPixelCopier.copyDepth(from: depth.depthMap)
            if let conf = depth.confidenceMap {
                confData = CameraPixelCopier.copyConfidence(from: conf)
            }
            dw = CVPixelBufferGetWidth(depth.depthMap)
            dh = CVPixelBufferGetHeight(depth.depthMap)
        }

        return FrameSnapshot(viewMatrix: frame.camera.viewMatrix(for: orientation),
                             intrinsics: frame.camera.intrinsics,
                             imageData: imageData,
                             imageWidth: CVPixelBufferGetWidth(img),
                             imageHeight: CVPixelBufferGetHeight(img),
                             depthData: depthData,
                             confidenceData: confData,
                             depthWidth: dw,
                             depthHeight: dh)
    }
}

// MARK: - 关键帧（深度图重建数据源）
//
// B 计划：不读取 ARKit 任何 GPU/池化缓冲——
// 深度与置信度在回调线程内**深拷贝**为纯 Swift 数组后再交给后台重建，
// 杜绝“引用存活但底层内存已被 ARKit 复写/解映射”的 Use-After-Free。

struct KeyFrameSnapshot {
    /// 该帧的「世界→相机」视图矩阵（值拷贝）
    let viewMatrix: simd_float4x4
    /// 相机内参（**已缩放到深度图分辨率**；深度图 256×192 与图像 1920×1440 不同源，
    /// 官方点云示例必须按 depthRes/imageRes 缩放 fx/fy/cx/cy 后才能用于深度反投影）
    let intrinsics: simd_float3x3
    /// 深拷贝的 LiDAR 深度（米，行紧凑）
    let depthValues: [Float]
    /// 深拷贝的置信度（0-255，可选）
    let confidences: [UInt8]?
    /// 深度图尺寸
    let width: Int
    let height: Int

    static func make(from frame: ARFrame?, orientation: UIInterfaceOrientation) -> KeyFrameSnapshot? {
        guard let frame = frame,
              let depth = frame.sceneDepth?.depthMap,
              let depthValues = CameraPixelCopier.copyDepth(from: depth) else { return nil }
        var conf: [UInt8]? = nil
        if let confMap = frame.sceneDepth?.confidenceMap {
            conf = CameraPixelCopier.copyConfidence(from: confMap)
        }

        // ★ 关键修复：ARKit 的 intrinsics 针对 capturedImage 分辨率（如 1920×1440），
        // 而 depthMap 是 256×192——必须按比例缩放后才是深度图的内参。
        // 直接使用图像内参会让反投影坐标放大 ~7.5 倍 → 模型畸变、与真实完全对不上。
        let imageRes = frame.camera.imageResolution
        let depthW = CVPixelBufferGetWidth(depth)
        let depthH = CVPixelBufferGetHeight(depth)
        var intrinsics = frame.camera.intrinsics
        if imageRes.width > 0, imageRes.height > 0, depthW > 0, depthH > 0 {
            let sx = Float(depthW) / Float(imageRes.width)
            let sy = Float(depthH) / Float(imageRes.height)
            intrinsics[0][0] *= sx   // fx
            intrinsics[1][1] *= sy   // fy
            intrinsics[2][0] *= sx   // cx
            intrinsics[2][1] *= sy   // cy
        }

        return KeyFrameSnapshot(viewMatrix: frame.camera.viewMatrix(for: orientation),
                                intrinsics: intrinsics,
                                depthValues: depthValues,
                                confidences: conf,
                                width: depthW,
                                height: depthH)
    }
}

// MARK: - 像素深拷贝（回调线程安全物化）

enum CameraPixelCopier {
    /// 拷贝相机图像为紧凑 BGRA8。返回 nil 表示不可用。
    static func copyBGRA(from buffer: CVPixelBuffer) -> [UInt8]? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        var out = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let src = base.advanced(by: y * bytesPerRow)
            out.withUnsafeMutableBytes { dst in
                memcpy(dst.baseAddress!.advanced(by: y * width * 4), src, width * 4)
            }
        }
        return out
    }

    /// 拷贝 LiDAR 深度图为 [Float]（米）
    static func copyDepth(from buffer: CVPixelBuffer) -> [Float]? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_DepthFloat16
                || format == kCVPixelFormatType_DepthFloat32 else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        var out = [Float](repeating: 0, count: width * height)
        if format == kCVPixelFormatType_DepthFloat16 {
            var oi = 0
            for y in 0..<height {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt16.self)
                for x in 0..<width {
                    out[oi] = Float(Float16(bitPattern: row[x]))
                    oi += 1
                }
            }
        } else {
            var oi = 0
            for y in 0..<height {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float.self)
                for x in 0..<width {
                    out[oi] = row[x]
                    oi += 1
                }
            }
        }
        return out
    }

    /// 拷贝置信度图为 [UInt8]
    static func copyConfidence(from buffer: CVPixelBuffer) -> [UInt8]? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        var out = [UInt8](repeating: 0, count: width * height)
        var oi = 0
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                out[oi] = row[x]
                oi += 1
            }
        }
        return out
    }
}

// MARK: - 导出选项

struct ExportOptions {
    var fileName: String = ""
    var format: ScanExportFormat = .obj
    var contentKind: ScanContentKind = .mesh
    var textured: Bool = true
    var exportDepth: Bool = false
}

// MARK: - 导出结果

struct ExportResult {
    let urls: [URL]
}

// MARK: - 错误

enum ScanExportError: LocalizedError {
    case noMeshData
    case pointCloudNotSupported(ScanExportFormat)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noMeshData:
            return "未捕获到任何网格数据，请先扫描一段时间再导出。"
        case .pointCloudNotSupported(let format):
            return "\(format.rawValue) 格式不支持点云，请选择 OBJ 或 PLY。"
        case .exportFailed(let reason):
            return "导出失败：\(reason)"
        }
    }
}