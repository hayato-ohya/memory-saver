import Testing
@testable import Sampling

struct TopParsingTests {
    @Test(arguments: [
        ("1402M", UInt64(1402) << 20),
        ("1402M+", UInt64(1402) << 20),
        ("1402M-", UInt64(1402) << 20),
        ("512K", UInt64(512) << 10),
        ("100B", UInt64(100)),
        ("2G", UInt64(2) << 30),
        ("1.5G", UInt64(3) << 29),
        ("0B", UInt64(0)),
        ("12m", UInt64(12) << 20),
    ])
    func parsesValues(text: String, expected: UInt64) {
        #expect(parseTopMemoryValue(text) == expected)
    }

    @Test(arguments: ["", "M", "+", "1402", "1402X", "abcM", "-5M", "1e3M", "infM", "1.2.3M", "1402M++"])
    func rejectsMalformedValues(text: String) {
        #expect(parseTopMemoryValue(text) == nil)
    }

    static let sampleOutput = """
        Processes: 712 total, 4 running, 708 sleeping, 3417 threads
        2026/11/16 10:00:00
        Load Avg: 2.10, 2.30, 2.40
        CPU usage: 5.0% user, 3.0% sys, 92.0% idle
        PhysMem: 30G used (3000M wired, 1200M compressor), 1700M unused.

        PID  COMMAND      MEM
        405  WindowServer 1402M
        """

    @Test func parsesTopOutput() {
        #expect(parseTopMemory(Self.sampleOutput, pid: 405) == UInt64(1402) << 20)
    }

    @Test func returnsNilWhenPIDMissing() {
        #expect(parseTopMemory(Self.sampleOutput, pid: 406) == nil)
        #expect(parseTopMemory("", pid: 405) == nil)
        #expect(parseTopMemory("PID COMMAND MEM\n", pid: 405) == nil)
    }

    @Test func returnsNilForMalformedRow() {
        #expect(parseTopMemory("PID COMMAND MEM\n405 WindowServer ???\n", pid: 405) == nil)
        #expect(parseTopMemory("405 1402M\n", pid: 405) == nil)
    }

    @Test func commandWithSpacesUsesLastColumn() {
        #expect(parseTopMemory("77  Some Helper App 3.5K+\n", pid: 77) == 3584)
    }
}
