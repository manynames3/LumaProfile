// Smoke test for the black-screen guard on a real macOS WindowServer.
// Usage: swift display-guard-smoke.swift zero <seconds>   — hold an all-zero curve on the main display
//        swift display-guard-smoke.swift read             — print the main display's curve end value
import CoreGraphics
import Foundation

let display = CGMainDisplayID()
func endValue() -> (Float, UInt32) {
    var r = [CGGammaValue](repeating: 0, count: 1024), g = r, b = r
    var count: UInt32 = 0
    CGGetDisplayTransferByTable(display, 1024, &r, &g, &b, &count)
    let k = Int(count)
    return k == 0 ? (-1, 0) : (max(r[k - 1], g[k - 1], b[k - 1]), count)
}
let mode = CommandLine.arguments.dropFirst().first ?? "read"
if mode == "zero" {
    let seconds = Int(CommandLine.arguments.last ?? "10") ?? 10
    var zeros = [CGGammaValue](repeating: 0, count: 256)
    let status = CGSetDisplayTransferByTable(display, 256, &zeros, &zeros, &zeros)
    print("zero set status \(status.rawValue) capacity \(CGDisplayGammaTableCapacity(display))")
    for second in 0..<seconds {
        let (value, count) = endValue()
        print("t=\(second)s holder sees end=\(value) samples=\(count)")
        fflush(stdout)
        sleep(1)
    }
} else {
    let (value, count) = endValue()
    print("observer sees end=\(value) samples=\(count)")
}
