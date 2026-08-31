//
//  MeasurementService.swift
//  Lidar Scan (二次开发)
//
//  测量能力：包围盒尺寸/对角线/体积 + 两点距离。
//  说明：ARKit 场景网格是真实世界尺度（米），因此距离即真实尺寸。
//

import Foundation
import simd
import SceneKit

struct SceneDimensions {
    var minimum: SIMD3<Float> = SIMD3(repeating: .greatestFiniteMagnitude)
    var maximum: SIMD3<Float> = SIMD3(repeating: -.greatestFiniteMagnitude)

    var size: SIMD3<Float> { maximum - minimum }
    var diagonal: Float { simd_length(size) }
    var volume: Float { size.x * size.y * size.z }
    var width: Float { size.x }
    var height: Float { size.y }
    var depth: Float { size.z }

    var isEmpty: Bool { minimum.x > maximum.x }

    /// 展示用摘要：长 × 宽 × 高
    var summary: String {
        guard !isEmpty else { return "—" }
        return "\(size.x.metersText) × \(size.z.metersText) × \(size.y.metersText)"
    }

    /// 标题行：包围盒 + 体积
    var detailSummary: String {
        guard !isEmpty else { return "—" }
        return "包围盒 \(size.x.metersText) × \(size.z.metersText) × \(size.y.metersText) · 体积 \(volume.metersText)"
    }
}

enum MeasurementService {
    /// 计算一组顶点的包围盒（世界坐标，米）
    static func boundingBox(of vertices: [SIMD3<Float>]) -> SceneDimensions {
        var dims = SceneDimensions()
        for v in vertices {
            dims.minimum = simd_min(dims.minimum, v)
            dims.maximum = simd_max(dims.maximum, v)
        }
        return dims
    }

    /// 三维两点距离（SceneKit 世界坐标系，单位米）
    static func distance(_ a: SCNVector3, _ b: SCNVector3) -> Float {
        let dx = a.x - b.x
        let dy = a.y - b.y
        let dz = a.z - b.z
        return sqrt(dx * dx + dy * dy + dz * dz)
    }
}