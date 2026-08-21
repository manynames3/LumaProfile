import Foundation

public struct LabColor: Codable, Hashable, Sendable {
    public var l: Double
    public var a: Double
    public var b: Double

    public init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }
}

public struct GammaFit: Codable, Hashable, Sendable {
    public var gamma: Double
    public var rootMeanSquareError: Double

    public init(gamma: Double, rootMeanSquareError: Double) {
        self.gamma = gamma
        self.rootMeanSquareError = rootMeanSquareError
    }
}

public enum ColorScience {
    public static let d65Reference = XYZColor(x: 0.95047, y: 1, z: 1.08883)
    public static let d50Reference = XYZColor(x: 0.96422, y: 1, z: 0.82521)

    public static func chromaticity(from xyz: XYZColor) -> Chromaticity? {
        let sum = xyz.x + xyz.y + xyz.z
        guard sum.isFinite, sum > 0 else { return nil }
        return Chromaticity(x: xyz.x / sum, y: xyz.y / sum)
    }

    public static func xyz(from chromaticity: Chromaticity, luminance: Double) -> XYZColor? {
        guard chromaticity.x.isFinite,
              chromaticity.y.isFinite,
              luminance.isFinite,
              chromaticity.y > 0,
              chromaticity.x >= 0,
              chromaticity.x + chromaticity.y <= 1,
              luminance >= 0 else {
            return nil
        }
        let x = chromaticity.x * luminance / chromaticity.y
        let z = (1 - chromaticity.x - chromaticity.y) * luminance / chromaticity.y
        return XYZColor(x: x, y: luminance, z: z)
    }

    /// Approximate CIE 1931 chromaticity on the Planckian locus. The published
    /// piecewise approximation is defined from 1667 K through 25000 K.
    public static func chromaticity(forColorTemperature kelvin: Double) -> Chromaticity? {
        guard kelvin.isFinite, (1_667...25_000).contains(kelvin) else { return nil }
        let t2 = kelvin * kelvin
        let t3 = t2 * kelvin
        let x: Double
        if kelvin <= 4_000 {
            x = -0.266_123_9e9 / t3 - 0.234_358_0e6 / t2 + 0.877_695_6e3 / kelvin + 0.179_910
        } else {
            x = -3.025_846_9e9 / t3 + 2.107_037_9e6 / t2 + 0.222_634_7e3 / kelvin + 0.240_390
        }
        let y: Double
        if kelvin <= 2_222 {
            y = -1.106_381_4 * pow(x, 3) - 1.348_110_20 * pow(x, 2) + 2.185_558_32 * x - 0.202_196_83
        } else if kelvin <= 4_000 {
            y = -0.954_947_6 * pow(x, 3) - 1.374_185_93 * pow(x, 2) + 2.091_370_15 * x - 0.167_488_67
        } else {
            y = 3.081_758_0 * pow(x, 3) - 5.873_386_70 * pow(x, 2) + 3.751_129_97 * x - 0.370_014_83
        }
        guard x.isFinite, y.isFinite, x > 0, y > 0, x + y < 1 else { return nil }
        return Chromaticity(x: x, y: y)
    }

    /// McCamy's CCT approximation, intended as operator guidance rather than a
    /// replacement for a full distance-to-locus calculation.
    public static func correlatedColorTemperature(from chromaticity: Chromaticity) -> Double? {
        let denominator = 0.1858 - chromaticity.y
        guard chromaticity.x.isFinite, chromaticity.y.isFinite, abs(denominator) > 1e-12 else { return nil }
        let n = (chromaticity.x - 0.3320) / denominator
        let kelvin = 449 * pow(n, 3) + 3_525 * pow(n, 2) + 6_823.3 * n + 5_520.33
        guard kelvin.isFinite, kelvin > 0, kelvin < 100_000 else { return nil }
        return kelvin
    }

    /// Compares normalized white chromaticities in CIELAB using a fixed D50
    /// reference and no chromatic adaptation. Both inputs use Y = 1, so the
    /// result represents chromaticity error rather than luminance error.
    public static func whitePointDeltaE2000(
        measured: Chromaticity,
        target: Chromaticity
    ) -> Double? {
        guard
            let measuredXYZ = xyz(from: measured, luminance: 1),
            let targetXYZ = xyz(from: target, luminance: 1),
            let measuredLab = lab(from: measuredXYZ, referenceWhite: d50Reference),
            let targetLab = lab(from: targetXYZ, referenceWhite: d50Reference)
        else { return nil }
        return deltaE2000(measuredLab, targetLab)
    }

