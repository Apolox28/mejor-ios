import Foundation

/// Reglas que dejan solo mensajes, historias, reels que te envían y búsqueda.
enum FocusFilter {

    /// Rutas que nunca se muestran y a dónde se redirigen.
    static func redirect(for url: URL) -> URL? {
        let path = url.path.lowercased()
        // Feed infinito de Reels (los reels sueltos que te mandan usan /reel/ID y sí se ven).
        if path == "/reels" || path == "/reels/" {
            return URL(string: "https://www.instagram.com/direct/inbox/")
        }
        // Cuadrícula de Explorar: se cambia por la búsqueda.
        if path == "/explore" || path == "/explore/" {
            return URL(string: "https://www.instagram.com/explore/search/")
        }
        return nil
    }

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

    /// Se inyecta en las tres pestañas. Instagram es una SPA, así que además de las
    /// cargas completas vigilamos los cambios de ruta internos.
    static let script = "(function(){ if (window.__merjoLoaded) return; window.__merjoLoaded = true;\n"
        + common
        + #"""
      var CSS = [
        /* Inicio: se ocultan las publicaciones; queda solo la fila de historias */
        'html[data-mj="home"] main article { display: none !important; }',
        'html[data-mj="home"] main [role="progressbar"] { display: none !important; }',
        'html[data-mj="home"] main { min-height: 0 !important; }',
        /* Búsqueda: sin cuadrícula de publicaciones sugeridas */
        'html[data-mj="search"] main a[href^="/p/"],',
        'html[data-mj="search"] main a[href^="/reel/"] { display: none !important; }',
        /* Sin resaltado gris al tocar */
        '* { -webkit-tap-highlight-color: transparent; }'
      ].join('\n');

      function addStyle() {
        if (document.getElementById('merjo-style')) return;
        var s = document.createElement('style');
        s.id = 'merjo-style';
        s.textContent = CSS;
        (document.head || document.documentElement).appendChild(s);
      }

      function kind(path) {
        if (path === '/' || path === '') return 'home';
        if (path.indexOf('/explore/search') === 0) return 'search';
        if (path.indexOf('/direct') === 0) return 'direct';
        if (path.indexOf('/stories') === 0) return 'story';
        return 'other';
      }

      function blocked(path) {
        if (path === '/reels' || path === '/reels/') return '/direct/inbox/';
        if (path === '/explore' || path === '/explore/') return '/explore/search/';
        return null;
      }

      /* La barra inferior de Instagram (Inicio, Explorar, Reels...) se oculta entera:
         MerJo ya tiene su propia barra con Mensajes, Historias y Buscar. */
      function hideInstagramTabBar() {
        var links = document.querySelectorAll('a[href="/explore/"], a[href="/reels/"], a[href^="/reels/"]');
        for (var i = 0; i < links.length; i++) {
          var bar = fixedAncestor(links[i], 10);
          if (bar) {
            var r = bar.getBoundingClientRect();
            if (r.top > window.innerHeight * 0.5) { hide(bar); continue; }
          }
          hide(links[i]);
        }
        /* Botones del menú por su nombre accesible */
        var svgs = document.querySelectorAll('svg[aria-label]');
        for (var j = 0; j < svgs.length; j++) {
          var label = svgs[j].getAttribute('aria-label');
          if (label === 'Explore' || label === 'Explorar' || label === 'Reels') {
            hide(svgs[j].closest('a') || svgs[j].parentElement);
          }
        }
      }

      var last = null;
      function check() {
        var path = location.pathname.toLowerCase();
        var to = blocked(path);
        if (to) { location.replace(to); return; }
        if (path !== last) {
          last = path;
          document.documentElement.setAttribute('data-mj', kind(path));
        }
        addStyle();
      }

      function sweep() {
        check();
        hideInstagramTabBar();
        hideAppBanners();
        dismissNags();
      }

      ['pushState', 'replaceState'].forEach(function (fn) {
        var orig = history[fn];
        history[fn] = function () {
          var r = orig.apply(this, arguments);
          setTimeout(sweep, 0);
          return r;
        };
      });
      window.addEventListener('popstate', sweep);
      document.addEventListener('DOMContentLoaded', function () {
        sweep();
        new MutationObserver(function () { schedule(sweep); })
          .observe(document.body, { childList: true, subtree: true });
      });
      setInterval(check, 800);
      check();
    })();
    """#
}
