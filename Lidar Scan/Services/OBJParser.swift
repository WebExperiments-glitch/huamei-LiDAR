//
//  OBJParser.swift
//  Lidar Scan (二次开发)
//
//  把 .OBJ 文件解析回 ScanMeshData，用于在预览页“转导出”其他格式。
//  支持：v / v x y z r g b（顶点色）/ vn / f（含 f v 与 f v//vn 形式）。
//  所有索引都做越界校验，外部坏文件只会报错，不会崩溃。
//

import Foundation
import simd

enum OBJParserError: LocalizedError {
    case invalidFile(String)
    case indexOutOfRange

    var errorDescription: String? {
        switch self {
        case .invalidFile(let reason): return "OBJ 文件无效：\(reason)"
        case .indexOutOfRange: return "OBJ 文件包含越界顶点索引，无法转换"
        }
    }
}

enum OBJParser {
    static func parse(url: URL) throws -> ScanMeshData {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw OBJParserError.invalidFile("无法读取文件")
        }

        var data = ScanMeshData()
        var hasColors = false

        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard let kind = parts.first else { continue }

            switch kind {
            case "v":
                guard parts.count >= 4,
                      let x = Float(String(parts[1])),
                      let y = Float(String(parts[2])),
                      let z = Float(String(parts[3])) else {
                    throw OBJParserError.invalidFile("顶点坐标格式错误")
                }
                data.vertices.append(SIMD3(x, y, z))
                data.normals.append(.zero)
                if parts.count >= 7,
                   let r = Float(String(parts[4])),
                   let g = Float(String(parts[5])),
                   let b = Float(String(parts[6])) {
                    // 顶点色 0…1（v x y z r g b 扩展格式）
                    if data.colors == nil {
                        data.colors = [SIMD3<Float>](repeating: .meshGray, count: data.vertexCount - 1)
                        hasColors = true
                    }
                    data.colors?.append(SIMD3(r, g, b))
                    hasColors = true
                } else if hasColors {
                    data.colors?.append(.meshGray)
                }

            case "vn":
                if parts.count >= 4,
                   let nx = Float(String(parts[1])),
                   let ny = Float(String(parts[2])),
                   let nz = Float(String(parts[3])),
                   data.normals.count > 0 {
                    let index = data.normals.count - 1
                    data.normals[index] = SIMD3(nx, ny, nz)
                }

            case "f":
                guard parts.count >= 4 else {
                    throw OBJParserError.invalidFile("面至少需要 3 个顶点")
                }
                var faceIndices: [UInt32] = []
                faceIndices.reserveCapacity(parts.count - 1)
                for part in parts.dropFirst() {
                    // 支持 "v" / "v/vt" / "v//vn" / "v/vt/vn"
                    let sub = part.split(separator: "/", omittingEmptySubsequences: false)
                    guard let raw = sub.first, let idx = Int(String(raw)) else {
                        throw OBJParserError.invalidFile("面索引格式错误")
                    }
                    let zeroBased: Int
                    if idx < 0 {
                        zeroBased = data.vertexCount + idx      // OBJ 负索引从当前顶点数倒推
                    } else {
                        zeroBased = idx - 1
                    }
                    guard zeroBased >= 0, zeroBased < data.vertexCount else {
                        throw OBJParserError.indexOutOfRange
                    }
                    faceIndices.append(UInt32(zeroBased))
                }
                // 扇形三角化（>3 顶点）
                for i in 1..<(faceIndices.count - 1) {
                    data.faces.append(faceIndices[0])
                    data.faces.append(faceIndices[i])
                    data.faces.append(faceIndices[i + 1])
                }

            default:
                continue
            }
        }

        guard !data.vertices.isEmpty else {
            throw OBJParserError.invalidFile("没有读到任何顶点")
        }
        if data.colors?.count != data.vertexCount {
            data.colors = nil
        }
        return data
    }
}