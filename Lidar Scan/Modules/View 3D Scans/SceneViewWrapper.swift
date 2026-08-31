//
//  SceneViewWrapper.swift
//  Lidar Scan (二次开发)
//
//  3D 模型预览器：旋转/缩放/平移 + 打标签 + 两点距离测量 + 包围盒尺寸显示。
//

import SwiftUI
import SceneKit

struct SceneViewWrapper: UIViewRepresentable {
    let scene: SCNScene?
    @Binding var measureResult: String
    @Binding var isMeasureMode: Bool
    @Binding var modelDimensions: String

    func makeCoordinator() -> Coordinator {
        let rootVC = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .rootViewController
        return Coordinator(scene: scene,
                           viewController: rootVC,
                           measureResult: $measureResult,
                           isMeasureMode: $isMeasureMode,
                           modelDimensions: $modelDimensions)
    }

    func makeUIView(context: Context) -> some UIView {
        let scnView = SCNView()
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = true
        scnView.antialiasingMode = .multisampling4X
        scnView.backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.10, alpha: 1)

        // 合并所有根节点到同一父节点下，便于居中对齐
        let parentNode = SCNNode()
        scene?.rootNode.childNodes.forEach { node in
            parentNode.addChildNode(node)
        }
        scene?.rootNode.addChildNode(parentNode)

        // 统一材质（灰色实体）
        parentNode.enumerateChildNodes { node, _ in
            if let geometry = node.geometry {
                let material = SCNMaterial()
                material.diffuse.contents = UIColor.lightGray
                material.lightingModel = .physicallyBased
                material.isDoubleSided = true
                geometry.materials = [material]
            }
        }

        // 居中模型
        let (minVec, maxVec) = parentNode.boundingBox
        let dxAxis = (minVec.x + maxVec.x) / 2
        let dyAxis = (minVec.y + maxVec.y) / 2
        let dzAxis = (minVec.z + maxVec.z) / 2
        parentNode.position = SCNVector3(-dxAxis, -dyAxis, -dzAxis)

        // 报告真实尺寸（ARKit 网格为米制）
        let size = SCNVector3(maxVec.x - minVec.x,
                              maxVec.y - minVec.y,
                              maxVec.z - minVec.z)
        let dimensionText = String(format: "模型尺寸  长 %.2f m · 宽 %.2f m · 高 %.2f m",
                                   size.x, size.z, size.y)
        DispatchQueue.main.async {
            if modelDimensions.isEmpty {
                modelDimensions = dimensionText
            }
        }

        // 适配模型相机
        let maxDimension = max(maxVec.x - minVec.x, maxVec.y - minVec.y, maxVec.z - minVec.z)
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(0, 0, max(maxDimension, 0.1) * 2)
        scene?.rootNode.addChildNode(cameraNode)

        // 方向光
        let lightNode = SCNNode()
        lightNode.light = SCNLight()
        lightNode.light?.type = .directional
        lightNode.light?.intensity = 1000
        lightNode.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
        scene?.rootNode.addChildNode(lightNode)

        // 环境光
        let ambientNode = SCNNode()
        ambientNode.light = SCNLight()
        ambientNode.light?.type = .ambient
        ambientNode.light?.color = UIColor(white: 0.35, alpha: 1.0)
        scene?.rootNode.addChildNode(ambientNode)

        scnView.scene = scene

        let tapGesture = UITapGestureRecognizer(target: context.coordinator,
                                                action: #selector(Coordinator.handleTap(_:)))
        scnView.addGestureRecognizer(tapGesture)

        return scnView
    }

    func updateUIView(_ uiView: UIViewType, context: Context) {
        context.coordinator.scene = scene
    }

    // MARK: - Coordinator

    class Coordinator: NSObject {
        var scene: SCNScene?
        weak var viewController: UIViewController?

        @Binding var measureResult: String
        @Binding var isMeasureMode: Bool
        @Binding var modelDimensions: String

        // 测量状态
        private var measureStartWorld: SCNVector3?
        private var measureNodes: [SCNNode] = []

        init(scene: SCNScene?,
             viewController: UIViewController?,
             measureResult: Binding<String>,
             isMeasureMode: Binding<Bool>,
             modelDimensions: Binding<String>) {
            self.scene = scene
            self.viewController = viewController
            self._measureResult = measureResult
            self._isMeasureMode = isMeasureMode
            self._modelDimensions = modelDimensions
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let scnView = gesture.view as? SCNView else { return }
            let location = gesture.location(in: scnView)
            let hits = scnView.hitTest(location, options: nil)
            guard let hit = hits.first else { return }
            let position = hit.worldCoordinates

            if isMeasureMode {
                handleMeasurePoint(position)
            } else {
                handleTag(at: position, scnView: scnView)
            }
        }

        // MARK: 测量

