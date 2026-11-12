import SwiftUI
import JarvisCore
import JarvisModel
import JarvisNet

/// Saved server addresses (Tailscale, ngrok, LAN...): one-tap switch, add / edit / delete, test connection.
/// The device token belongs to the Jarvis server, not the URL: switching reconnects everything without pairing again
/// when the server accepts the token; otherwise the pairing screen opens for the chosen address.
struct ServerAddressesView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var editor: AddressEditor.Target?
    @State private var results: [String: ApiClient.Probe] = [:]
    @State private var testing: Set<String> = []
    @State private var failure: String?
    @State private var confirmDelete: SavedServer?

    var body: some View {
        List {
            if let why = app.addressProblem {
                Section {
                    Label(why, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundColor(Theme.warn)
                    if let a = settings.activeServer { Button("Edit address") { editor = .edit(a) } }
                } header: { Text("The current address is not working") }
                  footer: { Text("ngrok free addresses change every time the tunnel restarts. Paste the new one, or switch to another saved address.") }
            }
            Section {
                ForEach(settings.servers) { s in row(s) }
                Button { editor = .new } label: { Label("Add address", systemImage: "plus.circle") }
            } header: { Text("Saved addresses") }
              footer: { Text("Tap an address to switch to it. The session, terminals, cameras and uploads move over without pairing again when it is the same Jarvis server.") }
        }
        .navigationTitle("Server addresses").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .sheet(item: $editor) { t in NavigationStack { AddressEditor(target: t, onSwitched: { dismiss() }) } }
        .alert("Could not switch", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failure ?? "") }
        .confirmationDialog("Delete this address?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let s = confirmDelete { do { try settings.deleteServer(id: s.id) } catch { failure = error.localizedDescription } }
                confirmDelete = nil
            }
        } message: { Text(confirmDelete.map { "\($0.name) · \($0.address)" } ?? "") }
    }

    private func row(_ s: SavedServer) -> some View {
        let active = s.id == settings.activeID
        return HStack(spacing: 10) {
            Button { switchTo(s) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(s.name).foregroundColor(Theme.text)
                        if active { PillLabel(text: "in use", color: Theme.ok) }
                        if !settings.hasToken(for: s.id) && !active { PillLabel(text: "not paired", color: Theme.dimText) }
                    }
                    Text(s.address).font(.footnote).foregroundColor(Theme.dimText).lineLimit(1).truncationMode(.middle)
                    if testing.contains(s.id) { Text("Testing…").font(.caption).foregroundColor(Theme.dimText) }
                    else if let r = results[s.id] { Text(r.summary).font(.caption).foregroundColor(color(r)) }
                }
            }
            .buttonStyle(.plain)
            .disabled(app.switching)
            Spacer()
            Menu {
                Button { test(s) } label: { Label("Test connection", systemImage: "network") }
                Button { editor = .edit(s) } label: { Label("Edit", systemImage: "pencil") }
                if !active { Button(role: .destructive) { confirmDelete = s } label: { Label("Delete", systemImage: "trash") } }
            } label: { Image(systemName: "ellipsis.circle").font(.title3).frame(width: 40, height: 40) }
            .accessibilityLabel("Options for \(s.name)")
        }
        .accessibilityElement(children: .contain)
    }

    private func color(_ p: ApiClient.Probe) -> Color {
        switch p { case .paired: return Theme.ok; case .unpaired: return Theme.warn; case .unreachable: return Theme.bad }
    }

    private func test(_ s: SavedServer) {
        testing.insert(s.id)
        Task {
            let r = await app.testConnection(address: s.address, serverID: s.id)
            results[s.id] = r; testing.remove(s.id)
        }
    }

    private func switchTo(_ s: SavedServer) {
        Task {
            switch await app.switchTo(s.id) {
            case .switched: dismiss()
            case .needsPairing: dismiss()          // the root view now shows the pairing screen for that address
            case .failed(let why): failure = "\(s.name) (\(s.address)): \(why)"
            }
        }
    }
}

/// Add or edit one address, with a live preview of how it was understood and a Test connection button.
struct AddressEditor: View {
    enum Target: Identifiable {
        case new, edit(SavedServer)
        var id: String { switch self { case .new: return "new"; case .edit(let s): return s.id } }
    }
    let target: Target
    var onSwitched: () -> Void
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var result: ApiClient.Probe?
    @State private var testing = false
    @State private var error: String?
    @State private var loaded = false

    private var existing: SavedServer? { if case .edit(let s) = target { return s }; return nil }
    private var parsed: Result<Endpoint, Error>? {
        address.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Result { try Endpoint.parse(address) }
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Tailscale, ngrok, LAN…", text: $name).textInputAutocapitalization(.words)
            }
            Section {
                TextField("my-laptop.tail1234.ts.net or https://abc.ngrok-free.app", text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                switch parsed {
                case .success(let ep)?:
                    Label("Connects to \(ep.origin)", systemImage: "checkmark.circle").font(.footnote).foregroundColor(Theme.ok)
                    if ep.isNgrok { Text("ngrok address: free-plan addresses change when the tunnel restarts.").font(.footnote).foregroundColor(Theme.dimText) }
                case .failure(let e)?:
                    Label(e.localizedDescription, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundColor(Theme.bad)
                case nil: EmptyView()
                }
            } header: { Text("Address") }
              footer: { Text("A bare host, host:port or a full URL. Paths and trailing slashes are ignored. Plain http:// works only for LAN, Tailscale and localhost addresses.") }
            Section {
                Button { test() } label: { HStack { Text("Test connection"); Spacer(); if testing { ProgressView() } } }
                    .disabled(testing || { if case .success? = parsed { return false }; return true }())
                if let r = result { Text(r.summary).font(.footnote).foregroundColor(resultColor(r)) }
            }
            if let error = error { Section { Text(error).font(.footnote).foregroundColor(Theme.bad) } }
            if existing == nil {
                Section { Button("Save and switch to it") { save(switchAfter: true) }.disabled(!valid) }
            }
        }
        .navigationTitle(existing == nil ? "New address" : "Edit address").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save(switchAfter: false) }.disabled(!valid) }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let s = existing { name = s.name; address = s.address }
        }
    }

    private var valid: Bool { if case .success? = parsed { return true }; return false }

    private func resultColor(_ p: ApiClient.Probe) -> Color {
        switch p { case .paired: return Theme.ok; case .unpaired: return Theme.warn; case .unreachable: return Theme.bad }
    }

    private func test() {
        testing = true; result = nil
        Task { result = await app.testConnection(address: address, serverID: existing?.id); testing = false }
    }

    private func save(switchAfter: Bool) {
        error = nil
        do {
            if let s = existing {
                let wasActive = s.id == settings.activeID
                let changed = (try? Endpoint.parse(address)) != s.endpoint
                try settings.updateServer(id: s.id, name: name, address: address)
                if wasActive && changed { app.activeAddressEdited() }
                dismiss()
            } else {
                let s = try settings.addServer(name: name, address: address)
                if switchAfter {
                    Task {
                        switch await app.switchTo(s.id) {
                        case .failed(let why): error = why        // stays saved; the owner can fix or test it
                        default: dismiss(); onSwitched()
                        }
                    }
                } else { dismiss() }
            }
        } catch { self.error = error.localizedDescription }
    }
}
