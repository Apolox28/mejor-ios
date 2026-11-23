import SwiftUI

struct LogoImage: View {
    let size: CGFloat
    var body: some View {
        Image("Logo")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .shadow(color: Brand.accent.opacity(0.35), radius: 24, y: 8)
    }
}

/// Pantalla de inicio de sesión nativa: usuario y contraseña van directo a Instagram.
struct WelcomeView: View {
    @EnvironmentObject private var session: Session
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var step: Step = .credentials
    @State private var code = ""
    @State private var twoFactorID = ""
    @State private var challengePath = ""
    @State private var hint = ""
    @FocusState private var focus: Field?

    enum Step { case credentials, twoFactor, email }
    enum Field { case username, password, code }

    var body: some View {
        ZStack {
            Brand.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    LogoImage(size: 96).padding(.top, 36)
                    Text("Mejor").font(.system(size: 40, weight: .heavy, design: .rounded)).foregroundColor(.white)
                    Text("Instagram sin el feed infinito")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))

                    switch step {
                    case .credentials: credentials
                    case .twoFactor, .email: codeForm
                    }

                    if let error = error {
                        Text(error)
                            .font(.footnote)
                            .foregroundColor(Color(red: 1, green: 0.5, blue: 0.5))
                            .multilineTextAlignment(.center)
                    }

                    Text("Tu usuario y contraseña van directo a Instagram. Mejor los cifra y no los guarda; solo guarda el permiso que Instagram entrega.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 32)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var credentials: some View {
        VStack(spacing: 12) {
            field("Usuario", text: $username, field: .username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
            secureField("Contraseña", text: $password)
            primaryButton("Iniciar sesión") { Task { await logIn() } }
                .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
        }
        .padding(.top, 10)
    }

    private var codeForm: some View {
        VStack(spacing: 12) {
            Text(hint).font(.system(size: 15)).foregroundColor(.white.opacity(0.8)).multilineTextAlignment(.center)
            field("Código", text: $code, field: .code)
                .keyboardType(.numberPad)
            primaryButton("Verificar") { Task { await submitCode() } }
                .disabled(code.trimmingCharacters(in: .whitespaces).count < 4)
            Button("Volver") { reset() }.font(.footnote).foregroundColor(.white.opacity(0.6))
        }
        .padding(.top, 10)
        .onAppear { focus = .code }
    }

    private func field(_ title: String, text: Binding<String>, field: Field) -> some View {
        TextField("", text: text, prompt: Text(title).foregroundColor(.white.opacity(0.4)))
            .focused($focus, equals: field)
            .foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func secureField(_ title: String, text: Binding<String>) -> some View {
        SecureField("", text: text, prompt: Text(title).foregroundColor(.white.opacity(0.4)))
            .focused($focus, equals: .password)
            .foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if busy { ProgressView().tint(Brand.night) }
                else { Text(title).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundColor(Brand.night) }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .background(Brand.ring).clipShape(Capsule())
        }
        .disabled(busy)
    }

    // MARK: Acciones

    private func logIn() async {
        busy = true; error = nil; focus = nil
        defer { busy = false }
        do {
            try await handle(InstagramAPI.shared.logIn(
                username: username.trimmingCharacters(in: .whitespaces), password: password))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func submitCode() async {
        busy = true; error = nil; focus = nil
        defer { busy = false }
        do {
            let result: LoginStep
            switch step {
            case .twoFactor:
                result = try await InstagramAPI.shared.submitTwoFactor(
                    code: code, identifier: twoFactorID,
                    username: username.trimmingCharacters(in: .whitespaces))
            case .email:
                result = try await InstagramAPI.shared.submitEmailCode(code, challengePath: challengePath)
            case .credentials:
                return
            }
            try await handle(result)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func handle(_ result: LoginStep) async throws {
        switch result {
        case .done:
            password = ""
            session.refresh()
        case .twoFactor(let identifier, let hintText):
            twoFactorID = identifier; hint = hintText; code = ""; step = .twoFactor
        case .checkpoint(let path, _):
            challengePath = path
            try await InstagramAPI.shared.requestEmailCode(challengePath: path)
            hint = "Instagram te envió un código por correo. Escríbelo aquí."
            code = ""; step = .email
        }
    }

    private func reset() {
        step = .credentials; code = ""; error = nil; focus = nil
    }
}
