//
//  Capture3DScanView.swift
//  Lidar Scan (二次开发)
//
//  扫描页：全屏 AR 预览 + 液态玻璃控制栏 + 导出选项面板。
//

import SwiftUI

struct Capture3DScanView: View {
    @Environment(\.presentationMode) private var mode
    @StateObject private var viewModel = CaptureViewModel()
    @State private var showExportSheet = false

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.alertMessage != nil },
            set: { if !$0 { viewModel.alertMessage = nil } }
        )
    }

    var body: some View {
        ZStack {
            // 相机 + 网格
            ARContainerView(viewModel: viewModel)
                .ignoresSafeArea()

            // 顶部返回
            VStack {
                HStack {
                    GlassIconButton(systemImage: "chevron.left") {
                        mode.wrappedValue.dismiss()
                    }
                    .padding(.leading, 20)
                    .padding(.top, 8)
                    Spacer()
                }
                Spacer()
            }

            // 底部控制栏
            VStack(spacing: 12) {
                StatusChip(text: viewModel.statusMessage ?? "扫描中…",
                           isActive: viewModel.isSessionRunning)

                HStack(spacing: 14) {
                    GlassIconButton(systemImage: viewModel.isSessionRunning ? "pause.fill" : "play.fill") {
                        viewModel.toggleSession()
                    }
                    GlassIconButton(systemImage: viewModel.showDebugMesh ? "square.grid.3d.fill" : "eye.fill") {
                        viewModel.toggleDebugMesh()
                    }
                    GlassButton(title: "导出",
                                systemImage: "square.and.arrow.up",
                                prominent: true,
                                disabled: viewModel.isExporting) {
                        showExportSheet = true
                    }
                }
            }
            .padding(.bottom, 24)
            .frame(maxHeight: .infinity, alignment: .bottom)

            // 导出中遮罩
            if viewModel.isExporting {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .overlay {
                        GlassCard {
                            HStack(spacing: 12) {
                                ProgressView()
                                    .tint(.white)
                                Text("正在生成模型…")
                                    .font(.system(.body, design: .rounded, weight: .semibold))
                            }
                        }
                    }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.isExporting)
        .sheet(isPresented: $showExportSheet) {
            ExportOptionsSheetView(viewModel: viewModel)
        }
        .alert("提示", isPresented: alertBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
        .onDisappear {
            viewModel.pauseForBackground()
        }
        .statusBarHidden(true)
    }
}

// MARK: - 导出选项面板

struct ExportOptionsSheetView: View {
    @Environment(\.presentationMode) private var mode
    @ObservedObject var viewModel: CaptureViewModel

    @State private var fileName = ""
    @State private var format: ScanExportFormat = .obj
    @State private var contentKind: ScanContentKind = .mesh
    @State private var textured = true
    @State private var exportDepth = true

    private var canExport: Bool {
        if contentKind == .pointCloud, !format.supportsPointCloud { return false }
        return !viewModel.isExporting
    }

    private var pointCloudHint: Bool {
        contentKind == .pointCloud && !format.supportsPointCloud
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 文件名
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("文件名")
                                .font(.system(.headline, design: .rounded, weight: .semibold))
                            GlassTextField(title: "留空自动命名", text: $fileName)
                            Text("将保存到 App 文档目录 SCANS 文件夹")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.primary.opacity(0.5))
                        }
                    }

                    // 格式
                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("格式")
                                .font(.system(.headline, design: .rounded, weight: .semibold))
                            GlassFormatMenu(selection: $format)
                            Text(formatDescription)
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.primary.opacity(0.5))
                        }
                    }

                    // 内容类型
                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("内容")
                                .font(.system(.headline, design: .rounded, weight: .semibold))
                            GlassSegmentedPicker(title: "内容", selection: $contentKind)
                            if pointCloudHint {
                                Text("\(format.rawValue) 不支持点云，请选择 OBJ 或 PLY")
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    // 进阶选项
                    GlassCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("进阶")
                                .font(.system(.headline, design: .rounded, weight: .semibold))
                            GlassToggleRow(title: "相机纹理上色",
                                           caption: "把最后镜头画面颜色采样到模型表面",
                                           isOn: $textured,
                                           enabled: format.supportsColor)
                            GlassToggleRow(title: "附带导出深度图 + 置信度",
                                           caption: "16-bit 深度 PNG（毫米）+ 置信度 PNG",
                                           isOn: $exportDepth)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("导出模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { mode.wrappedValue.dismiss() }
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let options = ExportOptions(fileName: fileName,
                                                    format: format,
                                                    contentKind: contentKind,
                                                    textured: textured,
                                                    exportDepth: exportDepth)
                        mode.wrappedValue.dismiss()
                        viewModel.export(options)
                    } label: {
                        Text("开始导出")
                            .font(.system(.body, design: .rounded, weight: .bold))
                    }
                    .disabled(!canExport)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .background(Color(red: 0.08, green: 0.08, blue: 0.12).ignoresSafeArea())
    }

    private var formatDescription: String {
        switch format {
        case .obj: return "通用网格格式，兼容大多数软件"
        case .ply: return "带点色/默认颜色，可做点云或网格"
        case .stl: return "3D 打印标准格式（无颜色）"
        case .glb: return "glTF 二进制，Web/AR 通用"
        case .usdz: return "苹果原生格式，AR Quick Look 直接预览"
        }
    }
}

// MARK: - 玻璃格式选择菜单

struct GlassFormatMenu: View {
    @Binding var selection: ScanExportFormat

    var body: some View {
        Menu {
            ForEach(ScanExportFormat.allCases) { item in
                Button {
                    selection = item
                } label: {
                    if item == selection {
                        Label(item.rawValue, systemImage: "checkmark")
                    } else {
                        Text(item.rawValue)
                    }
                }
            }
        } label: {
            HStack {
                Text(selection.rawValue)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Material.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .glassEffect(.regular)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
        }
    }
}