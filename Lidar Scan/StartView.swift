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
                        // huamei 动漫角色（AI 生成的 Q 版形象）
                        Image("Mascot")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 96, height: 96)
                            .clipShape(Circle())
                            .overlay(
                                Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 8)
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
                        .padding(.bottom, 20)

                        // 开源信息
                        VStack(spacing: 10) {
                            Link(destination: URL(string: "https://github.com/WebExperiments-glitch/huamei-LiDAR")!) {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 13, weight: .semibold))
                                    Text("GitHub · huamei-LiDAR")
                                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                }
                                .foregroundStyle(.white.opacity(0.75))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .background(.white.opacity(0.10), in: Capsule())
                            }

                            Text("本应用基于 MIT 开源协议发布，核心源于 SwiftLiDAR 项目；\n源码与许可声明详见上方 GitHub 仓库。")
                                .font(.system(.caption2, design: .rounded))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white.opacity(0.35))

                            Text("huamei-LiDAR · V0.1 RC")
                                .font(.system(.caption2, design: .rounded, weight: .medium))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        .padding(.bottom, 16)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 40))
                            Text("此设备不支持 LiDAR")
                                .font(.system(size: 24, weight: .bold, design: .rounded))
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