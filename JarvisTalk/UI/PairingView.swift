import SwiftUI
import JarvisCore
import JarvisModel

/// First run (and after "forget this phone"): the server address and the one-time code from `jarvis pair`.
struct PairingView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var settings: SettingsStore
    @State private var address = ""
    @State private var code = ""
    @State private var name = UIDevice.current.name
    @FocusState private var focus: Field?
    enum Field { case address, code, name }

    var body: some View {
        ZStack {
            StageBackground(accent: Theme.accent(.jarvis))
            ScrollView {
                VStack(spacing: 18) {
                    Circle().stroke(Theme.accent(.jarvis), lineWidth: 2).frame(width: 46, height: 46)
                        .overlay(Circle().fill(Theme.accentLight(.jarvis)).frame(width: 18, height: 18))
                        .shadow(color: Theme.accent(.jarvis).opacity(0.6), radius: 14)
                        .padding(.top, 36)
                        .accessibilityHidden(true)
                    Text("JARVIS").font(.system(size: 20, weight: .bold, design: .monospaced)).tracking(8).foregroundColor(Theme.text)
                    Text(app.pairingTarget.map { "Pair this iPhone on \($0.name)." } ?? "Pair this iPhone with your Jarvis server.")
                        .font(.subheadline).foregroundColor(Theme.dimText).multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: 12) {
                        field("Server address", text: $address, placeholder: "my-laptop.tail1234.ts.net or https://abc.ngrok-free.app", field: .address, keyboard: .URL)
                        addressPreview
                        field("Pairing code", text: $code, placeholder: "from `jarvis pair` on the laptop", field: .code, keyboard: .asciiCapable, mono: true)
                        field("Name of this phone", text: $name, placeholder: "iPhone", field: .name, keyboard: .default)
                        if let err = app.pairingError {
                            Label(err, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote).foregroundColor(Theme.bad)
                                .accessibilityLabel("Error: \(err)")
                        }
                        Button(action: submit) {
                            HStack { if app.pairing { ProgressView().tint(.black) }; Text(app.pairing ? "Pairing…" : "Pair").fontWeight(.bold) }
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent(.jarvis)))
                                .foregroundColor(.black)
                        }
                        .disabled(app.pairing || address.isEmpty || code.isEmpty)
                        .opacity(address.isEmpty || code.isEmpty ? 0.5 : 1)
                        if app.canCancelPairing {
                            Button("Back to the connected address") { app.cancelPairing() }.font(.footnote).frame(maxWidth: .infinity)
                        }
                    }
                    .padding(18).glass()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("How").font(.footnote.weight(.semibold)).foregroundColor(Theme.text)
                        Text("1. Turn Tailscale on on this iPhone.\n2. On the laptop run `jarvis pair` — it prints a code that works once, for 10 minutes.\n3. Enter the server address — the Tailscale name (the one `tailscale serve` shows), an ngrok https:// URL, or a LAN address like 192.168.1.5:8000 — and the code.\nYou can save more addresses and switch between them later in Settings.")
                            .font(.footnote).foregroundColor(Theme.dimText)
                    }.padding(.horizontal, 4)
                }
                .padding(20)
            }
        }
        .onAppear { if address.isEmpty { address = app.pairingTarget?.address ?? settings.endpointText } }
        .onTapGesture { focus = nil }
    }

    @ViewBuilder private var addressPreview: some View {
        if !address.trimmingCharacters(in: .whitespaces).isEmpty {
            switch Result(catching: { try Endpoint.parse(address) }) {
            case .success(let ep): Label("Connects to \(ep.origin)", systemImage: "checkmark.circle").font(.caption).foregroundColor(Theme.ok)
            case .failure(let e): Label(e.localizedDescription, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundColor(Theme.bad)
            }
        }
    }

    private func submit() {
        focus = nil
        Task { await app.pair(address: address, code: code, name: name) }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String, field: Field, keyboard: UIKeyboardType, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(Theme.dimText)
            TextField(placeholder, text: text)
                .keyboardType(keyboard).textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(mono ? .system(.body, design: .monospaced) : .body)
                .focused($focus, equals: field)
                .submitLabel(field == .name ? .go : .next)
                .onSubmit { if field == .address { focus = .code } else if field == .code { focus = .name } else { submit() } }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.4)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent(.jarvis).opacity(0.35)))
        }
    }
}
