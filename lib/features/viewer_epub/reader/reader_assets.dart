/// Reader stylesheet and script injected into every book document.
///
/// Both are inlined into the document's head (no extra requests before the
/// first layout). The script reads `window.__ER_CONFIG__` (set per load
/// right before it) and talks to Flutter through the `er` JavaScript
/// handler with `(type, jsonPayload)`. Neither may contain `]]>` or
/// `</script`/`</style` (they sit in CDATA in XHTML and raw text in HTML).
library;

const String kReaderCss = r'''
html:not(.er-ready) body {
  visibility: hidden;
  -webkit-animation: er-reveal 0s linear 4s forwards;
  animation: er-reveal 0s linear 4s forwards;
}
@-webkit-keyframes er-reveal { to { visibility: visible; } }
@keyframes er-reveal { to { visibility: visible; } }

html {
  -webkit-text-size-adjust: 100% !important;
  text-size-adjust: 100% !important;
  scroll-behavior: auto !important;
  -webkit-tap-highlight-color: transparent;
}
html[data-er-theme] {
  background-color: var(--er-bg) !important;
  background-image: none !important;
  color: var(--er-fg);
}
html[data-er-theme] body {
  background-color: transparent !important;
  background-image: none !important;
}
html[data-er-theme="sepia"] body,
html[data-er-theme="dark"] body,
html[data-er-theme="black"] body {
  color: var(--er-fg) !important;
}
html[data-er-theme="sepia"] body *,
html[data-er-theme="dark"] body *,
html[data-er-theme="black"] body * {
  color: inherit !important;
  background-color: transparent !important;
  border-color: var(--er-rule) !important;
}
html[data-er-theme="sepia"] body a:link, html[data-er-theme="sepia"] body a:visited,
html[data-er-theme="sepia"] body a:link *, html[data-er-theme="sepia"] body a:visited *,
html[data-er-theme="dark"] body a:link, html[data-er-theme="dark"] body a:visited,
html[data-er-theme="dark"] body a:link *, html[data-er-theme="dark"] body a:visited *,
html[data-er-theme="black"] body a:link, html[data-er-theme="black"] body a:visited,
html[data-er-theme="black"] body a:link *, html[data-er-theme="black"] body a:visited * {
  color: var(--er-link) !important;
}
html[data-er-font] body,
html[data-er-font] body *:not(code):not(pre):not(kbd):not(samp):not(tt):not(var) {
  font-family: var(--er-font-family) !important;
}
html[data-er-dyslexic] body {
  letter-spacing: 0.035em !important;
  word-spacing: 0.14em !important;
}
html[data-er-lh] body, html[data-er-lh] body p, html[data-er-lh] body li,
html[data-er-lh] body div, html[data-er-lh] body blockquote,
html[data-er-lh] body dd, html[data-er-lh] body dt, html[data-er-lh] body td {
  line-height: var(--er-line-height) !important;
}
html[data-er-align="justify"] body p, html[data-er-align="justify"] body li,
html[data-er-align="justify"] body dd, html[data-er-align="justify"] body blockquote {
  text-align: justify !important;
  -webkit-hyphens: auto !important;
  hyphens: auto !important;
}
html[data-er-align="left"] body p, html[data-er-align="left"] body li,
html[data-er-align="left"] body dd, html[data-er-align="left"] body blockquote {
  text-align: start !important;
  -webkit-hyphens: manual !important;
  hyphens: manual !important;
}

html.er-paginated img, html.er-paginated svg, html.er-paginated video,
html.er-paginated canvas, html.er-paginated iframe, html.er-paginated object,
html.er-paginated embed {
  max-width: 100% !important;
  max-height: var(--er-colh) !important;
  box-sizing: border-box;
  -webkit-column-break-inside: avoid;
  break-inside: avoid;
  page-break-inside: avoid;
}
html.er-paginated img { height: auto; object-fit: contain; }
/* Fixed-width containers (style="width: 550px") must not spill into the
   next column/page. */
html.er-paginated body div, html.er-scrolled body div,
html.er-paginated body p, html.er-scrolled body p,
html.er-paginated body figure, html.er-scrolled body figure,
html.er-paginated body section, html.er-scrolled body section,
html.er-paginated body article, html.er-scrolled body article,
html.er-paginated body aside, html.er-scrolled body aside,
html.er-paginated body header, html.er-scrolled body header,
html.er-paginated body footer, html.er-scrolled body footer,
html.er-paginated body nav, html.er-scrolled body nav,
html.er-paginated body blockquote, html.er-scrolled body blockquote,
html.er-paginated body table, html.er-scrolled body table,
html.er-paginated body ul, html.er-scrolled body ul,
html.er-paginated body ol, html.er-scrolled body ol,
html.er-paginated body dl, html.er-scrolled body dl,
html.er-paginated body pre, html.er-scrolled body pre,
html.er-paginated body hr, html.er-scrolled body hr,
html.er-paginated body h1, html.er-scrolled body h1,
html.er-paginated body h2, html.er-scrolled body h2,
html.er-paginated body h3, html.er-scrolled body h3,
html.er-paginated body h4, html.er-scrolled body h4,
html.er-paginated body h5, html.er-scrolled body h5,
html.er-paginated body h6, html.er-scrolled body h6 {
  max-width: 100% !important;
}
html.er-scrolled img, html.er-scrolled svg, html.er-scrolled video {
  max-width: 100% !important;
  box-sizing: border-box;
}
html.er-scrolled img { height: auto; }
html.er-paginated table, html.er-scrolled table { max-width: 100%; }
html.er-paginated pre, html.er-scrolled pre {
  white-space: pre-wrap !important;
  overflow-wrap: break-word !important;
  word-wrap: break-word !important;
}
html.er-paginated body { overflow-wrap: break-word; }
html.er-paginated h1, html.er-paginated h2, html.er-paginated h3,
html.er-paginated h4, html.er-paginated h5, html.er-paginated h6 {
  -webkit-column-break-after: avoid;
  break-after: avoid;
}

::highlight(er-search) { background-color: rgba(255, 196, 0, 0.55); color: inherit; }
mark.er-mark {
  background-color: rgba(255, 196, 0, 0.55) !important;
  color: inherit !important;
  padding: 0 !important;
}

.er-filler {
  display: block !important; height: 1px !important; margin: 0 !important;
  padding: 0 !important; border: 0 !important; visibility: hidden !important;
  float: none !important; position: static !important;
  -webkit-column-break-before: always !important; break-before: column !important;
}
html.er-scrolled .er-filler { display: none !important; }
#er-sentinel {
  display: block !important; height: 0 !important; margin: 0 !important;
  padding: 0 !important; border: 0 !important; overflow: hidden !important;
  visibility: hidden !important; float: none !important; position: static !important;
}
.er-chapter-nav {
  display: block !important; text-align: center !important; text-indent: 0 !important;
  margin: 1.5em 0 !important; padding: 0 !important;
}
.er-chapter-nav button {
  font: inherit; font-size: 0.95em; cursor: pointer;
  color: var(--er-link, #1a5fb4) !important; background: transparent !important;
  border: 1px solid currentColor !important; border-radius: 999px;
  padding: 0.55em 1.4em;
}
.er-image-doc { margin: 0; }
.er-image-page { text-align: center; text-indent: 0; }
.er-image-page img { max-width: 100%; max-height: var(--er-colh, 95vh); object-fit: contain; }
''';

