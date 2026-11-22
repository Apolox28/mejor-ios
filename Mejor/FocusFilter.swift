import Foundation

/// Limpia la página de inicio de sesión de Instagram (carteles de "abrir la app", avisos).
enum FocusFilter {
    /// Partes comunes: ocultar carteles de "abrir la app" y cerrar avisos molestos.
    private static let common = #"""
      var APP_TEXT = /^(open app|open the app|use the app|get the app|open instagram|abrir app|abrir la app|usar la app|obtener la app|descargar la app|abrir instagram|switch to the app|cambiar a la app)$/i;
      var NOT_NOW = /^(not now|ahora no|cancel|cancelar)$/i;

      function fixedAncestor(el, maxDepth) {
        var node = el;
        for (var i = 0; node && node !== document.body && i < maxDepth; i++) {
          var pos = getComputedStyle(node).position;
          if (pos === 'fixed' || pos === 'sticky') return node;
          node = node.parentElement;
        }
        return null;
      }

      function hide(el) {
        if (el && el.style) el.style.setProperty('display', 'none', 'important');
      }

      function hideAppBanners() {
        var els = document.querySelectorAll('a, button, div[role="button"], span');
        for (var i = 0; i < els.length; i++) {
          var t = (els[i].textContent || '').trim();
          if (t.length > 30 || !APP_TEXT.test(t)) continue;
          var bar = fixedAncestor(els[i], 8);
          hide(bar || els[i].closest('a, button, div[role="button"]') || els[i]);
        }
        var store = document.querySelectorAll('a[href*="apps.apple.com"], a[href*="itunes.apple.com"], a[href^="instagram://"]');
        for (var j = 0; j < store.length; j++) hide(store[j]);
      }

      /* Avisos como "Activar notificaciones" o "Agregar a inicio": se pulsa "Ahora no". */
      function dismissNags() {
        var dialogs = document.querySelectorAll('[role="dialog"]');
        for (var i = 0; i < dialogs.length; i++) {
          var txt = (dialogs[i].textContent || '').toLowerCase();
          var isNag = /notific|home screen|pantalla de inicio|app de instagram|instagram app|get the app|obtener la app/.test(txt);
          if (!isNag) continue;
          var buttons = dialogs[i].querySelectorAll('button, div[role="button"]');
          for (var b = 0; b < buttons.length; b++) {
            if (NOT_NOW.test((buttons[b].textContent || '').trim())) { buttons[b].click(); break; }
          }
        }
      }

      var scheduled = false;
      function schedule(fn) {
        if (scheduled) return;
        scheduled = true;
        requestAnimationFrame(function () { scheduled = false; fn(); });
      }
    """#

    /// Para la pantalla de inicio de sesión: solo se limpian los carteles.
    static let loginScript = "(function(){ if (window.__merjoLogin) return; window.__merjoLogin = true;\n"
        + common
        + #"""
      function sweep() { hideAppBanners(); dismissNags(); }
      document.addEventListener('DOMContentLoaded', function () {
        sweep();
        new MutationObserver(function () { schedule(sweep); })
          .observe(document.body, { childList: true, subtree: true });
      });
    })();
    """#
}
