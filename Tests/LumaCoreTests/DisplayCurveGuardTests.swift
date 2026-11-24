import Testing
@testable import LumaCore

@Suite
struct DisplayCurveGuardTests {
    @Test
    func allZeroCurveIsBlack() {
        let zero = [Float](repeating: 0, count: 1024)
        #expect(DisplayCurveGuard.isBlack(red: zero, green: zero, blue: zero))
    }

    @Test
    func calibratedAndLinearCurvesAreNotBlack() {
        let linear = (0..<1024).map { Float($0) / 1023 }
        // Shape of the curve measured on the affected display: lifted black, reduced white.
        let calibrated = linear.map { 0.012 + $0 * 0.85 }
        #expect(!DisplayCurveGuard.isBlack(red: linear, green: linear, blue: linear))
        #expect(!DisplayCurveGuard.isBlack(red: calibrated, green: calibrated, blue: calibrated))
    }

    @Test
    func oneLiveChannelIsNotBlack() {
        let zero = [Float](repeating: 0, count: 256)
        let linear = (0..<256).map { Float($0) / 255 }
        #expect(!DisplayCurveGuard.isBlack(red: zero, green: linear, blue: zero))
    }

    @Test
    func emptyOrMismatchedTablesAreNotReportedBlack() {
        #expect(!DisplayCurveGuard.isBlack(red: [], green: [], blue: []))
        #expect(!DisplayCurveGuard.isBlack(red: [0], green: [0, 0], blue: [0]))
    }
}
