//
//  MeshExtractor.swift
//  Lidar Scan (二次开发)
//
//  从 ARMeshAnchor 提取网格数据。
//
//  ⚠️ 关键安全约束（iPadOS 26/27 实测）：
//  1. ARMeshAnchor 的 geometry 缓冲由 ARKit 内部多线程持续更新 + 替换。
//  2. 每次属性访问（geometry.vertices / .buffer）都可能拿到不同对象——
//     因此「查长度的 buffer」与「读数据的 buffer」必须是同一个强引用，
//     否则长度校验对不上指针，照旧越界（SIGSEGV）。
//  3. 持有强引用的 MTLBuffer，Metal 保证其 contents() 映射在对象存活期有效。
//     宁可读到稍旧的数据，也绝不冒险裸读。
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
    /// 关键：所有 source/buffer 先取强引用到局部，再基于同一对象校验+读取。
    static func snapshot(of anchor: ARMeshAnchor) -> MeshAnchorSnapshot {
        let geometry = anchor.geometry

        // ══ 顶点 ══
        // 一次取强引用：source、buffer、常量都来自同一对象
        let vertexSource = geometry.vertices
        let vertexBuffer = vertexSource.buffer
        let vertexStride = vertexSource.stride
        let vertexOffset = vertexSource.offset
        let declaredCount = vertexSource.count

        // 用「count ≤ buffer 实际能容纳的数量」双向钳制
        let capacityCount = vertexStride > 0 ? vertexBuffer.length / vertexStride : 0
        let vertexCount = min(declaredCount, capacityCount)
        guard vertexCount > 0, vertexCount <= 5_000_000 else {
            return emptySnapshot(of: anchor)
        }

        var vertices = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        // 同一 buffer 对象上校验 offset + 字节数 <= length
        if vertexOffset + vertexCount * vertexStride <= vertexBuffer.length {
            let ptr = vertexBuffer.contents()
                .advanced(by: vertexOffset)
                .assumingMemoryBound(to: SIMD3<Float>.self)
            for i in 0..<vertexCount { vertices[i] = ptr[i] }
        } else {
            return emptySnapshot(of: anchor)
        }

        // ══ 法线 ══
        var normals = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        let normalSource = geometry.normals
        let normalBuffer = normalSource.buffer
        let normalStride = normalSource.stride
        let normalCapacity = normalStride > 0 ? normalBuffer.length / normalStride : 0
        if normalSource.count >= vertexCount, normalCapacity >= vertexCount {
            let normalOffset = normalSource.offset
            if normalOffset + vertexCount * normalStride <= normalBuffer.length {
                let ptr = normalBuffer.contents()
                    .advanced(by: normalOffset)
                    .assumingMemoryBound(to: SIMD3<Float>.self)
                for i in 0..<vertexCount { normals[i] = ptr[i] }
            }
        }

        // ══ 面索引 ══
        var faces: [UInt32] = []
        let faceSource = geometry.faces
        let faceBuffer = faceSource.buffer
        if faceSource.bytesPerIndex == 4,
           faceSource.indexCountPerPrimitive > 0,
           faceSource.count > 0 {
            let total = faceSource.count * faceSource.indexCountPerPrimitive
            let capacityIndices = faceBuffer.length / 4
            let safeTotal = min(total, capacityIndices)          // 双向钳制
            faces.reserveCapacity(safeTotal)
            let ptr = faceBuffer.contents().assumingMemoryBound(to: UInt32.self)
            for i in 0..<safeTotal {
                let index = ptr[i]
                if Int(index) < vertexCount {                    // 丢越界索引
                    faces.append(index)
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