const String kReaderJs = r'''
(function () {
  'use strict';
  if (window.ER) return;
  try { if (window.top && window.top !== window) return; } catch (e) { return; }

  var cfg = window.__ER_CONFIG__ || {};
  var doc = document;
  var root = doc.documentElement;
  var settings = cfg.settings || {};
  var hinge = cfg.hinge || null;
  var loadId = cfg.loadId || 0;
  var fixed = !!cfg.fixed;
  var WS = /[\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]/;

  var st = {
    page: 0, pages: 1, W: 1, H: 1, rtl: false, textDir: 'ltr', vertical: false,
    paginated: true, cols: 1, padL: 0, padR: 0, padT: 20, padB: 24, colH: 1,
    ready: false, inited: false, anchor: null, stickEnd: false,
    pending: cfg.target || null, focusRange: null, selAtStart: false,
    lastSwipe: 0, progScroll: 0, sig: '', baseRootPx: 0, baseBodyPx: 0,
    sentinel: null, anchorTimer: 0, snapTimer: 0
  };

  // ------------------------------------------------------------ bridge
  var queue = [];
  function bridge() {
    var b = window.flutter_inappwebview;
    return (b && typeof b.callHandler === 'function') ? b : null;
  }
  function send(type, payload) {
    var b = bridge();
    if (!b) { queue.push([type, payload]); return; }
    try { b.callHandler('er', type, payload); } catch (e) {}
  }
  function post(type, data) {
    data = data || {};
    data.loadId = loadId;
    send(type, JSON.stringify(data));
  }
  function flush() {
    if (!bridge()) return;
    var q = queue; queue = [];
    for (var i = 0; i < q.length; i++) send(q[i][0], q[i][1]);
  }
  window.addEventListener('flutterInAppWebViewPlatformReady', flush);
  var flushTries = 0;
  var flushTimer = setInterval(function () {
    flushTries++;
    if (queue.length && bridge()) flush();
    if (flushTries > 150 || (st.ready && !queue.length && bridge())) clearInterval(flushTimer);
  }, 100);
  window.addEventListener('error', function (e) {
    post('log', { message: String(e && e.message), source: String(e && e.filename) });
  });

  // ----------------------------------------------------------- helpers
  function px(v) { return v + 'px'; }
  function clamp(v, a, b) { return Math.max(a, Math.min(b, v)); }
  function body() { return doc.body || root; }
  function setImp(el, prop, val) {
    if (!el || !el.style) return;
    if (val === null || val === undefined) el.style.removeProperty(prop);
    else el.style.setProperty(prop, String(val), 'important');
  }
  function css(el) { return window.getComputedStyle(el); }
  function hasSelection() {
    var s = window.getSelection ? window.getSelection() : null;
    return !!(s && !s.isCollapsed && String(s).length > 0);
  }
  function docHeight() {
    return Math.max(root.scrollHeight, body().scrollHeight || 0);
  }
  function maxScrollY() { return Math.max(0, docHeight() - st.H); }
  function scrollToXY(x, y, smooth) {
    st.progScroll = Date.now();
    try { window.scrollTo({ left: x, top: y, behavior: smooth ? 'smooth' : 'auto' }); }
    catch (e) { window.scrollTo(x, y); }
  }

  // ----------------------------------------------------- theme/settings
  function captureBaseFont() {
    setImp(root, 'font-size', null);
    setImp(body(), 'font-size', null);
    st.baseRootPx = parseFloat(css(root).fontSize) || 16;
    st.baseBodyPx = parseFloat(css(body()).fontSize) || st.baseRootPx;
  }
  function applyTheme() {
    var s = settings;
    if (fixed) {
      root.removeAttribute('data-er-theme');
      setImp(root, 'background-color', s.bg || '#fff');
      return;
    }
    root.setAttribute('data-er-theme', s.theme || 'light');
    root.style.setProperty('--er-bg', s.bg || '#ffffff');
    root.style.setProperty('--er-fg', s.fg || '#1f1f1f');
    root.style.setProperty('--er-link', s.link || '#1a5fb4');
    root.style.setProperty('--er-rule', s.rule || 'rgba(128,128,128,0.4)');
    if (s.fontFamily) {
      root.setAttribute('data-er-font', s.font || 'custom');
      root.style.setProperty('--er-font-family', s.fontFamily);
    } else {
      root.removeAttribute('data-er-font');
    }
    if (s.font === 'dyslexic') root.setAttribute('data-er-dyslexic', '1');
    else root.removeAttribute('data-er-dyslexic');
    if (s.lineHeight) {
      root.setAttribute('data-er-lh', '1');
      root.style.setProperty('--er-line-height', String(s.lineHeight));
    } else {
      root.removeAttribute('data-er-lh');
    }
    if (s.align && s.align !== 'publisher') root.setAttribute('data-er-align', s.align);
    else root.removeAttribute('data-er-align');

    var scale = +s.fontScale || 1;
    if (Math.abs(scale - 1) < 0.001) {
      setImp(root, 'font-size', null);
      setImp(body(), 'font-size', null);
    } else {
      setImp(root, 'font-size', px(st.baseRootPx * scale));
      setImp(body(), 'font-size', null);
      var now = parseFloat(css(body()).fontSize) || 0;
      // Body sized in absolute units ignores the root size: scale it too.
      if (Math.abs(now - st.baseBodyPx) < 0.01) {
        setImp(body(), 'font-size', px(st.baseBodyPx * scale));
      }
    }
  }

  // ------------------------------------------------------------ layout
  function detectDirection() {
    var b = body();
    var bs = css(b);
    var wm = bs.writingMode || bs.webkitWritingMode || '';
    st.vertical = /^(vertical|sideways|tb)/.test(wm);
    st.textDir = bs.direction || 'ltr';
    st.rtl = cfg.dir === 'rtl' ? true : cfg.dir === 'ltr' ? false : st.textDir === 'rtl';
  }

  function measureViewport() {
    st.W = Math.max(1, Math.floor(window.innerWidth || root.clientWidth || 1));
    st.H = Math.max(1, Math.floor(window.innerHeight || root.clientHeight || 1));
  }

  function chapterNav() {
    var old = doc.querySelectorAll('.er-chapter-nav');
    for (var i = 0; i < old.length; i++) old[i].parentNode.removeChild(old[i]);
    if (st.paginated || fixed || st.vertical) return;
    var b = body();
    function mk(action, label) {
      var d = doc.createElement('div');
      d.className = 'er-ui er-chapter-nav';
      var btn = doc.createElement('button');
      btn.setAttribute('type', 'button');
      btn.setAttribute('data-er-action', action);
      btn.textContent = label;
      d.appendChild(btn);
      return d;
    }
    if (cfg.hasPrev) b.insertBefore(mk('prev', '\u2190 Previous chapter'), b.firstChild);
    if (cfg.hasNext) b.appendChild(mk('next', 'Next chapter \u2192'));
  }

  // The sentinel marks the end of the flow. Two filler columns after it
  // make sure the scroll range reaches the last page: Chrome leaves the
  // root's inline-end padding out of the multicol scrollable overflow.
  function ensureSentinel() {
    var b = body();
    function el(id, cls) {
      var e = doc.getElementById(id);
      if (!e) {
        e = doc.createElement('div');
        e.id = id;
        e.className = cls;
        e.setAttribute('aria-hidden', 'true');
      }
      b.appendChild(e);
      return e;
    }
    st.sentinel = el('er-sentinel', 'er-ui');
    el('er-filler-1', 'er-ui er-filler');
    el('er-filler-2', 'er-ui er-filler');
  }

  function fixSvg() {
    var svgs = doc.getElementsByTagNameNS('http://www.w3.org/2000/svg', 'svg');
    for (var i = 0; i < svgs.length; i++) {
      var svg = svgs[i];
      if (svg.parentNode && svg.parentNode.namespaceURI === 'http://www.w3.org/2000/svg') continue;
      var h = svg.getAttribute('height');
      if (h && /%\s*$/.test(h)) {
        setImp(svg, 'height', px(st.paginated ? st.colH : Math.round(st.H * 0.92)));
        setImp(svg, 'width', '100%');
      }
    }
  }

  function layoutFixed() {
    var b = body();
    var meta = doc.querySelector('meta[name="viewport"]');
    var vw = 0, vh = 0;
    if (meta) {
      var c = meta.getAttribute('content') || '';
      var mw = /width\s*=\s*([\d.]+)/.exec(c), mh = /height\s*=\s*([\d.]+)/.exec(c);
      if (mw) vw = +mw[1];
      if (mh) vh = +mh[1];
    }
    if (!vw || !vh) {
      var img = b.querySelector('img');
      if (img && img.naturalWidth) { vw = img.naturalWidth; vh = img.naturalHeight; }
    }
    setImp(root, 'overflow', 'hidden');
    setImp(root, 'margin', '0');
    setImp(root, 'padding', '0');
    setImp(root, 'width', px(st.W));
    setImp(root, 'height', px(st.H));
    if (vw && vh) {
      var s = Math.min(st.W / vw, st.H / vh);
      setImp(b, 'width', px(vw));
      setImp(b, 'height', px(vh));
      setImp(b, 'margin', '0');
      setImp(b, 'overflow', 'hidden');
      setImp(b, 'transform-origin', '0 0');
      setImp(b, 'transform', 'translate(' + px((st.W - vw * s) / 2) + ',' +
        px((st.H - vh * s) / 2) + ') scale(' + s + ')');
    } else {
      setImp(b, 'margin', '0');
      root.style.setProperty('--er-colh', px(st.H));
    }
    st.pages = 1;
    st.page = 0;
  }

  function layout() {
    if (!doc.body) return;
    measureViewport();
    var s = settings, W = st.W, H = st.H, b = body();
    if (fixed) { layoutFixed(); return; }
    st.paginated = s.paginated !== false && !st.vertical;
    root.classList.toggle('er-paginated', st.paginated);
    root.classList.toggle('er-scrolled', !st.paginated);
    if (st.vertical) { st.pages = 1; return; }

    var margin = clamp(+s.margin || 0, 0, 200);
    st.padT = 20;
    st.padB = 24;
    setImp(root, 'direction', st.rtl ? 'rtl' : 'ltr');
    setImp(b, 'direction', st.textDir);
    setImp(b, 'margin', '0');
    setImp(b, 'padding', '0');
    setImp(b, 'height', 'auto');
    setImp(b, 'min-height', '0');
    setImp(b, 'max-height', 'none');
    setImp(b, 'width', 'auto');
    setImp(b, 'min-width', '0');
    setImp(b, 'overflow', 'visible');
    setImp(b, 'column-count', 'auto');
    setImp(b, 'column-width', 'auto');
    setImp(root, 'margin', '0');
    setImp(root, 'min-height', '0');
    setImp(root, 'box-sizing', 'border-box');

    var fontPx = parseFloat(css(b).fontSize) || 16;
    chapterNav();
    if (st.paginated) {
      var cols = (s.spreads !== false && (hinge || W >= 840 || (W >= 600 && W > H * 1.05))) ? 2 : 1;
      var maxCol = Math.max(280, fontPx * 38);
      var m = margin;
      if (W / cols - 2 * m > maxCol) m = (W / cols - maxCol) / 2;
      var padL = m, padR = m;
      if (hinge && cols === 2) {
        var need = (+hinge.width || 0) + 32;
        if (2 * m < need) m = need / 2;
        var d = (+hinge.x + (+hinge.width || 0) / 2) - W / 2;
        padL = m + d; padR = m - d;
        if (padL < 8 || padR < 8) { padL = m; padR = m; }
      }
      padL = Math.max(0, Math.round(padL));
      padR = Math.max(0, Math.round(padR));
      var gap = padL + padR;
      st.cols = cols; st.padL = padL; st.padR = padR;
      st.colH = Math.max(40, H - st.padT - st.padB);
      setImp(root, 'width', px(W));
      setImp(root, 'height', px(H));
      setImp(root, 'max-width', 'none');
      setImp(root, 'max-height', 'none');
      setImp(root, 'padding', px(st.padT) + ' ' + px(padR) + ' ' + px(st.padB) + ' ' + px(padL));
      setImp(root, 'overflow', 'hidden');
      setImp(root, 'column-width', 'auto');
      setImp(root, 'column-count', String(cols));
      setImp(root, 'column-gap', px(gap));
      setImp(root, 'column-fill', 'auto');
      setImp(root, 'column-rule', 'none');
      setImp(b, 'max-width', 'none');
      root.style.setProperty('--er-colh', px(st.colH));
    } else {
      var maxW = Math.max(320, fontPx * 40);
      var side = Math.round(Math.max(margin, (W - maxW) / 2));
      st.cols = 1; st.padL = side; st.padR = side;
      st.colH = H - 40;
      setImp(root, 'width', 'auto');
      setImp(root, 'height', 'auto');
      setImp(root, 'max-height', 'none');
      setImp(root, 'overflow', null);
      setImp(root, 'overflow-x', 'hidden');
      setImp(root, 'overflow-y', 'auto');
      setImp(root, 'padding', px(st.padT) + ' ' + px(side) + ' ' + px(st.padB + 24) + ' ' + px(side));
      setImp(root, 'column-count', 'auto');
      setImp(root, 'column-width', 'auto');
      setImp(root, 'column-gap', 'normal');
      root.style.setProperty('--er-colh', px(Math.round(H * 0.92)));
    }
    fixSvg();
    ensureSentinel();
    void root.offsetHeight;
    computePages();
    st.sig = signature();
  }

  function signature() {
    return [st.W, st.H, root.scrollWidth, root.scrollHeight].join(':');
  }

  function lastContentRect() {
    var n = body().lastChild;
    var guard = 0;
    while (n && guard++ < 5000) {
      if (n.nodeType === 3 && /\S/.test(n.data)) {
        var r = doc.createRange();
        r.selectNodeContents(n);
        var rects = r.getClientRects();
        if (rects.length) return rects[rects.length - 1];
      } else if (n.nodeType === 1 && !(n.classList && n.classList.contains('er-ui'))) {
        var name = (n.localName || '').toLowerCase();
        if (name !== 'script' && name !== 'style') {
          if (n.lastChild && name !== 'svg' && name !== 'math') { n = n.lastChild; continue; }
          var rs = n.getClientRects();
          if (rs.length && (rs[rs.length - 1].width || rs[rs.length - 1].height)) return rs[rs.length - 1];
        }
      }
      while (n && !n.previousSibling && n.parentNode && n.parentNode !== body()) n = n.parentNode;
      n = n ? n.previousSibling : null;
    }
    return null;
  }

  function pageOfX(x) {
    return st.rtl ? Math.ceil(-x / st.W) : Math.floor(x / st.W);
  }
  function pageOfRect(r) {
    if (!r) return st.page;
    if (!st.paginated) return Math.floor((r.top + window.scrollY) / st.H);
    var x = (st.rtl ? r.right - 1 : r.left + 1) + window.scrollX;
    return clamp(pageOfX(x), 0, Math.max(0, st.pages - 1));
  }

  function computePages() {
    if (fixed) { st.pages = 1; return; }
    if (!st.paginated) {
      st.pages = Math.max(1, Math.ceil(docHeight() / st.H));
      return;
    }
    var n = Math.max(1, Math.ceil((root.scrollWidth - 2) / st.W));
    var r = lastContentRect();
    if (!r && st.sentinel) r = st.sentinel.getBoundingClientRect();
    if (r) {
      var x = (st.rtl ? r.left + 1 : r.right - 1) + window.scrollX;
      var p = pageOfX(x);
      if (p >= 0 && p + 1 <= n) n = p + 1;
    }
    st.pages = Math.max(1, n);
  }

  // ---------------------------------------------------------- position
  function goToPage(p, smooth) {
    if (!st.paginated || fixed) return;
    p = clamp(p | 0, 0, Math.max(0, st.pages - 1));
    if (p !== st.page) st.anchor = null;
    st.page = p;
    scrollToXY((st.rtl ? -1 : 1) * p * st.W, 0, smooth);
  }
  function goToEnd() {
    if (st.paginated) goToPage(st.pages - 1);
    else scrollToXY(0, maxScrollY());
  }
  function goToFraction(f) {
    f = clamp(+f || 0, 0, 1);
    // Tolerance: positions saved by older versions were rounded to 5
    // decimals, which could otherwise land one page early.
    if (st.paginated) goToPage(Math.floor(f * st.pages + 0.01));
    else scrollToXY(0, f * docHeight());
  }
  function currentFraction() {
    if (fixed) return 0;
    if (st.paginated) return st.pages > 0 ? st.page / st.pages : 0;
    return docHeight() > 0 ? clamp(window.scrollY / docHeight(), 0, 1) : 0;
  }
  function state() {
    if (!st.paginated && !fixed) {
      st.page = clamp(Math.floor((window.scrollY + 1) / st.H), 0, Math.max(0, st.pages - 1));
    }
    var atEnd = st.paginated || fixed
      ? st.page >= st.pages - 1
      : window.scrollY >= maxScrollY() - 2;
    return {
      page: st.page, pages: st.pages, fraction: currentFraction(),
      paginated: st.paginated, atEnd: atEnd, rtl: st.rtl, cols: st.cols
    };
  }

  function firstRect(el) {
    var rects = el.getClientRects();
    for (var i = 0; i < rects.length; i++) {
      if (rects[i].width || rects[i].height) return rects[i];
    }
    if (rects.length) return rects[0];
    var walker = doc.createTreeWalker(body(), NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, null, false);
    walker.currentNode = el;
    var n, guard = 0;
    while ((n = walker.nextNode()) && guard++ < 200) {
      var rs;
      if (n.nodeType === 3) {
        if (!/\S/.test(n.data)) continue;
        var rg = doc.createRange(); rg.selectNodeContents(n); rs = rg.getClientRects();
      } else rs = n.getClientRects();
      if (rs.length) return rs[0];
    }
    return null;
  }
  function rangeRect(range) {
    try {
      var r = range.cloneRange();
      var sc = r.startContainer;
      if (r.collapsed && sc.nodeType === 3 && r.startOffset < sc.length) r.setEnd(sc, r.startOffset + 1);
      var rects = r.getClientRects();
      for (var i = 0; i < rects.length; i++) if (rects[i].width || rects[i].height) return rects[i];
      var b = r.getBoundingClientRect();
      if (b && (b.width || b.height)) return b;
      var el = sc.nodeType === 1 ? sc : sc.parentNode;
      return el && el.getBoundingClientRect ? firstRect(el) : null;
    } catch (e) { return null; }
  }
  function findTarget(id) {
    if (!id) return null;
    var el = doc.getElementById(id);
    if (!el && doc.getElementsByName) el = doc.getElementsByName(id)[0] || null;
    return el;
  }
  function pageOfElement(el) { return pageOfRect(firstRect(el)); }
  function goToElement(el) {
    var r = firstRect(el);
    if (!r) return false;
    if (st.paginated) goToPage(pageOfRect(r));
    else scrollToXY(0, Math.max(0, r.top + window.scrollY - 12));
    return true;
  }
  function goToFragment(id) {
    var el = findTarget(id);
    return el ? goToElement(el) : false;
  }
  // [reveal]: keep the range away from the top edge (search results).
  function goToRange(range, reveal) {
    var r = rangeRect(range);
    if (!r) return false;
    if (st.paginated) goToPage(pageOfRect(r));
    else scrollToXY(0, Math.max(0, r.top + window.scrollY - (reveal ? st.H * 0.3 : 2)));
    return true;
  }

  function caretAt(x, y) {
    var r = null;
    try {
      if (doc.caretRangeFromPoint) r = doc.caretRangeFromPoint(x, y);
      else if (doc.caretPositionFromPoint) {
        var p = doc.caretPositionFromPoint(x, y);
        if (p) { r = doc.createRange(); r.setStart(p.offsetNode, p.offset); r.collapse(true); }
      }
    } catch (e) { r = null; }
    if (!r) return null;
    var c = r.startContainer;
    if (c && c.nodeType === 1 && c.classList && c.classList.contains('er-ui')) return null;
    if (st.paginated) {
      var rect = rangeRect(r);
      if (!rect || pageOfRect(rect) !== st.page) return null;
    }
    return r;
  }
  function captureAnchor() {
    if (!st.ready || fixed || st.vertical) return;
    var r = null, y;
    if (st.paginated) {
      var x0 = st.rtl ? (st.W - st.padR - 3) : (st.padL + 3);
      for (y = st.padT + 2; y < st.H - st.padB && !r; y += 14) r = caretAt(x0, y);
    } else {
      for (y = 8; y < st.H / 2 && !r; y += 14) r = caretAt(st.W / 2, y);
    }
    if (r) st.anchor = r;
  }

  function applyTarget(t) {
    if (!t) { if (st.paginated) goToPage(0); else scrollToXY(0, 0); return true; }
    switch (t.type) {
      case 'end': st.stickEnd = true; goToEnd(); return true;
      case 'fraction': goToFraction(t.value); return true;
      case 'fragment': return goToFragment(t.id) || (goToPage(0), false);
      case 'search': return find(t.query || '', t.occurrence || 0);
      default: if (st.paginated) goToPage(0); else scrollToXY(0, 0); return true;
    }
  }

  // Explicit navigation: the reading position is wherever it lands.
  function userMoved() {
    st.stickEnd = false;
    st.pending = null;
    st.focusRange = null;
    st.anchor = null;
  }

  function relocated() {
    if (!st.ready) return;
    post('relocated', state());
    clearTimeout(st.anchorTimer);
    if (!st.anchor) st.anchorTimer = setTimeout(captureAnchor, 450);
  }

  function relayout(force) {
    if (!st.ready || !doc.body) return;
    if (force && !st.anchor) captureAnchor();
    if (!force) {
      measureViewport();
      if (signature() === st.sig) return;
    }
    var frac = currentFraction();
    if (!st.anchor && !force) captureAnchor();
    var anchor = st.anchor;
    layout();
    if (st.focusRange) goToRange(st.focusRange, true);
    else if (st.pending && st.pending.type === 'fragment') goToFragment(st.pending.id);
    else if (st.stickEnd) goToEnd();
    else if (anchor && anchor.startContainer && doc.contains(anchor.startContainer)) {
      goToRange(anchor);
      // Keep the original anchor: re-capturing it from the top of the page
      // it landed on would move the position back on every relayout.
      st.anchor = anchor;
    }
    else goToFraction(frac);
    var s = state();
    s.anchors = anchorPages();
    post('layout', s);
    clearTimeout(st.anchorTimer);
    if (!st.anchor) st.anchorTimer = setTimeout(captureAnchor, 80);
  }
  var relayoutTimer = 0;
  function scheduleRelayout(delay, force) {
    clearTimeout(relayoutTimer);
    relayoutTimer = setTimeout(function () { relayout(force); }, delay || 100);
  }

  function anchorPages() {
    var ids = cfg.anchors || [], out = {};
    for (var i = 0; i < ids.length; i++) {
      var el = findTarget(ids[i]);
      if (el) out[ids[i]] = pageOfElement(el);
    }
    return out;
  }

  // ------------------------------------------------------------ paging
  function next(smooth) {
    if (fixed || st.vertical) { post('edge', { dir: 1 }); return; }
    if (!st.paginated) {
      if (window.scrollY >= maxScrollY() - 2) { post('edge', { dir: 1 }); return; }
      userMoved();
      scrollToXY(0, window.scrollY + st.H * 0.9 - 24, true);
      return;
    }
    if (st.page >= st.pages - 1) { post('edge', { dir: 1 }); return; }
    userMoved();
    goToPage(st.page + 1, smooth);
    relocated();
  }
  function prev(smooth) {
    if (fixed || st.vertical) { post('edge', { dir: -1 }); return; }
    if (!st.paginated) {
      if (window.scrollY <= 2) { post('edge', { dir: -1 }); return; }
      userMoved();
      scrollToXY(0, Math.max(0, window.scrollY - st.H * 0.9 + 24), true);
      return;
    }
    if (st.page <= 0) { post('edge', { dir: -1 }); return; }
    userMoved();
    goToPage(st.page - 1, smooth);
    relocated();
  }
  function side(s, smooth) {
    var forward = st.rtl ? s < 0 : s > 0;
    if (forward) next(smooth); else prev(smooth);
  }

  // ------------------------------------------------------------ search
  function skipNode(n) {
    var p = n.parentNode;
    while (p && p !== doc.body) {
      var name = (p.localName || p.nodeName || '').toLowerCase();
      if (name === 'script' || name === 'style') return true;
      if (p.classList && p.classList.contains('er-ui')) return true;
      p = p.parentNode;
    }
    return false;
  }
  function normalize(raw, map) {
    var out = [], prevSpace = false;
    for (var i = 0; i < raw.length; i++) {
      var c = raw.charAt(i);
      if (c === '\uE000') continue;
      if (WS.test(c)) {
        if (prevSpace) continue;
        prevSpace = true;
        out.push(' ');
        if (map) map.push(i);
        continue;
      }
      prevSpace = false;
      var l = c.toLowerCase();
      out.push(l.length === 1 ? l : c);
      if (map) map.push(i);
    }
    return out.join('');
  }
  function textIndex() {
    var walker = doc.createTreeWalker(body(), NodeFilter.SHOW_TEXT, null, false);
    var nodes = [], starts = [], parts = [], pos = 0, n;
    while ((n = walker.nextNode())) {
      if (skipNode(n)) continue;
      nodes.push(n); starts.push(pos); parts.push(n.data); pos += n.data.length;
    }
    var map = [];
    var text = normalize(parts.join(''), map);
    return { nodes: nodes, starts: starts, text: text, map: map };
  }
  function locate(idx, pos) {
    var lo = 0, hi = idx.starts.length - 1;
    while (lo < hi) {
      var mid = (lo + hi + 1) >> 1;
      if (idx.starts[mid] <= pos) lo = mid; else hi = mid - 1;
    }
    return { node: idx.nodes[lo], offset: pos - idx.starts[lo] };
  }
  var marks = [];
  function clearHighlight() {
    try { if (window.CSS && CSS.highlights) CSS.highlights.delete('er-search'); } catch (e) {}
    for (var i = 0; i < marks.length; i++) {
      var m = marks[i], p = m.parentNode;
      if (!p) continue;
      while (m.firstChild) p.insertBefore(m.firstChild, m);
      p.removeChild(m);
      p.normalize();
    }
    marks = [];
  }
  function highlight(range) {
    clearHighlight();
    try {
      if (window.CSS && CSS.highlights && typeof window.Highlight === 'function') {
        CSS.highlights.set('er-search', new window.Highlight(range));
        return range;
      }
    } catch (e) {}
    try {
      var container = range.commonAncestorContainer;
      if (container.nodeType === 3) container = container.parentNode;
      var walker = doc.createTreeWalker(container, NodeFilter.SHOW_TEXT, null, false);
      var list = [], n;
      while ((n = walker.nextNode())) if (range.intersectsNode(n)) list.push(n);
      var sc = range.startContainer, so = range.startOffset;
      var ec = range.endContainer, eo = range.endOffset;
      for (var i = 0; i < list.length; i++) {
        var tn = list[i];
        var s = tn === sc ? so : 0, e = tn === ec ? eo : tn.data.length;
        if (e <= s) continue;
        var mid = tn.splitText(s);
        mid.splitText(e - s);
        var mark = doc.createElement('mark');
        mark.className = 'er-mark';
        mid.parentNode.insertBefore(mark, mid);
        mark.appendChild(mid);
        marks.push(mark);
      }
      if (marks.length) {
        var r = doc.createRange();
        r.setStartBefore(marks[0]);
        r.setEndAfter(marks[marks.length - 1]);
        return r;
      }
    } catch (e2) {}
    return range;
  }
  function find(query, occurrence) {
    var q = normalize(String(query || '').trim(), null);
    if (!q) return false;
    var idx = textIndex();
    var at = -1, from = 0;
    for (var i = 0; i <= occurrence; i++) {
      var f = idx.text.indexOf(q, from);
      if (f < 0) break;
      at = f; from = f + 1;
    }
    if (at < 0 || !idx.nodes.length) return false;
    var s = locate(idx, idx.map[at]);
    var e = locate(idx, idx.map[at + q.length - 1]);
    var range = doc.createRange();
    try {
      range.setStart(s.node, s.offset);
      range.setEnd(e.node, Math.min(e.node.length, e.offset + 1));
    } catch (err) { return false; }
    var shown = highlight(range);
    st.focusRange = shown;
    goToRange(shown, true);
    return true;
  }

  // ------------------------------------------------------------ events
  doc.addEventListener('click', function (e) {
    var t = e.target;
    if (t && t.nodeType !== 1) t = t.parentNode;
    var ui = t && t.closest ? t.closest('[data-er-action]') : null;
    if (ui) {
      e.preventDefault();
      post('edge', { dir: ui.getAttribute('data-er-action') === 'next' ? 1 : -1 });
      return;
    }
    var link = t && t.closest ? t.closest('a') : null;
    if (link) {
      var href = link.getAttribute('href') ||
        link.getAttributeNS('http://www.w3.org/1999/xlink', 'href');
      if (href) { e.preventDefault(); followLink(href); return; }
    }
    if (t && t.closest && t.closest('audio,video,button,input,select,textarea,label,summary')) return;
    if (st.selAtStart || hasSelection()) { st.selAtStart = false; return; }
    if (Date.now() - st.lastSwipe < 500) return;
    var w = window.innerWidth || st.W, x = e.clientX;
    if (x < w / 3) side(-1, true);
    else if (x > (2 * w) / 3) side(1, true);
    else post('toggleControls', {});
  }, false);

  function followLink(href) {
    var url;
    try { url = new URL(href, location.href); } catch (e) { return; }
    if (url.host === location.host && url.pathname === location.pathname &&
        url.protocol === location.protocol) {
      var id = '';
      try { id = decodeURIComponent(url.hash.slice(1)); } catch (e2) { id = url.hash.slice(1); }
      if (!id) return;
      userMoved();
      if (goToFragment(id)) relocated();
      return;
    }
    post('link', { href: url.href });
  }

  var tx = 0, ty = 0, tt = 0, tracking = false;
  doc.addEventListener('mousedown', function () { st.selAtStart = hasSelection(); }, true);
  doc.addEventListener('touchstart', function (e) {
    st.selAtStart = hasSelection();
    if (e.touches.length !== 1) { tracking = false; return; }
    var t = e.touches[0];
    tx = t.clientX; ty = t.clientY; tt = Date.now(); tracking = true;
  }, { passive: true });
  doc.addEventListener('touchmove', function (e) {
    if (!tracking || !(st.paginated || fixed) || !e.cancelable || e.touches.length !== 1) return;
    var t = e.touches[0];
    if (Math.abs(t.clientX - tx) > Math.abs(t.clientY - ty) && !hasSelection()) e.preventDefault();
  }, { passive: false });
  doc.addEventListener('touchend', function (e) {
    if (!tracking) return;
    tracking = false;
    if (!(st.paginated || fixed)) return;
    var t = e.changedTouches[0];
    var dx = t.clientX - tx, dy = t.clientY - ty;
    if (Date.now() - tt > 900) return;
    if (Math.abs(dx) < 40 || Math.abs(dx) < Math.abs(dy) * 1.2) return;
    if (hasSelection()) return;
    st.lastSwipe = Date.now();
    side(dx < 0 ? 1 : -1, true);
  }, { passive: true });

  doc.addEventListener('keydown', function (e) {
    var tg = e.target;
    if (tg && (tg.isContentEditable || /^(input|textarea|select)$/i.test(tg.nodeName || ''))) return;
    var k = e.key, handled = true;
    if (k === 'ArrowRight') side(1, false);
    else if (k === 'ArrowLeft') side(-1, false);
    else if (k === 'PageDown' || (k === ' ' && !e.shiftKey)) next(false);
    else if (k === 'PageUp' || (k === ' ' && e.shiftKey)) prev(false);
    else if (st.paginated && k === 'ArrowDown') next(false);
    else if (st.paginated && k === 'ArrowUp') prev(false);
    else handled = false;
    if (handled) e.preventDefault();
  });

  var wheelLock = 0;
  doc.addEventListener('wheel', function (e) {
    if (!(st.paginated || fixed) || e.ctrlKey) return;
    e.preventDefault();
    var now = Date.now();
    if (now < wheelLock) return;
    var d = Math.abs(e.deltaY) >= Math.abs(e.deltaX) ? e.deltaY : e.deltaX;
    if (Math.abs(d) < 4) return;
    wheelLock = now + 350;
    if (d > 0) next(false); else prev(false);
  }, { passive: false });

  var scrollTimer = 0;
  window.addEventListener('scroll', function () {
    if (!st.ready || fixed) return;
    clearTimeout(scrollTimer);
    scrollTimer = setTimeout(function () {
      if (st.paginated) {
        // Snap back if something (selection drag, find) scrolled off-page.
        var expected = (st.rtl ? -1 : 1) * st.page * st.W;
        if (Math.abs(window.scrollX - expected) > 2 || Math.abs(window.scrollY) > 2) {
          var p = clamp(Math.round(Math.abs(window.scrollX) / st.W), 0, st.pages - 1);
          goToPage(p, false);
          relocated();
        }
        return;
      }
      if (Date.now() - st.progScroll > 400) {
        userMoved();
        st.anchor = null;
      }
      relocated();
    }, 160);
  }, { passive: true });

  window.addEventListener('resize', function () { scheduleRelayout(120, true); });

  // -------------------------------------------------------------- init
  function init() {
    if (st.inited || !doc.body) return;
    st.inited = true;
    if (doc.getElementsByTagName('parsererror').length) {
      // The browser's XML parser rejected the document: ask for HTML mode.
      post('parseError', {});
    }
    detectDirection();
    captureBaseFont();
    applyTheme();
    layout();
    var t = st.pending;
    applyTarget(t);
    if (!t || t.type === 'fraction' || t.type === 'start' || t.type === 'search') st.pending = null;
    root.classList.add('er-ready');
    st.ready = true;
    var s = state();
    s.anchors = anchorPages();
    post('ready', s);
    setTimeout(captureAnchor, 60);

    var imgs = doc.images || [];
    for (var i = 0; i < imgs.length; i++) {
      if (!imgs[i].complete) imgs[i].addEventListener('load', function () { scheduleRelayout(150, false); });
    }
    if (window.ResizeObserver) {
      try { new ResizeObserver(function () { scheduleRelayout(200, false); }).observe(body()); } catch (e) {}
    }
  }
  if (doc.readyState === 'loading') doc.addEventListener('DOMContentLoaded', init);
  else init();
  window.addEventListener('load', function () { init(); scheduleRelayout(30, false); });
  if (doc.fonts && doc.fonts.ready) {
    doc.fonts.ready.then(function () { scheduleRelayout(30, false); });
  }

  // --------------------------------------------------------------- API
  window.ER = {
    next: function () { next(true); },
    prev: function () { prev(true); },
    goToFraction: function (f) { userMoved(); goToFraction(f); relocated(); },
    goToFragment: function (id) {
      userMoved();
      var ok = goToFragment(id);
      if (ok) st.pending = { type: 'fragment', id: id };
      relocated();
      return ok;
    },
    goToStart: function () { userMoved(); applyTarget(null); relocated(); },
    goToEnd: function () { userMoved(); st.stickEnd = true; goToEnd(); relocated(); },
    find: function (q, occ) {
      userMoved();
      var ok = find(q, occ || 0);
      relocated();
      return ok;
    },
    clearHighlight: function () { clearHighlight(); st.focusRange = null; },
    applySettings: function (s) {
      if (!st.anchor) captureAnchor();
      settings = s || settings;
      captureBaseFont();
      applyTheme();
      relayout(true);
    },
    setHinge: function (h) { hinge = h || null; relayout(true); },
    setNav: function (hasPrev, hasNext) { cfg.hasPrev = !!hasPrev; cfg.hasNext = !!hasNext; },
    setAnchors: function (ids) { cfg.anchors = ids || []; },
    state: function () { var s = state(); s.anchors = anchorPages(); s.ready = st.ready; return JSON.stringify(s); }
  };
})();
''';
