import SwiftUI

/// LumaProfile's visual language.
///
/// The interface is deliberately hue-free: surfaces are neutral greys and the
/// accent is near-white, so the application chrome never biases the operator's
/// perception of the display being measured. Colour is reserved for status.
enum Luma {
    // MARK: Surfaces

    static let canvas = Color(white: 0.067)
    static let surface = Color(white: 0.105)
    static let raised = Color(white: 0.150)
    static let hairline = Color.white.opacity(0.08)
    static let accent = Color(white: 0.96)

    // MARK: Status

    static let positive = Color(red: 0.42, green: 0.82, blue: 0.58)
    static let caution = Color(red: 0.95, green: 0.72, blue: 0.36)
    static let critical = Color(red: 0.95, green: 0.44, blue: 0.40)
    static let info = Color(red: 0.52, green: 0.72, blue: 0.98)

    // MARK: Type scale

    static let display = Font.system(size: 28, weight: .semibold)
    static let title = Font.system(size: 17, weight: .semibold)
    static let lead = Font.system(size: 14)
    static let eyebrow = Font.system(size: 10.5, weight: .semibold)
    static let heroNumeral = Font.system(size: 46, weight: .light).monospacedDigit()
    static let numeral = Font.system(size: 19, weight: .regular).monospacedDigit()
    static let mono = Font.system(size: 12, design: .monospaced)

    // MARK: Geometry

    static let cardRadius: CGFloat = 14
    static let tileRadius: CGFloat = 10
    static let pageWidth: CGFloat = 880
    static let pagePadding: CGFloat = 32
}

extension View {
    /// Page title: large, tight, never bold-shouty.
    func lumaDisplay() -> some View {
        font(Luma.display).tracking(-0.4)
    }

    /// Small uppercase label used above values and groups.
    func lumaEyebrow() -> some View {
        font(Luma.eyebrow)
            .textCase(.uppercase)
            .tracking(1.1)
            .foregroundStyle(.secondary)
    }

    /// Quiet explanatory copy. Kept to one or two short sentences per card.
    func lumaNote() -> some View {
        font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Inset tile used for values inside a card.
    func lumaTile(padding: CGFloat = 12) -> some View {
        self
            .padding(padding)
            .background(Luma.raised, in: RoundedRectangle(cornerRadius: Luma.tileRadius, style: .continuous))
    }
}

// MARK: - Card

/// The single container used for grouped content. Mirrors the `GroupBox`
/// initialisers so call sites stay simple.
struct LumaCard<Content: View, Header: View>: View {
    private let content: Content
    private let header: Header?

    init(@ViewBuilder content: () -> Content) where Header == EmptyView {
        self.content = content()
        self.header = nil
    }

    init(_ title: String, @ViewBuilder content: () -> Content) where Header == Text {
        self.content = content()
        self.header = Text(title)
    }

    init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Header) {
        self.content = content()
        self.header = label()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let header {
                header.lumaEyebrow()
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Luma.surface, in: RoundedRectangle(cornerRadius: Luma.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Luma.cardRadius, style: .continuous)
                .strokeBorder(Luma.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Buttons

struct LumaPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let large = controlSize == .large
        return configuration.label
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .font(.system(size: large ? 14 : 13, weight: .semibold))
            .foregroundStyle(Color.black.opacity(isEnabled ? 0.92 : 0.5))
            .padding(.horizontal, large ? 22 : 14)
            .padding(.vertical, large ? 9 : 6)
            .background(
                Luma.accent.opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.25),
                in: Capsule()
            )
            .contentShape(Capsule())
    }
}

struct LumaSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let large = controlSize == .large
        let tone: Color = configuration.role == .destructive ? Luma.critical : Color.primary
        return configuration.label
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .font(.system(size: large ? 14 : 13, weight: .medium))
            .foregroundStyle(tone.opacity(isEnabled ? 1 : 0.4))
            .padding(.horizontal, large ? 20 : 13)
            .padding(.vertical, large ? 9 : 6)
            .background(
                Color.white.opacity(configuration.isPressed ? 0.14 : 0.06),
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(Luma.hairline, lineWidth: 1))
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == LumaPrimaryButtonStyle {
    static var lumaPrimary: LumaPrimaryButtonStyle { LumaPrimaryButtonStyle() }
}

extension ButtonStyle where Self == LumaSecondaryButtonStyle {
    static var lumaSecondary: LumaSecondaryButtonStyle { LumaSecondaryButtonStyle() }
}

// MARK: - Checklist toggle

/// A full-row confirmation used for explicit operator acknowledgements.
struct LumaChecklistToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(configuration.isOn ? Luma.positive : Color.secondary)
                configuration.label
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "Confirmed" : "Not confirmed")
    }
}

extension ToggleStyle where Self == LumaChecklistToggleStyle {
    static var lumaChecklist: LumaChecklistToggleStyle { LumaChecklistToggleStyle() }
}

// MARK: - Small building blocks

/// A label above a value. `prominent` values use the numeral face.
struct LumaMetric: View {
    var label: String
    var value: String
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).lumaEyebrow()
            Text(value)
                .font(prominent ? Luma.numeral : .system(size: 13).monospacedDigit())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Thin determinate progress rail.
struct LumaProgressBar: View {
    /// Fraction complete, clamped to 0...1.
    var fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(Luma.accent)
                    .frame(width: max(4, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.25), value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((min(max(fraction, 0), 1) * 100).rounded())) percent")
    }
}

/// Selectable option tile used in place of crowded segmented controls.
struct LumaOptionTile: View {
    var title: String
    var value: String
    var caption: String
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(value).font(Luma.numeral)
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                isSelected ? Luma.raised : Color.clear,
                in: RoundedRectangle(cornerRadius: Luma.tileRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Luma.tileRadius, style: .continuous)
                    .strokeBorder(isSelected ? Luma.accent.opacity(0.85) : Luma.hairline, lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Luma.tileRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(value) \(caption)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
