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
    //
    // 这些数据只允许在 ARSessionDelegate 回调（安全窗口）内写入，
    // 之后任何线程都不得再访问 ARKit 对象。

    /// 每个网格锚点在回调窗口内深拷贝的快照（identifier → 快照）
    private var meshSnapshots: [UUID: MeshExtractor.MeshAnchorSnapshot] = [:]
    /// 最近一帧的相机/图像快照（在回调窗口内物化）
    private var latestSnapshot: FrameSnapshot?

    /// 结束扫描时组装好的网格（纯 Swift 值）
    private var cachedMeshData: ScanMeshData?
    /// 结束扫描时的相机快照（纯值）
    private var cachedSnapshot: FrameSnapshot?

    // MARK: - 会话控制

    func startSessionIfNeeded() {
        guard !didStartSession else { return }
        didStartSession = true

        meshSnapshots.removeAll()
        latestSnapshot = nil

        let configuration = ARWorldTrackingConfiguration()
        configuration.environmentTexturing = .automatic
        configuration.planeDetection = [.horizontal, .vertical]
        // 稳定性优先：使用纯 .mesh 场景重建。
        // .meshWithClassification 会多挂一路语义分类更新器，与底层交互面更大，
        // 在 iPadOS 27 上更易触发时序问题；纯网格对流更稳。
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics = [.sceneDepth]
        }

        arView.automaticallyConfigureSession = false
        arView.session.delegate = self
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
        guard !isFinished else { return !meshSnapshots.isEmpty }
        guard !meshSnapshots.isEmpty else {
            alertMessage = "还没有捕捉到网格，请先扫描几秒再结束"
            return false
        }

        // 全部数据都已由回调提前物化好，这里不触碰任何 ARKit 对象
        let meshData = MeshExtractor.buildMesh(from: Array(meshSnapshots.values))
        guard !meshData.isEmpty else {
            alertMessage = "网格数据为空，请重新扫描"
            return false
        }
        let snapshot = latestSnapshot
        cachedMeshData = meshData
        cachedSnapshot = snapshot

        arView.session.pause()
        isSessionRunning = false
        isFinished = true
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
        meshSnapshots.removeAll()
        latestSnapshot = nil
        cachedMeshData = nil
        cachedSnapshot = nil
        if let configuration = currentConfiguration {
            arView.session.run(configuration)
        }
        isSessionRunning = true
        isFinished = false
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

    /// 读取当前界面方向（线程无关，可从 ARSessionDelegate 回调调用）
    private static nonisolated func readInterfaceOrientation() -> UIInterfaceOrientation {
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            return scene.interfaceOrientation
        }
        return .portrait
    }
}

// MARK: - ARSessionDelegate（数据采集安全窗口）
//
// 只有这里可以读取 ARKit 对象，且必须在回调内完成深拷贝。
// 产物（纯 Swift 值）通过 MainActor 任务写入存储，供结束扫描/导出使用。

extension CaptureViewModel: ARSessionDelegate {

    /// 网格拷贝节流间隔（秒）：同一锚点距上次深拷贝不足该值则跳过，
    /// 显著降低与 ARKit 底层缓冲纠缠的频率，也更省 CPU。
    private static let ingestThrottle: TimeInterval = 0.3

    /// 节流表（线程安全）
    private nonisolated static let ingestLock = NSLock()
    private nonisolated static var lastIngestTime: [UUID: TimeInterval] = [:]

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        ingestMeshAnchors(anchors)
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        ingestMeshAnchors(anchors)
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // 在回调窗口内把相机矩阵/图像物化为值（之后回主线程只传值）
        let orientation = Self.readInterfaceOrientation()
        guard let snapshot = FrameSnapshot.make(from: frame, orientation: orientation) else { return }
        Task { @MainActor [weak self] in
            self?.latestSnapshot = snapshot
        }
    }

    private nonisolated func ingestMeshAnchors(_ anchors: [ARAnchor]) {
        let now = ProcessInfo.processInfo.systemUptime
        for anchor in anchors {
            guard let mesh = anchor as? ARMeshAnchor else { continue }
            let identifier = mesh.identifier

            // 节流：高频 didUpdate 时避免对同一锚点反复全量深拷贝
            let shouldCopy = Self.ingestLock.withLock { () -> Bool in
                let last = Self.lastIngestTime[identifier] ?? -Double.greatestFiniteMagnitude
                guard now - last >= Self.ingestThrottle else { return false }
                Self.lastIngestTime[identifier] = now
                return true
            }
            guard shouldCopy else { continue }

            // 回调窗口内深拷贝网格缓冲（官方安全时机）
            let snapshot = MeshExtractor.snapshot(of: mesh)
            guard !snapshot.vertices.isEmpty else { continue }
            Task { @MainActor [weak self] in
                self?.meshSnapshots[identifier] = snapshot
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