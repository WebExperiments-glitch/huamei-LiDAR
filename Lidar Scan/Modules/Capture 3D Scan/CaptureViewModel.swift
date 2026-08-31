//
//  CaptureViewModel.swift
//  Lidar Scan (二次开发)
//
//  扫描会话管理（B 计划 / 深度图通道）：
//  不再读取 ARMeshAnchor 的 GPU 缓冲（M2 上会导致 SIGSEGV），
//  只采集 sceneDepth 深度图 + 相机位姿（CVPixelBuffer 线程安全通道），
//  结束时在 CPU 上反投影成世界点云并落盘 PLY。
//

import SwiftUI
import UIKit
import RealityKit
import ARKit
import CoreVideo

@MainActor
final class CaptureViewModel: NSObject, ObservableObject {
    // MARK: - 发布状态

    @Published var isSessionRunning = true
    @Published var isFinished = false
    @Published var isProcessing = false
    @Published var didFinishScan = false
    @Published var isExporting = false
    @Published var statusMessage: String?
    @Published var alertMessage: String?

    // MARK: - AR 视图

    let arView = ARView(frame: .zero)

    private var currentConfiguration: ARWorldTrackingConfiguration?
    private var didStartSession = false

    // MARK: - 采集缓存（纯值 + 线程安全缓冲）

    /// 关键帧（深度图 + 位姿），用于重建点云
    private var keyFrames: [KeyFrameSnapshot] = []
    /// 最近一帧（含相机图像），用于点云上色与深度图导出
    private var latestFrameSnapshot: FrameSnapshot?
    /// 结束扫描时生成的点云（纯 Swift 值）
    private var cachedMeshData: ScanMeshData?
    private var cachedSnapshot: FrameSnapshot?

    // MARK: - 会话控制

    func startSessionIfNeeded() {
        guard !didStartSession else { return }
        didStartSession = true

        keyFrames.removeAll()
        latestFrameSnapshot = nil
        cachedMeshData = nil

        let configuration = ARWorldTrackingConfiguration()
        configuration.environmentTexturing = .automatic
        configuration.planeDetection = [.horizontal, .vertical]
        // B 计划：不启用 sceneReconstruction（mesh），彻底绕开 GPU 缓冲读取
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics = [.sceneDepth]
        }

