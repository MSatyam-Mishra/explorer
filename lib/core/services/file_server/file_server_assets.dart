// Stylesheet and script for the file server's pages (file_server_page.dart).
// The colour variables come from the app's theme and are inlined per page.

const fileServerCss = r'''
@font-face{font-family:"Geist";src:url("geist.ttf") format("truetype");font-weight:100 900;font-style:normal;font-display:swap}
*,*::before,*::after{box-sizing:border-box}
html{-webkit-text-size-adjust:100%;text-size-adjust:100%;color-scheme:light}
html[data-mode=dark]{color-scheme:dark}
body{margin:0;min-height:100vh;min-height:100dvh;display:flex;flex-direction:column;background:var(--background);color:var(--foreground);font-family:"Geist",ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;font-size:14px;line-height:1.5;-webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale}
a{color:inherit;text-decoration:none}
button,input,select{font:inherit;color:inherit;letter-spacing:inherit}
button{cursor:pointer}
::selection{background:color-mix(in srgb,var(--primary) 22%,transparent)}
:focus-visible{outline:2px solid var(--ring);outline-offset:2px}
[hidden]{display:none!important}
html.no-js .js-only{display:none!important}
.sr-only{position:absolute;width:1px;height:1px;margin:-1px;padding:0;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;border:0}
.i{width:16px;height:16px;flex:none;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}
.container{width:100%;max-width:1180px;margin:0 auto;padding-left:max(16px,env(safe-area-inset-left));padding-right:max(16px,env(safe-area-inset-right))}
@media (min-width:640px){.container{padding-left:24px;padding-right:24px}}

/* Header */
.topbar{position:sticky;top:0;z-index:20;background:color-mix(in srgb,var(--background) 82%,transparent);-webkit-backdrop-filter:saturate(1.5) blur(14px);backdrop-filter:saturate(1.5) blur(14px);border-bottom:1px solid var(--border)}
.topbar-inner{height:56px;display:flex;align-items:center;gap:12px}
.brand{display:flex;align-items:center;gap:10px;min-width:0;border-radius:8px}
.brand img{width:28px;height:28px;flex:none}
.brand-text{display:flex;flex-direction:column;min-width:0;line-height:1.2}
.brand strong{font-weight:600;letter-spacing:-.01em}
.brand small{font-size:12px;color:var(--muted-foreground);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.live{display:inline-flex;align-items:center;gap:6px;height:24px;padding:0 10px 0 8px;border:1px solid var(--border);border-radius:999px;font-size:12px;font-weight:500;color:var(--muted-foreground);flex:none}
.live .dot{width:6px;height:6px;border-radius:50%;background:#22c55e;box-shadow:0 0 0 3px rgb(34 197 94/.18);animation:pulse 2.4s ease-in-out infinite}
.spacer{flex:1}
html[data-pref=light] #theme .i:not(.when-light),html[data-pref=dark] #theme .i:not(.when-dark),html[data-pref=system] #theme .i:not(.when-system){display:none}

/* Buttons */
.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;height:36px;padding:0 14px;border-radius:8px;border:1px solid transparent;background:none;font-size:14px;font-weight:500;line-height:1;white-space:nowrap;user-select:none;-webkit-user-select:none;transition:background-color .15s,border-color .15s,color .15s,box-shadow .15s}
.btn-primary{background:var(--primary);color:var(--primary-foreground);box-shadow:0 1px 2px rgb(0 0 0/.08)}
.btn-primary:hover{background:color-mix(in srgb,var(--primary) 88%,var(--background))}
.btn-outline{background:var(--background);border-color:var(--input);box-shadow:0 1px 2px rgb(0 0 0/.04)}
.btn-outline:hover,.btn-ghost:hover{background:var(--accent);color:var(--accent-foreground)}
.btn-icon{width:36px;padding:0}
.link{background:none;border:0;padding:0;color:var(--foreground);font-weight:500;text-decoration:underline;text-underline-offset:3px;text-decoration-color:color-mix(in srgb,var(--foreground) 35%,transparent)}
.link:hover{text-decoration-color:currentColor}

/* Page */
main{flex:1;padding-top:16px;padding-bottom:40px}
.crumbs{display:flex;align-items:center;gap:2px;margin:0 -6px;padding:2px 0;overflow-x:auto;scrollbar-width:none;white-space:nowrap;color:var(--muted-foreground)}
.crumbs::-webkit-scrollbar{display:none}
.crumbs a{display:inline-flex;align-items:center;gap:6px;height:28px;padding:0 6px;border-radius:6px;transition:color .15s,background-color .15s}
.crumbs a:hover{color:var(--foreground);background:var(--accent)}
.crumbs a[aria-current]{color:var(--foreground);font-weight:500}
.crumbs .sep{width:14px;height:14px;opacity:.55}
.page-head{display:flex;align-items:flex-end;justify-content:space-between;gap:12px 16px;flex-wrap:wrap;margin:10px 0 20px}
.page-title{min-width:0}
.page-head h1{margin:0;font-size:26px;line-height:1.25;font-weight:600;letter-spacing:-.025em;overflow-wrap:anywhere}
.summary{margin:4px 0 0;color:var(--muted-foreground)}
.actions{display:flex;gap:8px;flex-wrap:wrap}

/* Toolbar */
.toolbar{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:12px}
.search{position:relative;flex:1 1 260px;max-width:400px}
.search>.i{position:absolute;left:12px;top:50%;transform:translateY(-50%);color:var(--muted-foreground);pointer-events:none}
.input{width:100%;height:36px;padding:0 36px;border:1px solid var(--input);border-radius:8px;background:transparent;outline:none;box-shadow:0 1px 2px rgb(0 0 0/.04);transition:border-color .15s,box-shadow .15s;-webkit-appearance:none;appearance:none}
.input::-webkit-search-cancel-button{display:none}
.input::placeholder{color:var(--muted-foreground)}
.input:focus{border-color:var(--ring);box-shadow:0 0 0 3px color-mix(in srgb,var(--ring) 20%,transparent)}
.search kbd{position:absolute;right:8px;top:50%;transform:translateY(-50%);min-width:20px;height:20px;padding:0 5px;display:grid;place-items:center;border:1px solid var(--border);border-radius:4px;background:var(--muted);color:var(--muted-foreground);font:500 11px/1 inherit;pointer-events:none}
.search-clear{position:absolute;right:4px;top:50%;transform:translateY(-50%);width:28px;height:28px;display:grid;place-items:center;border:0;border-radius:6px;background:none;color:var(--muted-foreground)}
.search-clear:hover{background:var(--accent);color:var(--foreground)}
.toolbar-end{display:flex;align-items:center;gap:8px;margin-left:auto}
.select{position:relative;display:inline-flex}
.select select{height:36px;padding:0 32px 0 34px;border:1px solid var(--input);border-radius:8px;background:var(--background);color:var(--foreground);font-weight:500;box-shadow:0 1px 2px rgb(0 0 0/.04);-webkit-appearance:none;appearance:none;cursor:pointer;outline:none}
.select select:hover{background:var(--accent)}
.select select:focus-visible{border-color:var(--ring);box-shadow:0 0 0 3px color-mix(in srgb,var(--ring) 20%,transparent)}
.select .i{position:absolute;top:50%;transform:translateY(-50%);pointer-events:none;color:var(--muted-foreground)}
.select .lead{left:11px}.select .trail{right:10px}
#sort-dir .when-desc,#sort-dir.desc .when-asc{display:none}
#sort-dir.desc .when-desc{display:block}
.segmented{display:inline-flex;gap:2px;padding:3px;border-radius:9px;background:var(--muted)}
.segmented button{width:32px;height:30px;display:grid;place-items:center;border:0;border-radius:6px;background:none;color:var(--muted-foreground);transition:background-color .15s,color .15s,box-shadow .15s}
.segmented button:hover{color:var(--foreground)}
.segmented button[aria-pressed=true]{background:var(--background);color:var(--foreground);box-shadow:0 1px 3px rgb(0 0 0/.1),0 0 0 1px color-mix(in srgb,var(--border) 70%,transparent)}

/* List */
.files{border:1px solid var(--border);border-radius:12px;background:var(--card);color:var(--card-foreground);overflow:hidden}
.files-head,.entry{display:grid;grid-template-columns:minmax(0,1fr) 96px 168px 40px;align-items:center;column-gap:16px;padding:0 8px 0 12px}
.files-head{height:40px;border-bottom:1px solid var(--border);color:var(--muted-foreground);font-size:13px;font-weight:500}
html.no-js .files-head button{pointer-events:none}
.files-head button{justify-self:start;display:inline-flex;align-items:center;gap:4px;height:28px;margin:0 -8px;padding:0 8px;border:0;border-radius:6px;background:none;color:inherit;font-weight:500;transition:background-color .15s,color .15s}
.files-head button.end{justify-self:end}
.files-head button:hover{background:var(--accent);color:var(--foreground)}
.files-head button[aria-sort]{color:var(--foreground)}
.files-head .dir{width:14px;height:14px;opacity:0;transition:transform .15s,opacity .15s}
.files-head button[aria-sort] .dir{opacity:1}
.files-head button[aria-sort=descending] .dir{transform:rotate(180deg)}
.entry{position:relative;min-height:56px;border-top:1px solid var(--border);transition:background-color .12s}
.entries .entry:first-child{border-top:0}
.entry:hover{background:color-mix(in srgb,var(--muted) 60%,transparent)}
.entry:focus-within{background:color-mix(in srgb,var(--muted) 60%,transparent)}
.main{display:flex;align-items:center;gap:12px;min-width:0;padding:8px 0}
.thumb{position:relative;width:36px;height:36px;flex:none;display:grid;place-items:center;border-radius:8px;overflow:hidden}
.thumb .ic{width:32px;height:32px;object-fit:contain}
.thumb .ic-dark{display:none}
html[data-mode=dark] .has-dark .ic-light{display:none}
html[data-mode=dark] .has-dark .ic-dark{display:block}
.thumb .preview{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;background:var(--muted)}
.thumb video.preview{opacity:0;transition:opacity .25s}
.thumb video.preview.ready{opacity:1}
.name{display:flex;flex-direction:column;min-width:0}
.open{display:flex;min-width:0;font-weight:500;white-space:nowrap;border-radius:4px}
.open .stem{min-width:0;overflow:hidden;text-overflow:ellipsis}
.open .ext{flex:none}
.open::after{content:"";position:absolute;inset:0;z-index:1}
.open:focus-visible{outline:none}
.entry:has(.open:focus-visible){outline:2px solid var(--ring);outline-offset:-2px}
.meta{display:none;font-size:12px;color:var(--muted-foreground);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.meta span+span::before{content:" · "}
.size,.date{color:var(--muted-foreground);font-size:13px;white-space:nowrap;font-variant-numeric:tabular-nums}
.size{text-align:right}
.row-actions{position:relative;z-index:2;display:flex;justify-content:flex-end}
.row-actions .btn{width:32px;height:32px;color:var(--muted-foreground);opacity:0;transition:opacity .12s,background-color .15s,color .15s}
.row-actions .btn:hover{color:var(--foreground)}
.entry:hover .row-actions .btn,.row-actions .btn:focus-visible{opacity:1}
@media (hover:none){.row-actions .btn{opacity:1}.search kbd{display:none}}
.entry[data-hidden]{display:none}
.show-hidden .entry[data-hidden]:not([hidden]){display:grid}
.entry[data-hidden] .open{color:var(--muted-foreground)}

/* Grid */
.files[data-view=grid]{border:0;border-radius:0;background:none;overflow:visible}
.files[data-view=grid] .files-head{display:none}
.files[data-view=grid] .entries{display:grid;grid-template-columns:repeat(auto-fill,minmax(172px,1fr));gap:12px}
.files[data-view=grid] .entry,.files[data-view=grid].show-hidden .entry[data-hidden]:not([hidden]){display:flex;flex-direction:column;align-items:stretch;min-height:0;padding:0;border:1px solid var(--border);border-radius:12px;background:var(--card);overflow:hidden;transition:border-color .15s,box-shadow .15s,transform .15s}
.files[data-view=grid] .entry:hover{background:var(--card);border-color:color-mix(in srgb,var(--foreground) 22%,var(--border));box-shadow:0 8px 24px -12px rgb(0 0 0/.28)}
.files[data-view=grid] .main{flex-direction:column;align-items:stretch;gap:0;padding:0}
.files[data-view=grid] .thumb{width:auto;height:auto;aspect-ratio:4/3;border-radius:0;background:color-mix(in srgb,var(--muted) 70%,transparent);border-bottom:1px solid var(--border)}
.files[data-view=grid] .thumb .ic{width:56px;height:56px}
.files[data-view=grid] .entry[data-kind=video] .thumb::after{content:"";position:absolute;left:8px;bottom:8px;z-index:1;width:28px;height:28px;border-radius:50%;background:rgb(0 0 0/.55) url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='white'%3E%3Cpath d='M8 5.5v13l11-6.5z'/%3E%3C/svg%3E") 55% 50%/14px no-repeat;-webkit-backdrop-filter:blur(6px);backdrop-filter:blur(6px)}
.files[data-view=grid] .name{padding:10px 12px 12px}
.files[data-view=grid] .open{font-size:13px;line-height:1.4}
.files[data-view=grid] .meta{display:block;margin-top:3px}
.files[data-view=grid] .size,.files[data-view=grid] .date{display:none}
.files[data-view=grid] .row-actions{position:absolute;top:8px;right:8px}
.files[data-view=grid] .row-actions .btn{background:color-mix(in srgb,var(--background) 85%,transparent);border:1px solid var(--border);-webkit-backdrop-filter:blur(8px);backdrop-filter:blur(8px)}

/* Empty states */
.empty{display:flex;flex-direction:column;align-items:center;text-align:center;padding:64px 16px;border:1px dashed var(--border);border-radius:12px;color:var(--muted-foreground)}
.badge-icon{width:48px;height:48px;display:grid;place-items:center;margin-bottom:14px;border-radius:12px;background:var(--muted);color:var(--foreground)}
.badge-icon .i{width:22px;height:22px}
.empty h2{margin:0 0 4px;font-size:16px;font-weight:600;color:var(--foreground)}
.empty p{margin:0;max-width:380px}
.empty p:empty{display:none}
.empty .btn{margin-top:20px;color:var(--foreground)}
main>.empty:first-child{margin-top:16px}

footer{border-top:1px solid var(--border);color:var(--muted-foreground);font-size:12px}
footer .container{display:flex;justify-content:space-between;gap:4px 16px;flex-wrap:wrap;padding-top:16px;padding-bottom:max(16px,env(safe-area-inset-bottom))}

/* Viewer */
.viewer:focus{outline:none}
.viewer{position:fixed;inset:0;z-index:50;display:flex;flex-direction:column;background:#09090b;color:#fafafa;animation:fade .15s ease-out}
.viewer-bar{display:flex;align-items:center;gap:4px;height:60px;flex:none;padding:env(safe-area-inset-top) 8px 0 20px}
.viewer-title{display:flex;flex-direction:column;flex:1;min-width:0;line-height:1.3}
.viewer-title strong{font-weight:500;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.viewer-title span{font-size:12px;color:#a1a1aa}
.vbtn{width:40px;height:40px;display:grid;place-items:center;flex:none;border:0;border-radius:8px;background:none;color:#e4e4e7;transition:background-color .15s}
.vbtn:hover{background:rgb(255 255 255/.1)}
.vbtn .i,.vnav .i{width:20px;height:20px}
.viewer-stage{position:relative;flex:1;min-height:0;display:flex;align-items:center;justify-content:center;padding:0 16px max(16px,env(safe-area-inset-bottom));touch-action:pan-y}
.viewer-stage>img,.viewer-stage>video{max-width:100%;max-height:100%;object-fit:contain;border-radius:6px;box-shadow:0 20px 60px -20px rgb(0 0 0/.6);animation:zoom .18s ease-out}
.viewer-stage>video{width:min(100%,1280px);background:#000}
.vnav{position:absolute;top:50%;z-index:2;width:44px;height:44px;margin-top:20px;display:grid;place-items:center;border:1px solid rgb(255 255 255/.12);border-radius:999px;background:rgb(255 255 255/.08);color:#fff;-webkit-backdrop-filter:blur(8px);backdrop-filter:blur(8px);transform:translateY(-50%);transition:background-color .15s}
.vnav:hover{background:rgb(255 255 255/.18)}
.vnav.prev{left:16px}.vnav.next{right:16px}
@media (hover:none){.vnav{display:none}}
.audio-card,.viewer-error{width:min(420px,100%);display:flex;flex-direction:column;align-items:center;gap:14px;padding:28px 24px;border:1px solid #27272a;border-radius:16px;background:#18181b;text-align:center;animation:zoom .18s ease-out}
.audio-card img{width:72px;height:72px}
.audio-card strong{overflow-wrap:anywhere;font-weight:500}
.audio-card audio{width:100%}
.viewer-error p{margin:0;color:#a1a1aa}
.viewer-error .btn-primary{background:#fafafa;color:#18181b}
.viewer-error .i{width:28px;height:28px;color:#a1a1aa}
.spinner{position:absolute;width:28px;height:28px;border:2.5px solid rgb(255 255 255/.18);border-top-color:#fff;border-radius:50%;animation:spin .7s linear infinite}

/* Uploads */
.dropzone{position:fixed;inset:0;z-index:40;display:grid;place-items:center;padding:16px;background:color-mix(in srgb,var(--background) 75%,transparent);-webkit-backdrop-filter:blur(6px);backdrop-filter:blur(6px);animation:fade .12s}
.dropzone-inner{width:min(560px,100%);height:260px;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:4px;border:2px dashed var(--primary);border-radius:16px;background:var(--card);color:var(--muted-foreground);text-align:center;pointer-events:none}
.dropzone-inner strong{color:var(--foreground);font-size:16px;font-weight:600}
.uploads{position:fixed;right:16px;bottom:16px;z-index:45;width:min(380px,calc(100vw - 32px));overflow:hidden;border:1px solid var(--border);border-radius:12px;background:var(--popover);color:var(--popover-foreground);box-shadow:0 16px 40px -12px rgb(0 0 0/.3),0 4px 12px -6px rgb(0 0 0/.12);animation:rise .2s ease-out}
.uploads-head{display:flex;align-items:center;gap:8px;min-height:52px;padding:8px 8px 8px 16px;border-bottom:1px solid var(--border)}
.uploads-head strong{flex:1;font-weight:600}
.uploads-head .btn{height:32px;padding:0 10px;font-size:13px}
.uploads-head .btn-icon{width:32px;padding:0}
.uploads ul{list-style:none;margin:0;padding:6px 0;max-height:280px;overflow:auto}
.uploads li{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:6px 12px;padding:8px 16px;font-size:13px}
.up-name{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-weight:500}
.up-status{color:var(--muted-foreground);font-variant-numeric:tabular-nums;white-space:nowrap}
.bar{grid-column:1/-1;height:4px;overflow:hidden;border-radius:99px;background:var(--muted)}
.bar span{display:block;width:0;height:100%;border-radius:inherit;background:var(--primary);transition:width .2s}
.uploads li.done .bar span{background:#22c55e}
.uploads li.error .bar span{background:var(--destructive)}
.uploads li.error .up-status{color:var(--destructive)}
html[data-mode=dark] .uploads li.error .up-status{color:#f87171}
.toast{position:fixed;left:50%;bottom:24px;z-index:60;max-width:calc(100vw - 32px);padding:10px 16px;border-radius:10px;background:var(--foreground);color:var(--background);font-weight:500;box-shadow:0 10px 30px -10px rgb(0 0 0/.4);transform:translateX(-50%);animation:toast .2s ease-out}

@keyframes fade{from{opacity:0}}
@keyframes rise{from{opacity:0;transform:translateY(8px)}}
@keyframes toast{from{opacity:0;transform:translate(-50%,8px)}}
@keyframes zoom{from{opacity:0;transform:scale(.97)}}
@keyframes spin{to{transform:rotate(360deg)}}
@keyframes pulse{50%{box-shadow:0 0 0 5px rgb(34 197 94/.08)}}

@media (max-width:760px){
  .files-head{display:none}
  .entry{grid-template-columns:minmax(0,1fr) 40px;padding-left:12px}
  .entry .size,.entry .date{display:none}
  .meta{display:block}
  .files[data-view=grid] .entries{grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:10px}
}
@media (max-width:560px){
  .live{display:none}
  .page-head h1{font-size:22px}
  .actions{width:100%}
  .actions .btn{flex:1}
  .search{flex-basis:100%;max-width:none}
  .toolbar-end{width:100%;margin-left:0}
  .select{flex:1}
  .select select{width:100%}
  .files[data-view=grid] .entries{grid-template-columns:repeat(2,minmax(0,1fr))}
  .files[data-view=grid] .thumb .ic{width:48px;height:48px}
  .uploads{right:12px;bottom:12px;width:calc(100vw - 24px)}
}
@media (prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important}}
''';

