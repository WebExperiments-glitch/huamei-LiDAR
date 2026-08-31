//
//  ScanFileExporter.swift
//  Lidar Scan (二次开发)
//
//  导出协调器：负责目录、文件名、纹理着色、多格式写出与深度图附带。
//

import Foundation
import ARKit

struct ScanFileExporter {
    static let folderName = "SCANS"

    /// 支持在列表页展示的模型扩展名
    static let modelExtensions: Set<String> = ["obj", "ply", "stl", "glb", "usdz"]

    // MARK: - 目录

    static func scanDirectory() -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first else { return nil }
        let folder = documents.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder,
                                                 withIntermediateDirectories: true,
                                                 attributes: nil)
        return folder
    }

    /// 列出所有模型文件（含扩展名与大小）
    static func listModelFiles() -> [URL] {
        guard let folder = scanDirectory() else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder,
                                                                      includingPropertiesForKeys: keys) else {
            return []
        }
        return urls
            .filter { modelExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - 主流程

    static func run(data: ScanMeshData,
                    options: ExportOptions,
                    snapshot: FrameSnapshot?) throws -> ExportResult {
        guard !data.isEmpty else { throw ScanExportError.noMeshData }
        guard let folder = scanDirectory() else {
            throw ScanExportError.exportFailed("无法访问文档目录")
        }

        // 1) 需要颜色时，先给顶点采样相机颜色
        var mesh = data
        if options.textured, options.format.supportsColor,
           let colors = TextureMapper.sampleColors(vertices: data.vertices, snapshot: snapshot) {
            mesh.colors = colors
        }

        // 2) 确定文件名（去重，含扩展名避免异格式覆盖）
        let baseName = uniqueBaseName(raw: options.fileName, ext: options.format.fileExtension, in: folder)
        let fileURL = folder.appendingPathComponent(baseName + "." + options.format.fileExtension)

        // 3) 写模型文件
        try MeshWriter.write(mesh, kind: options.contentKind, format: options.format, to: fileURL)

        var urls: [URL] = [fileURL]

        // 4) 附带导出深度图 / 置信度
        if options.exportDepth {
            if let depth = snapshot?.depthMap {
                let depthURL = folder.appendingPathComponent(baseName + "_depth.png")
                try? DepthExporter.writeDepthMap(depth, to: depthURL)
                urls.append(depthURL)
            }
            if let confidence = snapshot?.confidenceMap {
                let confURL = folder.appendingPathComponent(baseName + "_confidence.png")
                try? DepthExporter.writeConfidenceMap(confidence, to: confURL)
                urls.append(confURL)
            }
        }

        return ExportResult(urls: urls)
    }

    // MARK: - 命名工具

    /// 文件名清洗：去掉非法字符
    static func sanitize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let illegal = CharacterSet(charactersIn: "/\\:?*\"<>|")
        var name = trimmed.unicodeScalars.map { illegal.contains($0) ? "-" : String($0) }.joined()
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        return name
    }

    /// 生成唯一文件名（存在则追加 -2 / -3 …）
    static func uniqueBaseName(raw: String, ext: String, in folder: URL) -> String {
        let base = raw.isEmpty ? defaultName() : sanitize(raw)
        var candidate = base
        var counter = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate + "." + ext).path) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }

    static func defaultName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "Scan_\(formatter.string(from: Date()))"
    }
}

// MARK: - 文件元数据

struct ScanFileItem: Identifiable, Hashable, Equatable {
    let url: URL
    let name: String
    let sizeText: String
    let format: ScanExportFormat?

    var id: String { url.path }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url.path)
    }

    init(url: URL) {
        self.url = url
        self.name = url.deletingPathExtension().lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        self.sizeText = Int64(size).fileSizeText
        if let format = ScanExportFormat(rawValue: url.pathExtension.uppercased()) {
            self.format = format
        } else {
            self.format = nil
        }
    }
}