        arView.automaticallyConfigureSession = false
        arView.session.delegate = self
        arView.session.run(configuration)
        currentConfiguration = configuration
        statusMessage = "请缓慢移动设备，环绕扫描目标"
    }

    /// 暂停 / 继续
    func toggleSession() {
        guard !isFinished else { return }
        if isSessionRunning {
            arView.session.pause()
            isSessionRunning = false
            statusMessage = "已暂停"
        } else {
            if let configuration = currentConfiguration {
                arView.session.run(configuration)
            }
            isSessionRunning = true
            statusMessage = "扫描已继续"
        }
    }

    /// 结束扫描：在主线程收尾，后台反投影成点云并落盘，完成后自动退出
    @discardableResult
    func finishScan() -> Bool {
        guard !isFinished else { return cachedMeshData != nil }
        guard !keyFrames.isEmpty else {
            alertMessage = "还没有采集到深度数据，请先扫描几秒再结束"
            return false
        }
        guard let latest = latestFrameSnapshot else {
            alertMessage = "相机尚未就绪，请稍后再试"
            return false
        }

        let frames = keyFrames
        isFinished = true
        arView.session.pause()
        isSessionRunning = false
        statusMessage = "正在空中三角测量计算…"
        isProcessing = true

        // 后台：关键帧 → TSDF 融合 → 表面网格 → 上色 → 落盘 OBJ。
        // 若重建失败（异常数据/空场），自动降级为深度反投影点云并落盘 PLY，绝不崩溃。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var mesh: ScanMeshData
            var kind: ScanContentKind = .mesh
            do {
                // 主路径：TSDF 重建网格
                mesh = try TSDFReconstruction.reconstruct(from: frames)
                kind = .mesh
            } catch {
                // 降级路径：点云
                let rawPoints = PointCloudGenerator.generate(from: frames)
                guard !rawPoints.isEmpty else {
                    Task { @MainActor in
                        guard let self else { return }
                        self.isProcessing = false
                        self.isFinished = false
                        self.statusMessage = "重建失败，请重试"
                        self.alertMessage = "没有采集到有效深度数据，请重新扫描"
                    }
                    return
                }
                mesh = ScanMeshData()
                mesh.vertices = rawPoints.map { $0.position }
                mesh.colors = rawPoints.map { $0.color }
                kind = .pointCloud
            }

            // 用最近一帧相机画面给模型上色
            if let colors = TextureMapper.sampleColors(vertices: mesh.vertices, snapshot: latest) {
                mesh.colors = colors
            }
            guard !mesh.isEmpty else {
                Task { @MainActor in
                    guard let self else { return }
                    self.isProcessing = false
                    self.isFinished = false
                    self.statusMessage = "模型为空，请重新扫描"
                    self.alertMessage = "扫描数据不足，请重新扫描"
                }
                return
            }

            let options = ExportOptions(fileName: ScanFileExporter.defaultName(),
                                        format: .obj,
                                        contentKind: kind,
                                        textured: false,
                                        exportDepth: false)
            do {
                let result = try ScanFileExporter.run(data: mesh, options: options, snapshot: latest)
                Task { @MainActor in
                    guard let self else { return }
                    self.cachedMeshData = mesh
                    self.cachedSnapshot = latest
                    self.isProcessing = false
                    self.statusMessage = "模型已生成，可导出"
                    self.didFinishScan = true
                    _ = result
                }
            } catch {
                Task { @MainActor in
                    guard let self else { return }
                    self.isProcessing = false
                    self.isFinished = false
                    self.statusMessage = "保存失败，请重试"
                    self.alertMessage = error.localizedDescription
                }
            }
        }
        return true
    }

    /// 重新扫描
    func resumeScan() {
        guard isFinished else { return }
        keyFrames.removeAll()
        latestFrameSnapshot = nil
        cachedMeshData = nil
        cachedSnapshot = nil
        if let configuration = currentConfiguration {
            arView.session.run(configuration)
        }
        isSessionRunning = true
        isFinished = false
        statusMessage = "扫描已继续"
    }

    /// 页面退出时关闭会话
    func pauseForBackground() {
        if isSessionRunning {
            arView.session.pause()
            isSessionRunning = false
        }
    }

    // MARK: - 导出（用结束扫描时生成的点云）

    func export(_ options: ExportOptions) {
        guard !isExporting else { return }
        guard finishScan() else { return }
        guard let meshData = cachedMeshData else {
            alertMessage = "点云数据为空，请重新扫描后再导出"
            return
        }
        let snapshot = cachedSnapshot

        isExporting = true
        statusMessage = "正在导出…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try ScanFileExporter.run(data: meshData,
                                                      options: options,
                                                      snapshot: snapshot)
                Task { @MainActor in
                    guard let self else { return }
                    let names = result.urls.map(\.lastPathComponent).joined(separator: "、")
                    self.statusMessage = "导出完成"
                    self.alertMessage = "已保存：\n\(names)"
                    self.isExporting = false
                }
            } catch {
                Task { @MainActor in
                    guard let self else { return }
                    self.statusMessage = "导出失败"
                    self.alertMessage = error.localizedDescription
                    self.isExporting = false
                }
            }
        }
    }
}

// MARK: - ARSessionDelegate（只读取线程安全的 CVPixelBuffer 通道）

extension CaptureViewModel: ARSessionDelegate {

    /// 关键帧采样间隔
    private static let keyFrameInterval: TimeInterval = 0.25
    /// 关键帧数量上限：采用**循环缓冲**（超出替换最旧帧），
    /// 长时扫描内存恒定（≈240×100KB≈24MB），时长无限也不会增长。
    private static let keyFrameLimit = 240

    private enum DepthSampler {
        static let lock = NSLock()
        static var lastSampleAt: TimeInterval = 0
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let orientation = Self.readInterfaceOrientation()

        // 关键帧采样（节流）。只有采样帧才做深拷贝（image+depth+conf），
        // 其余帧直接跳过，既不空转也不留 CVPixelBuffer 引用给后台。
        let now = ProcessInfo.processInfo.systemUptime
        let shouldSample = DepthSampler.lock.withLock { () -> Bool in
            guard now - DepthSampler.lastSampleAt >= Self.keyFrameInterval else { return false }
            DepthSampler.lastSampleAt = now
            return true
        }
        guard shouldSample else { return }

        // 深拷贝发生在 ARKit 回调线程（缓冲仍活的窗口内），物化成纯 Swift 值
        guard let snapshot = FrameSnapshot.make(from: frame, orientation: orientation),
              let keyFrame = KeyFrameSnapshot.make(from: frame, orientation: orientation) else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.latestFrameSnapshot = snapshot
            if self.keyFrames.count >= Self.keyFrameLimit {
                self.keyFrames.removeFirst()   // 循环缓冲：替换最旧帧
            }
            self.keyFrames.append(keyFrame)
        }
    }

    /// 读取当前界面方向（线程无关）
    private static nonisolated func readInterfaceOrientation() -> UIInterfaceOrientation {
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            return scene.interfaceOrientation
        }
        return .portrait
    }
}

// MARK: - AR 容器视图

struct ARContainerView: UIViewRepresentable {
    @ObservedObject var viewModel: CaptureViewModel

    func makeUIView(context: Context) -> ARView {
        viewModel.startSessionIfNeeded()
        return viewModel.arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // 会话生命周期全部由 CaptureViewModel 管理
    }
}