//
//  TSDFReconstruction.swift
//  Lidar Scan (二次开发)
//
//  「深度图 → 体素融合(TSDF) → 表面提取」端上重建引擎（对标 Polycam 端上链路）。
//  - 只读 sceneDepth（CVPixelBuffer 线程安全通道）+ 值类型矩阵，绝不触碰 ARKit GPU 缓冲
//  - 全部内存（体素场）由本模块分配并管理，生命周期可控，杜绝 SIGSEGV
//  - 表面提取采用 Surface-Nets（无查找表，稳健）；后续可无缝升级 Marching Cubes
//

import Foundation
import CoreVideo
import simd

enum TSDFReconstruction {

    // MARK: - 参数

    /// 体积分辨率（体素数/边），192³ ≈ 1.5cm/体素 @3m 场景
    private static let dimension = 192
    /// 场景边长（米）
    private static let sizeMeters: Float = 3.0
    /// 体素边长
    private static let voxelSize: Float = sizeMeters / Float(dimension)
    /// TSDF 截断距离（体素个数），工业标定 ≈5-6
    private static let truncationVoxels = 6
    /// 权重封顶（防数值溢出/模型僵化，形成滑动记忆窗）
    private static let maxWeight: Float = 20
    /// 提取前最小权重阈值（低于此视为噪声体素，置空）
    private static let minConfidentWeight: Float = 2
    /// 置信度阈值：仅融合 medium(85) 及以上的深度像素
    private static let confidenceThreshold: UInt8 = 85
    /// 深度采样步长（帧内每隔 n 像素）
    private static let samplingStep = 2
    /// 帧数上限
    private static let frameLimit = 90

    // MARK: - 入口

    /// 用一批关键帧重建网格（世界坐标）。空数据抛 noMeshData。
    static func reconstruct(from frames: [KeyFrameSnapshot]) throws -> ScanMeshData {
        let usedFrames = Array(frames.prefix(frameLimit))
        guard !usedFrames.isEmpty,
              let first = usedFrames.first else { throw ScanExportError.noMeshData }

        // 以第一帧相机位置为场景中心原点
        let cameraWorld = cameraPosition(of: first.viewMatrix)
        let origin = cameraWorld - SIMD3<Float>(sizeMeters / 2,
                                                sizeMeters / 2,
                                                sizeMeters / 2)

        var volume = TSDFVolume(origin: origin,
                                voxelSize: voxelSize,
                                dimension: dimension)

        for frame in usedFrames {
            volume.integrate(frame)
        }

        let mesh = volume.extractSurface()
        guard !mesh.vertices.isEmpty else { throw ScanExportError.noMeshData }
        return mesh
    }

    private static func cameraPosition(of viewMatrix: simd_float4x4) -> SIMD3<Float> {
        let worldFromCamera = viewMatrix.inverse
        let p = worldFromCamera * SIMD4<Float>(0, 0, 0, 1)
        return SIMD3(p.x, p.y, p.z)
    }
}

// MARK: - 体素场

private struct TSDFVolume {
    let origin: SIMD3<Float>
    let voxelSize: Float
    let dimension: Int

    // 融合/提取参数（与 TSDFReconstruction 保持一致）
    private static let samplingStep = 2
    private static let confidenceThreshold: UInt8 = 85
    private static let truncationVoxels = 6
    private static let maxWeight: Float = 20
    private static let minConfidentWeight: Float = 2

    private var tsdf: [Float]
    private var weight: [Float]

    init(origin: SIMD3<Float>, voxelSize: Float, dimension: Int) {
        self.origin = origin
        self.voxelSize = voxelSize
        self.dimension = dimension
        let count = dimension * dimension * dimension
        self.tsdf = [Float](repeating: 1.0, count: count)   // 未融合＝表面外
        self.weight = [Float](repeating: 0, count: count)
    }

    private func index(_ i: Int, _ j: Int, _ k: Int) -> Int {
        (i * dimension + j) * dimension + k
    }

    private func inBounds(_ i: Int, _ j: Int, _ k: Int) -> Bool {
        i >= 0 && j >= 0 && k >= 0 && i < dimension && j < dimension && k < dimension
    }

    private func voxelIndex(of world: SIMD3<Float>) -> SIMD3<Int> {
        SIMD3(Int((world.x - origin.x) / voxelSize),
              Int((world.y - origin.y) / voxelSize),
              Int((world.z - origin.z) / voxelSize))
    }

