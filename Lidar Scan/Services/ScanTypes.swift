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
        self == .obj || self == .usdz
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

struct FrameSnapshot {
    let camera: ARCamera?
    let image: CVPixelBuffer?
    let intrinsics: simd_float3x3?
    let viewport: CGSize
    /// LiDAR 深度图（可空；仅当配置了 .sceneDepth 时才有）
    let depthMap: CVPixelBuffer?
    /// 深度置信度图（可空）
    let confidenceMap: CVPixelBuffer?

    static func make(from frame: ARFrame?) -> FrameSnapshot? {
        guard let frame = frame else { return nil }
        let img = frame.capturedImage
        let viewport = CGSize(width: CVPixelBufferGetWidth(img),
                              height: CVPixelBufferGetHeight(img))
        return FrameSnapshot(camera: frame.camera,
                             image: img,
                             intrinsics: frame.camera.intrinsics,
                             viewport: viewport,
                             depthMap: frame.sceneDepth?.depthMap,
                             confidenceMap: frame.sceneDepth?.confidenceMap)
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