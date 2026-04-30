//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Testing
@_spi(Testing) import SWBCore
import SWBTestSupport

@Suite
fileprivate struct WebAssemblyExecutableExtensionTests: CoreBasedTests {
    @Test(arguments: [
        (domain: "wasi", identifier: "com.apple.product-type.tool", expected: "wasm"),
        (domain: "wasi", identifier: "com.apple.product-type.tool.host-build", expected: "wasm"),
        (domain: "wasi", identifier: "com.apple.product-type.tool.swiftpm-test-runner", expected: "wasm"),
        (domain: "emscripten", identifier: "com.apple.product-type.tool", expected: "js"),
        (domain: "emscripten", identifier: "com.apple.product-type.tool.host-build", expected: "wasm"),
        (domain: "emscripten", identifier: "com.apple.product-type.tool.swiftpm-test-runner", expected: "js"),
        (domain: "webassembly", identifier: "com.apple.product-type.tool", expected: "wasm"),
        (domain: "webassembly", identifier: "com.apple.product-type.tool.host-build", expected: "wasm"),
        (domain: "webassembly", identifier: "com.apple.product-type.tool.swiftpm-test-runner", expected: "wasm"),
    ] as [(domain: String, identifier: String, expected: String)])
    func executableExtensionByDomain(
        domain: String,
        identifier: String,
        expected: String,
    ) async throws {
        let core = try await Self.makeCore()
        let spec = try core.specRegistry.getSpec(
            identifier,
            domain: domain,
            ofType: ProductTypeSpec.self,
        )
        let observed = try spec.evaluateStringMacro("EXECUTABLE_EXTENSION")
        #expect(
            observed == expected,
            "\(domain):\(identifier) must declare EXECUTABLE_EXTENSION = \"\(expected)\" (got \"\(observed)\")",
        )
    }
}
