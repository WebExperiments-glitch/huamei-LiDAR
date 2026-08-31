//
//  MeshExtractor.swift
//  Lidar Scan (二次开发)
//
//  从 ARMeshAnchor 提取网格数据。
//
//  ⚠️ 关键安全约束：
//  1. ARMeshAnchor 的 geometry 缓冲由 ARKit 内部线程持续更新，只在
//     ARSessionDelegate 回调（didAdd / didUpdate）内读取，并立即深拷贝。
//  2. 即使是回调窗口内，缓冲也正在被系统重建 —— 任何指针访问都必须
//     先用 MTLBuffer 的真实 length 校验边界，越界一律跳过而非读取。
//     这是防 SIGSEGV 指针越界的最后一道闸。
//

import ARKit
import simd

enum MeshExtractor {

    /// 单个锚点在某个回调窗口内的深拷贝快照
    struct MeshAnchorSnapshot {
        let identifier: UUID
        let transform: simd_float4x4
        let vertices: [SIMD3<Float>]
        let normals: [SIMD3<Float>]
        let faces: [UInt32]
    }

    /// 在 ARSessionDelegate 回调内调用：把 anchor 的几何深拷贝出来。
    /// 之后可安全地在任意线程使用返回的值。
    /// 所有 buffer 访问都先做边界校验，异常/越界一律返回空快照，绝不裸读。
    static func snapshot(of anchor: ARMeshAnchor) -> MeshAnchorSnapshot {
        let geometry = anchor.geometry
        let vertexCount = geometry.vertices.count

        // 防御 1：数量异常（0 / 超大）视为无效
        guard vertexCount > 0, vertexCount <= 5_000_000 else {
            return emptySnapshot(of: anchor)
        }

        var vertices = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        var normals = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        var faces: [UInt32] = []

        // 防御 2：顶点缓冲边界校验（offset + 期望字节数 <= 实际 length）
        let vertexBytes = geometry.vertices.stride * vertexCount
        if vertexBytes > 0,
           geometry.vertices.offset + vertexBytes <= geometry.vertices.buffer.length {
            let vertexPtr = geometry.vertices.buffer.contents()
                .advanced(by: geometry.vertices.offset)
                .assumingMemoryBound(to: SIMD3<Float>.self)
            for i in 0..<vertexCount { vertices[i] = vertexPtr[i] }
        } else {
            // 缓冲被系统收缩/替换，读它会越界 → 放弃本锚点
            return emptySnapshot(of: anchor)
        }

        // 防御 3：法线缓冲边界校验（存在性 + 长度）
        if geometry.normals.count == vertexCount {
            let normalBytes = geometry.normals.stride * vertexCount
            if normalBytes > 0,
               geometry.normals.offset + normalBytes <= geometry.normals.buffer.length {
                let normalPtr = geometry.normals.buffer.contents()
                    .advanced(by: geometry.normals.offset)
                    .assumingMemoryBound(to: SIMD3<Float>.self)
                for i in 0..<vertexCount { normals[i] = normalPtr[i] }
            }
        }

        // 防御 4：面索引边界校验（仅支持 4 字节索引，元素缓冲无 offset）
        let faceCount = geometry.faces.count
        let indicesPerFace = geometry.faces.indexCountPerPrimitive
        if faceCount > 0, indicesPerFace > 0, geometry.faces.bytesPerIndex == 4 {
            let total = faceCount * indicesPerFace
            let indexBytes = geometry.faces.bytesPerIndex * total
            if indexBytes <= geometry.faces.buffer.length {
                faces.reserveCapacity(total)
                let ptr = geometry.faces.buffer.contents().assumingMemoryBound(to: UInt32.self)
                for i in 0..<total {
                    let index = ptr[i]
                    if Int(index) < vertexCount {   // 防御：丢弃越界索引
                        faces.append(index)
                    }
                }
            }
        }

        return MeshAnchorSnapshot(identifier: anchor.identifier,
                                  transform: anchor.transform,
                                  vertices: vertices,
                                  normals: normals,
                                  faces: faces)
    }

    /// 生成空快照（buildMesh 会跳过它）
    private static func emptySnapshot(of anchor: ARMeshAnchor) -> MeshAnchorSnapshot {
        MeshAnchorSnapshot(identifier: anchor.identifier,
                           transform: anchor.transform,
                           vertices: [],
                           normals: [],
                           faces: [])
    }

    /// 把若干锚点快照合并成一个统一的网格数据集（世界坐标、全局索引）。
    /// 只使用已深拷贝的值，可在任意线程安全调用。
    static func buildMesh(from snapshots: [MeshAnchorSnapshot]) -> ScanMeshData {
        var data = ScanMeshData()
        // 排序保证合并顺序稳定
        let ordered = snapshots.sorted { $0.identifier.uuidString < $1.identifier.uuidString }

        for snapshot in ordered {
            let vertexCount = snapshot.vertices.count
            guard vertexCount > 0 else { continue }

            let globalBase = UInt32(data.vertices.count)
            for i in 0..<vertexCount {
                let local = snapshot.vertices[i]
                let world = snapshot.transform * SIMD4<Float>(local.x, local.y, local.z, 1)
                data.vertices.append(SIMD3(world.x, world.y, world.z))
                if i < snapshot.normals.count {
                    data.normals.append(snapshot.normals[i])
                } else {
                    data.normals.append(.zero)
                }
            }

            for index in snapshot.faces {
                if Int(index) < snapshot.vertices.count {   // 防御：丢弃越界索引
                    data.faces.append(index + globalBase)
                }
            }
        }
        return data
    }
}