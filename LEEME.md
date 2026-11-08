<img src="assets/logo-512.png" width="120" alt="Logo de Mejor">

# Mejor: Instagram sin distracciones (iOS 15+)

Esta app tiene solo tres pestañas:

| Pestaña | Qué muestra |
|---|---|
| **Mensajes** | Tu bandeja de DMs. Los reels que te mandan se ven ahí mismo. |
| **Historias** | Solo la fila de historias. Las publicaciones del feed quedan ocultas. |
| **Buscar** | El buscador de cuentas, sin la cuadrícula de Explorar. |

El feed de Reels y Explorar están bloqueados: si llegas a ellos, la app te redirige.

## Cómo funciona

La app carga la versión web oficial de Instagram (instagram.com) dentro de la app y le oculta lo que no quieres ver.
Inicias sesión en la página de Instagram, igual que en Safari. La app no guarda ni ve tu contraseña.
No usa la API privada de Instagram, así que el riesgo de bloqueo de cuenta es mucho menor que con las apps "clon".

Hay un límite: si Instagram cambia el diseño de su web, puede que algún filtro deje de ocultar algo y haya que ajustar `MerJo/FocusFilter.swift`.

## 1. Conseguir el .ipa (sin Mac)

Las apps de iPhone solo se compilan en macOS. Por eso el proyecto se compila gratis en una Mac de GitHub:

1. Sube esta carpeta a un repositorio de GitHub (rama `main`).
2. En el repositorio, entra a **Actions** → **Compilar IPA**. Se ejecuta solo con cada cambio (o con **Run workflow**).
3. Cuando termine (unos 5 minutos), descarga **Mejor-ipa** al final de la página de esa ejecución. Dentro del .zip viene `Mejor.ipa`.

## 2. Instalarlo en el iPhone

**Con TrollStore (lo más fácil):** pasa `Mejor.ipa` al iPhone (AirDrop, Archivos o iCloud), ábrelo con TrollStore y toca Instalar. Queda instalada de forma permanente, sin renovar cada 7 días.

**Sin TrollStore:** el .ipa sale **sin firmar**, así que se instala con una herramienta que lo firma con tu Apple ID:

- **Sideloadly** (Windows): conecta el iPhone por cable, arrastra `Mejor.ipa`, pon tu Apple ID y dale a Start.
- **AltStore**: también funciona desde Windows.

Con un Apple ID gratuito la app dura **7 días**; después hay que volver a instalarla (Sideloadly puede renovarla sola). Con una cuenta de desarrollador pagada dura un año.
En el iPhone, después de instalar: **Ajustes → General → VPN y gestión de dispositivos** → confía en tu Apple ID. En iOS 16 o superior activa también **Modo desarrollador** (Ajustes → Privacidad y seguridad).

## Archivos

- `MerJo/MerJoApp.swift`: pestañas de la app.
- `MerJo/InstagramWebView.swift`: el navegador interno (sesión compartida, deslizar para recargar, enlaces externos van a Safari).
- `MerJo/FocusFilter.swift`: qué se oculta y qué se bloquea.
- `project.yml`: definición del proyecto (XcodeGen genera el proyecto de Xcode a partir de esto).
- `.github/workflows/build-ipa.yml`: la compilación automática.