    public static func lab(from xyz: XYZColor, referenceWhite: XYZColor) -> LabColor? {
        guard referenceWhite.x > 0,
              referenceWhite.y > 0,
              referenceWhite.z > 0,
              [xyz.x, xyz.y, xyz.z, referenceWhite.x, referenceWhite.y, referenceWhite.z].allSatisfy(\.isFinite) else {
            return nil
        }

        let epsilon = 216.0 / 24_389.0
        let kappa = 24_389.0 / 27.0
        func f(_ value: Double) -> Double {
            value > epsilon ? pow(value, 1.0 / 3.0) : (kappa * value + 16) / 116
        }

        let fx = f(xyz.x / referenceWhite.x)
        let fy = f(xyz.y / referenceWhite.y)
        let fz = f(xyz.z / referenceWhite.z)
        return LabColor(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    /// CIEDE2000 using the standard parametric factors for reference conditions.
    public static func deltaE2000(_ first: LabColor, _ second: LabColor) -> Double {
        let degrees = 180.0 / Double.pi
        let radians = Double.pi / 180.0
        let c1 = hypot(first.a, first.b)
        let c2 = hypot(second.a, second.b)
        let cBar = (c1 + c2) / 2
        let cBar7 = pow(cBar, 7)
        let g = 0.5 * (1 - sqrt(cBar7 / (cBar7 + pow(25.0, 7))))
        let a1Prime = (1 + g) * first.a
        let a2Prime = (1 + g) * second.a
        let c1Prime = hypot(a1Prime, first.b)
        let c2Prime = hypot(a2Prime, second.b)

        func hue(_ a: Double, _ b: Double) -> Double {
            guard a != 0 || b != 0 else { return 0 }
            let result = atan2(b, a) * degrees
            return result >= 0 ? result : result + 360
        }

        let h1Prime = hue(a1Prime, first.b)
        let h2Prime = hue(a2Prime, second.b)
        let deltaLPrime = second.l - first.l
        let deltaCPrime = c2Prime - c1Prime
        let rawHueDifference = h2Prime - h1Prime
        let deltaHDegrees: Double
        if c1Prime * c2Prime == 0 {
            deltaHDegrees = 0
        } else if abs(rawHueDifference) <= 180 {
            deltaHDegrees = rawHueDifference
        } else if rawHueDifference > 180 {
            deltaHDegrees = rawHueDifference - 360
        } else {
            deltaHDegrees = rawHueDifference + 360
        }
        let deltaHPrime = 2 * sqrt(c1Prime * c2Prime) * sin(deltaHDegrees * radians / 2)

        let lBarPrime = (first.l + second.l) / 2
        let cBarPrime = (c1Prime + c2Prime) / 2
        let hBarPrime: Double
        if c1Prime * c2Prime == 0 {
            hBarPrime = h1Prime + h2Prime
        } else if abs(h1Prime - h2Prime) <= 180 {
            hBarPrime = (h1Prime + h2Prime) / 2
        } else if h1Prime + h2Prime < 360 {
            hBarPrime = (h1Prime + h2Prime + 360) / 2
        } else {
            hBarPrime = (h1Prime + h2Prime - 360) / 2
        }

        let t = 1
            - 0.17 * cos((hBarPrime - 30) * radians)
            + 0.24 * cos(2 * hBarPrime * radians)
            + 0.32 * cos((3 * hBarPrime + 6) * radians)
            - 0.20 * cos((4 * hBarPrime - 63) * radians)
        let deltaTheta = 30 * exp(-pow((hBarPrime - 275) / 25, 2))
        let cBarPrime7 = pow(cBarPrime, 7)
        let rC = 2 * sqrt(cBarPrime7 / (cBarPrime7 + pow(25.0, 7)))
        let lTerm = lBarPrime - 50
        let sL = 1 + 0.015 * lTerm * lTerm / sqrt(20 + lTerm * lTerm)
        let sC = 1 + 0.045 * cBarPrime
        let sH = 1 + 0.015 * cBarPrime * t
        let rT = -sin(2 * deltaTheta * radians) * rC
        let lRatio = deltaLPrime / sL
        let cRatio = deltaCPrime / sC
        let hRatio = deltaHPrime / sH
        return sqrt(lRatio * lRatio + cRatio * cRatio + hRatio * hRatio + rT * cRatio * hRatio)
    }

    public static func percentile(_ percentile: Double, of values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty, percentile.isFinite else { return nil }
        let p = min(max(percentile, 0), 1)
        let index = p * Double(sorted.count - 1)
        let lower = Int(floor(index))
        let upper = Int(ceil(index))
        guard lower != upper else { return sorted[lower] }
        let fraction = index - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    /// Fits `output = input^gamma` in log space and reports RMS error in linear output units.
    public static func fitGamma(samples: [(input: Double, output: Double)]) -> GammaFit? {
        let usable = samples.filter {
            $0.input.isFinite && $0.output.isFinite &&
            $0.input > 0 && $0.input <= 1 && $0.output > 0 && $0.output <= 1
        }
        guard usable.count >= 2 else { return nil }
        let x = usable.map { log($0.input) }
        let y = usable.map { log($0.output) }
        let denominator = x.reduce(0) { $0 + $1 * $1 }
        guard denominator > 0 else { return nil }
        let gamma = zip(x, y).reduce(0) { $0 + $1.0 * $1.1 } / denominator
        guard gamma.isFinite else { return nil }
        let meanSquaredError = usable.reduce(0.0) { partial, sample in
            let residual = sample.output - pow(sample.input, gamma)
            return partial + residual * residual
        } / Double(usable.count)
        return GammaFit(gamma: gamma, rootMeanSquareError: sqrt(meanSquaredError))
    }
}

public struct VerificationCriteria: Codable, Hashable, Sendable {
    /// Increment when the meaning of the application's default thresholds or
    /// rating algorithm changes. Each assessment persists both this version and
    /// the exact criteria values so historical results remain explainable.
    public static let applicationDefaultVersion = 1

    public var excellentAverageDeltaE: Double
    public var excellentMaximumDeltaE: Double
    public var goodAverageDeltaE: Double
    public var goodMaximumDeltaE: Double
    public var maximumWhitePointDeltaE: Double
    public var maximumLuminanceErrorPercent: Double
    public var maximumGammaError: Double

    public init(
        excellentAverageDeltaE: Double = 1,
        excellentMaximumDeltaE: Double = 3,
        goodAverageDeltaE: Double = 2,
        goodMaximumDeltaE: Double = 4,
        maximumWhitePointDeltaE: Double = 2,
        maximumLuminanceErrorPercent: Double = 10,
        maximumGammaError: Double = 0.15
    ) {
        self.excellentAverageDeltaE = excellentAverageDeltaE
        self.excellentMaximumDeltaE = excellentMaximumDeltaE
        self.goodAverageDeltaE = goodAverageDeltaE
        self.goodMaximumDeltaE = goodMaximumDeltaE
        self.maximumWhitePointDeltaE = maximumWhitePointDeltaE
        self.maximumLuminanceErrorPercent = maximumLuminanceErrorPercent
        self.maximumGammaError = maximumGammaError
    }

    public static let applicationDefault = VerificationCriteria()
}

public enum VerificationRating: String, Codable, CaseIterable, Hashable, Sendable {
    case excellent = "Excellent"
    case good = "Good"
    case needsAttention = "Needs Attention"
}

public struct VerificationAssessment: Codable, Hashable, Sendable {
    public var criteriaVersion: Int
    public var criteria: VerificationCriteria
    public var rating: VerificationRating
    public var reasons: [String]
    public var evaluatedAt: Date

    public init(
        criteriaVersion: Int,
        criteria: VerificationCriteria,
        rating: VerificationRating,
        reasons: [String],
        evaluatedAt: Date = Date()
    ) {
        self.criteriaVersion = criteriaVersion
        self.criteria = criteria
        self.rating = rating
        self.reasons = reasons
        self.evaluatedAt = evaluatedAt
    }
}

public extension VerificationCriteria {
    func rating(
        for metrics: VerificationMetrics,
        targetLuminance: Double?,
        targetGamma: Double?
    ) -> VerificationRating {
        evaluation(
            for: metrics,
            targetLuminance: targetLuminance,
            targetGamma: targetGamma
        ).rating
    }

    func assessment(
        for metrics: VerificationMetrics,
        targetLuminance: Double?,
        targetGamma: Double?,
        criteriaVersion: Int = VerificationCriteria.applicationDefaultVersion,
        evaluatedAt: Date = Date()
    ) -> VerificationAssessment {
        let result = evaluation(
            for: metrics,
            targetLuminance: targetLuminance,
            targetGamma: targetGamma
        )
        return VerificationAssessment(
            criteriaVersion: criteriaVersion,
            criteria: self,
            rating: result.rating,
            reasons: result.reasons,
            evaluatedAt: evaluatedAt
        )
    }

    private func evaluation(
        for metrics: VerificationMetrics,
        targetLuminance: Double?,
        targetGamma: Double?
    ) -> (rating: VerificationRating, reasons: [String]) {
        var goodFailures: [String] = []
        var excellentMisses: [String] = []

        if !metrics.averageDeltaE2000.isFinite {
            goodFailures.append("Average color error was unavailable.")
        } else if metrics.averageDeltaE2000 >= goodAverageDeltaE {
            goodFailures.append(
                "Average ΔE2000 \(formatted(metrics.averageDeltaE2000)) is not below the Good limit of \(formatted(goodAverageDeltaE))."
            )
        } else if metrics.averageDeltaE2000 >= excellentAverageDeltaE {
            excellentMisses.append(
                "Average ΔE2000 \(formatted(metrics.averageDeltaE2000)) meets Good, but not the Excellent limit of \(formatted(excellentAverageDeltaE))."
            )
        }

        if !metrics.maximumDeltaE2000.isFinite {
            goodFailures.append("Maximum color error was unavailable.")
        } else if metrics.maximumDeltaE2000 >= goodMaximumDeltaE {
            goodFailures.append(
                "Maximum ΔE2000 \(formatted(metrics.maximumDeltaE2000)) is not below the Good limit of \(formatted(goodMaximumDeltaE))."
            )
        } else if metrics.maximumDeltaE2000 >= excellentMaximumDeltaE {
            excellentMisses.append(
                "Maximum ΔE2000 \(formatted(metrics.maximumDeltaE2000)) meets Good, but not the Excellent limit of \(formatted(excellentMaximumDeltaE))."
            )
        }

        if !metrics.whitePointDeltaE2000.isFinite {
            goodFailures.append("White-point error was unavailable.")
        } else if metrics.whitePointDeltaE2000 > maximumWhitePointDeltaE {
            goodFailures.append(
                "White-point ΔE2000 \(formatted(metrics.whitePointDeltaE2000)) exceeds the limit of \(formatted(maximumWhitePointDeltaE))."
            )
        }

        if let targetLuminance, targetLuminance.isFinite, targetLuminance > 0 {
            if metrics.luminanceCDM2.isFinite {
                let errorPercent = abs(metrics.luminanceCDM2 - targetLuminance) / targetLuminance * 100
                if errorPercent > maximumLuminanceErrorPercent {
                    goodFailures.append(
                        "Luminance is \(formatted(errorPercent))% from target, beyond the \(formatted(maximumLuminanceErrorPercent))% limit."
                    )
                }
            } else {
                goodFailures.append("Luminance was unavailable for the selected target.")
            }
        }

        if let targetGamma, targetGamma.isFinite {
            guard let measuredGamma = metrics.measuredGamma, measuredGamma.isFinite else {
                goodFailures.append("Gamma was unavailable for the selected target.")
                return finalEvaluation(
                    goodFailures: goodFailures,
                    excellentMisses: excellentMisses,
                    warnings: metrics.warnings
                )
            }
            let gammaError = abs(measuredGamma - targetGamma)
            if gammaError > maximumGammaError {
                goodFailures.append(
                    "Gamma differs from target by \(formatted(gammaError)), beyond the \(formatted(maximumGammaError)) limit."
                )
            }
        }

        return finalEvaluation(
            goodFailures: goodFailures,
            excellentMisses: excellentMisses,
            warnings: metrics.warnings
        )
    }

    private func finalEvaluation(
        goodFailures: [String],
        excellentMisses: [String],
        warnings: [String]
    ) -> (rating: VerificationRating, reasons: [String]) {
        let warningReasons = warnings.map { "Verification warning: \($0)" }
        if !goodFailures.isEmpty || !warningReasons.isEmpty {
            return (.needsAttention, goodFailures + warningReasons)
        }
        if !excellentMisses.isEmpty {
            return (.good, excellentMisses)
        }
        return (
            .excellent,
            ["Average and maximum color error, white point, and applicable target checks meet the Excellent criteria."]
        )
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