        private func handleMeasurePoint(_ position: SCNVector3) {
            if let start = measureStartWorld {
                // 第二点：画线 + 标注距离
                addMarkerNode(at: start, color: .systemGreen)
                addMarkerNode(at: position, color: .systemGreen)
                addLineNode(from: start, to: position)
                addLabelNode(center: midpoint(from: start, to: position),
                             text: distanceText(start, position))
                measureStartWorld = nil
            } else {
                // 第一点：只画点位
                measureStartWorld = position
                addMarkerNode(at: position, color: .systemGreen)
            }
        }

        private func clearMeasureVisuals() {
            measureNodes.forEach { $0.removeFromParentNode() }
            measureNodes.removeAll()
        }

        private func addMarkerNode(at position: SCNVector3, color: UIColor) {
            guard let root = scene?.rootNode else { return }
            let sphere = SCNSphere(radius: 0.008)
            sphere.firstMaterial?.diffuse.contents = color
            let node = SCNNode(geometry: sphere)
            node.position = position
            root.addChildNode(node)
            measureNodes.append(node)
        }

        private func addLineNode(from a: SCNVector3, to b: SCNVector3) {
            guard let root = scene?.rootNode else { return }
            let height = MeasurementService.distance(a, b)
            let cylinder = SCNCylinder(radius: 0.004, height: CGFloat(height))
            cylinder.firstMaterial?.diffuse.contents = UIColor.systemGreen
            let node = SCNNode(geometry: cylinder)
            node.position = midpoint(from: a, to: b)

            // 让圆柱体 Y 轴对齐 a→b 方向
            let up = SCNVector3(0, 1, 0)
            let dir = SCNVector3(b.x - a.x, b.y - a.y, b.z - a.z)
            let len = max(sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z), 1e-6)
            let normalizedDir = SCNVector3(dir.x / len, dir.y / len, dir.z / len)

            let dot = up.x * normalizedDir.x + up.y * normalizedDir.y + up.z * normalizedDir.z
            let angle = acos(min(max(dot, -1), 1))
            if angle > 1e-4 {
                let cross = SCNVector3(up.y * normalizedDir.z - up.z * normalizedDir.y,
                                       up.z * normalizedDir.x - up.x * normalizedDir.z,
                                       up.x * normalizedDir.y - up.y * normalizedDir.x)
                node.rotation = SCNVector4(cross.x, cross.y, cross.z, angle)
            }

            root.addChildNode(node)
            measureNodes.append(node)
        }

        private func addLabelNode(center position: SCNVector3, text: String) {
            guard let root = scene?.rootNode else { return }
            let textGeometry = SCNText(string: text, extrusionDepth: 0.1)
            textGeometry.font = UIFont.systemFont(ofSize: 2, weight: .bold)
            textGeometry.firstMaterial?.diffuse.contents = UIColor.white
            textGeometry.firstMaterial?.isDoubleSided = true
            textGeometry.firstMaterial?.readsFromDepthBuffer = false

            let node = SCNNode(geometry: textGeometry)
            node.scale = SCNVector3(0.01, 0.01, 0.01)
            node.position = SCNVector3(position.x, position.y + 0.05, position.z)
            node.renderingOrder = 2000
            node.constraints = [SCNBillboardConstraint()]
            root.addChildNode(node)
            measureNodes.append(node)
        }

        private func midpoint(from a: SCNVector3, to b: SCNVector3) -> SCNVector3 {
            SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
        }

        private func distanceText(_ a: SCNVector3, _ b: SCNVector3) -> String {
            let distance = MeasurementService.distance(a, b)
            measureResult = String(format: "测量距离 %.2f m", distance)
            return String(format: "%.2f m", distance)
        }

        // MARK: 打标签（原版功能）

        private func handleTag(at position: SCNVector3, scnView: SCNView) {
            let alert = UIAlertController(title: "添加标签", message: "输入标签文字", preferredStyle: .alert)
            alert.addTextField { textField in
                textField.placeholder = "标签名"
            }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "添加", style: .default, handler: { [weak self] _ in
                guard let text = alert.textFields?.first?.text, !text.isEmpty else { return }
                self?.addTag(at: position, with: text)
            }))
            viewController?.present(alert, animated: true)
        }

        func addTag(at position: SCNVector3, with text: String) {
            guard let root = scene?.rootNode else { return }
            let textGeometry = SCNText(string: text, extrusionDepth: 0.2)
            textGeometry.font = UIFont.systemFont(ofSize: 5)
            textGeometry.firstMaterial?.diffuse.contents = UIColor.systemOrange
            textGeometry.firstMaterial?.isDoubleSided = true
            textGeometry.firstMaterial?.readsFromDepthBuffer = false

            let textNode = SCNNode(geometry: textGeometry)
            textNode.scale = SCNVector3(0.01, 0.01, 0.01)
            textNode.position = position
            textNode.renderingOrder = 1000

            let constraint = SCNBillboardConstraint()
            constraint.freeAxes = [.Y]
            textNode.constraints = [constraint]
            root.addChildNode(textNode)
        }
    }
}