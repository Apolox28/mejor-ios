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

    /// Se inyecta en cada página. Instagram es una SPA, así que además de las
    /// cargas completas vigilamos los cambios de ruta internos.
    static let script = #"""
    (function () {
      if (window.__merjoLoaded) return;
      window.__merjoLoaded = true;

      var CSS = [
        /* Inicio: se ocultan las publicaciones; queda solo la fila de historias */
        'html[data-dp="home"] main article { display: none !important; }',
        'html[data-dp="home"] main [role="progressbar"] { display: none !important; }',
        /* Búsqueda: se oculta la cuadrícula de publicaciones sugeridas */
        'html[data-dp="search"] main a[href^="/p/"],',
        'html[data-dp="search"] main a[href^="/reel/"] { display: none !important; }',
        /* Accesos a feed, explorar y reels en la barra de Instagram */
        'a[href="/explore/"], a[href="/reels/"] { display: none !important; }',
        'nav a[href="/"], [role="navigation"] a[href="/"] { display: none !important; }',
        /* Carteles de "abrir en la app" */
        'a[href*="itunes.apple.com"], a[href*="apps.apple.com"] { display: none !important; }'
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

      var last = null;
      function check() {
        var path = location.pathname.toLowerCase();
        var to = blocked(path);
        if (to) { location.replace(to); return; }
        if (path !== last) {
          last = path;
          document.documentElement.setAttribute('data-dp', kind(path));
        }
        addStyle();
        hideIcons();
      }

      /* Oculta botones por su etiqueta accesible (Home / Inicio, Explore, Reels). */
      var LABELS = ['Home', 'Inicio', 'Explore', 'Explorar', 'Reels'];
      function hideIcons() {
        var svgs = document.querySelectorAll('nav svg[aria-label], [role="navigation"] svg[aria-label]');
        for (var i = 0; i < svgs.length; i++) {
          if (LABELS.indexOf(svgs[i].getAttribute('aria-label')) !== -1) {
            var a = svgs[i].closest('a') || svgs[i].parentElement;
            if (a) a.style.setProperty('display', 'none', 'important');
          }
        }
      }

      ['pushState', 'replaceState'].forEach(function (fn) {
        var orig = history[fn];
        history[fn] = function () {
          var r = orig.apply(this, arguments);
          setTimeout(check, 0);
          return r;
        };
      });
      window.addEventListener('popstate', check);
      document.addEventListener('DOMContentLoaded', function () {
        check();
        new MutationObserver(function () { hideIcons(); addStyle(); })
          .observe(document.body, { childList: true, subtree: true });
      });
      setInterval(check, 700);
      check();
    })();
    """#
}
