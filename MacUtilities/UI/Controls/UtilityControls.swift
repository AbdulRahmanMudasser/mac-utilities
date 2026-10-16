import AppKit
import SwiftUI

private struct HandPointerModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .pointerStyle(.link)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    (isEnabled ? NSCursor.pointingHand : NSCursor.arrow).set()
                case .ended:
                    NSCursor.arrow.set()
                }
            }
    }
}

extension View {
    func handPointer() -> some View {
        modifier(HandPointerModifier())
    }
}

struct HandCursorToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: UtilityStyle.contentSpacing) {
                configuration.label
                Spacer()
                Capsule()
                    .fill(configuration.isOn ? Color.accentColor : UtilityStyle.Toggle.offColor)
                    .frame(width: UtilityStyle.Toggle.width, height: UtilityStyle.Toggle.height)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(configuration.isOn ? UtilityStyle.Toggle.onThumbColor : UtilityStyle.Toggle.offThumbColor)
                            .frame(width: UtilityStyle.Toggle.thumbSize, height: UtilityStyle.Toggle.thumbSize)
                            .padding(UtilityStyle.Toggle.thumbInset)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handPointer()
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

struct HandCursorPicker<Option: Hashable & Identifiable>: View {
    let title: String
    let options: [Option]
    @Binding var selection: Option
    let optionTitle: (Option) -> String
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: UtilityStyle.contentSpacing) {
                Text(title)
                Spacer()
                Text(optionTitle(selection)).foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down").font(UtilityStyle.Picker.indicatorFont)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handPointer()
        .accessibilityLabel(title)
        .accessibilityValue(optionTitle(selection))
        .popover(isPresented: $isPresented) {
            VStack(spacing: UtilityStyle.Picker.optionSpacing) {
                ForEach(options) { option in
                    Button {
                        selection = option
                        isPresented = false
                    } label: {
                        HStack(spacing: UtilityStyle.contentSpacing) {
                            Text(optionTitle(option))
                            Spacer()
                            Image(systemName: "checkmark").opacity(selection == option ? 1 : 0)
                        }
                        .padding(UtilityStyle.Picker.optionPadding)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .handPointer()
                    .accessibilityAddTraits(selection == option ? .isSelected : [])
                }
            }
            .padding(UtilityStyle.Picker.padding)
            .frame(width: UtilityStyle.Picker.width)
        }
    }
}
