//
//  LidarScanApp.swift
//  Lidar Scan (二次开发)
//

import SwiftUI

@main
struct LidarScanApp: App {
    var body: some Scene {
        WindowGroup {
            StartView()
                .environment(\.colorScheme, .dark)
                .preferredColorScheme(.dark)
        }
    }
}