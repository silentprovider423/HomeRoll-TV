import SwiftUI

/// Anmeldung, ganz ohne Touch: links QR-Code + Code für die Kopplung per iPhone/Browser, rechts „Auf dem Fernseher
/// eingeben“ (Bildschirmtastatur; tvOS bietet die Eingabe auch als Mitteilung auf dem iPhone an).
struct LoginView: View {
    @Environment(AppModel.self) private var app
    @State private var pairing = PairingModel()
    @State private var manual = false

    var body: some View {
        NavigationStack {
            HStack(alignment: .center, spacing: 100) {
                VStack(alignment: .leading, spacing: 28) {
                    Label { Text("HomeRoll TV") } icon: { Image(systemName: "photo.stack.fill") }
                        .font(.system(size: 64, weight: .bold))
                    Text("Deine Fotos vom eigenen Immich-Server – auf dem Fernseher.")
                        .font(.title3).foregroundStyle(.secondary)
                    Spacer().frame(height: 20)
                    Button { manual = true } label: {
                        Label("Auf dem Fernseher eingeben", systemImage: "keyboard")
                            .frame(minWidth: 620)
                    }
                    .accessibilityIdentifier("login-manual")
                    Text("Server-Adresse, E-Mail und Passwort mit der Fernbedienung – oder per iPhone-Tastatur.")
                        .font(.callout).foregroundStyle(.secondary).frame(maxWidth: 700, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                PairingPanel(model: pairing)
                    .frame(width: 720)
            }
            .padding(.horizontal, 60)
            .navigationDestination(isPresented: $manual) { ManualLoginView() }
        }
        .task {
            await pairing.start { acc in app.didLogin(acc) }
        }
        .onDisappear { pairing.stop() }
    }
}

/// Kopplung: kleiner Webserver im Heimnetz + QR-Code.
@MainActor @Observable
final class PairingModel {
    var link: String?
    var code = ""
    var qr: CGImage?
    var failed = false
    @ObservationIgnored private var server: PairingServer?

    func start(onLogin: @escaping @MainActor (Account) -> Void) async {
        guard server == nil else { return }
        let client = ImmichClient.shared
        let s = PairingServer { sub in
            do {
                let acc = sub.usesKey ? try await client.login(server: sub.server, key: sub.key)
                                      : try await client.login(server: sub.server, email: sub.email, password: sub.password)
                await MainActor.run { onLogin(acc) }
                return .success(acc.name ?? acc.email ?? "")
            } catch { return .failure(error) }
        }
        s.onCodeChange = { [weak self] c in Task { @MainActor in self?.update(code: c) } }
        server = s
        do {
            let port = try await s.start()
            var host = LocalAddress.ipv4()
            #if DEBUG
            // Bildschirmfotos ohne die echte Heimnetz-Adresse
            if let h = ProcessInfo.processInfo.environment["FOTOS_PAIRING_HOST"] { host = h }
            #endif
            guard let ip = host else { failed = true; return }
            link = PairingServer.link(host: ip, port: port, code: nil)
            update(code: s.currentCode, ip: ip, port: port)
        } catch { failed = true }
    }

    @ObservationIgnored private var ip = ""
    @ObservationIgnored private var port: UInt16 = 0
    private func update(code c: String, ip: String? = nil, port: UInt16? = nil) {
        if let ip { self.ip = ip }
        if let port { self.port = port }
        code = c
        qr = QRCode.image(PairingServer.link(host: self.ip, port: self.port, code: c))
    }

    func stop() { server?.stop(); server = nil }
}

private struct PairingPanel: View {
    let model: PairingModel
    var body: some View {
        VStack(spacing: 26) {
            Text("Mit dem iPhone anmelden").font(.title3.weight(.semibold))
            if let qr = model.qr {
                Image(decorative: qr, scale: 1).interpolation(.none).resizable().scaledToFit()
                    .frame(width: 360, height: 360).padding(22)
                    .background(.white, in: RoundedRectangle(cornerRadius: 28))
                    .accessibilityLabel(Text("QR-Code zur Anmeldung"))
                Text("Code mit der Kamera scannen und Server + Zugang eintragen.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let link = model.link {
                    VStack(spacing: 8) {
                        Text("Ohne Kamera: im Browser öffnen").font(.caption).foregroundStyle(.secondary)
                        Text(link).font(.headline.monospaced())
                        Text(model.code).font(.system(size: 54, weight: .bold, design: .monospaced)).kerning(10)
                            .accessibilityIdentifier("pairing-code")
                    }
                }
            } else if model.failed {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 80)).foregroundStyle(.secondary)
                Text("Kopplung nicht möglich – kein Heimnetz gefunden. Bitte auf dem Fernseher eingeben.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .padding(40)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 44))
    }
}

/// Eingabe per Bildschirmtastatur.
struct ManualLoginView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("lastServer") private var server = ""
    @State private var email = ""
    @State private var password = ""
    @State private var key = ""
    @State private var useKey = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 30) {
            Text("Bei Immich anmelden").font(.title2.weight(.bold))
            Form {
                Section {
                    TextField("Server-Adresse, z. B. https://photos.example.com", text: $server)
                        .textContentType(.URL).keyboardType(.URL).autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("login-server")
                }
                Section {
                    Picker("Zugang", selection: $useKey) {
                        Text("E-Mail und Passwort").tag(false)
                        Text("API-Schlüssel").tag(true)
                    }
                    if useKey {
                        SecureField("API-Schlüssel", text: $key)
                    } else {
                        TextField("E-Mail", text: $email)
                            .textContentType(.username).keyboardType(.emailAddress).autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityIdentifier("login-email")
                        SecureField("Passwort", text: $password).textContentType(.password)
                            .accessibilityIdentifier("login-password")
                    }
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Text("Anmelden")
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || server.isEmpty || (useKey ? key.isEmpty : (email.isEmpty || password.isEmpty)))
                    .accessibilityIdentifier("login-submit")
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
            .frame(maxWidth: 1100)
        }
    }

    private func submit() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let acc = useKey ? try await app.client.login(server: server, key: key)
                             : try await app.client.login(server: server, email: email, password: password)
            password = ""; key = ""
            app.didLogin(acc)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
