import Foundation
import Testing
@testable import LumaCore

@Suite
struct ArgyllVerificationParserTests {
    @Test
    func cgatsParserPreservesSignatureKeywordsFieldsRowsAndQuotedValue() throws {
        let text = try TestSupport.fixture("verification.synthetic", extension: "ti3")
        let document = try ArgyllCGATSParser.parse(Data(text.utf8))

        #expect(document.signature == "CTI3")
        #expect(document.keywords["DESCRIPTOR"] == "Synthetic verification gamma ramp")
        #expect(document.keywords["LUMINANCE_XYZ_CDM2"] == "114.056 120.000 130.660")
        #expect(document.fields == ["SAMPLE_ID", "RGB_R", "RGB_G", "RGB_B", "XYZ_X", "XYZ_Y", "XYZ_Z"])
        #expect(document.rows.count == 5)
        #expect(document.column("xyz_y") == 5)
        #expect(document.numericValue(row: 4, field: "XYZ_Y") == 100)
        #expect(document.rawText == text)
    }

    @Test
    func cgatsParserRejectsTruncatedOrMismatchedTables() throws {
        let malformed = """
        CTI3
        # SYNTHETIC TEST VALUE
        NUMBER_OF_FIELDS 3
        NUMBER_OF_SETS 2
        BEGIN_DATA_FORMAT
        SAMPLE_ID XYZ_X XYZ_Y
        END_DATA_FORMAT
        BEGIN_DATA
        1 1.0 2.0
        END_DATA
        """
        do {
            _ = try ArgyllCGATSParser.parse(Data(malformed.utf8))
            Issue.record("Expected declared row-count mismatch")
        } catch ArgyllEngineError.unsupportedOutput(let parser, _, let excerpt) {
            #expect(parser == "cgats-v1")
            #expect(excerpt.contains("NUMBER_OF_SETS"))
        }
    }

