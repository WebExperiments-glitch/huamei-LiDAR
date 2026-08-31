//
//  TextureMapper.swift
//  Lidar Scan (二次开发)
//
//  把相机画面颜色采样到网格顶点上（顶点取色）。
//  投影只用“值类型”的视图矩阵 + 内参（由 FrameSnapshot 在暂停前物化），
//  因此可以安全地在后台线程执行，不会触碰 ARKit 对象的共享内存。
//

import CoreVideo
import CoreGraphics
import simd

enum TextureMapper {
    /// 为每个顶点采样相机颜色；无有效快照时返回 nil（调用方持有灰色兜底）
    static func sampleColors(vertices: [SIMD3<Float>],
                             snapshot: FrameSnapshot?) -> [SIMD3<Float>]? {
        guard let snapshot = snapshot,
              let image = snapshot.image else { return nil }

        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        guard width > 0, height > 0 else { return nil }

        let intrinsics = snapshot.intrinsics
        let viewMatrix = snapshot.viewMatrix

        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(image) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(image)

        // 读取内参（simd_float3x3 按 [列][行] 索引）
        let fx = intrinsics[0][0]
        let fy = intrinsics[1][1]
        let cx = intrinsics[2][0]
        let cy = intrinsics[2][1]

        var result = [SIMD3<Float>](repeating: .meshGray, count: vertices.count)
        var hitCount = 0

        for i in 0..<vertices.count {
            // 世界坐标 → 相机坐标（viewMatrix 已包含界面方向转换）
            let cameraPoint = viewMatrix * SIMD4<Float>(vertices[i].x, vertices[i].y, vertices[i].z, 1)

            // 只在相机前方（z > 0）的顶点取色
            let z = cameraPoint.z
            guard z > 0 else { continue }

            let projectedX = fx * cameraPoint.x / z + cx
            let projectedY = fy * cameraPoint.y / z + cy
            let x = Int(projectedX)
            let y = Int(projectedY)
            guard x >= 0, x < width, y >= 0, y < height else { continue }

            let pixel = base.advanced(by: y * bytesPerRow + x * 4)
            let bytes = pixel.assumingMemoryBound(to: UInt8.self)

            // capturedImage 为 BGRA 布局
            let b = Float(bytes[0]) / 255.0
            let g = Float(bytes[1]) / 255.0
            let r = Float(bytes[2]) / 255.0
            result[i] = SIMD3(r, g, b)
            hitCount += 1
        }

        // 一个像素都没采到（比如相机未就绪）视为失败，返回 nil
        return hitCount > 0 ? result : nil
    }
}