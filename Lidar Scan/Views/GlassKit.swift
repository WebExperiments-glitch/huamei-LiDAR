//
//  GlassKit.swift
//  Lidar Scan (二次开发)
//
//  液态玻璃 UI 组件库：磨砂 + 高光描边 + 柔和投影，适配深色主题。
//

import SwiftUI

// MARK: - 玻璃卡片

struct GlassCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(20)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .glassEffect(.regular)
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.32), Color.white.opacity(0.05)],
                                       startPoint: .topLeading,
                                       endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 8)
    }
}

// MARK: - 玻璃胶囊按钮

struct GlassButton: View {
    let title: String
    var systemImage: String?
    var prominent: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage = systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(.system(.body, design: .rounded, weight: .semibold))
            }
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                prominent
                    ? AnyShapeStyle(.white.opacity(0.22))
                    : AnyShapeStyle(.ultraThinMaterial),
                in: Capsule()
            )
            .glassEffect(.regular)
            .overlay(
                Capsule().strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.4), Color.white.opacity(0.06)],
                                   startPoint: .top,
                                   endPoint: .bottom),
                    lineWidth: 1
                )
            )
            .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
        }
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .buttonStyle(.plain)
    }
}

// MARK: - 玻璃圆形图标按钮

struct GlassIconButton: View {
    let systemImage: String
    var prominent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(width: 44, height: 44)
                .background(
                    prominent
                        ? AnyShapeStyle(.white.opacity(0.22))
                        : AnyShapeStyle(.ultraThinMaterial),
                    in: Circle()
                )
                .glassEffect(.regular)
                .overlay(
                    Circle().strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.4), Color.white.opacity(0.06)],
                                       startPoint: .top,
                                       endPoint: .bottom),
                        lineWidth: 1
                    )
                )
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 胶囊式分段选择器（玻璃版）

struct GlassSegmentedPicker<T: CaseIterable & Hashable & RawRepresentable>: View where T.RawValue == String {
    let title: String
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(T.allCases), id: \.self) { item in
                let isSelected = item == selection
                Button {
                    selection = item
                } label: {
                    Text(item.rawValue)
                        .font(.system(.subheadline, design: .rounded, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary.opacity(0.7)))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            isSelected
                                ? AnyShapeStyle(.white.opacity(0.2))
                                : AnyShapeStyle(.clear),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .glassEffect(.regular)
        .overlay(
            Capsule().strokeBorder(
                LinearGradient(colors: [Color.white.opacity(0.25), Color.white.opacity(0.05)],
                               startPoint: .top,
                               endPoint: .bottom),
                lineWidth: 1
            )
        )
    }
}

// MARK: - 状态标签

struct StatusChip: View {
    let text: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isActive ? Color.green : Color.gray)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .glassEffect(.regular)
    }
}

// MARK: - 玻璃输入框

struct GlassTextField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        TextField(title, text: $text)
            .font(.system(.body, design: .rounded))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .glassEffect(.regular)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
    }
}

// MARK: - 玻璃开关行

struct GlassToggleRow: View {
    let title: String
    let caption: String
    @Binding var isOn: Bool
    var enabled: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $isOn) {
                Text(title)
                    .font(.system(.body, design: .rounded, weight: .medium))
            }
            .tint(.white.opacity(0.5))
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)

            Text(caption)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.primary.opacity(0.55))
        }
    }
}

// MARK: - 玻璃背景（整页）

struct GlassBackground<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [
                Color(red: 0.10, green: 0.10, blue: 0.16),
                Color(red: 0.05, green: 0.05, blue: 0.09),
            ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            content
        }
    }
}