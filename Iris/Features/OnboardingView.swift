import SwiftUI

struct OnboardingView: View {
    @Bindable var model: AppModel
    var adding = false
    var existing: SavedConnection?
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var address = ""
    @State private var name = "Mon Hermes"
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""
    @State private var mode = "basic"
    @State private var busy = false
    @State private var error: String?
    @State private var showGuide = false

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        HStack {
                            HStack(spacing: 10) { IrisMark(size: 28); Text("iris").font(.system(size: 26, weight: .semibold, design: .rounded)) }
                            Spacer()
                            Text(step == 0 ? "BONJOUR" : "CONNEXION").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                        }.padding(.top, 14)
                        if step == 0 && !adding {
                            Spacer(minLength: 20)
                            hero
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Votre agent.\nTout simplement.").font(.system(size: 43, weight: .regular, design: .serif)).tracking(-1.8).fixedSize(horizontal: false, vertical: true)
                                Text("Un endroit calme pour parler à Hermes.\nVos idées, vos agents, votre rythme.")
                                    .font(.body).foregroundStyle(.secondary).lineSpacing(5)
                            }
                            HStack(spacing: 20) {
                                Label("100 % natif", systemImage: "iphone")
                                Label("Chez vous", systemImage: "lock.shield")
                            }.font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 14)
                            VStack(spacing: 18) {
                                PrimaryButton(title: "Rencontrer mon Hermes") { withAnimation { step = 1 } }
                                Button("Découvrir l’interface") { model.loadDemo() }
                                    .font(.subheadline).foregroundStyle(.secondary).padding(.bottom, 8)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Faisons le lien.").font(.system(size: 38, weight: .regular, design: .serif)).tracking(-1)
                                Text("Ouvrez Tailscale sur votre iPhone, puis entrez l’adresse de votre serveur Hermes.")
                                    .foregroundStyle(.secondary).lineSpacing(4)
                            }.padding(.top, 24)
                            VStack(alignment: .leading, spacing: 18) {
                                field("Nom de la connexion", text: $name, placeholder: "Mon Hermes")
                                field("Adresse Hermes", text: $address, placeholder: "https://hermes.tailnet.ts.net", url: true)
                                Picker("Authentification", selection: $mode) {
                                    Text("Identifiants Hermes").tag("basic")
                                    Text("Jeton existant").tag("token")
                                }.pickerStyle(.segmented)
                                if mode == "basic" {
                                    field("Utilisateur", text: $username, placeholder: "admin")
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Mot de passe").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                        SecureField("Mot de passe Hermes", text: $password).textContentType(.password)
                                            .padding(15).background(IrisTheme.background, in: RoundedRectangle(cornerRadius: 14))
                                    }
                                } else {
                                    SecureField("Jeton de session du serveur", text: $token)
                                        .padding(15).background(IrisTheme.background, in: RoundedRectangle(cornerRadius: 14))
                                    Text("Le jeton de session Hermes, pas une clé de fournisseur de modèle.").font(.caption).foregroundStyle(.secondary)
                                }
                            }.irisCard()
                            if let error {
                                Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(IrisTheme.accent).fixedSize(horizontal: false, vertical: true)
                            }
                            PrimaryButton(title: "Connecter mon agent", symbol: "link", busy: busy) { connect() }
                                .disabled(address.isEmpty || (mode == "basic" ? password.isEmpty || username.isEmpty : token.isEmpty))
                                .accessibilityIdentifier("connect-agent")
                            Button { showGuide = true } label: {
                                Label("Où trouver ces informations ?", systemImage: "questionmark.circle")
                                    .font(.subheadline).frame(maxWidth: .infinity)
                            }
                            Label("Connexion directe à Hermes. Vos identifiants restent dans le trousseau de cet iPhone.", systemImage: "lock")
                                .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
                            Spacer(minLength: 12)
                        }
                    }.padding(.horizontal, 28).frame(maxWidth: 540).frame(minHeight: geo.size.height).frame(maxWidth: .infinity)
                }.scrollDismissesKeyboard(.interactively).background(IrisTheme.background)
            }
            .toolbar {
                if adding { ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } } }
                else if step > 0 { ToolbarItem(placement: .topBarLeading) { Button { step = 0 } label: { Image(systemName: "arrow.left") } } }
            }
            .sheet(isPresented: $showGuide) { ConnectionGuide() }
            .onAppear {
                if adding { step = 1 }
                if let existing { name = existing.name; address = existing.endpoint.baseURL.absoluteString; mode = existing.mode }
            }
        }
    }

    private var hero: some View {
        ZStack {
            Circle().fill(IrisTheme.accent.opacity(0.045)).frame(width: 246, height: 246)
            Circle().strokeBorder(IrisTheme.accent.opacity(0.13), lineWidth: 1).frame(width: 205, height: 205)
            Circle().strokeBorder(IrisTheme.accent.opacity(0.07), lineWidth: 1).frame(width: 274, height: 274)
            IrisMark(size: 116)
            Text("vous").font(.caption.weight(.medium)).padding(.horizontal, 17).padding(.vertical, 9)
                .background(IrisTheme.surface, in: Capsule()).rotationEffect(.degrees(-8)).offset(x: -95, y: 62)
            HStack(spacing: 5) { Circle().fill(.green).frame(width: 5, height: 5); Text("Hermes") }.font(.caption.weight(.medium))
                .padding(.horizontal, 15).padding(.vertical, 10).background(IrisTheme.surface, in: Capsule())
                .rotationEffect(.degrees(7)).offset(x: 93, y: -61)
        }.frame(maxWidth: .infinity).frame(height: 260).accessibilityHidden(true)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String, url: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(url ? .URL : .default).accessibilityLabel(label)
                .padding(15).background(IrisTheme.background, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func connect() {
        busy = true; error = nil
        Task {
            do {
                let endpoint = try Endpoint(address)
                let connection = SavedConnection(id: existing?.id ?? UUID(), name: name.isEmpty ? "Hermes" : name, endpoint: endpoint, mode: mode)
                try await model.addConnection(connection, username: username, password: password, token: token)
                password = ""; token = ""; dismiss()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct ConnectionGuide: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Votre Hermes,\ndans votre poche.").font(.system(size: 34, design: .serif))
                    instruction("1", "Le même réseau privé", "Connectez votre serveur et votre iPhone au même compte Tailscale. Gardez Tailscale activé sur l’iPhone.")
                    instruction("2", "L’accès natif de Hermes", "Sur votre serveur, configurez les identifiants du tableau de bord Hermes dans son fichier .env, avec un secret de signature stable.")
                    Text("HERMES_DASHBOARD_BASIC_AUTH_USERNAME\nHERMES_DASHBOARD_BASIC_AUTH_PASSWORD\nHERMES_DASHBOARD_BASIC_AUTH_SECRET")
                        .font(.system(.caption2, design: .monospaced)).textSelection(.enabled).irisCard()
                    instruction("3", "Démarrer le serveur", "Lancez le serveur officiel avec son adresse privée Tailscale. Iris utilise son API directement.")
                    Text("hermes serve --host <IP-Tailscale> --port 9119")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled).irisCard()
                    Text("Dans Iris, entrez http://<IP-Tailscale>:9119. Si vous utilisez Tailscale Serve avec HTTPS, entrez plutôt son adresse https://…ts.net.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Link("Ouvrir la documentation officielle", destination: URL(string: "https://hermes-agent.nousresearch.com/docs/user-guide/desktop#connecting-to-a-remote-backend")!)
                    Text("L’authentification par mot de passe est prévue pour votre réseau privé. Iris ne configure pas votre serveur à votre place.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }.background(IrisTheme.background).navigationTitle("Connexion").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Terminé") { dismiss() } } }
        }
    }
    private func instruction(_ n: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(n).font(.subheadline.weight(.semibold)).frame(width: 30, height: 30).background(IrisTheme.accent.opacity(0.1), in: Circle()).foregroundStyle(IrisTheme.accent)
            VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); Text(detail).font(.subheadline).foregroundStyle(.secondary).lineSpacing(3) }
        }
    }
}
