//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Testing
import SWBCore
import SWBProtocol
import SWBTestSupport
import SWBTaskExecution
import SWBUtil

@Suite
fileprivate struct SWBWebAssemblyPlatformTests: CoreBasedTests {
    @Test(.requireSDKs(.host))
    func wasmSwiftSDKRunDestination() async throws {
        try await withTemporaryDirectory { tmpDir in
            let clangCompilerPath = try await self.clangCompilerPath
            let swiftCompilerPath = try await self.swiftCompilerPath
            let swiftVersion = try await self.swiftVersion
            let testProject = try await TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("SourceFile.c"),
                        TestFile("SwiftFile.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "MyLibrary",
                        type: .staticLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [
                                                    "GENERATE_INFOPLIST_FILE": "YES",
                                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                                    "SDKROOT": "auto",
                                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                    "CLANG_ENABLE_MODULES": "YES",
                                                    "SWIFT_EXEC": swiftCompilerPath.str,
                                                    "SWIFT_VERSION": swiftVersion,
                                                    "CC": clangCompilerPath.str,
                                                    "CLANG_EXPLICIT_MODULES_LIBCLANG_PATH": libClangPath.str,
                                                    "CLANG_USE_RESPONSE_FILE": "NO",
                                                   ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("SourceFile.c"),
                                TestBuildFile("SwiftFile.swift"),
                            ]),
                        ]),
                ])
            // Use a dedicated core for this test so the SDKs it registers do not impact other tests
            let core = try await Self.makeCore()
            let tester = try TaskConstructionTester(core, testProject)

            // Swift SDK contents
            let sdkManifestContents = """
            {
                "schemaVersion" : "4.0",
                "targetTriples" : {
                    "wasm32-unknown-wasip1" : {
                        "sdkRootPath" : "WASI.sdk",
                        "swiftResourcesPath" : "swift.xctoolchain/usr/lib/swift_static",
                        "swiftStaticResourcesPath" : "swift.xctoolchain/usr/lib/swift_static",
                        "toolsetPaths" : [
                            "toolset.json"
                        ]
                    }
                }
            }
            """
            let sdkManifestDir = tmpDir
            try localFS.createDirectory(sdkManifestDir)
            let sdkManifestPath = sdkManifestDir.join("swift-sdk.json")
            try await localFS.writeFileContents(sdkManifestDir.join("swift-sdk.json"), waitForNewTimestamp: false, body: { $0.write(sdkManifestContents) })
            try await localFS.writeFileContents(sdkManifestDir.join("toolset.json"), waitForNewTimestamp: false, body: { stream in
                stream.write("""
                {
                    "rootPath" : "swift.xctoolchain/usr/bin",
                    "schemaVersion" : "1.0",
                    "swiftCompiler" : {
                        "extraCLIOptions" : [
                            "-static-stdlib"
                        ]
                    }
                }
                """)
            })

            let sysroot = sdkManifestDir.join("WASI.sdk")
            let sdkroot = sdkManifestDir.join("WASI.sdk")

            let destination = try RunDestinationInfo(sdkManifestPath: sdkManifestPath, triple: "wasm32-unknown-wasip1", targetArchitecture: "wasm32", supportedArchitectures: ["wasm32"], disableOnlyActiveArch: false, core: core)
            let parameters = BuildParameters(configuration: "Debug", activeRunDestination: destination)
            await tester.checkBuild(parameters, runDestination: nil, fs: localFS) { results in
                results.checkTask(.matchTargetName("MyLibrary"), .matchRuleType("CompileC")) { task in
                    task.checkCommandLineContains([
                        [clangCompilerPath.str],
                        ["-target", "wasm32-unknown-wasip1"],
                        ["--sysroot", sysroot.str],
                    ].reduce([], +))
                }

                results.checkTask(.matchTargetName("MyLibrary"), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineContains([
                        ["-resource-dir", sdkManifestDir.join("swift.xctoolchain").join("usr").join("lib").join("swift_static").str],
                        ["-static-stdlib"],
                        ["-sdk", sdkroot.str],
                        ["-sysroot", sysroot.str],
                        ["-target", "wasm32-unknown-wasip1"],
                    ].reduce([], +))
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }
        }
    }

    /// Regression test: a wasm app target depending on a library with platform specialization
    /// must not fail with `unable to find sdk 'webassembly'`.
    ///
    /// Two code paths in swift-build push `SDKROOT = platform.sdkCanonicalName` (= `"webassembly"`)
    /// for Swift-SDK-backed builds, neither of which has a matching SDK in the registry when the
    /// only wasm sysroot comes from a synthesized Swift SDK (whose canonical name is the manifest
    /// path, not the platform name):
    ///
    /// 1. `SpecializationParameters.imposed(on:workspaceContext:)`
    ///    in `swift-build/Sources/SWBCore/DependencyResolution.swift` — exercised by `MyLibrary`,
    ///    which is reachable via specialization from `MyApp`.
    /// 2. `addRunDestinationSettingsPlatformSDK` in
    ///    `swift-build/Sources/SWBCore/Settings/Settings.swift` else branch — exercised by
    ///    `MyMacOSLib`, whose configured SDK (`macosx`) does not match the destination platform
    ///    (`webassembly`) but whose `SUPPORTED_PLATFORMS` still includes wasm.
    @Test(.requireSDKs(.host))
    func wasmSwiftSDKDependencySpecialization() async throws {
        try await withTemporaryDirectory { (tmpDir: Path) in
            let clangCompilerPath = try await self.clangCompilerPath
            let swiftCompilerPath = try await self.swiftCompilerPath
            let swiftVersion = try await self.swiftVersion
            let testProject = try await TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("App.swift"),
                        TestFile("Lib.swift"),
                        TestFile("MacLib.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "MyApp",
                        type: .commandLineTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [
                                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                                    "SDKROOT": "auto",
                                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                    "CLANG_ENABLE_MODULES": "YES",
                                                    "SWIFT_EXEC": swiftCompilerPath.str,
                                                    "SWIFT_VERSION": swiftVersion,
                                                    "CC": clangCompilerPath.str,
                                                    "CLANG_EXPLICIT_MODULES_LIBCLANG_PATH": libClangPath.str,
                                                    "CLANG_USE_RESPONSE_FILE": "NO",
                                                   ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([TestBuildFile("App.swift")]),
                        ],
                        dependencies: ["MyLibrary", "MyMacOSLib"]
                    ),
                    // Exercises DependencyResolution.swift `SpecializationParameters.imposed(on:)`:
                    // gets specialized to wasm via the dependency from MyApp.
                    TestStandardTarget(
                        "MyLibrary",
                        type: .staticLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [
                                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                                    "SDKROOT": "auto",
                                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                    "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES",
                                                    "CLANG_ENABLE_MODULES": "YES",
                                                    "SWIFT_EXEC": swiftCompilerPath.str,
                                                    "SWIFT_VERSION": swiftVersion,
                                                    "CC": clangCompilerPath.str,
                                                    "CLANG_EXPLICIT_MODULES_LIBCLANG_PATH": libClangPath.str,
                                                    "CLANG_USE_RESPONSE_FILE": "NO",
                                                   ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([TestBuildFile("Lib.swift")]),
                        ]),
                    // Exercises Settings.swift `addRunDestinationSettingsPlatformSDK` else branch:
                    // configured SDK ("macosx") differs from destination platform ("webassembly")
                    // but SUPPORTED_PLATFORMS includes wasm, so the SDK gets re-targeted.
                    // No ALLOW_TARGET_PLATFORM_SPECIALIZATION here — that flag would short-circuit
                    // the early-return guard at Settings.swift:3600 and skip the else branch.
                    TestStandardTarget(
                        "MyMacOSLib",
                        type: .staticLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [
                                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                                    "SDKROOT": "macosx",
                                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                    "CLANG_ENABLE_MODULES": "YES",
                                                    "SWIFT_EXEC": swiftCompilerPath.str,
                                                    "SWIFT_VERSION": swiftVersion,
                                                    "CC": clangCompilerPath.str,
                                                    "CLANG_EXPLICIT_MODULES_LIBCLANG_PATH": libClangPath.str,
                                                    "CLANG_USE_RESPONSE_FILE": "NO",
                                                   ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([TestBuildFile("MacLib.swift")]),
                        ]),
                ])
            // Use a dedicated core for this test so the SDKs it registers do not impact other tests
            let core = try await Self.makeCore()
            let tester = try TaskConstructionTester(core, testProject)

            let sdkManifestContents = """
            {
                "schemaVersion" : "4.0",
                "targetTriples" : {
                    "wasm32-unknown-wasip1" : {
                        "sdkRootPath" : "WASI.sdk",
                        "swiftResourcesPath" : "swift.xctoolchain/usr/lib/swift_static",
                        "swiftStaticResourcesPath" : "swift.xctoolchain/usr/lib/swift_static",
                        "toolsetPaths" : [ "toolset.json" ]
                    }
                }
            }
            """
            let sdkManifestDir = tmpDir
            try localFS.createDirectory(sdkManifestDir)
            let sdkManifestPath = sdkManifestDir.join("swift-sdk.json")
            try await localFS.writeFileContents(sdkManifestPath, waitForNewTimestamp: false, body: { $0.write(sdkManifestContents) })
            try await localFS.writeFileContents(sdkManifestDir.join("toolset.json"), waitForNewTimestamp: false, body: { stream in
                stream.write("""
                {
                    "rootPath" : "swift.xctoolchain/usr/bin",
                    "schemaVersion" : "1.0",
                    "swiftCompiler" : { "extraCLIOptions" : [ "-static-stdlib" ] }
                }
                """)
            })

            let sysroot = sdkManifestDir.join("WASI.sdk")
            let sdkroot = sdkManifestDir.join("WASI.sdk")

            let destination = try RunDestinationInfo(sdkManifestPath: sdkManifestPath, triple: "wasm32-unknown-wasip1", targetArchitecture: "wasm32", supportedArchitectures: ["wasm32"], disableOnlyActiveArch: false, core: core)
            let parameters = BuildParameters(configuration: "Debug", activeRunDestination: destination)

            // Path 1: build MyApp — exercises DependencyResolution.swift `SpecializationParameters.imposed(on:)`
            // because MyLibrary is reached via dependency from MyApp, which pre-imposes SDKROOT.
            // Without the DependencyResolution fix, MyLibrary's specialized configuration would
            // fail with `unable to find sdk 'webassembly'`.
            await tester.checkBuild(parameters, runDestination: nil, targetName: "MyApp", fs: localFS) { results in
                results.checkTask(.matchTargetName("MyLibrary"), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineContains([
                        ["-static-stdlib"],
                        ["-sdk", sdkroot.str],
                        ["-sysroot", sysroot.str],
                        ["-target", "wasm32-unknown-wasip1"],
                    ].reduce([], +))
                }

                results.checkNoErrors()
            }

            // Path 2: build MyMacOSLib standalone — exercises Settings.swift `addRunDestinationSettingsPlatformSDK`
            // else branch because no dependency imposes SDKROOT, and the target's own SDK ("macosx")
            // doesn't match the destination platform ("webassembly"). Without the Settings.swift fix,
            // this branch would push SDKROOT="webassembly" and the lookup would fail.
            await tester.checkBuild(parameters, runDestination: nil, targetName: "MyMacOSLib", fs: localFS) { results in
                results.checkTask(.matchTargetName("MyMacOSLib"), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineContains([
                        ["-sdk", sdkroot.str],
                        ["-sysroot", sysroot.str],
                        ["-target", "wasm32-unknown-wasip1"],
                    ].reduce([], +))
                }

                results.checkNoErrors()
            }
        }
    }

    /// Smoke test: ensures wasm test compiles emit a `-plugin-path` for swift-testing
    /// macros, derived from the toolchain that holds the active swiftc (`SWIFT_EXEC`).
    ///
    /// `WebAssemblySettingsBuilderExtension.getTargetTestingSwiftPluginFlags` overrides
    /// the universal `Settings.getTargetTestingSwiftPluginFlags` so the plugin path is
    /// derived from `SWIFT_TOOLS_DIR`/`SWIFT_EXEC` rather than `TOOLCHAIN_DIR`. This
    /// matters under SwiftPM-driven cross-compiles to wasm where `TOOLCHAIN_DIR`
    /// resolves to XcodeDefault.xctoolchain even when `SWIFT_EXEC` points at a
    /// development snapshot — the XcodeDefault `libTestingMacros.dylib` then expands
    /// `@Test` against the wasm SDK's newer `Testing.swiftmodule`, producing
    /// "extra argument 'sourceLocation'" errors.
    ///
    /// Limitation: in this test environment `swiftCompilerPath` and `TOOLCHAIN_DIR`
    /// happen to point at the same toolchain (XcodeDefault), so this test passes whether
    /// or not the extension is installed. The actual XcodeDefault-vs-active-toolchain
    /// divergence is exercised by JavaScriptKit's `js test` end-to-end run; this test
    /// catches regressions where the wasm-domain plugin-path stops being derived from
    /// the toolchain that holds swiftc.
    @Test(.requireSDKs(.host))
    func wasmTestingPluginPathDerivedFromSwiftExec() async throws {
        try await withTemporaryDirectory { (tmpDir: Path) in
            let swiftCompilerPath = try await self.swiftCompilerPath
            let swiftVersion = try await self.swiftVersion
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [TestFile("MyTest.swift")]),
                targets: [
                    TestStandardTarget(
                        "MyTests",
                        type: .unitTest,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [
                                                    "GENERATE_INFOPLIST_FILE": "YES",
                                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                                    "SDKROOT": "auto",
                                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                    "SWIFT_EXEC": swiftCompilerPath.str,
                                                    "SWIFT_VERSION": swiftVersion,
                                                    "ENABLE_TESTING_SEARCH_PATHS": "YES",
                                                   ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([TestBuildFile("MyTest.swift")]),
                        ]),
                ])
            // Use a dedicated core for this test so the SDKs it registers do not impact other tests
            let core = try await Self.makeCore()
            let tester = try TaskConstructionTester(core, testProject)

            let sdkManifestContents = """
            {
                "schemaVersion" : "4.0",
                "targetTriples" : {
                    "wasm32-unknown-wasip1" : {
                        "sdkRootPath" : "WASI.sdk",
                        "swiftResourcesPath" : "swift.xctoolchain/usr/lib/swift_static",
                        "swiftStaticResourcesPath" : "swift.xctoolchain/usr/lib/swift_static",
                        "toolsetPaths" : [ "toolset.json" ]
                    }
                }
            }
            """
            let sdkManifestDir = tmpDir
            try localFS.createDirectory(sdkManifestDir)
            let sdkManifestPath = sdkManifestDir.join("swift-sdk.json")
            try await localFS.writeFileContents(sdkManifestPath, waitForNewTimestamp: false, body: { $0.write(sdkManifestContents) })
            try await localFS.writeFileContents(sdkManifestDir.join("toolset.json"), waitForNewTimestamp: false, body: { stream in
                stream.write("""
                {
                    "rootPath" : "swift.xctoolchain/usr/bin",
                    "schemaVersion" : "1.0",
                    "swiftCompiler" : { "extraCLIOptions" : [ "-static-stdlib" ] }
                }
                """)
            })

            let destination = try RunDestinationInfo(sdkManifestPath: sdkManifestPath, triple: "wasm32-unknown-wasip1", targetArchitecture: "wasm32", supportedArchitectures: ["wasm32"], disableOnlyActiveArch: false, core: core)
            let parameters = BuildParameters(configuration: "Debug", activeRunDestination: destination)

            await tester.checkBuild(parameters, runDestination: nil, fs: localFS) { results in
                results.checkTask(.matchTargetName("MyTests"), .matchRuleType("SwiftDriver Compilation")) { task in
                    // The extension derives the testing-plugin path from the toolchain that holds
                    // the active swiftc (`SWIFT_EXEC`), not from `TOOLCHAIN_DIR`. Verify the emitted
                    // `-plugin-path` matches `<toolchain>/usr/lib/swift/host/plugins/testing` where
                    // `<toolchain>` is `SWIFT_EXEC`'s enclosing `<usr-parent>` (i.e. the parent of
                    // the `usr/bin` that contains swiftc).
                    let expectedPluginPath = swiftCompilerPath.dirname.dirname.join("lib/swift/host/plugins/testing").str

                    let words = Array(task.commandLineAsStrings)
                    var pluginPathArgs: [String] = []
                    for idx in words.indices where words[idx] == "-plugin-path" {
                        let next = idx + 1
                        if next < words.count {
                            pluginPathArgs.append(words[next])
                        }
                    }
                    #expect(
                        pluginPathArgs.contains(expectedPluginPath),
                        "Expected -plugin-path \(expectedPluginPath); got pluginPaths=\(pluginPathArgs)"
                    )
                }

                results.checkNoErrors()
            }
        }
    }
}
