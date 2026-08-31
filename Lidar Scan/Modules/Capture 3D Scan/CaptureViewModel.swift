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
    /// 实时三角网格预览（系统 sceneReconstruction 渲染）
    @Published var showSceneMesh = false
    /// 深度热力图（近红→中黄→远绿），基于深拷贝深度生成，用于距离校验
    @Published var depthHeatmapImage: UIImage?

    // MARK: - AR 视图

    let arView = ARView(frame: .zero)

    private var currentConfiguration: ARWorldTrackingConfiguration?
    private var didStartSession = false

    // MARK: - 采集缓存（纯值 + 线程安全缓冲）

    /// 关键帧（深度图 + 位姿），用于重建点云
    private var keyFrames: [KeyFrameSnapshot] = []
    /// 最近一帧（含相机图像），用于点云上色与深度图导出
    private var latestFrameSnapshot: FrameSnapshot?
    /// 视觉帧（隔段采样的含图帧），用于多帧 best-view 上色
    private var visualFrames: [FrameSnapshot] = []
    private var visualFrameCounter = 0
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
        visualFrames.removeAll()
        visualFrameCounter = 0

        let configuration = ARWorldTrackingConfiguration()
        configuration.environmentTexturing = .automatic
        configuration.planeDetection = [.horizontal, .vertical]
        // 实时三角网格预览：ARKit/RealityKit 内部渲染 sceneReconstruction 网格
        // （叠加在相机画面上，用于“建模 vs 相机”位置校准）。
        // 仅“显示”，从不读取网格缓冲——渲染由系统完成，零崩溃风险。
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
            arView.debugOptions.insert(.showSceneUnderstanding)
            showSceneMesh = true
        }
        // 数据管线仍只依赖 sceneDepth（深拷贝通道），与网格预览互不影响
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics = [.sceneDepth]
        }

        arView.automaticallyConfigureSession = false
        arView.session.delegate = self
        arView.session.run(configuration)
        currentConfiguration = configuration
        statusMessage = "缓慢环绕扫描，距墙面/物体 1~2 米，避免快速移动"
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
        let visualFrames = self.visualFrames
        isFinished = true
        arView.session.pause()
        isSessionRunning = false
        statusMessage = "正在融合重建网格（TSDF）…"
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

            // 多帧 best-view 上色（每顶点选“法线朝向相机、视角正对”的最佳帧取色）；
            // 视觉帧不足时回退单帧
            if let colors = TextureMapper.sampleColorsBestView(vertices: mesh.vertices,
                                                               normals: mesh.normals,
                                                               frames: visualFrames) {
                mesh.colors = colors
            } else if let colors = TextureMapper.sampleColors(vertices: mesh.vertices, snapshot: latest) {
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

            // 居中到原点：预览相机默认看向原点，保证模型必然可见；尺寸不变
            if !mesh.vertices.isEmpty {
                var lo = mesh.vertices[0]
                var hi = mesh.vertices[0]
                for v in mesh.vertices {
                    lo = simd_min(lo, v)
                    hi = simd_max(hi, v)
                }
                let center = (lo + hi) / 2
                if simd_length(center) > 0.001 {
                    for i in 0..<mesh.vertices.count {
                        mesh.vertices[i] -= center
                    }
                }
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
                    self.statusMessage = "模型已生成：\(mesh.vertexCount) 顶点 / \(mesh.faceCount) 面"
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
        visualFrames.removeAll()
        visualFrameCounter = 0
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

    /// 切换三角网格预览开/关（只切渲染选项，不碰缓冲）
    func toggleSceneMesh() {
        showSceneMesh.toggle()
        if showSceneMesh {
            arView.debugOptions.insert(.showSceneUnderstanding)
        } else {
            arView.debugOptions.remove(.showSceneUnderstanding)
        }
    }

    /// 由深拷贝深度生成红黄绿热力图（近红→中黄→远绿）
    nonisolated static func makeDepthHeatmap(depth: [Float],
                                             width: Int,
                                             height: Int) -> UIImage? {
        guard width > 0, height > 0, depth.count >= width * height else { return nil }

        // 输出宽度固定 72（等比缩小），避免生成大图
        let outW = 72
        let outH = max(1, height * outW / width)
        let yStride = max(1, height / outH)
        let xStride = max(1, width / outW)

        var rgba = [UInt8](repeating: 0, count: outW * outH * 4)

        func heatColor(_ d: Float) -> (UInt8, UInt8, UInt8) {
            // 0.4m 红 → 1.2m 黄 → 3.0m+ 绿；无效/超远灰
            guard d.isFinite, d > 0.2, d < 6.0 else { return (90, 90, 90) }
            let t = min(max((d - 0.4) / 2.6, 0), 1)   // 0=红 1=绿
            let r: UInt8, g: UInt8, b: UInt8
            if t < 0.5 {
                let f = t * 2                       // 红→黄
                r = 255
                g = UInt8(255 * f)
                b = 0
            } else {
                let f = (t - 0.5) * 2               // 黄→绿
                r = UInt8(255 * (1 - f))
                g = 255
                b = 0
            }
            return (r, g, b)
        }

        var oy = 0
        var y = 0
        while y < height, oy < outH {
            var ox = 0
            var x = 0
            while x < width, ox < outW {
                let d = depth[y * width + x]
                let (r, g, b) = heatColor(d)
                let i = (oy * outW + ox) * 4
                rgba[i] = r
                rgba[i + 1] = g
                rgba[i + 2] = b
                rgba[i + 3] = 255
                x += xStride
                ox += 1
            }
            y += yStride
            oy += 1
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        guard let cg = CGImage(width: outW,
                               height: outH,
                               bitsPerComponent: 8,
                               bitsPerPixel: 32,
                               bytesPerRow: outW * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider,
                               decode: nil,
                               shouldInterpolate: false,
                               intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
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
    /// 关键帧数量上限：循环缓冲。150 帧 ≈ 38 秒窗口——
    /// 控制 VIO 位姿漂移累积（过长扫描会“墙变厚/拉丝”，对齐开源重建经验）。
    private static let keyFrameLimit = 150

    private enum DepthSampler {
        static let lock = NSLock()
        static var lastSampleAt: TimeInterval = 0
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // 丢弃低跟踪质量帧（苹果官方建议）：漂移帧混入会导致"对不上/墙变厚/尖刺"
        guard frame.camera.trackingState == .normal else { return }

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

        // 从深拷贝深度生成热力图（近红·中黄·远绿），用于距离校验
        let heatmap = Self.makeDepthHeatmap(depth: keyFrame.depthValues,
                                            width: keyFrame.width,
                                            height: keyFrame.height)

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.latestFrameSnapshot = snapshot
            self.depthHeatmapImage = heatmap
            // 每 8 个关键帧保留一张“视觉帧”用于多帧上色（≈2s 一张，内存有界）
            self.visualFrameCounter += 1
            if self.visualFrameCounter % 8 == 0 {
                if self.visualFrames.count >= 40 { self.visualFrames.removeFirst() }
                self.visualFrames.append(snapshot)
            }
            if self.keyFrames.count >= Self.keyFrameLimit {
                self.keyFrames.removeFirst()   // 循环缓冲：替换最旧帧
            }
            self.keyFrames.append(keyFrame)
        }
    }

    /// 读取当前界面方向（优先前台活跃窗口场景；iPad 多窗口下不会拿错方向）
    private static nonisolated func readInterfaceOrientation() -> UIInterfaceOrientation {
        if let scene = UIApplication.shared.connectedScenes
            .first(where: { ($0 as? UIWindowScene)?.activationState == .foregroundActive }) as? UIWindowScene {
            return scene.interfaceOrientation
        }
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