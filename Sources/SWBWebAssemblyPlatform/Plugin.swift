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
import SWBProtocol
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
        activeRunDestination: SWBProtocol.RunDestinationInfo?,
        project: SWBCore.Project?
    ) -> [String] {
        let platformName = scope.evaluate(BuiltinMacros.PLATFORM_NAME)
        let swiftExec = scope.evaluate(BuiltinMacros.SWIFT_EXEC)
        let swiftToolsDir = scope.evaluate(BuiltinMacros.SWIFT_TOOLS_DIR)
        fputs("DEBUG WebAssemblySettingsBuilderExtension: PLATFORM_NAME=\(platformName) SWIFT_EXEC=\(swiftExec.str) SWIFT_TOOLS_DIR=\(swiftToolsDir)\n", stderr)
        guard platformName == "webassembly" else {
            fputs("DEBUG   -> skipped: platform not webassembly\n", stderr)
            return []
        }

        let swiftBinDir: Path
        if !swiftToolsDir.isEmpty {
            let toolsPath = Path(swiftToolsDir)
            guard toolsPath.isAbsolute else {
                fputs("DEBUG   -> skipped: swiftToolsDir not absolute\n", stderr)
                return []
            }
            swiftBinDir = toolsPath
        } else {
            guard !swiftExec.isEmpty, swiftExec.isAbsolute else {
                fputs("DEBUG   -> skipped: swiftExec empty or not absolute\n", stderr)
                return []
            }
            swiftBinDir = swiftExec.dirname
        }

        guard swiftBinDir.basename == "bin" else {
            fputs("DEBUG   -> skipped: swiftBinDir basename != 'bin' (=\(swiftBinDir.str))\n", stderr)
            return []
        }
        let usrDir = swiftBinDir.dirname
        guard usrDir.basename == "usr" else {
            fputs("DEBUG   -> skipped: usrDir basename != 'usr' (=\(usrDir.str))\n", stderr)
            return []
        }
        let toolchainRoot = usrDir.dirname

        guard toolchainRegistry.toolchains.contains(where: { $0.path == toolchainRoot }) else {
            let registryPaths = toolchainRegistry.toolchains.map { $0.path.str }.sorted().joined(separator: ", ")
            fputs("DEBUG   -> skipped: toolchainRoot \(toolchainRoot.str) not in registry; registry contains [\(registryPaths)]\n", stderr)
            return []
        }

        let pluginPath = usrDir.join("lib/swift/host/plugins/testing")
        fputs("DEBUG   -> emitting -plugin-path \(pluginPath.str)\n", stderr)
        return ["-plugin-path", pluginPath.str]
    }
}
