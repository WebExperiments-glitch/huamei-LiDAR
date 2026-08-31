//
//  MeshExtractor.swift
//  Lidar Scan (二次开发)
//
//  把 ARKit 的 ARMeshAnchor 集合抽取为统一的 ScanMeshData
//  （顶点已转换到世界坐标，面索引已重映射为全局索引）。
//

import ARKit
import simd

enum MeshExtractor {
    /// 抽取所有锚点并合并成一个网格数据集
    static func extract(from anchors: [ARMeshAnchor]) -> ScanMeshData {
        var data = ScanMeshData()

        for anchor in anchors {
            let geometry = anchor.geometry
            let vertexCount = geometry.vertices.count
            guard vertexCount > 0 else { continue }

            let vertexBase = geometry.vertices.buffer.contents().advanced(by: geometry.vertices.offset)
            let vertexPtr = vertexBase.assumingMemoryBound(to: SIMD3<Float>.self)

            // ARKit 网格自带法线；缺失时补零，由导出层自行兜底
            let hasNormals = geometry.normals.count == vertexCount
            let normalPtr: UnsafePointer<SIMD3<Float>>? = hasNormals
                ? geometry.normals.buffer.contents().advanced(by: geometry.normals.offset).assumingMemoryBound(to: SIMD3<Float>.self)
                : nil

            let globalBase = UInt32(data.vertices.count)

            for i in 0..<vertexCount {
                let local = vertexPtr[i]
                let world = anchor.transform * SIMD4<Float>(local.x, local.y, local.z, 1)
                data.vertices.append(SIMD3(world.x, world.y, world.z))
                data.normals.append(normalPtr?[i] ?? .zero)
            }

            // 面索引
            let faceCount = geometry.faces.count
            let indicesPerFace = geometry.faces.indexCountPerPrimitive
            guard faceCount > 0, indicesPerFace > 0,
                  geometry.faces.bytesPerIndex == 4 else { continue }

            let indexPtr = geometry.faces.buffer.contents().assumingMemoryBound(to: UInt32.self)
            let total = faceCount * indicesPerFace
            for j in 0..<total {
                data.faces.append(indexPtr[j] + globalBase)
            }
        }

        return data
    }
}