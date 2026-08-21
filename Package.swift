// swift-tools-version:6.3.1
import PackageDescription

let package = Package(
  name: "IMGLYPluginAutoCaptions",
  platforms: [.iOS(.v16)],
  products: [
    .library(name: "IMGLYPluginAutoCaptions", targets: ["IMGLYPluginAutoCaptions"]),
  ],
  dependencies: [
    .package(url: "https://github.com/imgly/IMGLYUI-swift.git", exact: "1.81.0-rc.1"),
  ],
  targets: [
    .target(
      name: "IMGLYPluginAutoCaptions",
      dependencies: [
        .product(name: "IMGLYUI", package: "IMGLYUI-swift"),
      ],
    ),
    .testTarget(
      name: "IMGLYPluginAutoCaptionsTests",
      dependencies: ["IMGLYPluginAutoCaptions"],
    ),
  ],
)
