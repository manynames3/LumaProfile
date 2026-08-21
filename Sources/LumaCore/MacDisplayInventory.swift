import AppKit
import CoreGraphics
import Foundation

public enum DisplayInventoryError: LocalizedError, Sendable {
    case enumerationFailed(CGError)

    public var errorDescription: String? {
        switch self {
        case .enumerationFailed(let error):
            "macOS could not enumerate connected displays (Core Graphics error \(error.rawValue))."
        }
    }
}

/// Enumerates the physical display endpoints currently known to WindowServer.
///
/// The inventory deliberately does not guess Argyll display indexes. Those are
/// reconciled by the calibration engine, which has the authoritative ordering.
public struct MacDisplayInventory: DisplayInventory, Sendable {
    public init() {}

    public func displays() async throws -> [PhysicalDisplay] {
        var count: UInt32 = 0
        let countResult = CGGetOnlineDisplayList(0, nil, &count)
        guard countResult == .success else {
            throw DisplayInventoryError.enumerationFailed(countResult)
        }

        var identifiers = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let listResult = CGGetOnlineDisplayList(count, &identifiers, &count)
        guard listResult == .success else {
            throw DisplayInventoryError.enumerationFailed(listResult)
        }

        let screenMetadata: [CGDirectDisplayID: ScreenMetadata] = await MainActor.run {
            var result: [CGDirectDisplayID: ScreenMetadata] = [:]
            for screen in NSScreen.screens {
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                    continue
                }
                result[CGDirectDisplayID(number.uint32Value)] = ScreenMetadata(
                    name: screen.localizedName,
                    scale: screen.backingScaleFactor
                )
            }
            return result
        }

        return identifiers.prefix(Int(count)).map { displayID in
            let metadata = screenMetadata[displayID]
            let vendor = CGDisplayVendorNumber(displayID)
            let model = CGDisplayModelNumber(displayID)
            let serial = CGDisplaySerialNumber(displayID)
            let screenSize = CGDisplayScreenSize(displayID)
            let fingerprint = Self.fingerprint(
                displayID: displayID,
                vendor: vendor,
                model: model,
                serial: serial
            )
            let likelyVirtual = vendor == 0 || model == 0 || (screenSize.width == 0 && screenSize.height == 0)

            return PhysicalDisplay(
                fingerprint: fingerprint,
                cgDisplayID: displayID,
                name: metadata?.name ?? "Display \(displayID)",
                widthPixels: Int(CGDisplayPixelsWide(displayID)),
                heightPixels: Int(CGDisplayPixelsHigh(displayID)),
                scale: metadata?.scale ?? 1,
                isMain: CGDisplayIsMain(displayID) != 0,
                isMirrored: CGDisplayIsInMirrorSet(displayID) != 0,
                isVirtual: likelyVirtual,
                argyllDisplayIndex: nil,
                userReportedMode: nil
            )
        }
        .sorted { lhs, rhs in
            if lhs.isMain != rhs.isMain { return lhs.isMain }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func fingerprint(
        displayID: CGDirectDisplayID,
        vendor: UInt32,
        model: UInt32,
        serial: UInt32
    ) -> String {
        if vendor != 0, model != 0, serial != 0 {
            return String(format: "display-%08X-%08X-%08X", vendor, model, serial)
        }

        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            return "display-\(CFUUIDCreateString(nil, uuid) as String)"
        }
        return "display-id-\(displayID)"
    }
}

private struct ScreenMetadata: Sendable {
    var name: String
    var scale: Double
}