const fileServerJs = r'''
(() => {
  'use strict';
  const doc = document;
  const root = doc.documentElement;
  const $ = (s, el = doc) => el.querySelector(s);
  const $$ = (s, el = doc) => Array.from(el.querySelectorAll(s));
  const store = {
    get(k) { try { return localStorage.getItem('explorer.' + k); } catch (e) { return null; } },
    set(k, v) { try { localStorage.setItem('explorer.' + k, v); } catch (e) {} },
  };
  const svg = (id) => `<svg class="i" aria-hidden="true"><use href="#i-${id}"/></svg>`;
  const make = (tag, cls, text) => {
    const el = doc.createElement(tag);
    if (cls) el.className = cls;
    if (text != null) el.textContent = text;
    return el;
  };
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  const formatSize = (n) => {
    let u = 0;
    while (n >= 1024 && u < units.length - 1) { n /= 1024; u++; }
    return n.toFixed(u ? 1 : 0) + ' ' + units[u];
  };

  // Theme: System → Light → Dark.
  const media = window.matchMedia('(prefers-color-scheme: dark)');
  const prefs = ['system', 'light', 'dark'];
  const prefNames = { system: 'System', light: 'Light', dark: 'Dark' };
  function applyTheme() {
    let pref = store.get('theme');
    if (!prefs.includes(pref)) pref = 'system';
    root.dataset.pref = pref;
    root.dataset.mode = pref === 'dark' || (pref === 'system' && media.matches) ? 'dark' : 'light';
    const button = $('#theme');
    if (button) {
      button.title = 'Theme: ' + prefNames[pref];
      button.setAttribute('aria-label', button.title);
    }
  }
  if (media.addEventListener) media.addEventListener('change', applyTheme);
  else if (media.addListener) media.addListener(applyTheme);
  $('#theme')?.addEventListener('click', () => {
    store.set('theme', prefs[(prefs.indexOf(root.dataset.pref) + 1) % prefs.length]);
    applyTheme();
    toast('Theme: ' + prefNames[root.dataset.pref]);
  });
  applyTheme();

  let toastTimer = 0;
  function toast(text) {
    let el = $('#toast');
    if (!el) {
      el = make('div', 'toast');
      el.id = 'toast';
      el.setAttribute('role', 'status');
      doc.body.appendChild(el);
    }
    el.textContent = text;
    el.hidden = false;
    el.style.animation = 'none';
    void el.offsetWidth;
    el.style.animation = '';
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { el.hidden = true; }, 2200);
  }

  // Dates in the viewer's locale.
  const now = new Date();
  const longDate = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' });
  const shortDate = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium' });
  const time = new Intl.DateTimeFormat(undefined, { timeStyle: 'short' });
  const isToday = (d) => d.toDateString() === now.toDateString();
  $$('.date[data-t]').forEach((el) => {
    const d = new Date(+el.dataset.t);
    el.textContent = isToday(d) ? 'Today, ' + time.format(d) : longDate.format(d);
    el.title = d.toLocaleString();
  });
  $$('.meta-date[data-t]').forEach((el) => {
    const d = new Date(+el.dataset.t);
    el.textContent = isToday(d) ? time.format(d) : shortDate.format(d);
  });

  const files = $('#files');
  const list = $('#entries');
  const uploads = { queue: [], active: 0, done: 0, failed: 0, total: 0, panel: null };
  if (doc.body.dataset.upload === '1') setUpUploads();
  if (!files || !list) return;

  const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' });
  const fold = (s) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
  const items = $$('.entry', list).map((el) => ({
    el,
    name: el.dataset.name,
    key: fold(el.dataset.name),
    dir: el.dataset.dir === '1',
    size: +el.dataset.size || 0,
    mtime: +el.dataset.mtime || 0,
    type: el.dataset.type || '',
    kind: el.dataset.kind,
    view: el.dataset.view,
    hidden: el.dataset.hidden === '1',
    href: $('a.open', el).getAttribute('href'),
  }));
  const byEl = new Map(items.map((i) => [i.el, i]));

  const sorts = ['name', 'date', 'size', 'type'];
  const mediaShare = (+files.dataset.media || 0) / Math.max(1, items.filter((i) => !i.dir).length);
  const state = {
    sort: sorts.includes(store.get('sort')) ? store.get('sort') : 'name',
    desc: store.get('desc') === '1',
    view: store.get('view') || (mediaShare >= 0.6 ? 'grid' : 'list'),
    q: '',
    showHidden: store.get('hidden') === '1',
  };
  if (state.view !== 'grid') state.view = 'list';

  function compare(a, b) {
    if (a.dir !== b.dir) return a.dir ? -1 : 1;
    let r = 0;
    if (state.sort === 'date') r = a.mtime - b.mtime;
    else if (state.sort === 'size') r = a.size - b.size;
    else if (state.sort === 'type') r = collator.compare(a.type, b.type);
    if (r === 0) r = collator.compare(a.name, b.name);
    return state.desc ? -r : r;
  }

  function sort() {
    const frag = doc.createDocumentFragment();
    items.slice().sort(compare).forEach((i) => frag.appendChild(i.el));
    list.appendChild(frag);
    $('#sort').value = state.sort;
    const dir = $('#sort-dir');
    dir.classList.toggle('desc', state.desc);
    dir.title = state.desc ? 'Descending' : 'Ascending';
    $$('.files-head [data-sort]').forEach((b) => {
      if (b.dataset.sort === state.sort) b.setAttribute('aria-sort', state.desc ? 'descending' : 'ascending');
      else b.removeAttribute('aria-sort');
    });
  }

  function filter() {
    let shown = 0;
    for (const i of items) {
      const visible = !state.q || i.key.includes(state.q);
      i.el.hidden = !visible;
      if (visible && (!i.hidden || state.showHidden)) shown++;
    }
    const none = shown === 0 && items.length > 0;
    files.hidden = none;
    const noMatch = $('#no-match');
    noMatch.hidden = !none;
    if (none) {
      $('h2', noMatch).textContent = state.q ? 'No matches' : 'Nothing to show';
      $('p', noMatch).textContent = state.q ? `Nothing in this folder matches “${search.value.trim()}”.` : 'This folder only has hidden items.';
    }
    if (state.view === 'grid') loadVideoPreviews();
  }

  function setView(view) {
    state.view = view;
    files.dataset.view = view;
    $$('[data-view-btn]').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.viewBtn === view)));
    if (view === 'grid') loadVideoPreviews();
  }

  function setSort(key, desc) {
    state.sort = key;
    state.desc = desc == null ? key === 'date' || key === 'size' : desc;
    store.set('sort', key);
    store.set('desc', state.desc ? '1' : '0');
    sort();
  }

  $('#sort').addEventListener('change', (e) => setSort(e.target.value));
  $('#sort-dir').addEventListener('click', () => setSort(state.sort, !state.desc));
  $$('.files-head [data-sort]').forEach((b) => b.addEventListener('click', () => {
    const key = b.dataset.sort;
    setSort(key, key === state.sort ? !state.desc : null);
  }));
  $$('[data-view-btn]').forEach((b) => b.addEventListener('click', () => {
    store.set('view', b.dataset.viewBtn);
    setView(b.dataset.viewBtn);
  }));

  const hiddenToggle = $('#toggle-hidden');
  function applyHidden() {
    files.classList.toggle('show-hidden', state.showHidden);
    if (hiddenToggle) hiddenToggle.textContent = state.showHidden ? 'Hide' : 'Show';
    filter();
  }
  hiddenToggle?.addEventListener('click', () => {
    state.showHidden = !state.showHidden;
    store.set('hidden', state.showHidden ? '1' : '0');
    applyHidden();
  });

  const search = $('#q');
  const clear = $('#q-clear');
  const key = $('#q-key');
  search.addEventListener('input', () => {
    state.q = fold(search.value.trim());
    clear.hidden = !search.value;
    key.hidden = !!search.value;
    filter();
  });
  search.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      if (search.value) { search.value = ''; search.dispatchEvent(new Event('input')); }
      else search.blur();
    }
  });
  clear.addEventListener('click', () => {
    search.value = '';
    search.dispatchEvent(new Event('input'));
    search.focus();
  });

  // Video frames as previews in the grid, loaded as they scroll into view.
  const observer = 'IntersectionObserver' in window
    ? new IntersectionObserver((entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          observer.unobserve(entry.target);
          attachVideo(byEl.get(entry.target));
        }
      }, { rootMargin: '300px' })
    : null;
  function loadVideoPreviews() {
    if (!observer) return;
    for (const i of items) {
      if (i.kind === 'video' && !i.observed && !i.el.hidden) {
        i.observed = true;
        observer.observe(i.el);
      }
    }
  }
  function attachVideo(i) {
    const video = make('video', 'preview');
    video.muted = true;
    video.playsInline = true;
    video.preload = 'metadata';
    video.setAttribute('aria-hidden', 'true');
    video.addEventListener('loadeddata', () => video.classList.add('ready'), { once: true });
    video.addEventListener('error', () => video.remove(), { once: true });
    video.src = i.href + '#t=0.5';
    $('.thumb', i.el).appendChild(video);
  }

  // Viewer for photos, videos and music.
  const viewer = $('#viewer');
  const stage = $('#v-stage');
  let gallery = [];
  let current = -1;
  let opener = null;

  const viewable = (i) => !!i.view && !i.el.hidden && (!i.hidden || state.showHidden);
  function openViewer(item, push) {
    gallery = $$('.entry', list).map((el) => byEl.get(el)).filter(viewable);
    current = gallery.indexOf(item);
    if (current < 0) return;
    opener = doc.activeElement;
    viewer.hidden = false;
    doc.body.style.overflow = 'hidden';
    show();
    const hash = '#' + encodeURIComponent(item.name);
    if (push) history.pushState({ viewer: true }, '', hash);
    viewer.focus({ preventScroll: true });
  }

  function closeViewer(fromHistory) {
    if (viewer.hidden) return;
    viewer.hidden = true;
    stage.textContent = '';
    doc.body.style.overflow = '';
    if (!fromHistory) {
      if (history.state && history.state.viewer) history.back();
      else history.replaceState(null, '', location.pathname + location.search);
    }
    if (opener && opener.focus) opener.focus({ preventScroll: true });
  }

  function step(delta) {
    if (gallery.length < 2) return;
    current = (current + delta + gallery.length) % gallery.length;
    show();
    history.replaceState(history.state, '', '#' + encodeURIComponent(gallery[current].name));
  }

  function show() {
    const item = gallery[current];
    $('#v-name').textContent = item.name;
    const meta = item.size ? formatSize(item.size) : '';
    $('#v-count').textContent = gallery.length > 1 ? `${current + 1} of ${gallery.length}` + (meta ? ' · ' + meta : '') : meta;
    $('#v-open').href = item.href;
    $('#v-dl').href = item.href + '?download';
    $('#v-prev').hidden = $('#v-next').hidden = gallery.length < 2;
    stage.textContent = '';
    if (item.view === 'image') {
      const spinner = make('div', 'spinner');
      const img = new Image();
      img.alt = item.name;
      img.decoding = 'async';
      img.addEventListener('load', () => spinner.remove(), { once: true });
      img.addEventListener('error', () => failed(item), { once: true });
      img.src = item.el.dataset.full || item.href;
      stage.append(spinner, img);
      for (const d of [1, -1]) {
        const next = gallery[(current + d + gallery.length) % gallery.length];
        if (next && next.view === 'image') new Image().src = next.el.dataset.full || next.href;
      }
    } else if (item.view === 'video') {
      const video = make('video');
      video.controls = true;
      video.autoplay = true;
      video.playsInline = true;
      video.addEventListener('error', () => failed(item), { once: true });
      video.src = item.href;
      stage.append(video);
    } else {
      const card = make('div', 'audio-card');
      const icon = $('.ic', item.el).cloneNode();
      icon.className = '';
      const audio = make('audio');
      audio.controls = true;
      audio.autoplay = true;
      audio.addEventListener('error', () => failed(item), { once: true });
      audio.src = item.href;
      card.append(icon, make('strong', '', item.name), audio);
      stage.append(card);
    }
  }

  function failed(item) {
    if (gallery[current] !== item || viewer.hidden) return;
    stage.textContent = '';
    const box = make('div', 'viewer-error');
    box.innerHTML = svg('circle-alert');
    const link = make('a', 'btn btn-primary');
    link.href = item.href + '?download';
    link.setAttribute('download', '');
    link.innerHTML = svg('download') + 'Download';
    box.append(make('p', '', 'This file can’t be played in the browser.'), link);
    stage.append(box);
  }

  list.addEventListener('click', (e) => {
    const link = e.target.closest('a.open');
    if (!link || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    const item = byEl.get(link.closest('.entry'));
    if (item && item.view) {
      e.preventDefault();
      openViewer(item, true);
    }
  });
  $('#v-close').addEventListener('click', () => closeViewer(false));
  $('#v-prev').addEventListener('click', () => step(-1));
  $('#v-next').addEventListener('click', () => step(1));
  stage.addEventListener('click', (e) => { if (e.target === stage) closeViewer(false); });
  let swipe = null;
  stage.addEventListener('pointerdown', (e) => {
    swipe = e.pointerType !== 'mouse' && gallery[current]?.view === 'image' ? { x: e.clientX, y: e.clientY } : null;
  });
  stage.addEventListener('pointercancel', () => { swipe = null; });
  stage.addEventListener('pointerup', (e) => {
    if (!swipe) return;
    const dx = e.clientX - swipe.x;
    const dy = e.clientY - swipe.y;
    swipe = null;
    if (Math.abs(dx) > 48 && Math.abs(dx) > Math.abs(dy) * 1.5) step(dx < 0 ? 1 : -1);
  });
  window.addEventListener('popstate', () => {
    if (!viewer.hidden) closeViewer(true);
    else openFromHash();
  });
  function openFromHash() {
    if (location.hash.length < 2) return;
    let name;
    try { name = decodeURIComponent(location.hash.slice(1)); } catch (e) { return; }
    const item = items.find((i) => i.name === name && i.view);
    if (item) openViewer(item, false);
  }

  doc.addEventListener('keydown', (e) => {
    if (!viewer.hidden) {
      if (e.key === 'Escape') closeViewer(false);
      else if (e.key === 'ArrowLeft') step(-1);
      else if (e.key === 'ArrowRight') step(1);
      else return;
      e.preventDefault();
      return;
    }
    const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(e.target.tagName) || e.target.isContentEditable;
    if (e.key === '/' && !typing && !e.metaKey && !e.ctrlKey && !e.altKey) {
      e.preventDefault();
      search.focus();
      search.select();
    }
  });

  setView(state.view);
  sort();
  applyHidden();
  openFromHash();

  function setUpUploads() {
    const picker = $('#picker');
    $('#upload-btn')?.addEventListener('click', () => picker.click());
    picker?.addEventListener('change', () => {
      upload(Array.from(picker.files || []));
      picker.value = '';
    });
    const zone = $('#dropzone');
    let depth = 0;
    const hasFiles = (e) => !!e.dataTransfer && Array.from(e.dataTransfer.types || []).includes('Files');
    window.addEventListener('dragenter', (e) => {
      if (!hasFiles(e)) return;
      e.preventDefault();
      depth++;
      zone.hidden = false;
    });
    window.addEventListener('dragover', (e) => {
      if (!hasFiles(e)) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = 'copy';
    });
    window.addEventListener('dragleave', (e) => {
      if (!hasFiles(e)) return;
      depth = Math.max(0, depth - 1);
      if (!depth) zone.hidden = true;
    });
    window.addEventListener('drop', (e) => {
      if (!hasFiles(e)) return;
      e.preventDefault();
      depth = 0;
      zone.hidden = true;
      upload(Array.from(e.dataTransfer.files || []));
    });
  }

  function upload(fileList) {
    if (!fileList.length) return;
    const panel = uploadPanel();
    for (const file of fileList) {
      const row = make('li');
      const status = make('span', 'up-status', 'Waiting');
      const bar = make('span', 'bar');
      bar.appendChild(make('span'));
      row.append(make('span', 'up-name', file.name), status, bar);
      $('ul', panel).appendChild(row);
      uploads.queue.push({ file, row, status, fill: bar.firstChild });
      uploads.total++;
    }
    updatePanel();
    pump();
  }

  function uploadPanel() {
    if (uploads.panel) return uploads.panel;
    const panel = make('section', 'uploads');
    panel.setAttribute('aria-live', 'polite');
    panel.innerHTML = '<div class="uploads-head"><strong></strong></div><ul></ul>';
    doc.body.appendChild(panel);
    uploads.panel = panel;
    return panel;
  }
  function updatePanel() {
    const { panel, done, failed, total, active, queue } = uploads;
    const busy = active > 0 || queue.length > 0;
    const head = $('.uploads-head', panel);
    $('strong', head).textContent = busy
      ? `Uploading ${done + failed + 1} of ${total}`
      : failed ? `${done} uploaded, ${failed} failed` : `${done} ${done === 1 ? 'file' : 'files'} uploaded`;
    $$('.btn', head).forEach((b) => b.remove());
    if (!busy) {
      const refresh = make('button', 'btn btn-outline');
      refresh.type = 'button';
      refresh.innerHTML = svg('refresh-cw') + 'Refresh';
      refresh.addEventListener('click', () => location.reload());
      const close = make('button', 'btn btn-ghost btn-icon');
      close.type = 'button';
      close.setAttribute('aria-label', 'Close');
      close.innerHTML = svg('x');
      close.addEventListener('click', () => {
        panel.remove();
        Object.assign(uploads, { panel: null, done: 0, failed: 0, total: 0 });
      });
      head.append(refresh, close);
    }
  }
  function pump() {
    while (uploads.active < 2 && uploads.queue.length) {
      const job = uploads.queue.shift();
      uploads.active++;
      send(job).then(() => {
        uploads.active--;
        updatePanel();
        if (uploads.active === 0 && uploads.queue.length === 0) finished();
        else pump();
      });
    }
  }
  function send(job) {
    return new Promise((resolve) => {
      const xhr = new XMLHttpRequest();
      xhr.open('POST', location.pathname + '?upload');
      xhr.setRequestHeader('X-File-Name', encodeURIComponent(job.file.name));
      xhr.setRequestHeader('Content-Type', 'application/octet-stream');
      job.status.textContent = '0%';
      xhr.upload.addEventListener('progress', (e) => {
        if (!e.lengthComputable) return;
        const share = e.total ? e.loaded / e.total : 1;
        job.fill.style.width = (share * 100).toFixed(1) + '%';
        job.status.textContent = `${formatSize(e.loaded)} of ${formatSize(e.total)}`;
      });
      const fail = (message) => {
        uploads.failed++;
        job.row.className = 'error';
        job.fill.style.width = '100%';
        job.status.textContent = message;
        resolve();
      };
      xhr.addEventListener('load', () => {
        if (xhr.status === 201) {
          uploads.done++;
          job.row.className = 'done';
          job.fill.style.width = '100%';
          job.status.textContent = 'Done';
          resolve();
          return;
        }
        let message = 'Failed';
        try { message = JSON.parse(xhr.responseText).error || message; } catch (e) {}
        fail(message);
      });
      xhr.addEventListener('error', () => fail('Connection lost'));
      xhr.addEventListener('abort', () => fail('Cancelled'));
      xhr.send(job.file);
    });
  }
  function finished() {
    if (uploads.done && !uploads.failed) setTimeout(() => location.reload(), 900);
  }
})();
''';