    @Test
    func profcheckPatchParserComputesAverageNearestRankP95MaximumAndWhitePatch() throws {
        let output = try TestSupport.fixture("profcheck-patches.synthetic")
        let result = try ArgyllProfcheckParser.parse(output)

        #expect(result.parserVersion == 1)
        #expect(result.patches == [
            ArgyllProfcheckPatch(patchNumber: 1, deltaE2000: 0.5, deviceValues: [0, 0, 0]),
            ArgyllProfcheckPatch(patchNumber: 2, deltaE2000: 1, deviceValues: [50, 50, 50]),
            ArgyllProfcheckPatch(patchNumber: 3, deltaE2000: 2.5, deviceValues: [100, 100, 100]),
        ])
        #expect(abs(result.averageDeltaE2000 - (4.0 / 3.0)) < 1e-12)
        #expect(result.percentile95DeltaE2000 == 2.5)
        #expect(result.maximumDeltaE2000 == 2.5)
        #expect(result.whitePatchDeltaE2000 == 2.5)
        #expect(result.warnings == ["Warning: synthetic patch tolerance warning."])
        #expect(result.rawOutput == output)
    }

    @Test
    func profcheckSummaryFallbackParsesWithoutInventingPatchRows() throws {
        let output = try TestSupport.fixture("profcheck-summary.synthetic")
        let result = try ArgyllProfcheckParser.parse(output)
        #expect(result.patches.isEmpty)
        #expect(result.averageDeltaE2000 == 0.75)
        #expect(result.percentile95DeltaE2000 == 1.7)
        #expect(result.maximumDeltaE2000 == 2.25)
        #expect(result.whitePatchDeltaE2000 == nil)
    }

    @Test
    func profcheckParserRejectsTruncatedOutputWithoutPatchOrSummary() throws {
        let output = "[SYNTHETIC TEST FIXTURE]\nAverage error ="
        do {
            _ = try ArgyllProfcheckParser.parse(output)
            Issue.record("Expected unsupported truncated profcheck output")
        } catch ArgyllEngineError.unsupportedOutput(let parser, _, let excerpt) {
            #expect(parser == "profcheck-v1")
            #expect(excerpt.contains("SYNTHETIC TEST FIXTURE"))
        }
    }

    @Test
    func verificationParserCombinesDeltaEWhiteLuminanceBlackContrastAndGamma() throws {
        let profcheck = try TestSupport.fixture("profcheck-patches.synthetic")
        let ti3 = try TestSupport.fixture("verification.synthetic", extension: "ti3")
        let measuredAt = Date(timeIntervalSince1970: 1_700_000_321)
        let report = try ArgyllVerificationParser.parse(
            profcheckOutput: profcheck,
            measurementData: Data(ti3.utf8),
            measuredAt: measuredAt
        )
        let metrics = report.metrics

        #expect(report.measuredAt == measuredAt)
        #expect(abs(metrics.averageDeltaE2000 - (4.0 / 3.0)) < 1e-12)
        #expect(metrics.percentile95DeltaE2000 == 2.5)
        #expect(metrics.maximumDeltaE2000 == 2.5)
        #expect(metrics.whitePointDeltaE2000 == 2.5)
        #expect(abs(metrics.measuredWhite.x - 0.3127266) < 0.000_001)
        #expect(abs(metrics.measuredWhite.y - 0.3290231) < 0.000_001)
        #expect(metrics.luminanceCDM2 == 120)
        #expect(abs((metrics.blackLevelCDM2 ?? -1) - 0.012) < 1e-12)
        #expect(abs((metrics.contrastRatio ?? -1) - 10_000) < 1e-8)
        #expect(abs((metrics.measuredGamma ?? -1) - 2.2) < 0.002)
        #expect((metrics.gammaRMSError ?? 1) < 0.000_1)
        #expect(metrics.warnings == ["Warning: synthetic patch tolerance warning."])
        #expect(report.rawOutput.contains("--- verification.ti3 ---"))
        #expect(report.rawOutput.contains("Synthetic verification gamma ramp"))
    }

    @Test
    func verificationParserComparesWhiteLuminanceAndToneResponseToSelectedTarget() throws {
        let profcheck = try TestSupport.fixture("profcheck-patches.synthetic")
        let ti3 = try TestSupport.fixture("verification.synthetic", extension: "ti3")
        let report = try ArgyllVerificationParser.parse(
            profcheckOutput: profcheck,
            measurementData: Data(ti3.utf8),
            target: .photography
        )

        // The synthetic fixture stores XYZ with four decimal places, so an
        // effectively-D65 white retains a small quantization residual.
        #expect(report.metrics.whitePointDeltaE2000 < 0.01)
        #expect(report.metrics.targetWhite == .d65)
        #expect(report.metrics.targetLuminanceCDM2 == 120)
        #expect(report.metrics.targetTransferFunction == .gamma(2.2))
        #expect(abs((report.metrics.measuredCorrelatedColorTemperature ?? 0) - 6_504) < 20)
        #expect((report.metrics.toneResponseRMSError ?? 1) < 0.001)
    }

    @Test
    func verificationParserWarnsWhenAbsoluteLuminanceKeywordAndWhitePatchAreUnavailable() throws {
        let profcheck = try TestSupport.fixture("profcheck-summary.synthetic")
        var ti3 = try TestSupport.fixture("verification.synthetic", extension: "ti3")
        ti3 = ti3.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("LUMINANCE_XYZ_CDM2") }
            .joined(separator: "\n")

        let report = try ArgyllVerificationParser.parse(
            profcheckOutput: profcheck,
            measurementData: Data(ti3.utf8)
        )

        #expect(report.metrics.luminanceCDM2 == 100)
        #expect(report.metrics.whitePointDeltaE2000 == 0)
        #expect(report.metrics.warnings.contains { $0.contains("normalized rather than cd/m²") })
        #expect(report.metrics.warnings.contains { $0.contains("white-patch error") })
    }
}
