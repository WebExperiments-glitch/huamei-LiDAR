//
//  View3DScansView.swift
//  Lidar Scan (二次开发)
//
//  扫描列表页：玻璃风格列表 + 分享 + 删除 + 预览跳转 + 尺寸显示。
//

import SwiftUI
import SceneKit

// MARK: - 分享内容（sheet 需要 Identifiable）

struct ShareContent: Identifiable {
    let id = UUID()
    let urls: [URL]
}

// MARK: - 列表页

struct View3DScansView: View {
    @Environment(\.presentationMode) private var mode
    @State private var items: [ScanFileItem] = []
    @State private var shareContent: ShareContent?
    @State private var noteMessage: String?
    @State private var pendingItem: ScanFileItem?

    private var noteBinding: Binding<Bool> {
        Binding(
            get: { noteMessage != nil },
            set: { if !$0 { noteMessage = nil } }
        )
    }

    private var pendingBinding: Binding<Bool> {
        Binding(
            get: { pendingItem != nil },
            set: { if !$0 { pendingItem = nil } }
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground {
                    VStack(spacing: 0) {
                        header

                        if items.isEmpty {
                            emptyState
                        } else {
                            List {
                                ForEach(items) { item in
                                    row(item)
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                                }
                                .onDelete(perform: deleteItems)
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                            .refreshable { refresh() }
                        }
                    }
                }
            }
            .navigationDestination(isPresented: pendingBinding) {
                if let item = pendingItem {
                    ScanViewerView(item: item)
                }
            }
        }
        .onAppear { refresh() }
        .alert("提示", isPresented: noteBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(noteMessage ?? "")
        }
        .sheet(item: $shareContent) { content in
            ShareSheet(items: content.urls.map { $0 as Any })
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: 头部

    private var header: some View {
        HStack {
            GlassIconButton(systemImage: "chevron.left") {
                mode.wrappedValue.dismiss()
            }
            Spacer()
            VStack(spacing: 2) {
                Text("我的扫描")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                Text("\(items.count) 个模型")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            // 占位保持对称
            Color.clear
                .frame(width: 44, height: 44)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: 空态

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "cube.transparent")
                .font(.system(size: 52))
                .foregroundStyle(.white.opacity(0.35))
            Text("还没有扫描模型")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
            Text("先回到首页进入「开始扫描」，\n扫描完成后模型会出现在这里")
                .font(.system(.subheadline, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // MARK: 行

    private func row(_ item: ScanFileItem) -> some View {
        GlassCard {
            HStack(spacing: 14) {
                // 格式图标
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.12))
                        .frame(width: 48, height: 48)
                    Image(systemName: formatIcon(item.format))
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(item.name)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(item.sizeText)
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                        Text(item.format?.rawValue ?? "—")
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.15), in: Capsule())
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }

                Spacer()

                // 分享
                Button {
                    shareContent = ShareContent(urls: [item.url])
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { open(item) }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                delete(item)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: 行为

    private func open(_ item: ScanFileItem) {
        if let format = item.format, format.previewSupported {
            pendingItem = item
        } else {
            noteMessage = "该格式（\(item.format?.rawValue ?? "未知")）暂不支持内嵌预览。你可以通过分享导出查看，或改用 OBJ / USDZ 格式扫描导出。"
        }
    }

    private func deleteItems(at offsets: IndexSet) {
        for index in offsets {
            delete(items[index])
        }
        refresh()
    }

    private func delete(_ item: ScanFileItem) {
        try? FileManager.default.removeItem(at: item.url)
        refresh()
    }

    private func refresh() {
        items = ScanFileExporter.listModelFiles().map { ScanFileItem(url: $0) }
        // 重排：最新的在前
        items.sort {
            let t0 = (try? $0.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let t1 = (try? $1.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return t0 > t1
        }
    }

    private func formatIcon(_ format: ScanExportFormat?) -> String {
        switch format {
        case .obj: return "doc.richtext"
        case .ply: return "point.3.connected.trianglepath.dotted"
        case .stl: return "cube"
        case .glb: return "cube.box"
        case .usdz: return "arkit"
        case nil: return "doc"
        }
    }
}

// MARK: - 预览页

struct ScanViewerView: View {
    @Environment(\.presentationMode) private var mode
    let item: ScanFileItem

    @State private var loadedScene: SCNScene?
    @State private var measureMode = false
    @State private var measureResultText = ""
    @State private var modelDimensions = ""
    @State private var showShare = false

    var body: some View {
        ZStack {
            if let scene = loadedScene {
                SceneViewWrapper(scene: scene,
                                 measureResult: $measureResultText,
                                 isMeasureMode: $measureMode,
                                 modelDimensions: $modelDimensions)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text("无法预览此格式")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                    Text("仅 OBJ / USDZ 支持内嵌预览，其他格式请使用分享导出手动查看。")
                        .font(.system(.subheadline, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 40)
                }
            }

            VStack {
                HStack {
                    GlassIconButton(systemImage: "chevron.left") {
                        mode.wrappedValue.dismiss()
                    }
                    Spacer()
                    // 测量模式开关
                    ZStack(alignment: .topTrailing) {
                        GlassIconButton(systemImage: measureMode ? "ruler.fill" : "ruler") {
                            measureMode.toggle()
                            if !measureMode { measureResultText = "" }
                        }
                        if measureMode {
                            Circle()
                                .fill(.green)
                                .frame(width: 10, height: 10)
                                .padding(2)
                                .offset(x: 4, y: -4)
                        }
                    }
                    GlassIconButton(systemImage: "square.and.arrow.up") {
                        showShare = true
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                Spacer()
            }

            // 测量结果 / 尺寸
            if !measureResultText.isEmpty || !modelDimensions.isEmpty {
                VStack {
                    Spacer()
                    GlassCard {
                        VStack(spacing: 6) {
                            if !measureResultText.isEmpty {
                                HStack(spacing: 8) {
                                    Image(systemName: "ruler")
                                        .foregroundStyle(.green)
                                    Text(measureResultText)
                                        .font(.system(.body, design: .rounded, weight: .bold))
                                }
                            }
                            if !modelDimensions.isEmpty {
                                Text(modelDimensions)
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            Text(measureMode
                                 ? "测量已开启：轻点模型中的两个位置查看距离"
                                 : "点击右上角标尺可开启测量")
                                .font(.system(.caption2, design: .rounded))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .frame(maxWidth: 340)
                    .padding(.bottom, 24)
                }
            }
        }
        .statusBarHidden(true)
        .onAppear {
            loadedScene = try? SCNScene(url: item.url)
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: [item.url])
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: - 系统分享面板

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }
}