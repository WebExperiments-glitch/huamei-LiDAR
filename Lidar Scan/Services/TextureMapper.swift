//
//  TextureMapper.swift
//  Lidar Scan (二次开发)
//
//  把相机当前帧的颜色采样到网格顶点上（顶点取色）。
//  原理：世界坐标顶点 → 投影到相机像素 → 读取 BGRA 颜色。
//

import ARKit
import CoreVideo
import CoreGraphics
import UIKit
import simd

enum TextureMapper {
    /// 当前界面方向（projectPoint 需要；图片坐标对齐屏幕）
    private static func currentOrientation() -> UIInterfaceOrientation {
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            return scene.interfaceOrientation
        }
        return .portrait
    }

    /// 为每个顶点采样相机颜色；失败或不可见顶点保持 nil（由调用方决定兜底）
    static func sampleColors(vertices: [SIMD3<Float>],
                             snapshot: FrameSnapshot?) -> [SIMD3<Float>]? {
        guard let camera = snapshot?.camera,
              let image = snapshot?.image else { return nil }

        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        guard width > 0, height > 0 else { return nil }

        let viewport = CGSize(width: width, height: height)
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(image) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(image)

        let orientation = currentOrientation()
        var result = [SIMD3<Float>](repeating: .meshGray, count: vertices.count)
        var hitCount = 0

        for i in 0..<vertices.count {
            let projected = camera.projectPoint(vertices[i],
                                                orientation: orientation,
                                                viewportSize: viewport)
            // 只在 z > 0（相机前方）且在画面内的顶点取色
            guard projected.z > 0 else { continue }
            let x = Int(projected.x)
            let y = Int(projected.y)
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