# huamei-LiDAR (V0.1 RC)

> 话梅 · 苹果激光雷达 3D 扫描仪 — 基于 MIT 开源项目 SwiftUI-LiDAR 的二次开发版。
> 当前版本：**V0.1 RC**（发布候选版，优化BAG中）

用苹果 LiDAR（iPhone 12 Pro 及以上 / 2020 年后 iPad Pro）实时扫描三维环境，导出多种 3D 格式，自带 iOS 26 液态玻璃（Liquid Glass）界面。

## ✨ 功能

- **实时扫描**：ARKit 场景重建（`sceneReconstruction`）+ 深度图，网格带语义分类
- **多格式导出**：OBJ（带顶点点色）/ PLY / STL / GLB / USDZ
- **两种内容**：网格模型 或 点云（OBJ / PLY）
- **相机纹理上色**：把镜头画面颜色采样到模型表面（OBJ / PLY / GLB）
- **深度数据导出**：16-bit 深度 PNG（毫米）+ 置信度 PNG
- **测量**：预览页两点距离测量 + 自动显示模型包围盒尺寸（真实米制）
- **3D 预览**：旋转 / 缩放 / 平移 / 打标签 / 分享 / 删除
- **液态玻璃 UI**：iOS 26 原生 `.glass` 材质 + `glassEffect`，深色主题

## 📱 要求

- 部署目标 **iOS 26.0**（Liquid Glass 需要；对应 Xcode 26）
- 开发/验证环境为 **iOS / iPadOS 27**，向下兼容 iOS 26（部署目标即最低支持版本）
- 真机：iPhone 12 Pro/13 Pro/14 Pro/15 Pro/16 Pro，或 2020 年后的 iPad Pro（带 LiDAR；模拟器不支持）
- 支持 iPhone 与 iPad

## 🚀 无 Mac 编译（GitHub Actions）

本仓库已配置 `.github/workflows/build.yml`，用 GitHub 免费 macOS Runner 上的真 Xcode 26 编译，无需本机 Mac：

1. 在 GitHub 新建**公开仓库**，命名为 `huamei-LiDAR`（公开仓库 macOS 编译免费且不限时）
2. 本地推送：

   ```bash
   git init
   git add .
   git commit -m "huamei-LiDAR V0.1 RC"
   git branch -M main
   git remote add origin https://github.com/<你的账号>/huamei-LiDAR.git
   git push -u origin main
   ```

3. 打开仓库 **Actions** 页 → `iOS Build` → `Run workflow`（推送 main 分支也会自动触发）
4. 构建完成后，下载工件 `LidarScan-device-unsigned`（内含未签名的 `Lidar Scan.app`）
5. **签名安装到你的设备**（任选其一）：
   - **SideStore / AltStore**：把 .zip 内的 `.app` 转成 .ipa 导入，自动签名续期
   - **爱思助手**：设备连电脑，导入签名安装
   - **zsign**（Windows）：`zsign -k 你的证书.p12 -p 密码 -m 描述文件.mobileprovision -o out.ipa "Lidar Scan.app"`
   - 注意：免费开发者账号签名 **7 天过期**，可用 SideStore 自动续签

> 若本地有 Mac：直接 `open "huamei-LiDAR.xcodeproj"`，选择 `Lidar Scan` scheme，真机运行即可（记得把 `DEVELOPMENT_TEAM` 换成你自己的）。

## 📦 版本信息

| 项 | 值 |
|---|---|
| 版本 | 0.1（V0.1 RC） |
| 显示名 | huamei-LiDAR |
| Bundle ID | com.Lidar-Scan（可自行修改后重新签名） |
| 部署目标 | iOS 26.0 |
| 设备 | iPhone / iPad（1,2） |

## 🛠️ 技术栈

- SwiftUI（iOS 26 Liquid Glass）
- ARKit（LiDAR 场景重建 / 深度）
- RealityKit（AR 视图容器）
- SceneKit（.OBJ / .USDZ 预览、测量、标签）
- ModelIO（USDZ 导出）/ 自研 GLB · PLY · STL · OBJ 写出器

## 📁 目录

```
.
├── huamei-LiDAR.xcodeproj      # Xcode 工程
├── .github/workflows/build.yml # GitHub Actions（Xcode 26 编译）
├── Lidar Scan/                 # 源码
│   ├── LidarScanApp.swift          # 入口（强制深色）
│   ├── StartView.swift             # 首页（液态玻璃）
│   ├── Views/GlassKit.swift        # 液态玻璃组件库
│   ├── Services/
│   │   ├── ScanTypes.swift         # 格式/网格/快照模型
│   │   ├── MeshExtractor.swift     # ARMeshAnchor → 网格数据
│   │   ├── TextureMapper.swift     # 相机取色调顶点颜色
│   │   ├── MeshWriter.swift        # OBJ/PLY/STL/GLB/USDZ 写出器
│   │   ├── DepthExporter.swift     # 深度图/置信度 PNG
│   │   ├── ScanFileExporter.swift  # 导出协调（目录/命名/去重）
│   │   └── MeasurementService.swift# 尺寸/距离/体积
│   └── Modules/
│       ├── Capture 3D Scan/        # 扫描页 + 导出面板 + 会话管理
│       └── View 3D Scans/          # 列表 / 预览 / 测量 / 标签
```

## 📜 License

MIT License（原项目 [SwiftLiDAR](https://github.com/cedanmisquith/SwiftLiDAR)，Copyright (c) 2025 Cedan Misquith；二次开发部分遵循同一协议）。