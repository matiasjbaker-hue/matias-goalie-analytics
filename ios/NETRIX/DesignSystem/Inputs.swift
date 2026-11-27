import SwiftUI

/// Text field from the design system: rounded 64pt field, leading icon, floating label,
/// trailing check / eye toggle, ice-blue focus ring and red error state.
struct NXTextField: View {
    let label: String
    var icon: String? = nil
    @Binding var text: String
    var isSecure = false
    var isValid = false
    var error: String? = nil
    var helper: String? = nil
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType? = nil
    var autocapitalization: TextInputAutocapitalization = .sentences
    var submitLabel: SubmitLabel = .next
    var onSubmit: () -> Void = {}

    @FocusState private var focused: Bool
    @State private var revealed = false

    private var floating: Bool { focused || !text.isEmpty }
    private var borderColor: Color {
        if error != nil { return NX.error.opacity(0.8) }
        if focused { return NX.borderFocus }
        return NX.borderSubtle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: NX.S.m) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 16))
                        .foregroundStyle(NX.textSecondary)
                        .frame(width: 20)
                }
                ZStack(alignment: .leading) {
                    Text(label)
                        .font(floating ? .nxCaption : .nxBodyL)
                        .foregroundStyle(focused && error == nil ? NX.ice : NX.textMuted)
                        .offset(y: floating ? -11 : 0)
                    field
                        .font(.nxBodyL)
                        .foregroundStyle(.white)
                        .tint(NX.ice)
                        .offset(y: floating ? 9 : 0)
                        .opacity(floating ? 1 : 0.02)
                }
                .animation(.easeOut(duration: 0.15), value: floating)
                if isSecure {
                    Button { revealed.toggle() } label: {
                        Image(systemName: revealed ? "eye" : "eye.slash")
                            .font(.system(size: 16))
                            .foregroundStyle(NX.textSecondary)
                            .frame(width: 32, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(revealed ? "Hide password" : "Show password")
                } else if isValid {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(NX.success)
                }
            }
            .padding(.horizontal, NX.S.l)
            .frame(height: 64)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(NX.field))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(borderColor, lineWidth: focused || error != nil ? 1.5 : 1))
            .shadow(color: focused ? NX.ice.opacity(0.25) : .clear, radius: 10)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }

            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.nxBodyS)
                    .foregroundStyle(NX.error)
            } else if let helper {
                Text(helper).font(.nxCaption).foregroundStyle(NX.textMuted)
            }
        }
    }

    @ViewBuilder private var field: some View {
        Group {
            if isSecure && !revealed {
                SecureField("", text: $text)
            } else {
                TextField("", text: $text)
            }
        }
        .focused($focused)
        .keyboardType(keyboard)
        .textContentType(contentType)
        .textInputAutocapitalization(autocapitalization)
        .autocorrectionDisabled(isSecure || keyboard == .emailAddress)
        .submitLabel(submitLabel)
        .onSubmit(onSubmit)
    }
}

/// Multi-line note field with character count.
struct NXTextArea: View {
    let placeholder: String
    @Binding var text: String
    var limit = 500
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).font(.nxBody).foregroundStyle(NX.textMuted)
                        .padding(.horizontal, NX.S.l).padding(.vertical, 14)
                }
                TextEditor(text: $text)
                    .font(.nxBody)
                    .foregroundStyle(.white)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, NX.S.m).padding(.vertical, 6)
                    .onChange(of: text) { _, new in if new.count > limit { text = String(new.prefix(limit)) } }
            }
            .frame(height: 130)
            .background(RoundedRectangle(cornerRadius: NX.R.lg, style: .continuous).fill(NX.field))
            .overlay(RoundedRectangle(cornerRadius: NX.R.lg, style: .continuous).stroke(NX.borderSubtle))
            Text("\(text.count) / \(limit)").font(.nxCaption).foregroundStyle(NX.textMuted)
        }
    }
}

/// Square checkbox with label (terms, remember me).
struct NXCheckbox<Label: View>: View {
    @Binding var isOn: Bool
    @ViewBuilder var label: () -> Label
    var body: some View {
        HStack(spacing: 10) {
            Button { isOn.toggle(); Haptics.select() } label: {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isOn ? Color.white : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(isOn ? Color.white : NX.borderStrong, lineWidth: 1.5))
                    .overlay(Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(NX.navy).opacity(isOn ? 1 : 0))
                    .frame(width: 20, height: 20)
                    .frame(width: 44, height: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isOn ? .isSelected : [])
            label()
        }
    }
}

/// Four-segment password strength meter.
struct StrengthMeter: View {
    let password: String
    private var score: Int {
        var s = 0
        if password.count >= 8 { s += 1 }
        if password.rangeOfCharacter(from: .decimalDigits) != nil { s += 1 }
        if password.rangeOfCharacter(from: .uppercaseLetters) != nil { s += 1 }
        if password.count >= 12 || password.rangeOfCharacter(from: .punctuationCharacters.union(.symbols)) != nil { s += 1 }
        return password.isEmpty ? 0 : s
    }
    private var label: (String, Color) {
        switch score {
        case 0...1: return ("Weak", NX.error)
        case 2: return ("Fair", NX.warning)
        default: return ("Strong", NX.success)
        }
    }
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
                Capsule().fill(i < score ? label.1 : Color.white.opacity(0.1)).frame(height: 3)
            }
            Text(label.0).font(.nxLabel).foregroundStyle(label.1).frame(width: 56, alignment: .trailing)
        }
        .opacity(password.isEmpty ? 0 : 1)
        .animation(.easeOut, value: score)
    }
}

extension String {
    var isPlausibleEmail: Bool {
        let parts = split(separator: "@")
        return parts.count == 2 && parts[1].contains(".") && !parts[0].isEmpty && count < 255
    }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
