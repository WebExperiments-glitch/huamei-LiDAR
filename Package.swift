// swift-tools-version:5.7

//
//  Package.swift
//
//
//  Created by jonathan decorion on 10/28/25.
//

import PackageDescription

let package = Package(
    name: "SwiftUILiDAR",
    platforms: [
        .iOS(.v26)
    ],
    products: [
        .library(
            name: "SwiftUILiDAR",
            targets: ["SwiftUILiDAR"]
        ),
    ],
    targets: [
        .target(
            name: "SwiftUILiDAR",
            path: "Lidar Scan"
        )
    ]
)