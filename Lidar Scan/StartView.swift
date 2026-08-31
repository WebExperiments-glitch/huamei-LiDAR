//
//  StartView.swift
//  Lidar Scan (二次开发)
//
//  首页：液态玻璃风格入口，LiDAR 能力检测。
//

import SwiftUI
import ARKit

struct StartView: View {
    @State private var showScanView = false
    @State private var showList = false

    private var lidarCapable: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    var body: some View {
        NavigationStack {
            GlassBackground {
                VStack(spacing: 28) {
                    Spacer()

                    // Logo / 标题
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(colors: [Color(red: 0.45, green: 0.35, blue: 0.95),
                                                        Color(red: 0.16, green: 0.55, blue: 0.95)],
                                               startPoint: .topLeading,
                                               endPoint: .bottomTrailing)
                            )
                            .frame(width: 96, height: 96)
                            .shadow(color: Color(red: 0.3, green: 0.4, blue: 1.0).opacity(0.5),
                                    radius: 22, y: 8)
                        Image(systemName: "view.3d")
                            .font(.system(size: 42, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .padding(.bottom, 4)

                    VStack(spacing: 8) {
                        // 主标题
                        Group {
                            Text("激光雷达 3D 扫描")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            + Text("LiDAR")
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(red: 0.55, green: 0.70, blue: 1.0))
                        }
                        Text("iPhone 12 Pro / iPad Pro 以上 · ARKit 实时场景重建")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                    }

                    Spacer()

                    if lidarCapable {
                        // 功能按钮
                        VStack(spacing: 16) {
                            GlassButton(title: "开始扫描",
                                        systemImage: "camera.viewfinder",
                                        prominent: true) {
                                showScanView = true
                            }
                            .frame(maxWidth: .infinity)

                            GlassButton(title: "查看扫描模型",
                                        systemImage: "square.stack.3d.up.fill") {
                                showList = true
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .frame(maxWidth: 340)

                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11))
                            Text("扫描以真实尺寸（米）导出 OBJ / PLY / STL / GLB / USDZ")
                                .font(.system(.caption, design: .rounded))
                        }
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.bottom, 32)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 40))
                            Text("此设备不支持 LiDAR")
                                .font(.system(.title3, weight: .bold, design: .rounded))
                            Text("该功能需要搭载激光雷达扫描仪的 iPhone 12 Pro 及以上机型，或 2020 年后的 iPad Pro")
                                .font(.system(.subheadline, design: .rounded))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .padding(.bottom, 48)
                    }

                }
                .padding(.horizontal, 32)
                .navigationDestination(isPresented: $showScanView) {
                    Capture3DScanView().navigationBarHidden(true)
                }
                .navigationDestination(isPresented: $showList) {
                    View3DScansView().navigationBarHidden(true)
                }
            }
        }
    }
}

#Preview {
    StartView()
}