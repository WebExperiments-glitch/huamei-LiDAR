//
//  CaptureViewModel.swift
//  Lidar Scan (二次开发)
//
//  扫描会话管理：会话启停、网格显示，以及
//  「结束扫描 → 主线程物化数据 → 后台导出」的安全流程。
//
//  ⚠️ 防闪退红线：任何 ARKit 对象（ARMeshAnchor / ARCamera / 深度缓冲）
//  都只能在「会话尚未暂停、主线程」时读取；读取结果必须物化为纯 Swift 值
//  （数组 / 矩阵 / 像素缓冲强引用）后，才能交给后台线程处理。
//  否则暂停瞬间 ARKit 会释放底层共享内存，后台读取即 UAF 闪退。
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
    /// 是否已完成「结束扫描」并物化好数据（只允许在已结束时导出）
    @Published var isFinished = false
    /// 结束后的计算/落盘阶段（显示「空中三角测量计算中…」遮罩）
    @Published var isProcessing = false
    /// 落盘完成，页面应自动退出回主界面
    @Published var didFinishScan = false
    @Published var showDebugMesh = true
    @Published var isExporting = false
    @Published var statusMessage: String?
    /// 弹窗通知（导出成功 / 失败 / 提示）
    @Published var alertMessage: String?

    // MARK: - AR 视图

    let arView = ARView(frame: .zero)

    private var currentConfiguration: ARWorldTrackingConfiguration?
    private var didStartSession = false

    // MARK: - 已物化的扫描数据（纯 Swift 值，可安全跨线程）

    private var cachedMeshData: ScanMeshData?
    private var cachedSnapshot: FrameSnapshot?

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

    /// 暂停 / 继续（扫描阶段）
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
        applyDebugState()
    }

    /// 网格显示开关
    func toggleDebugMesh() {
        showDebugMesh.toggle()
        applyDebugState()
    }

    /// 结束扫描：主线程同步物化网格 + 相机快照，然后暂停会话。
    /// 物化之后，后台线程绝不再触碰任何 ARKit 对象。
    @discardableResult
    func finishScan() -> Bool {
        guard !isFinished else { return cachedMeshData != nil }
        guard let frame = arView.session.currentFrame else {
            alertMessage = "相机尚未就绪，请稍后再试"
            return false
        }

        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !anchors.isEmpty else {
            alertMessage = "还没有捕捉到网格，请先扫描几秒再结束"
            return false
        }

        // 前置：把相机矩阵按当前界面方向物化为值（再暂停就安全了）
        let orientation = currentInterfaceOrientation()
        let snapshot = FrameSnapshot.make(from: frame, orientation: orientation)

        // 核心：同步抽取网格为纯 Swift 数组（此刻会话仍在运行，内存有效）
        let meshData = MeshExtractor.extract(from: anchors)
        guard !meshData.isEmpty else {
            alertMessage = "网格数据为空，请重新扫描"
            return false
        }

        arView.session.pause()
        isSessionRunning = false
        isFinished = true
        cachedMeshData = meshData
        cachedSnapshot = snapshot
        statusMessage = "正在空中三角测量计算…"
        isProcessing = true

        // 后台：给顶点采样相机颜色 → 自动落盘一份 OBJ 供列表查看
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var finalMesh = meshData
            if let colors = TextureMapper.sampleColors(vertices: meshData.vertices, snapshot: snapshot) {
                finalMesh.colors = colors
            }
            let options = ExportOptions(fileName: ScanFileExporter.defaultName(),
                                        format: .obj,
                                        contentKind: .mesh,
                                        textured: false,
                                        exportDepth: false)
            do {
                _ = try ScanFileExporter.run(data: finalMesh, options: options, snapshot: snapshot)
                Task { @MainActor in
                    guard let self else { return }
                    self.isProcessing = false
                    self.didFinishScan = true
                }
            } catch {
                Task { @MainActor in
                    guard let self else { return }
                    self.isProcessing = false
                    self.isFinished = false
                    self.statusMessage = "模型保存失败，请重试"
                    self.alertMessage = error.localizedDescription
                }
            }
        }
        return true
    }

    /// 重新扫描：恢复会话并清掉缓存
    func resumeScan() {
        guard isFinished else { return }
        if let configuration = currentConfiguration {
            arView.session.run(configuration)
        }
        isSessionRunning = true
        isFinished = false
        cachedMeshData = nil
        cachedSnapshot = nil
        statusMessage = "扫描已继续"
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

    // MARK: - 导出（后台只处理已物化的值类型数据）

    func export(_ options: ExportOptions) {
        guard !isExporting else { return }

        // 未结束扫描？先结束（物化 + 暂停），保证数据快照一致性
        guard finishScan() else { return }

        guard let meshData = cachedMeshData else {
            alertMessage = "模型数据为空，请重新扫描后再导出"
            return
        }
        let snapshot = cachedSnapshot

        isExporting = true
        statusMessage = "正在生成模型…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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

    // MARK: - 工具

    private func currentInterfaceOrientation() -> UIInterfaceOrientation {
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
        // 会话生命周期全部由 CaptureViewModel 管理，这里无需处理
    }
}