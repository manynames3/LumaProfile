import AppKit
import Foundation
import SwiftUI

struct AboutView: View {
    @ObservedObject var model: AppModel
    private let documents = LegalDocumentLocator()

    private var version: String {
        let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (marketing, build) {
        case let (.some(marketing), .some(build)) where marketing != build:
            return "Version \(marketing) (\(build))"
        case let (.some(marketing), _):
            return "Version \(marketing)"
        case let (_, .some(build)):
            return "Build \(build)"
        default:
            return "Source build"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                licenseNotice
                warrantyNotice
                privacyNotice
                sourceNotice
                argyllNotice
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .navigationTitle("About & Licenses")
    }

    private var privacyNotice: some View {
        LumaCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.title2)
                    .foregroundStyle(Luma.info)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Local by default")
                        .font(.headline)
                    Text("Display measurements, generated profiles, imported corrections, and run logs stay in your user account on this Mac. LumaProfile does not upload calibration data or require an account.")
                    HStack {
                        Button("Show My Data in Finder") { Task { await model.revealLocalData() } }
                        Button("Copy Support Diagnostics") { model.copyDiagnostics() }
                    }
                    Text("The copied summary omits raw measurements and replaces your home-folder path with ~. Review it before posting publicly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            Group {
                if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                   let icon = NSImage(contentsOf: iconURL) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "circle.lefthalf.filled").resizable().foregroundStyle(Luma.accent)
                }
            }
            .scaledToFit()
            .frame(width: 72, height: 72)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("LumaProfile")
                    .lumaDisplay()
                Text(version)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Native display calibration for macOS")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var licenseNotice: some View {
        LumaCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("GNU AGPLv3-only", systemImage: "checkmark.seal.fill")
                    .font(Luma.title)
                    .foregroundStyle(Luma.accent)
                Text("LumaProfile is free software licensed only under version 3 of the GNU Affero General Public License (AGPL-3.0-only). You may copy, share, and modify it under that license's terms.")
                legalDocumentButton(
                    localURL: documents.lumaProfileLicense,
                    localTitle: "Open Packaged License",
                    fallbackTitle: "Read AGPLv3 Online",
                    fallbackURL: URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!
                )
                if documents.lumaProfileLicense == nil {
                    Label("The packaged license file is not available in this source run; the button opens the official GNU copy.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var warrantyNotice: some View {
        LumaCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(Luma.caution)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("No warranty")
                        .font(.headline)
                    Text("LumaProfile is provided as-is, without any warranty, including implied warranties of merchantability or fitness for a particular purpose, to the extent permitted by law. See the GNU AGPLv3 for the complete disclaimer and limitation of liability.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sourceNotice: some View {
        LumaCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.title2)
                    .foregroundStyle(Luma.positive)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Corresponding source included")
                        .font(.headline)
                    Text("This AGPL distribution includes the corresponding source code and build materials for LumaProfile and its bundled AGPL components. Preserve the license, source, copyright, and attribution notices when redistributing it.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var argyllNotice: some View {
        LumaCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "shippingbox.fill")
                        .font(.title2)
                        .foregroundStyle(Luma.info)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Bundled ArgyllCMS 3.5.0")
                            .font(.headline)
                        Text("LumaProfile bundles the Argyll Color Management System, version 3.5.0, developed by Graeme W. Gill and contributors. Copyright in ArgyllCMS is held by Graeme W. Gill and other named contributors. The package as a whole is distributed under the GNU Affero General Public License version 3. Individual bundled components may carry compatible separate notices; consult the packaged third-party notices for details.")
                    }
                }
                HStack {
                    legalDocumentButton(
                        localURL: documents.argyllLicense,
                        localTitle: "Open ArgyllCMS License",
                        fallbackTitle: "Read ArgyllCMS License Notice",
                        fallbackURL: URL(string: "https://www.argyllcms.com/doc/ArgyllDoc.html")!
                    )
                    legalDocumentButton(
                        localURL: documents.thirdPartyNotices,
                        localTitle: "Open Third-Party Notices",
                        fallbackTitle: "Read Component Notices Online",
                        fallbackURL: URL(string: "https://www.argyllcms.com/doc/ArgyllDoc.html")!
                    )
                    Link(destination: URL(string: "https://www.argyllcms.com/")!) {
                        Label("ArgyllCMS Project", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)
                }
                if documents.argyllLicense == nil || documents.thirdPartyNotices == nil {
                    Label("One or more packaged notice files are not available in this source run; their buttons open the upstream notice.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func legalDocumentButton(
        localURL: URL?,
        localTitle: String,
        fallbackTitle: String,
        fallbackURL: URL
    ) -> some View {
        Link(destination: localURL ?? fallbackURL) {
            Label(
                localURL == nil ? fallbackTitle : localTitle,
                systemImage: localURL == nil ? "arrow.up.right.square" : "doc.text"
            )
        }
        .buttonStyle(.lumaPrimary)
    }
}

private struct LegalDocumentLocator {
    var lumaProfileLicense: URL? {
        locate([
            "Licenses/LumaProfile-AGPL-3.0.txt",
            "Licenses/AGPL-3.0.txt",
            "Licenses/LumaProfile.txt",
            "LICENSE",
            "LICENSE.txt",
            "LICENSE.md",
            "COPYING",
            "COPYING.txt",
            "AGPL-3.0.txt",
        ])
    }

    var argyllLicense: URL? {
        locate([
            "Licenses/ArgyllCMS-License.txt",
            "Licenses/ArgyllCMS.txt",
            "ArgyllCMS/License.txt",
        ])
    }

    var thirdPartyNotices: URL? {
        locate([
            "Licenses/THIRD_PARTY_NOTICES.md",
            "NOTICE",
            "NOTICE.txt",
            "NOTICES.txt",
            "THIRD-PARTY-NOTICES.txt",
            "THIRD_PARTY_NOTICES.md",
        ])
    }

    private func locate(_ relativePaths: [String]) -> URL? {
        for root in candidateRoots {
            for relativePath in relativePaths {
                let candidate = root.appending(path: relativePath).standardizedFileURL
                guard candidate.path.hasPrefix(root.standardizedFileURL.path) else { continue }
                if isRegularFile(candidate) { return candidate }
            }
        }
        return nil
    }

    private var candidateRoots: [URL] {
        var roots: [URL] = []
        if let resources = Bundle.main.resourceURL { roots.append(resources) }
        if let sharedSupport = Bundle.main.sharedSupportURL { roots.append(sharedSupport) }

        // `swift run` does not create an application resource bundle. Walk only
        // a few ancestors so checked-in legal files remain usable during source runs.
        let sourceStarts = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            URL(fileURLWithPath: CommandLine.arguments.first ?? "", isDirectory: false).deletingLastPathComponent(),
        ]
        for start in sourceStarts {
            if let packageRoot = packageRoot(startingAt: start) { roots.append(packageRoot) }
        }
        return roots.reduce(into: []) { unique, url in
            if !unique.contains(url.standardizedFileURL) { unique.append(url.standardizedFileURL) }
        }
    }

    private func packageRoot(startingAt start: URL) -> URL? {
        var candidate = start.standardizedFileURL
        for _ in 0..<8 {
            let manifest = candidate.appending(path: "Package.swift")
            if isRegularFile(manifest) { return candidate }
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate { break }
            candidate = parent
        }
        return nil
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}
