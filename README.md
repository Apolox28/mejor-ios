<p align="center">
  <img src="assets/logo-512.png" width="140" alt="Ícono de Mejor: un faro iluminando el mar de noche">
</p>

<h1 align="center">Mejor</h1>

<p align="center"><b>Instagram solo con lo que importa: mensajes, historias, búsqueda y tu perfil.</b><br>Sin feed infinito, sin Reels, sin Explorar. Para iPhone con iOS 15 o superior.</p>

<p align="center">
  <a href="https://github.com/Apolox28/mejor-ios/releases/latest/download/Mejor.ipa">
    <img src="assets/boton-descargar.png" alt="Toca aquí para descargar Mejor.ipa" width="320">
  </a>
  <br>
  <sub><a href="https://github.com/Apolox28/mejor-ios/releases/latest">Ver novedades de la última versión</a></sub>
</p>

---

## ✨ Qué incluye

| | |
|---|---|
| ✉️ **Mensajes** | Tus chats y los reels que te mandan |
| ⭕ **Historias** | Solo las historias, a pantalla completa, sin publicaciones |
| 🔍 **Buscar** | Encuentra cuentas sin la cuadrícula de Explorar |
| 👤 **Perfil** | Tu perfil, detectado automáticamente |

El feed de Reels y Explorar están bloqueados: si llegas a ellos, la app te redirige.

## 📲 Instalar

**Con TrollStore (recomendado)**
1. Toca el botón dorado de arriba desde **Safari** en tu iPhone.
2. Abre **Archivos → Descargas**.
3. Mantén presionado **Mejor.ipa** → **Compartir** → **TrollStore** → **Instalar**.

Queda instalada para siempre. Las versiones nuevas se instalan encima y mantienen tu sesión.

**Sin TrollStore:** instala `Mejor.ipa` con **Sideloadly** o **AltStore** usando tu Apple ID. Con una cuenta gratuita dura 7 días y hay que renovarla.

## 🔒 Privacidad

Inicias sesión en la página oficial de Instagram dentro de la app. Mejor no ve ni guarda tu contraseña y no usa la API privada de Instagram, así que el riesgo para tu cuenta es mucho menor que con apps modificadas.
La primera vez Instagram puede pedirte un código de verificación: es normal en un dispositivo nuevo.

---

<details>
<summary><b>Para desarrolladores</b></summary>

Las apps de iPhone solo se compilan en macOS, así que el `.ipa` se compila en una Mac de GitHub Actions con cada cambio en `main` (**Actions → Compilar IPA**).

- `Mejor/MejorApp.swift`: pestañas, sesión y barra inferior.
- `Mejor/WelcomeView.swift`: bienvenida e inicio de sesión.
- `Mejor/InstagramWebView.swift`: el navegador interno.
- `Mejor/FocusFilter.swift`: qué se oculta y qué se bloquea. Si Instagram cambia su web, aquí se ajusta.
- `project.yml`: definición del proyecto para XcodeGen.
- `.github/workflows/build-ipa.yml`: la compilación automática.

</details>
