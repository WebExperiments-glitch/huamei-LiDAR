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
    /// 相机图像像素缓冲（强引用，可安全在后台读取）
    let image: CVPixelBuffer?
    /// LiDAR 深度图（可空）
    let depthMap: CVPixelBuffer?
    /// 深度置信度图（可空）
    let confidenceMap: CVPixelBuffer?
    /// 图像像素尺寸
    let viewport: CGSize

    static func make(from frame: ARFrame?, orientation: UIInterfaceOrientation) -> FrameSnapshot? {
        guard let frame = frame else { return nil }
        let img = frame.capturedImage
        let viewport = CGSize(width: CVPixelBufferGetWidth(img),
                              height: CVPixelBufferGetHeight(img))
        return FrameSnapshot(viewMatrix: frame.camera.viewMatrix(for: orientation),
                             intrinsics: frame.camera.intrinsics,
                             image: img,
                             depthMap: frame.sceneDepth?.depthMap,
                             confidenceMap: frame.sceneDepth?.confidenceMap,
                             viewport: viewport)
    }
}

// MARK: - 关键帧（深度图重建数据源）
//
// B 计划：不再读取 ARMeshAnchor 的 GPU 缓冲（M2 上 AGX 驱动重映射导致崩溃），
// 改为只采集 CVPixelBuffer 深度图 + 相机位姿（纯值），在 CPU 上反投影成点云。

struct KeyFrameSnapshot {
    /// 该帧的「世界→相机」视图矩阵（值拷贝）
    let viewMatrix: simd_float4x4
    /// 相机内参（fx/fy/cx/cy）
    let intrinsics: simd_float3x3
    /// LiDAR 深度图（16-bit float，CVPixelBuffer 为线程安全数据通道）
    let depthMap: CVPixelBuffer?
    /// 深度置信度图（Y8：0=low，85=medium，170=high），用于融合时去噪
    let confidenceMap: CVPixelBuffer?
    /// 深度图尺寸
    let viewport: CGSize

    static func make(from frame: ARFrame?, orientation: UIInterfaceOrientation) -> KeyFrameSnapshot? {
        guard let frame = frame,
              let depth = frame.sceneDepth?.depthMap else { return nil }
        return KeyFrameSnapshot(viewMatrix: frame.camera.viewMatrix(for: orientation),
                                intrinsics: frame.camera.intrinsics,
                                depthMap: depth,
                                confidenceMap: frame.sceneDepth?.confidenceMap,
                                viewport: CGSize(width: CVPixelBufferGetWidth(depth),
                                                 height: CVPixelBufferGetHeight(depth)))
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