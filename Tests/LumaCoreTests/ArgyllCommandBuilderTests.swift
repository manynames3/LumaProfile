import Foundation
import Testing
@testable import LumaCore

@Suite
struct ArgyllCommandBuilderTests {
    @Test
    func testSpotMeasurementIncludesInstrumentCorrectionAndMeasurementMode() throws {
        let root = URL(fileURLWithPath: "/tmp/LumaProfile-Synthetic")
        let installation = installation(at: root.appending(path: "bin"))
        let correctionURL = root.appending(path: "corrections/WLED synthetic.ccss")
        let request = SpotMeasurementRequest(
            instrument: TestSupport.instrument(id: "2"),
            display: TestSupport.display(),
            correction: TestSupport.correction(at: correctionURL),
            mode: .refresh
        )

        let invocation = try ArgyllCommandBuilder.spotMeasurement(
            installation: installation,
            request: request
        )

        #expect(invocation.tool == .spotread)
        #expect(invocation.executableURL == root.appending(path: "bin/spotread"))
        #expect(invocation.arguments == [
            "-e", "-x", "-T", "-O",
            "-c", "2",
            "-X", correctionURL.path,
            "-Y", "r",
        ])
    }

    @Test
    func testSpotMeasurementAutoModeOmitsOverrideAndRejectsUnmappedInstrument() throws {
        let installation = installation(at: URL(fileURLWithPath: "/tmp/LumaProfile-Synthetic/bin"))
        let valid = SpotMeasurementRequest(instrument: TestSupport.instrument(id: "1"), mode: .auto)
        #expect(!(try ArgyllCommandBuilder.spotMeasurement(
            installation: installation,
            request: valid
        ).arguments.contains("-Y")))

        for id in ["", "0", "usb:1", "-2"] {
            let request = SpotMeasurementRequest(instrument: TestSupport.instrument(id: id))
            do {
                _ = try ArgyllCommandBuilder.spotMeasurement(installation: installation, request: request)
                Issue.record("Expected invalid instrument id: \(id)")
            } catch {
                assertInvalidRequest(error)
            }
        }
    }

    @Test
    func testDispcalPhotographyPresetMapsTargetQualityCorrectionAndGeometry() throws {
        let root = URL(fileURLWithPath: "/tmp/LumaProfile-Synthetic")
        let installation = installation(at: root.appending(path: "bin"))
        let correctionURL = root.appending(path: "correction.ccss")
        let output = root.appending(path: "session/calibration.cal")
        var target = CalibrationTarget.photography
        target.quality = .high
        let request = CalibrationRequest(
            sessionDirectory: root.appending(path: "session"),
            display: TestSupport.display(),
            instrument: TestSupport.instrument(id: "3"),
            target: target,
            correction: TestSupport.correction(at: correctionURL),
            mode: .nonRefresh
        )

        let invocation = try ArgyllCommandBuilder.dispcal(
            installation: installation,
            request: request,
            outputBaseURL: output
        )

        #expect(invocation.tool == .dispcal)
        #expect(invocation.arguments == [
            "-v2", "-d", "1", "-m",
            "-c", "3", "-qh",
            "-t", "6500", "-b", "120", "-g2.2",
            "-X", correctionURL.path,
            "-y", "n",
            "-P", "0.5,0.5,2.5,2.5",
            root.appending(path: "session/calibration").path,
        ])
        #expect(!invocation.arguments.contains("-Yp"))
        #expect(!invocation.arguments.containsOrderedSubsequence(["-Y", "p"]))
    }

    @Test
    func testDispcalMapsEveryDocumentedCalibrationQualityFlag() throws {
        let root = URL(fileURLWithPath: "/tmp/LumaProfile-Synthetic")
        let installation = installation(at: root.appending(path: "bin"))
        let output = root.appending(path: "session/calibration.cal")
        let expected: [(CalibrationQuality, String)] = [
            (.quick, "-ql"),
            (.medium, "-qm"),
            (.high, "-qh"),
        ]

        for (quality, expectedFlag) in expected {
            var target = CalibrationTarget.photography
            target.quality = quality
            let request = CalibrationRequest(
                sessionDirectory: root.appending(path: "session"),
                display: TestSupport.display(),
                instrument: TestSupport.instrument(id: "1"),
                target: target
            )

            let arguments = try ArgyllCommandBuilder.dispcal(
                installation: installation,
                request: request,
                outputBaseURL: output
            ).arguments

            #expect(arguments.filter { $0.hasPrefix("-q") } == [expectedFlag], "quality=\(quality)")
        }
    }

    @Test
    func testDispcalMapsEveryWhitePointAndTransferFunctionVariant() throws {
        let installation = installation(at: URL(fileURLWithPath: "/tmp/LumaProfile-Synthetic/bin"))
        let base = URL(fileURLWithPath: "/tmp/LumaProfile-Synthetic/output")
        let variants: [(WhitePointTarget, TransferFunction, BlackPointMode, [String])] = [
            (.native, .sRGB, .native, ["-gs"]),
            (.temperature(kelvin: 5_000), .gamma(2.4), .native, ["-t", "5000", "-g2.4"]),
            (.chromaticity(.init(x: 0.3457, y: 0.3585)), .bt1886, .optimize,
             ["-w", "0.3457,0.3585", "-G2.4", "-f0", "-k0"]),
        ]

        for (whitePoint, transfer, blackPoint, expectedOrderedSubset) in variants {
            let target = CalibrationTarget(
                name: "Synthetic target",
                whitePoint: whitePoint,
                luminanceCDM2: nil,
                transferFunction: transfer,
                blackPointMode: blackPoint,
                quality: .quick
            )
            let request = CalibrationRequest(
                sessionDirectory: base.deletingLastPathComponent(),
                display: TestSupport.display(),
                instrument: TestSupport.instrument(id: "1"),
                target: target
            )
            let arguments = try ArgyllCommandBuilder.dispcal(
                installation: installation,
                request: request,
                outputBaseURL: base
            ).arguments
            #expect(arguments.containsOrderedSubsequence(expectedOrderedSubset), "arguments=\(arguments)")
            #expect(arguments.contains("-ql"))
        }
    }

    @Test
    func testDispcalRejectsInvalidTargetDisplayAndPatchValues() throws {
        let installation = installation(at: URL(fileURLWithPath: "/tmp/LumaProfile-Synthetic/bin"))
        let output = URL(fileURLWithPath: "/tmp/LumaProfile-Synthetic/output")
        let invalidTargets: [CalibrationTarget] = [
            .init(name: "bad", whitePoint: .temperature(kelvin: 999), luminanceCDM2: 100, transferFunction: .gamma(2.2)),
            .init(name: "bad", whitePoint: .temperature(kelvin: .nan), luminanceCDM2: 100, transferFunction: .gamma(2.2)),
            .init(name: "bad", whitePoint: .chromaticity(.init(x: 0.8, y: 0.3)), luminanceCDM2: 100, transferFunction: .gamma(2.2)),
            .init(name: "bad", whitePoint: .d65, luminanceCDM2: 0, transferFunction: .gamma(2.2)),
            .init(name: "bad", whitePoint: .d65, luminanceCDM2: 100, transferFunction: .gamma(5.1)),
            .init(
                name: "bad",
                whitePoint: .d65,
                luminanceCDM2: 100,
                transferFunction: .gamma(2.2),
                patchGeometry: .init(widthFraction: 0, heightFraction: 0.25, horizontalPosition: 0.5, verticalPosition: 0.5)
            ),
        ]

        for target in invalidTargets {
            let request = CalibrationRequest(
                sessionDirectory: output.deletingLastPathComponent(),
                display: TestSupport.display(),
                instrument: TestSupport.instrument(id: "1"),
                target: target
            )
            do {
                _ = try ArgyllCommandBuilder.dispcal(
                    installation: installation,
                    request: request,
                    outputBaseURL: output
                )
                Issue.record("Expected invalid calibration target")
            } catch {
                assertInvalidRequest(error)
            }
        }

        var unmapped = TestSupport.display()
        unmapped.argyllDisplayIndex = nil
        let request = CalibrationRequest(
            sessionDirectory: output.deletingLastPathComponent(),
            display: unmapped,
            instrument: TestSupport.instrument(id: "1"),
            target: .photography
        )
        do {
            _ = try ArgyllCommandBuilder.dispcal(
                installation: installation,
                request: request,
                outputBaseURL: output
            )
            Issue.record("Expected unmapped display rejection")
        } catch {
            assertInvalidRequest(error)
        }
    }

    @Test
    func testTargenCharacterizationPresetsHaveStablePatchBudgets() throws {
        let installation = installation(at: URL(fileURLWithPath: "/tmp/LumaProfile-Synthetic/bin"))
        let base = URL(fileURLWithPath: "/tmp/LumaProfile-Synthetic/patches.ti1")
        let outputBase = "/tmp/LumaProfile-Synthetic/patches"
        let expected: [(CharacterizationPreset, Int, [String])] = [
            (.fast, 119, [
                "-v", "-d3", "-e4", "-B4", "-s5", "-g17", "-f119", outputBase,
            ]),
            (.standard, 220, [
                "-v", "-d3", "-e4", "-B4", "-s9", "-g21", "-f220", outputBase,
            ]),
            (.high, 478, [
                "-v", "-d3", "-e4", "-B4", "-s13", "-g25", "-f478", "-G", outputBase,
            ]),
            (.reference, 1_024, [
                "-v", "-d3", "-e4", "-B4", "-s17", "-g33", "-f1024", "-G", outputBase,
            ]),
        ]

        for (preset, sampleCount, expectedArguments) in expected {
            let invocation = try ArgyllCommandBuilder.targen(
                installation: installation,
                preset: preset,
                outputBaseURL: base
            )
            #expect(invocation.tool == .targen)
            #expect(invocation.executableURL == installation.executables[.targen])
            #expect(preset.requestedPatchCount == sampleCount)
            #expect(invocation.arguments == expectedArguments, "preset=\(preset)")
        }
    }

    @Test
    func testCalibrationEffortMappingsDetailsCountsAndCodableRawValues() throws {
        let expected: [(
            effort: CalibrationEffort,
            quality: CalibrationQuality,
            preset: CharacterizationPreset,
            count: Int,
            rawValue: String,
            detail: String
        )] = [
            (
                .quick,
                .quick,
                .fast,
                119,
                "Quick",
                "Shortest run. Fewer patches and lighter refinement trade some profile detail for speed."
            ),
            (
                .balanced,
                .medium,
                .standard,
                220,
                "Balanced",
                "Recommended for most displays: broader sampling with standard calibration refinement."
            ),
            (
                .detailed,
                .high,
                .high,
                478,
                "Detailed",
                "A longer run with more color patches and higher refinement for more profile detail."
            ),
            (
                .reference,
                .high,
                .reference,
                1_024,
                "Reference",
                "Expert option. The longest run, intended for demanding work rather than routine calibration."
            ),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        #expect(CalibrationEffort.allCases == expected.map(\.effort))
        for value in expected {
            #expect(value.effort.calibrationQuality == value.quality)
            #expect(value.effort.characterizationPreset == value.preset)
            #expect(value.effort.characterizationPatchCount == value.count)
            #expect(value.effort.rawValue == value.rawValue)
            #expect(value.effort.detail == value.detail)
            #expect(CalibrationEffort.matching(
                calibrationQuality: value.quality,
                characterizationPreset: value.preset
            ) == value.effort)

            let encoded = try encoder.encode(value.effort)
            #expect(String(decoding: encoded, as: UTF8.self) == "\"\(value.rawValue)\"")
            #expect(try decoder.decode(CalibrationEffort.self, from: encoded) == value.effort)
        }

        #expect(CalibrationEffort.matching(
            calibrationQuality: .quick,
            characterizationPreset: .reference
        ) == nil)
    }

    @Test
    func testCharacterizationDispreadUsesCalibrationAndCorrection() throws {
        let root = URL(fileURLWithPath: "/tmp/LumaProfile-Synthetic")
        let installation = installation(at: root.appending(path: "bin"))
        let calibration = root.appending(path: "session/display.cal")
        let correction = root.appending(path: "corrections/display.ccmx")
        let correctionValue = DisplayCorrection(
            kind: .ccmx,
            name: "Synthetic CCMX",
            sourceURL: correction,
            importedURL: correction,
            sha256: String(repeating: "c", count: 64),
            provenance: "Synthetic test"
        )
        let request = CharacterizationRequest(
            sessionDirectory: root.appending(path: "session"),
            display: TestSupport.display(),
            instrument: TestSupport.instrument(id: "4"),
            calibrationURL: calibration,
            preset: .standard,
            correction: correctionValue,
            mode: .refresh
        )

        let invocation = try ArgyllCommandBuilder.dispread(
            installation: installation,
            request: request,
            inputOutputBaseURL: root.appending(path: "session/patches.ti1")
        )

        #expect(invocation.tool == .dispread)
        #expect(invocation.arguments.containsOrderedSubsequence([
            "-d", "1", "-c", "4", "-X", correction.path, "-y", "r", "-k", calibration.path,
        ]))
        #expect(invocation.arguments.containsOrderedSubsequence(["-P", "0.5,0.5,2.5,2.5"]))
        #expect(!invocation.arguments.contains("-Yp"))
        #expect(!invocation.arguments.containsOrderedSubsequence(["-Y", "p"]))
        #expect(invocation.arguments.last == root.appending(path: "session/patches").path)
    }

    @Test
    func testPinnedArgyll35UsesToolSpecificRefreshModeFlags() throws {
        let root = URL(fileURLWithPath: "/tmp/LumaProfile-Synthetic")
        let installation = installation(at: root.appending(path: "bin"))
        let instrument = TestSupport.instrument(id: "1")
        let display = TestSupport.display()

        for (mode, value) in [(MeasurementMode.refresh, "r"), (.nonRefresh, "n")] {
            let spot = try ArgyllCommandBuilder.spotMeasurement(
                installation: installation,
                request: SpotMeasurementRequest(instrument: instrument, mode: mode)
            )
            #expect(spot.arguments.containsOrderedSubsequence(["-Y", value]))
            #expect(!spot.arguments.containsOrderedSubsequence(["-y", value]))

            let calibration = try ArgyllCommandBuilder.dispcal(
                installation: installation,
                request: CalibrationRequest(
                    sessionDirectory: root.appending(path: "session"),
                    display: display,
                    instrument: instrument,
                    target: .photography,
                    mode: mode
                ),
                outputBaseURL: root.appending(path: "session/calibration")
            )
            #expect(calibration.arguments.containsOrderedSubsequence(["-y", value]))
            #expect(!calibration.arguments.containsOrderedSubsequence(["-Y", value]))

            let characterization = try ArgyllCommandBuilder.dispread(
                installation: installation,
                request: CharacterizationRequest(
                    sessionDirectory: root.appending(path: "session"),
                    display: display,
                    instrument: instrument,
                    calibrationURL: root.appending(path: "session/calibration.cal"),
                    preset: .fast,
                    mode: mode
                ),
                inputOutputBaseURL: root.appending(path: "session/patches")
            )
            #expect(characterization.arguments.containsOrderedSubsequence(["-y", value]))
            #expect(!characterization.arguments.containsOrderedSubsequence(["-Y", value]))
        }
    }

    @Test
    func testColprofMapsEveryProfileModelAndPreservesSafeMetadata() throws {
        let root = URL(fileURLWithPath: "/tmp/LumaProfile-Synthetic")
        let installation = installation(at: root.appending(path: "bin"))
        let expected: [(ProfileModel, String)] = [(.matrix, "-am"), (.shaperMatrix, "-as"), (.lut, "-aX")]

        for (model, algorithm) in expected {
            let request = ProfileBuildRequest(
                sessionDirectory: root.appending(path: "session"),
                measurementURL: root.appending(path: "session/display.ti3"),
                calibrationURL: root.appending(path: "session/display.cal"),
                outputURL: root.appending(path: "profiles/display.icc"),
                model: model,
                displayName: "  Synthetic Display  ",
                description: "  Synthetic profile \(model.rawValue)  ",
                metadata: ["manufacturer": " Synthetic Maker ", "copyright": " Test only "]
            )

            let invocation = try ArgyllCommandBuilder.colprof(installation: installation, request: request)

            #expect(invocation.tool == .colprof)
            #expect(invocation.arguments.contains(algorithm))
            #expect(invocation.arguments.containsOrderedSubsequence([
                "-A", "Synthetic Maker",
                "-M", "Synthetic Display",
                "-D", "Synthetic profile \(model.rawValue)",
                "-C", "Test only",
                "-Y", "c:\(root.appending(path: "session/display.cal").path)",
                "-O", root.appending(path: "profiles/display.icc").path,
                root.appending(path: "session/display").path,
            ]))
        }
    }

    @Test
    func testColprofRejectsUnsafeMetadataAndWrongExtensions() throws {
        let root = URL(fileURLWithPath: "/tmp/LumaProfile-Synthetic")
        let installation = installation(at: root.appending(path: "bin"))
        let badDescriptions = ["", "line one\nline two", String(repeating: "x", count: 256)]

        for description in badDescriptions {
            let request = profileRequest(root: root, description: description)
            do {
                _ = try ArgyllCommandBuilder.colprof(installation: installation, request: request)
                Issue.record("Expected unsafe metadata rejection")
            } catch {
                assertInvalidRequest(error)
            }
        }

        var wrongExtension = profileRequest(root: root, description: "Synthetic valid")
        wrongExtension.outputURL = root.appending(path: "profile.txt")
        do {
            _ = try ArgyllCommandBuilder.colprof(installation: installation, request: wrongExtension)
            Issue.record("Expected wrong profile extension rejection")
        } catch {
            assertInvalidRequest(error)
        }
    }

    @Test
    func testCorrectionKindMustMatchImportedFileExtension() throws {
        let root = URL(fileURLWithPath: "/tmp/LumaProfile-Synthetic")
        let installation = installation(at: root.appending(path: "bin"))
        let wrongURL = root.appending(path: "mismatch.ccmx")
        let correction = DisplayCorrection(
            kind: .ccss,
            name: "Mismatch",
            sourceURL: wrongURL,
            importedURL: wrongURL,
            sha256: String(repeating: "d", count: 64),
            provenance: "Synthetic mismatch"
        )
        let request = SpotMeasurementRequest(
            instrument: TestSupport.instrument(id: "1"),
            correction: correction
        )

        do {
            _ = try ArgyllCommandBuilder.spotMeasurement(installation: installation, request: request)
            Issue.record("Expected correction extension mismatch rejection")
        } catch {
            assertInvalidRequest(error)
        }
    }

    @Test
    func testProfcheckUsesExplicitMeasurementThenProfilePaths() throws {
        let root = URL(fileURLWithPath: "/tmp/LumaProfile-Synthetic")
        let installation = installation(at: root.appending(path: "bin"))
        let measurement = root.appending(path: "verify.ti3")
        let profile = root.appending(path: "profile.icm")

        let invocation = try ArgyllCommandBuilder.profcheck(
            installation: installation,
            measurementURL: measurement,
            profileURL: profile
        )

        #expect(invocation.tool == .profcheck)
        #expect(invocation.arguments == ["-k", "-v2", measurement.path, profile.path])
    }

    @Test
    func testRestoreActiveProfileCalibrationTargetsOnlyConfirmedDisplay() throws {
        let root = URL(fileURLWithPath: "/tmp/LumaProfile-Synthetic")
        let installation = installation(at: root.appending(path: "bin"))
        var display = TestSupport.display()
        display.argyllDisplayIndex = 3

        let invocation = try ArgyllCommandBuilder.restoreActiveProfileCalibration(
            installation: installation,
            display: display
        )

        #expect(invocation.tool == .dispwin)
        #expect(invocation.executableURL == root.appending(path: "bin/dispwin"))
        #expect(invocation.arguments == ["-v", "-d", "3", "-L"])
    }

    @Test
    func testInvocationCreatesLocalePinnedProcessRequestWithoutShell() throws {
        let installation = installation(at: URL(fileURLWithPath: "/tmp/LumaProfile-Synthetic/bin"))
        let invocation = try ArgyllCommandBuilder.probe(installation: installation)
        let working = URL(fileURLWithPath: "/tmp/LumaProfile-Synthetic/session")
        let request = invocation.processRequest(
            workingDirectoryURL: working,
            timeout: .seconds(2),
            inheritedEnvironment: [
                "ARGYLL_NOT_INTERACTIVE": "0",
                "PATH": "/usr/bin:/bin",
            ]
        )

        #expect(request.executableURL == installation.executables[.spotread])
        #expect(request.arguments == ["-?"])
        #expect(request.workingDirectoryURL == working)
        #expect(request.environment == [
            "ARGYLL_NOT_INTERACTIVE": "1",
            "LC_ALL": "C",
            "LANG": "C",
            "PATH": "/tmp/LumaProfile-Synthetic/bin:/usr/bin:/bin",
        ])
        #expect(request.timeout == .seconds(2))
    }

    @Test
    func testInvocationPrependsResolvedExecutableDirectoryToPATH() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeTemporaryDirectory(root) }
        let realDirectory = root.appending(path: "real-bin", directoryHint: .isDirectory)
        let facadeDirectory = root.appending(path: "facade-bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: facadeDirectory, withIntermediateDirectories: true)
        let target = try TestSupport.makeExecutable(named: ArgyllTool.spotread.rawValue, in: realDirectory)
        let facade = facadeDirectory.appending(path: ArgyllTool.spotread.rawValue)
        try FileManager.default.createSymbolicLink(at: facade, withDestinationURL: target)

        let invocation = ArgyllInvocation(tool: .spotread, executableURL: facade, arguments: ["-?"])
        let request = invocation.processRequest(
            workingDirectoryURL: root,
            inheritedEnvironment: ["PATH": "/usr/local/bin:/usr/bin"]
        )

        #expect(request.environment["PATH"] == "\(realDirectory.path):/usr/local/bin:/usr/bin")
        #expect(request.environment["ARGYLL_NOT_INTERACTIVE"] == "1")
        #expect(request.environment["LC_ALL"] == "C")
        #expect(request.environment["LANG"] == "C")
    }

    private func installation(at directory: URL) -> ArgyllInstallation {
        ArgyllInstallation(
            directory: directory,
            executables: Dictionary(uniqueKeysWithValues: ArgyllTool.allCases.map {
                ($0, directory.appending(path: $0.rawValue))
            })
        )
    }

    private func profileRequest(root: URL, description: String) -> ProfileBuildRequest {
        ProfileBuildRequest(
            sessionDirectory: root,
            measurementURL: root.appending(path: "display.ti3"),
            calibrationURL: root.appending(path: "display.cal"),
            outputURL: root.appending(path: "display.icc"),
            model: .shaperMatrix,
            displayName: "Synthetic Display",
            description: description
        )
    }

    private func assertInvalidRequest(_ error: Error) {
        guard case ArgyllEngineError.invalidRequest = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
    }
}

private extension Array where Element: Equatable {
    func containsOrderedSubsequence(_ expected: [Element]) -> Bool {
        guard !expected.isEmpty else { return true }
        var index = expected.startIndex
        for element in self where element == expected[index] {
            index = expected.index(after: index)
            if index == expected.endIndex { return true }
        }
        return false
    }
}
