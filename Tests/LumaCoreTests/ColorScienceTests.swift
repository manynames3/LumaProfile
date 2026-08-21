import Darwin
import Foundation
import Testing
@testable import LumaCore

@Suite
struct ColorScienceTests {
    @Test
    func testD65WhiteConvertsToExpectedChromaticityAndLab() throws {
        let chromaticity = try #require(ColorScience.chromaticity(from: ColorScience.d65Reference))
        #expect(abs(chromaticity.x - 0.3127266) <= 0.000_001)
        #expect(abs(chromaticity.y - 0.3290231) <= 0.000_001)

        let lab = try #require(
            ColorScience.lab(from: ColorScience.d65Reference, referenceWhite: ColorScience.d65Reference)
        )
        #expect(abs(lab.l - 100) <= 1e-12)
        #expect(abs(lab.a) <= 1e-12)
        #expect(abs(lab.b) <= 1e-12)
    }

    @Test
    func testXYZChromaticityRoundTripPreservesCoordinatesAndLuminance() throws {
        let original = XYZColor(x: 19.01, y: 20, z: 21.78)
        let chromaticity = try #require(ColorScience.chromaticity(from: original))
        let reconstructed = try #require(ColorScience.xyz(from: chromaticity, luminance: original.y))

        #expect(abs(reconstructed.x - original.x) <= 1e-12)
        #expect(abs(reconstructed.y - original.y) <= 1e-12)
        #expect(abs(reconstructed.z - original.z) <= 1e-12)
    }

    @Test
    func testWhitePointAndColorTemperatureHelpersMatchD65() throws {
        let planckian = try #require(ColorScience.chromaticity(forColorTemperature: 6_500))
        #expect(abs(planckian.x - 0.3135) < 0.002)
        #expect(abs(planckian.y - 0.3237) < 0.002)
        let cct = try #require(ColorScience.correlatedColorTemperature(from: .d65))
        #expect(abs(cct - 6_504) < 20)
        let identical = try #require(ColorScience.whitePointDeltaE2000(measured: .d65, target: .d65))
        #expect(abs(identical) < 1e-12)
        #expect(ColorScience.chromaticity(forColorTemperature: 1_000) == nil)
    }

    @Test
    func testInvalidColorInputsAreRejected() {
        #expect(ColorScience.chromaticity(from: XYZColor(x: 0, y: 0, z: 0)) == nil)
        #expect(ColorScience.chromaticity(from: XYZColor(x: .infinity, y: 1, z: 1)) == nil)
        #expect(ColorScience.xyz(from: Chromaticity(x: 0.3, y: 0), luminance: 100) == nil)
        #expect(ColorScience.xyz(from: Chromaticity(x: 0.8, y: 0.3), luminance: 100) == nil)
        #expect(ColorScience.xyz(from: .d65, luminance: -1) == nil)
        #expect(
            ColorScience.lab(
                from: XYZColor(x: 1, y: 1, z: 1),
                referenceWhite: XYZColor(x: 0, y: 1, z: 1)
            ) == nil
        )
    }

    @Test
    func testDeltaE2000MatchesPublishedSharmaKnownAnswers() {
        // CIEDE2000 supplementary test data by Sharma, Wu, and Dalal. Values are
        // mathematical reference vectors, not readings from calibration hardware.
        let vectors: [(LabColor, LabColor, Double)] = [
            (.init(l: 50, a: 2.6772, b: -79.7751), .init(l: 50, a: 0, b: -82.7485), 2.0425),
            (.init(l: 50, a: 3.1571, b: -77.2803), .init(l: 50, a: 0, b: -82.7485), 2.8615),
            (.init(l: 50, a: 2.8361, b: -74.0200), .init(l: 50, a: 0, b: -82.7485), 3.4412),
            (.init(l: 50, a: -1.3802, b: -84.2814), .init(l: 50, a: 0, b: -82.7485), 1.0000),
            (.init(l: 50, a: -1.1848, b: -84.8006), .init(l: 50, a: 0, b: -82.7485), 1.0000),
            (.init(l: 50, a: -0.9009, b: -85.5211), .init(l: 50, a: 0, b: -82.7485), 1.0000),
            (.init(l: 50, a: 0, b: 0), .init(l: 50, a: -1, b: 2), 2.3669),
            (.init(l: 50, a: -1, b: 2), .init(l: 50, a: 0, b: 0), 2.3669),
            (.init(l: 50, a: 2.49, b: -0.001), .init(l: 50, a: -2.49, b: 0.0009), 7.1792),
            (.init(l: 50, a: 2.49, b: -0.001), .init(l: 50, a: -2.49, b: 0.0010), 7.1792),
            (.init(l: 50, a: 2.49, b: -0.001), .init(l: 50, a: -2.49, b: 0.0011), 7.2195),
            (.init(l: 50, a: 2.49, b: -0.001), .init(l: 50, a: -2.49, b: 0.0012), 7.2195),
            (.init(l: 50, a: -0.001, b: 2.49), .init(l: 50, a: 0.0009, b: -2.49), 4.8045),
            (.init(l: 50, a: -0.001, b: 2.49), .init(l: 50, a: 0.0010, b: -2.49), 4.8045),
            (.init(l: 50, a: -0.001, b: 2.49), .init(l: 50, a: 0.0011, b: -2.49), 4.7461),
            (.init(l: 50, a: 2.5, b: 0), .init(l: 50, a: 0, b: -2.5), 4.3065),
            (.init(l: 50, a: 2.5, b: 0), .init(l: 73, a: 25, b: -18), 27.1492),
            (.init(l: 50, a: 2.5, b: 0), .init(l: 61, a: -5, b: 29), 22.8977),
            (.init(l: 50, a: 2.5, b: 0), .init(l: 56, a: -27, b: -3), 31.9030),
            (.init(l: 50, a: 2.5, b: 0), .init(l: 58, a: 24, b: 15), 19.4535),
            (.init(l: 60.2574, a: -34.0099, b: 36.2677), .init(l: 60.4626, a: -34.1751, b: 39.4387), 1.2644),
            (.init(l: 63.0109, a: -31.0961, b: -5.8663), .init(l: 62.8187, a: -29.7946, b: -4.0864), 1.2630),
            (.init(l: 61.2901, a: 3.7196, b: -5.3901), .init(l: 61.4292, a: 2.2480, b: -4.9620), 1.8731),
            (.init(l: 35.0831, a: -44.1164, b: 3.7933), .init(l: 35.0232, a: -40.0716, b: 1.5901), 1.8645),
            (.init(l: 22.7233, a: 20.0904, b: -46.6940), .init(l: 23.0331, a: 14.9730, b: -42.5619), 2.0373),
            (.init(l: 36.4612, a: 47.8580, b: 18.3852), .init(l: 36.2715, a: 50.5065, b: 21.2231), 1.4146),
            (.init(l: 90.8027, a: -2.0831, b: 1.4410), .init(l: 91.1528, a: -1.6435, b: 0.0447), 1.4441),
            (.init(l: 90.9257, a: -0.5406, b: -0.9208), .init(l: 88.6381, a: -0.8985, b: -0.7239), 1.5381),
            (.init(l: 6.7747, a: -0.2908, b: -2.4247), .init(l: 5.8714, a: -0.0985, b: -2.2286), 0.6377),
            (.init(l: 2.0776, a: 0.0795, b: -1.1350), .init(l: 0.9033, a: -0.0636, b: -0.5514), 0.9082),
        ]

        for (index, vector) in vectors.enumerated() {
            let actual = ColorScience.deltaE2000(vector.0, vector.1)
            #expect(abs(actual - vector.2) <= 0.000_1, "Reference vector \(index + 1)")
        }
    }

    @Test
    func testDeltaEIdentityAndSymmetry() {
        let first = LabColor(l: 48.2, a: 12.4, b: -8.9)
        let second = LabColor(l: 52.7, a: 10.1, b: -4.2)
        #expect(abs(ColorScience.deltaE2000(first, first)) <= 1e-12)
        #expect(abs(ColorScience.deltaE2000(first, second) - ColorScience.deltaE2000(second, first)) <= 1e-12)
    }

    @Test
    func testPercentileInterpolatesClampsAndDropsNonFiniteValues() {
        let values = [40.0, .nan, 10, 30, .infinity, 20]
        #expect(ColorScience.percentile(0, of: values) == 10)
        #expect(ColorScience.percentile(0.5, of: values) == 25)
        #expect(ColorScience.percentile(0.95, of: values) == 38.5)
        #expect(ColorScience.percentile(-1, of: values) == 10)
        #expect(ColorScience.percentile(2, of: values) == 40)
        #expect(ColorScience.percentile(0.5, of: [.nan, .infinity]) == nil)
        #expect(ColorScience.percentile(.nan, of: values) == nil)
    }

    @Test
    func testGammaFitRecoversKnownPowerCurveAndIgnoresInvalidSamples() throws {
        let gamma = 2.2
        var samples = stride(from: 0.1, through: 1.0, by: 0.1).map {
            (input: $0, output: pow($0, gamma))
        }
        samples.append((input: 0, output: 0))
        samples.append((input: Double.nan, output: 0.5))

        let fit = try #require(ColorScience.fitGamma(samples: samples))
        #expect(abs(fit.gamma - gamma) <= 1e-12)
        #expect(abs(fit.rootMeanSquareError) <= 1e-12)
        #expect(ColorScience.fitGamma(samples: [(input: 0, output: 0)]) == nil)
    }

    @Test
    func testVerificationRatingAppliesDeltaEAndTargetGuardrails() {
        let excellent = metrics(average: 0.5, maximum: 1.5, white: 0.8, luminance: 120, gamma: 2.2)
        let good = metrics(average: 1.5, maximum: 3.5, white: 1.5, luminance: 115, gamma: 2.1)
        let luminanceMiss = metrics(average: 0.5, maximum: 1.5, white: 0.8, luminance: 100, gamma: 2.2)
        let gammaMiss = metrics(average: 0.5, maximum: 1.5, white: 0.8, luminance: 120, gamma: 1.9)

        let criteria = VerificationCriteria.applicationDefault
        #expect(criteria.rating(for: excellent, targetLuminance: 120, targetGamma: 2.2) == .excellent)
        #expect(criteria.rating(for: good, targetLuminance: 120, targetGamma: 2.2) == .good)
        #expect(criteria.rating(for: luminanceMiss, targetLuminance: 120, targetGamma: 2.2) == .needsAttention)
        #expect(criteria.rating(for: gammaMiss, targetLuminance: 120, targetGamma: 2.2) == .needsAttention)
    }

    @Test
    func verificationAssessmentPersistsVersionCriteriaRatingAndReasons() {
        let metrics = metrics(average: 1.5, maximum: 3.5, white: 1.5, luminance: 115, gamma: 2.1)
        let evaluatedAt = Date(timeIntervalSince1970: 1_700_000_500)
        let criteria = VerificationCriteria.applicationDefault

        let assessment = criteria.assessment(
            for: metrics,
            targetLuminance: 120,
            targetGamma: 2.2,
            evaluatedAt: evaluatedAt
        )

        #expect(assessment.criteriaVersion == VerificationCriteria.applicationDefaultVersion)
        #expect(assessment.criteria == criteria)
        #expect(assessment.rating == .good)
        #expect(assessment.reasons.contains { $0.contains("Average ΔE2000") })
        #expect(assessment.reasons.contains { $0.contains("Maximum ΔE2000") })
        #expect(assessment.evaluatedAt == evaluatedAt)
    }

    @Test
    func verificationAssessmentDoesNotOverclaimWhenRequiredDataOrWarningsArePresent() {
        let criteria = VerificationCriteria.applicationDefault
        let missingGamma = metrics(
            average: 0.5,
            maximum: 1.5,
            white: 0.8,
            luminance: 120,
            gamma: nil
        )
        let missingAssessment = criteria.assessment(
            for: missingGamma,
            targetLuminance: 120,
            targetGamma: 2.2
        )
        #expect(missingAssessment.rating == .needsAttention)
        #expect(missingAssessment.reasons.contains { $0.contains("Gamma was unavailable") })

        var warned = metrics(
            average: 0.5,
            maximum: 1.5,
            white: 0.8,
            luminance: 120,
            gamma: 2.2
        )
        warned.warnings = ["Synthetic incomplete metric warning"]
        let warnedAssessment = criteria.assessment(
            for: warned,
            targetLuminance: 120,
            targetGamma: 2.2
        )
        #expect(warnedAssessment.rating == .needsAttention)
        #expect(warnedAssessment.reasons == ["Verification warning: Synthetic incomplete metric warning"])
    }

    private func metrics(
        average: Double,
        maximum: Double,
        white: Double,
        luminance: Double,
        gamma: Double?
    ) -> VerificationMetrics {
        VerificationMetrics(
            averageDeltaE2000: average,
            percentile95DeltaE2000: maximum,
            maximumDeltaE2000: maximum,
            whitePointDeltaE2000: white,
            measuredWhite: .d65,
            luminanceCDM2: luminance,
            blackLevelCDM2: 0.1,
            contrastRatio: 1_200,
            measuredGamma: gamma,
            gammaRMSError: 0.01
        )
    }
}
