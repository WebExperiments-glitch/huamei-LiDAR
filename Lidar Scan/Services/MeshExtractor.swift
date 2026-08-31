//
//  MeshExtractor.swift
//  Lidar Scan (二次开发)
//
//  从 ARMeshAnchor 提取网格数据。
//
//  ⚠️ 关键安全约束：
//  ARMeshAnchor 的 geometry 缓冲由 ARKit 内部工作线程持续更新，
//  **只在 ARSessionDelegate 回调（didAdd / didUpdate）内部**读取才是安全的。
//  本模块提供 snapshot(of:) 在回调窗口内把 bufffer 深拷贝为纯 Swift 值，
//  之后（后台线程/结束扫描）只允许使用这些已拷贝的值。
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
    /// 此后可安全地在任意线程使用返回的值。
    /// 含防御性校验：异常几何量级会被忽略（返回空快照），不参与后续流程。
    static func snapshot(of anchor: ARMeshAnchor) -> MeshAnchorSnapshot {
        let geometry = anchor.geometry
        let vertexCount = geometry.vertices.count
        // 防御：数量异常（0 或超大）视为无效锚点，直接返回空快照
        guard vertexCount > 0, vertexCount <= 5_000_000 else {
            return MeshAnchorSnapshot(identifier: anchor.identifier,
                                      transform: anchor.transform,
                                      vertices: [],
                                      normals: [],
                                      faces: [])
        }

        var vertices = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        var normals = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        var faces: [UInt32] = []

        // 顶点（深拷贝为纯 Swift 数组）
        let vertexPtr = geometry.vertices.buffer.contents()
            .advanced(by: geometry.vertices.offset)
            .assumingMemoryBound(to: SIMD3<Float>.self)
        for i in 0..<vertexCount { vertices[i] = vertexPtr[i] }

        // 法线（可能存在也可能为空）
        if geometry.normals.count == vertexCount {
            let normalPtr = geometry.normals.buffer.contents()
                .advanced(by: geometry.normals.offset)
                .assumingMemoryBound(to: SIMD3<Float>.self)
            for i in 0..<vertexCount { normals[i] = normalPtr[i] }
        }

        // 面索引（仅支持 4 字节索引）
        let faceCount = geometry.faces.count
        let indicesPerFace = geometry.faces.indexCountPerPrimitive
        if faceCount > 0, indicesPerFace > 0, geometry.faces.bytesPerIndex == 4 {
            let total = faceCount * indicesPerFace
            faces.reserveCapacity(total)
            let ptr = geometry.faces.buffer.contents().assumingMemoryBound(to: UInt32.self)
            for i in 0..<total {
                let index = ptr[i]
                if Int(index) < vertexCount {   // 防御：丢弃越界索引
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