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

public import SWBUtil
import SWBCore
import SWBMacro
import Foundation

public let initializePlugin: PluginInitializationFunction = { manager in
    manager.register(WebAssemblyPlatformSpecsExtension(), type: SpecificationsExtensionPoint.self)
    manager.register(WebAssemblyPlatformExtension(), type: PlatformInfoExtensionPoint.self)
    manager.register(WebAssemblySettingsBuilderExtension(), type: SettingsBuilderExtensionPoint.self)
}

struct WebAssemblyPlatformSpecsExtension: SpecificationsExtension {
    func specificationFiles(resourceSearchPaths: [Path]) -> Bundle? {
        findResourceBundle(nameWhenInstalledInToolchain: "SwiftBuild_SWBWebAssemblyPlatform", resourceSearchPaths: resourceSearchPaths, defaultBundle: Bundle.module)
    }

    func specificationDomains() -> [String: [String]] {
        ["webassembly": ["generic-unix"]]
    }
}

struct WebAssemblyPlatformExtension: PlatformInfoExtension {
    func additionalPlatforms(context: any PlatformInfoExtensionAdditionalPlatformsContext) throws -> [(path: Path, data: [String: PropertyListItem])] {
        [
            (.root, [
                "Type": .plString("Platform"),
                "Name": .plString("webassembly"),
                "Identifier": .plString("webassembly"),
                "Description": .plString("webassembly"),
                "FamilyName": .plString("WebAssembly"),
                "FamilyIdentifier": .plString("webassembly"),
                "IsDeploymentPlatform": .plString("YES"),
            ])
        ]
    }

    func platformName(triple: LLVMTriple) -> String? {
        if triple.system.hasPrefix("wasi") {
            return "webassembly"
        }

        return nil
    }
}

/// Provides wasm-aware overrides for testing-related Swift compiler plugin
/// flags.
///
/// `Settings.getTargetTestingSwiftPluginFlags(_:)` derives the testing macro
/// plugin path from `TOOLCHAIN_DIR`. Under SwiftPM-driven cross-compiles to
/// wasm32, `TOOLCHAIN_DIR` frequently resolves to XcodeDefault even when
/// `SWIFT_EXEC` (the actual swiftc that will be invoked) lives in a
/// different (e.g. development snapshot) toolchain. The XcodeDefault
/// `libTestingMacros.dylib` is then loaded for `@Test` etc., producing
/// "extra argument 'sourceLocation'" / "missing argument 'sourceBounds'"
/// errors when type-checked against the wasm SDK's swift-testing.
///
/// We override the hook for the wasm domain only and derive the plugin path
/// from `SWIFT_TOOLS_DIR` (the bin directory of the active swiftc) so the
/// plugin matches the swiftc that will load it.
struct WebAssemblySettingsBuilderExtension: SettingsBuilderExtension {
    func getTargetTestingSwiftPluginFlags(
        _ scope: MacroEvaluationScope,
        toolchainRegistry: ToolchainRegistry,
        sdkRegistry: SDKRegistry,
        activeRunDestination: SWBCore.RunDestinationInfo?,
        project: SWBCore.Project?
    ) -> [String] {
        guard scope.evaluate(BuiltinMacros.PLATFORM_NAME) == "webassembly" else { return [] }

        let swiftBinDir: Path
        let swiftToolsDir = scope.evaluate(BuiltinMacros.SWIFT_TOOLS_DIR)
        if !swiftToolsDir.isEmpty {
            let toolsPath = Path(swiftToolsDir)
            guard toolsPath.isAbsolute else { return [] }
            swiftBinDir = toolsPath
        } else {
            let swiftExec = scope.evaluate(BuiltinMacros.SWIFT_EXEC)
            guard !swiftExec.isEmpty, swiftExec.isAbsolute else { return [] }
            swiftBinDir = swiftExec.dirname
        }

        guard swiftBinDir.basename == "bin" else { return [] }
        let usrDir = swiftBinDir.dirname
        guard usrDir.basename == "usr" else { return [] }

        let pluginPath = usrDir.join("lib/swift/host/plugins/testing")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: pluginPath.str, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        return ["-plugin-path", pluginPath.str]
    }
}
