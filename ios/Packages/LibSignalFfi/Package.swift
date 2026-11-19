// swift-tools-version:6.0
//
// The Rust half of libsignal (`libsignal_ffi.a`), as the XCFramework Signal
// publishes for each release. The Swift half is the `LibSignalClient`
// package from github.com/signalapp/libsignal at the SAME version (see
// `project.yml`); a mismatch fails to link with an undefined
// `signal_ffi_version_X_Y_Z` symbol.
//
// SwiftPM downloads the zip once and refuses it unless its SHA-256 matches
// `checksum`, which is the value Signal publishes next to the GitHub release
// (`libsignal-client-ios-build-v<version>.xcframework.zip.sha256`).
// To bump: change both versions, then `ios/scripts/libsignal-checksum.sh <version>`.
import PackageDescription

let libsignalVersion = "0.108.1"

let package = Package(
    name: "LibSignalFfi",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "LibSignalFfi", targets: ["LibSignalFfi"]),
    ],
    targets: [
        .binaryTarget(
            name: "LibSignalFfi",
            url: "https://build-artifacts.signal.org/libraries/libsignal-client-ios-build-v\(libsignalVersion).xcframework.zip",
            checksum: "1a1ebf8b50a9f885ae0d336b1aaa5d0d1b984794ef9280b20df11c3156a896cb"
        ),
    ]
)
