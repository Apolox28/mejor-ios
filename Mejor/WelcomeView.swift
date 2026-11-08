import SwiftUI

struct SplashView: View {
    var body: some View {
        ZStack {
            Brand.background.ignoresSafeArea()
            LogoImage(size: 110)
        }
    }
}

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

struct WelcomeView: View {
    @EnvironmentObject private var session: Session
    @State private var showLogin = false

    var body: some View {
        ZStack {
            Brand.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                LogoImage(size: 112)

                Text("Mejor")
                    .font(.system(size: 42, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.top, 22)

                Text("Instagram sin el feed infinito")
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 18) {
                    FeatureRow(icon: "paperplane.fill", title: "Mensajes",
                               detail: "Tus chats y los reels que te mandan")
                    FeatureRow(icon: "circle.dashed", title: "Historias",
                               detail: "Solo las historias, sin publicaciones")
                    FeatureRow(icon: "magnifyingglass", title: "Buscar",
                               detail: "Encuentra cuentas sin la cuadrícula de Explorar")
                }
                .padding(.top, 40)

                Spacer(minLength: 24)

                Button {
                    showLogin = true
                } label: {
                    Text("Iniciar sesión con Instagram")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundColor(Brand.night)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(Brand.ring)
                        .clipShape(Capsule())
                }

                Text("Entras en la página oficial de Instagram. Mejor no ve ni guarda tu contraseña.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.top, 14)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showLogin) {
            LoginSheet()
                .environmentObject(session)
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                Text(detail)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
        }
    }
}

struct LoginSheet: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var reloadToken = 0

    private let loginURL = URL(string: "https://www.instagram.com/accounts/login/")!

    var body: some View {
        NavigationView {
            WebScreen(startURL: loginURL, section: nil, resetToken: reloadToken) { url in
                // Si la web ya salió del login, la sesión está iniciada.
                let path = url.path.lowercased()
                if path.hasPrefix("/accounts/onetap") {
                    // Esta pantalla ("¿Guardar tu información?") solo sale tras entrar bien.
                    session.markLoggedIn()
                } else if !path.hasPrefix("/accounts/login") {
                    session.refresh()
                }
            }
            .navigationTitle("Iniciar sesión")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            reloadToken += 1
                        } label: {
                            Label("Recargar", systemImage: "arrow.clockwise")
                        }
                        Button(role: .destructive) {
                            session.signOut()
                            reloadToken += 1
                        } label: {
                            Label("Borrar datos y reintentar", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .accentColor(Brand.accent)
    }
}
