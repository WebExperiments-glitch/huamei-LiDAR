//
//  CaptureViewModel.swift
//  Lidar Scan (二次开发)
//
//  扫描会话管理：负责 ARKit 会话的启动/暂停/网格开关，
//  以及「导出」全流程（快照 → 网格抽取 → 纹理取色 → 多格式写出）。
//

import SwiftUI
import RealityKit
import ARKit
import CoreVideo

@MainActor
final class CaptureViewModel: NSObject, ObservableObject {
    // MARK: - 发布状态

    @Published var isSessionRunning = true
    @Published var showDebugMesh = true
    @Published var isExporting = false
    @Published var statusMessage: String?
    /// 弹窗通知（导出成功 / 失败 / 提示）
    @Published var alertMessage: String?

    // MARK: - AR 视图

    let arView = ARView(frame: .zero)

    private var currentConfiguration: ARWorldTrackingConfiguration?
    private var didStartSession = false

    // MARK: - 会话控制

    func startSessionIfNeeded() {
        guard !didStartSession else { return }
        didStartSession = true

        let configuration = ARWorldTrackingConfiguration()
        configuration.environmentTexturing = .automatic
        configuration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .meshWithClassification
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics = [.sceneDepth]
        }

        arView.automaticallyConfigureSession = false
        arView.session.run(configuration)
        currentConfiguration = configuration
        applyDebugState()
        statusMessage = "请缓慢移动设备，扫描周围环境"
    }

    /// 暂停 / 继续
    func toggleSession() {
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
        applyDebugState()
    }

    /// 网格显示开关（彩色语义网格 / 纯净相机画面）
    func toggleDebugMesh() {
        showDebugMesh.toggle()
        applyDebugState()
    }

    /// 页面退出时关闭会话，节省功耗
    func pauseForBackground() {
        if isSessionRunning {
            arView.session.pause()
            isSessionRunning = false
        }
    }

    private func applyDebugState() {
        if showDebugMesh {
            arView.debugOptions.insert(.showSceneUnderstanding)
        } else {
            arView.debugOptions.remove(.showSceneUnderstanding)
        }
    }

    // MARK: - 导出

    func export(_ options: ExportOptions) {
        guard !isExporting else { return }
        guard let frame = arView.session.currentFrame else {
            alertMessage = "相机尚未就绪，请稍后再试"
            return
        }

        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !anchors.isEmpty else {
            alertMessage = "还没有捕捉到网格，请先扫描几秒再导出"
            return
        }

        let snapshot = FrameSnapshot.make(from: frame)

        // 先暂停会话并保留当前帧，再在后台做重活，避免卡 UI
        arView.session.pause()
        isSessionRunning = false
        isExporting = true
        statusMessage = "正在生成模型…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let meshData = MeshExtractor.extract(from: anchors)
            do {
                let result = try ScanFileExporter.run(data: meshData,
                                                      options: options,
                                                      snapshot: snapshot)
                Task { @MainActor in
                    guard let self else { return }
                    let names = result.urls.map(\.lastPathComponent).joined(separator: "、")
                    self.statusMessage = "模型已导出"
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

// MARK: - AR 容器视图

struct ARContainerView: UIViewRepresentable {
    @ObservedObject var viewModel: CaptureViewModel

    func makeUIView(context: Context) -> ARView {
        viewModel.startSessionIfNeeded()
        return viewModel.arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // 会话生命周期全部由 CaptureViewModel 管理，这里无需处理
    }
}