//
//  Extensions.swift
//  Lidar Scan (二次开发)
//
//  通用小工具：字节流拼接、长度格式化、SIMD 辅助。
//

import Foundation
import simd

// MARK: - Data 字节流（用于 GLB 二进制写入）

extension Data {
    /// 追加一个小端序整数
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    /// 追加一个 Float（小端序，直接按位拷贝）
    mutating func appendFloat(_ value: Float) {
        var v = value
        withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    /// 追加多个 Float
    mutating func appendFloats(_ values: [Float]) {
        values.forEach { appendFloat($0) }
    }

    /// 追加对齐填充（GLB 要求 4 字节对齐）
    mutating func pad4(with byte: UInt8 = 0) {
        while count % 4 != 0 {
            append(byte)
        }
    }
}

// MARK: - 长度 / 时间格式化

extension Float {
    /// 米格式化：如 1.23 m
    var metersText: String {
        String(format: "%.2f m", self)
    }

    /// 字节格式化（用于文件大小显示）
    var fileSizeText: String {
        let b = Double(self)
        if b >= 1024 * 1024 {
            return String(format: "%.1f MB", b / (1024 * 1024))
        }
        if b >= 1024 {
            return String(format: "%.0f KB", b / 1024)
        }
        return String(format: "%.0f B", b)
    }
}

extension Int64 {
    /// 文件大小显示
    var fileSizeText: String {
        Float(self).fileSizeText
    }
}

// MARK: - SIMD 辅助

extension SIMD3 where Scalar == Float {
    /// 0.6 灰（无纹理时默认模型颜色）
    static var meshGray: SIMD3<Float> { SIMD3(repeating: 0.62) }
}