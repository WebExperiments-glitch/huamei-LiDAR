//
//  PLYParser.swift
//  Lidar Scan (二次开发)
//
//  把 .PLY 文件解析回 ScanMeshData（支持 ASCII，带 RGB 顶点色）。
//  预览页加载点云 / 转换导出时使用。
//

import Foundation
import simd

enum PLYParserError: LocalizedError {
    case invalidFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidFile(let reason): return "PLY 文件无效：\(reason)"
        }
    }
}

enum PLYParser {
    static func parse(url: URL) throws -> ScanMeshData {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw PLYParserError.invalidFile("无法读取文件")
        }

        var data = ScanMeshData()
        var inHeader = true
        var vertexCount = 0
        var faceCount = 0
        var readVertices = 0

        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if inHeader {
                if line.hasPrefix("element vertex") {
                    let parts = line.split(separator: " ")
                    if parts.count >= 3, let n = Int(parts[2]) {
                        vertexCount = n
                        data.vertices.reserveCapacity(n)
                    }
                } else if line.hasPrefix("element face") {
                    let parts = line.split(separator: " ")
                    if parts.count >= 3, let n = Int(parts[2]) {
                        faceCount = n
                    }
                } else if line == "end_header" {
                    inHeader = false
                }
                continue
            }

            // 数据区
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard !parts.isEmpty else { continue }

            if parts[0] == "3", parts.count == 4 {
                // 面：list uchar int vertex_indices
                guard readVertices > 0, let a = Int(parts[1]), let b = Int(parts[2]), let c = Int(parts[3]) else { continue }
                if a < readVertices, b < readVertices, c < readVertices {
                    data.faces.append(UInt32(a))
                    data.faces.append(UInt32(b))
                    data.faces.append(UInt32(c))
                }
                continue
            }

            // 顶点行：x y z [r g b]
            guard parts.count >= 3,
                  let x = Float(String(parts[0])),
                  let y = Float(String(parts[1])),
                  let z = Float(String(parts[2])) else { continue }

            data.vertices.append(SIMD3(x, y, z))
            data.normals.append(.zero)
            if parts.count >= 6,
               let r = Float(String(parts[3])),
               let g = Float(String(parts[4])),
               let b = Float(String(parts[5])) {
                // PLY RGB 是 0-255，归一化
                if data.colors == nil {
                    data.colors = [SIMD3<Float>](repeating: .meshGray, count: data.vertices.count - 1)
                }
                data.colors?.append(SIMD3(r / 255, g / 255, b / 255))
            } else if data.colors != nil {
                data.colors?.append(.meshGray)
            }
            readVertices += 1
        }

        guard !data.vertices.isEmpty else {
            throw PLYParserError.invalidFile("没有读到任何顶点")
        }
        if data.colors?.count != data.vertices.count {
            data.colors = nil
        }
        _ = faceCount
        return data
    }
}