    private func voxelCenter(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> {
        SIMD3(origin.x + (Float(i) + 0.5) * voxelSize,
              origin.y + (Float(j) + 0.5) * voxelSize,
              origin.z + (Float(k) + 0.5) * voxelSize)
    }

    // MARK: 融合单帧

    mutating func integrate(_ frame: KeyFrameSnapshot) {
        let width = frame.width
        let height = frame.height
        let depthValues = frame.depthValues
        guard width > 0, height > 0, depthValues.count >= width * height else { return }
        let confidences = frame.confidences   // 可选；行紧凑与深度一致

        let intrinsics = frame.intrinsics
        let fx = intrinsics[0][0]
        let fy = intrinsics[1][1]
        let cx = intrinsics[2][0]
        let cy = intrinsics[2][1]

        let worldFromCamera = frame.viewMatrix.inverse
        let cameraWorld = (worldFromCamera * SIMD4<Float>(0, 0, 0, 1)).xyz

        let tau = voxelSize * Float(Self.truncationVoxels)
        let step = voxelSize

        for y in stride(from: 0, to: height, by: Self.samplingStep) {
            for x in stride(from: 0, to: width, by: Self.samplingStep) {
                let p = y * width + x

                // 置信度过滤：低于 medium(85) 的深度像素不可靠，跳过
                if let confidences = confidences {
                    guard confidences[p] >= Self.confidenceThreshold else { continue }
                }

                let depthValue = depthValues[p]
                guard depthValue.isFinite, depthValue > 0.2, depthValue < 5.5 else { continue }

                // 像素 → 相机坐标 → 世界坐标
                let camPoint = SIMD4<Float>((Float(x) - cx) / fx * depthValue,
                                            (Float(y) - cy) / fy * depthValue,
                                            depthValue,
                                            1)
                let surfacePoint = (worldFromCamera * camPoint).xyz
                guard surfacePoint.x.isFinite, surfacePoint.y.isFinite, surfacePoint.z.isFinite else { continue }

                // 沿视线双侧（表面两侧截断区）更新 TSDF
                let dir = simd_normalize(surfacePoint - cameraWorld)
                var s: Float = step
                while s <= tau {
                    // 表面朝向相机侧（sdf 为正）
                    updateVoxel(at: surfacePoint - dir * s, sdf: s / tau)
                    // 表面背向相机侧（sdf 为负）
                    updateVoxel(at: surfacePoint + dir * s, sdf: -s / tau)
                    s += step
                }
            }
        }
    }

    private mutating func updateVoxel(at world: SIMD3<Float>, sdf: Float) {
        let idx3 = voxelIndex(of: world)
        guard inBounds(idx3.x, idx3.y, idx3.z), sdf >= -1, sdf <= 1 else { return }
        let i = index(idx3.x, idx3.y, idx3.z)
        let w = min(weight[i] + 1, Self.maxWeight)   // 权重封顶，防溢出/僵化
        tsdf[i] = (tsdf[i] * weight[i] + sdf) / w
        weight[i] = w
    }

    // MARK: 表面提取（Surface-Nets，双面）

    mutating func extractSurface() -> ScanMeshData {
        let d = dimension
        let count = d * d * d

        // 提取前：低权重体素视为噪声（稀疏观测/抖动），置为空 ['表面外'=1]
        for i in 0..<count where weight[i] < Self.minConfidentWeight {
            tsdf[i] = 1
        }

        // 第 1 遍：每个“跨零”体素生成一个顶点
        var vertexAt = [Int32](repeating: -1, count: count)
        var positions: [SIMD3<Float>] = []

        for i in 0..<d {
            for j in 0..<d {
                for k in 0..<d {
                    let corner = voxelCorners(i, j, k)
                    let neg = corner.min() ?? 0
                    let pos = corner.max() ?? 0
                    guard neg <= 0, pos > 0 else { continue }   // 8 角不全同号 → 跨零

                    // 12 条边插值交点，取均值作顶点（稳健）
                    var sum = SIMD3<Float>(0, 0, 0)
                    var n = 0
                    let c = corner
                    let v = [voxelCenter(i, j, k), voxelCenter(i + 1, j, k),
                             voxelCenter(i + 1, j + 1, k), voxelCenter(i, j + 1, k),
                             voxelCenter(i, j, k + 1), voxelCenter(i + 1, j, k + 1),
                             voxelCenter(i + 1, j + 1, k + 1), voxelCenter(i, j + 1, k + 1)]
                    let edges: [(Int, Int)] = [(0,1),(1,2),(2,3),(3,0),(4,5),(5,6),(6,7),(7,4),(0,4),(1,5),(2,6),(3,7)]
                    for (a, b) in edges {
                        let va = c[a], vb = c[b]
                        if (va <= 0 && vb > 0) || (va > 0 && vb <= 0) {
                            let t = va / (va - vb)          // 线性插值
                            sum += v[a] + (v[b] - v[a]) * t
                            n += 1
                        }
                    }
                    if n > 0 {
                        vertexAt[index(i, j, k)] = Int32(positions.count)
                        positions.append(sum / Float(n))
                    }
                }
            }
        }

        // 第 2 遍：表面连接 —— 某立方体单元四角体素都有顶点即成面（Surface-Nets）
        var mesh = ScanMeshData()
        mesh.vertices = positions
        mesh.normals = [SIMD3<Float>](repeating: .zero, count: positions.count)

        func vertex(_ i: Int, _ j: Int, _ k: Int) -> Int32 {
            if i < 0 || j < 0 || k < 0 || i >= d || j >= d || k >= d { return -1 }
            return vertexAt[index(i, j, k)]
        }

        func emitQuad(_ a0: Int32, _ b0: Int32, _ c0: Int32, _ d0: Int32) {
            mesh.faces.append(UInt32(a0)); mesh.faces.append(UInt32(b0)); mesh.faces.append(UInt32(c0))
            mesh.faces.append(UInt32(c0)); mesh.faces.append(UInt32(d0)); mesh.faces.append(UInt32(a0))
            // 双面（规避 winding 问题）
            mesh.faces.append(UInt32(a0)); mesh.faces.append(UInt32(c0)); mesh.faces.append(UInt32(b0))
            mesh.faces.append(UInt32(c0)); mesh.faces.append(UInt32(a0)); mesh.faces.append(UInt32(d0))
        }

        for i in 0..<d {
            for j in 0..<d {
                for k in 0..<d {
                    let v0 = vertex(i, j, k)
                    guard v0 >= 0 else { continue }

                    // 沿 +x 方向的单元：四角 (i,j,k)(i+1,j,k)(i+1,j+1,k)(i,j+1,k)
                    let v1x = vertex(i + 1, j, k)
                    let v2x = vertex(i + 1, j + 1, k)
                    let v3x = vertex(i, j + 1, k)
                    if v1x >= 0, v2x >= 0, v3x >= 0 {
                        emitQuad(v0, v1x, v2x, v3x)
                    }

                    // 沿 +y 方向的单元：(i,j,k)(i,j+1,k)(i,j+1,k+1)(i,j,k+1)
                    let v1y = vertex(i, j + 1, k)
                    let v2y = vertex(i, j + 1, k + 1)
                    let v3y = vertex(i, j, k + 1)
                    if v1y >= 0, v2y >= 0, v3y >= 0 {
                        emitQuad(v0, v1y, v2y, v3y)
                    }

                    // 沿 +z 方向的单元：(i,j,k)(i,j,k+1)(i+1,j,k+1)(i+1,j,k)
                    let v1z = vertex(i, j, k + 1)
                    let v2z = vertex(i + 1, j, k + 1)
                    let v3z = vertex(i + 1, j, k)
                    if v1z >= 0, v2z >= 0, v3z >= 0 {
                        emitQuad(v0, v1z, v2z, v3z)
                    }
                }
            }
        }

        // 法线补齐
        if mesh.faceCount > 0 {
            var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
            var f = 0
            while f + 2 < mesh.faces.count {
                let a = Int(mesh.faces[f]), b = Int(mesh.faces[f + 1]), c = Int(mesh.faces[f + 2])
                if a < positions.count, b < positions.count, c < positions.count {
                    let ab = positions[b] - positions[a]
                    let ac = positions[c] - positions[a]
                    var n = SIMD3(ab.y * ac.z - ab.z * ac.y,
                                  ab.z * ac.x - ab.x * ac.z,
                                  ab.x * ac.y - ab.y * ac.x)
                    let len = simd_length(n)
                    if len > 1e-6 { n /= len }
                    normals[a] += n; normals[b] += n; normals[c] += n
                }
                f += 3
            }
            for i in 0..<normals.count {
                let len = simd_length(normals[i])
                if len > 1e-6 { normals[i] /= len }
            }
            mesh.normals = normals
        }
        return mesh
    }

    /// 某体素某方向的共享面是否跨越表面（4 角正负混合）——（保留备用）
    /// 体素 8 角 TSDF（顺序：底面 0-3，顶面 4-7）
    private func voxelCorners(_ i: Int, _ j: Int, _ k: Int) -> [Float] {
        func value(_ ii: Int, _ jj: Int, _ kk: Int) -> Float {
            if inBounds(ii, jj, kk) { return tsdf[index(ii, jj, kk)] }
            return 1
        }
        return [value(i, j, k), value(i + 1, j, k), value(i + 1, j + 1, k), value(i, j + 1, k),
                value(i, j, k + 1), value(i + 1, j, k + 1), value(i + 1, j + 1, k + 1), value(i, j + 1, k + 1)]
    }
}

// MARK: - SIMD 辅助

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}