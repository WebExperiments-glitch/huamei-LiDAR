//
//  PointCloudGenerator.swift
//  Lidar Scan (二次开发)
//
//  B 计划核心：把若干关键帧的 LiDAR 深度图反投影成世界坐标点云。
//  全程只读 CVPixelBuffer（Apple 线程安全数据通道） + 值类型矩阵，
//  不触碰任何 ARKit 的 GPU 缓冲，从根本上杜绝 SIGSEGV。
//

import Foundation
import CoreVideo
import simd

enum PointCloudGenerator {

    /// 反投影采样步长（深度图每隔 n 像素取一点，控制密度）
    private static let samplingStep = 2

    /// 单帧可产生的最大点数（防爆内存）
    private static let maxPointsPerFrame = 60_000

    /// 总点数上限（防爆内存）
    public static let maxTotalPoints = 1_500_000

    struct ColoredPoint {
        var position: SIMD3<Float>
        var color: SIMD3<Float>
    }

    /// 把一批关键帧的深度图反投影合并成世界坐标点云。
    /// 返回点云；失败或空则返回空数组。
    static func generate(from frames: [KeyFrameSnapshot], maxTotal: Int = maxTotalPoints) -> [ColoredPoint] {
        var all: [ColoredPoint] = []
        all.reserveCapacity(min(frames.count * maxPointsPerFrame, maxTotal))

        for frame in frames {
            guard !frame.depthValues.isEmpty else { continue }
            let points = project(depthValues: frame.depthValues,
                                 intrinsics: frame.intrinsics,
                                 viewMatrix: frame.viewMatrix,
                                 width: frame.width,
                                 height: frame.height)
            all.append(contentsOf: points)
            if all.count >= maxTotal { break }
        }
        return all
    }

    // MARK: - 单帧反投影

    private static func project(depthValues: [Float],
                                intrinsics: simd_float3x3,
                                viewMatrix: simd_float4x4,
                                width: Int,
                                height: Int) -> [ColoredPoint] {
        guard width > 0, height > 0, depthValues.count >= width * height else { return [] }

        let fx = intrinsics[0][0]
        let fy = intrinsics[1][1]
        let cx = intrinsics[2][0]
        let cy = intrinsics[2][1]

        // 世界坐标 ← 相机坐标 的变换（视图矩阵的逆）
        let worldFromCamera = viewMatrix.inverse

        var points: [ColoredPoint] = []
        points.reserveCapacity(min(maxPointsPerFrame, (width / samplingStep) * (height / samplingStep)))

        for y in stride(from: 0, to: height, by: samplingStep) {
            for x in stride(from: 0, to: width, by: samplingStep) {
                let depth = depthValues[y * width + x]

                // 只保留合理距离内的有效深度
                guard depth.isFinite, depth > 0.2, depth < 6.0 else { continue }

                // 相机坐标（深度图沿相机 -Z 方向，ARKit +Z 指向后方）
                let cam = SIMD4<Float>((Float(x) - cx) / fx * depth,
                                       (Float(y) - cy) / fy * depth,
                                       -depth,
                                       1)

                let world = (worldFromCamera * cam).xyz
                if !world.x.isFinite || !world.y.isFinite || !world.z.isFinite { continue }

                points.append(ColoredPoint(position: world, color: .meshGray))
                if points.count >= maxPointsPerFrame { return points }
            }
        }
        return points
    }
}

// MARK: - SIMD 辅助

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}