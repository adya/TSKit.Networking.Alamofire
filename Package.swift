// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TSKit.Networking.Alamofire",
    products: [
        .library(
            name: "TSKit.Networking.Alamofire",
            targets: ["TSKit.Networking.Alamofire"]),
    ],
    dependencies: [
        .package(url: "https://github.com/adya/TSKit.Core.git", .upToNextMajor(from: "2.10.0")),
        .package(url: "https://github.com/adya/TSKit.Log.git", .upToNextMajor(from: "2.3.0")),
        .package(url: "https://github.com/adya/TSKit.Networking.git", .upToNextMajor(from: "5.2.0")),
        .package(url: "https://github.com/Alamofire/Alamofire.git", .upToNextMajor(from: "4.0.0")),
        .package(url: "https://github.com/Quick/Nimble.git", .upToNextMajor(from: "9.0.0")),
        .package(url: "https://github.com/Quick/Quick.git", .upToNextMajor(from: "3.0.0")),
        .package(url: "https://github.com/AliSoftware/OHHTTPStubs.git", .upToNextMajor(from: "9.0.0")),
    ],
    targets: [
        .target(
            name: "TSKit.Networking.Alamofire",
            dependencies: ["TSKit.Core", "TSKit.Log", "TSKit.Networking", "Alamofire"]),
        .testTarget(
            name: "TSKit.Networking.AlamofireTests",
            dependencies: ["TSKit.Networking.Alamofire",
                           "Quick",
                           "Nimble",
                           "Alamofire",
                           .product(name: "OHHTTPStubsSwift", package: "OHHTTPStubs")]),
    ]
)
