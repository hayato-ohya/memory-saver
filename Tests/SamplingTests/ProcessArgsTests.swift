import Foundation
import Testing
@testable import Sampling

/// Builds a KERN_PROCARGS2-shaped buffer: argc, exec path, NUL padding, argv, environment.
private func procArgs(
    argc: Int32? = nil, path: String = "/Applications/B.app/Contents/MacOS/Helper",
    padding: Int = 3, args: [String], env: [String] = ["SECRET=--type=leak"]
) -> [UInt8] {
    var bytes = withUnsafeBytes(of: argc ?? Int32(args.count)) { Array($0) }
    bytes += Array(path.utf8) + [0]
    bytes += [UInt8](repeating: 0, count: padding)
    for arg in args + env { bytes += Array(arg.utf8) + [0] }
    return bytes
}

struct ProcessArgsTests {
    @Test func renderer() {
        let buffer = procArgs(args: ["/x/Helper", "--type=renderer", "--lang=en-US"])
        #expect(ProcessSampler.helperRole(procArgs: buffer) == "renderer")
    }

    @Test func utilitySubType() {
        let buffer = procArgs(args: [
            "/x/Helper", "--type=utility", "--utility-sub-type=network.mojom.NetworkService",
        ])
        #expect(ProcessSampler.helperRole(procArgs: buffer) == "utility (NetworkService)")
    }

    @Test func gpuWithoutPadding() {
        let buffer = procArgs(padding: 0, args: ["/x/Helper", "--type=gpu-process"])
        #expect(ProcessSampler.helperRole(procArgs: buffer) == "gpu-process")
    }

    @Test func noTypeArgument() {
        #expect(ProcessSampler.helperRole(procArgs: procArgs(args: ["/x/Helper", "--foo"])) == nil)
        #expect(ProcessSampler.helperRole(procArgs: procArgs(args: ["/x/Helper", "--type="])) == nil)
    }

    @Test func environmentIsNotRead() {
        // argc says one argument, so "--type=leak" in the environment must be ignored.
        let buffer = procArgs(args: ["/x/Helper"])
        #expect(ProcessSampler.helperRole(procArgs: buffer) == nil)
    }

    @Test func malformedBuffers() {
        #expect(ProcessSampler.helperRole(procArgs: [UInt8]()) == nil)
        #expect(ProcessSampler.helperRole(procArgs: [1, 0]) == nil)
        #expect(ProcessSampler.helperRole(procArgs: procArgs(argc: 0, args: ["--type=renderer"])) == nil)
        #expect(ProcessSampler.helperRole(procArgs: procArgs(argc: -5, args: ["--type=renderer"])) == nil)
        // argc larger than the arguments present runs off the end.
        #expect(ProcessSampler.helperRole(
            procArgs: procArgs(argc: 1_000_000, args: ["--type=renderer"], env: [])) == nil)
        // Path never terminated.
        let unterminated = withUnsafeBytes(of: Int32(1)) { Array($0) } + Array("/no/nul".utf8)
        #expect(ProcessSampler.helperRole(procArgs: unterminated) == nil)
    }

    @Test func truncatedBuffer() {
        let full = procArgs(args: ["/x/Helper", "--type=renderer"], env: [])
        for length in 0..<full.count {
            #expect(ProcessSampler.helperRole(procArgs: full.prefix(length)) == nil)
        }
        #expect(ProcessSampler.helperRole(procArgs: full) == "renderer")
    }

    @Test(arguments: [
        ("/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/1/Helpers/Brave Browser Helper (Renderer).app/Contents/MacOS/Brave Browser Helper (Renderer)", true),
        ("/Applications/Slack.app/Contents/Frameworks/Slack Helper (GPU).app/Contents/MacOS/Slack Helper (GPU)", true),
        ("/Applications/Brave Browser.app/Contents/MacOS/Brave Browser", false),
        ("/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU", false),
        ("/usr/libexec/trustd", false),
    ])
    func nestedHelperPath(path: String, expected: Bool) {
        #expect(ProcessSampler.isNestedHelper(path: path) == expected)
    }
}
