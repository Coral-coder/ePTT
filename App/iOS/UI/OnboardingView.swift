import SwiftUI

/// First launch: pick the name people see when you key up. Shown until a name is chosen.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var name = ""
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ZStack {
            GridBackground(horizon: 0.72, energy: 1.1)
            VStack(spacing: 22) {
                Spacer(minLength: 40)
                Text("NXTPTT")
                    .font(NX.display(34, relativeTo: .largeTitle))
                    .tracking(6)
                    .foregroundStyle(.white)
                    .neonGlow(NX.cyan, radius: 14)
                    .accessibilityAddTraits(.isHeader)
                Text("Push to talk, the Nextel way. Encrypted end to end, with no server in between.")
                    .font(NX.body(16))
                    .foregroundStyle(NX.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 8) {
                    SectionCaption(text: "Your name")
                    TextField("", text: $name, prompt: Text("What should people see?").foregroundColor(NX.textMuted))
                        .font(NX.body(20, .medium))
                        .foregroundStyle(NX.text)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($focused)
                        .onSubmit(finish)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 56)
                        .glass(cornerRadius: 18, glow: focused ? 0.35 : 0.15, strong: focused)
                    Text("Shown to everyone you pair and talk with. You can change it later in Settings.")
                        .font(NX.body(13))
                        .foregroundStyle(NX.textMuted)
                }
                .padding(.top, 10)

                Button("START", action: finish)
                    .buttonStyle(NXButtonStyle(kind: .gel))
                    .disabled(trimmed.isEmpty)
                    .opacity(trimmed.isEmpty ? 0.5 : 1)

                Spacer()
            }
            .padding(.horizontal, 26)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Offer the current name unless it's the old generic device default.
            let current = model.snapshot.settings.displayName
            if !["iPhone", "iPad", ""].contains(current) { name = current }
            focused = true
        }
    }

    private func finish() {
        if model.setDisplayName(name) { focused = false }
    }
}
