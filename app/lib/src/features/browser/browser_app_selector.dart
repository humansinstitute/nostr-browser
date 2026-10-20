import '../../theme/browser_palette.dart';
import 'browser_bookmark_store.dart';

String _escape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

String browserAppSelectorHtml(
    {required List<BrowserBookmark> savedBookmarks,
    String? builtInUrl,
    String? backgroundImage,
    String labelColour = '#ffffff'}) {
  final cards = savedBookmarks.map((app) {
    final builtIn = app.url == builtInUrl;
    final thumbnail = app.thumbnail;
    return '''<article class="app">
      <button class="app-open" data-url="${_escape(app.url)}" aria-label="Open ${_escape(app.title)}">
        <span class="icon" aria-hidden="true"><span class="fallback">${builtIn ? '✦' : _escape(app.title.isEmpty ? '?' : String.fromCharCode(app.title.runes.first).toUpperCase())}</span>${thumbnail == null || builtIn ? '' : '<img src="${_escape(thumbnail)}" alt="" referrerpolicy="no-referrer">'}</span>
        <span class="name">${_escape(app.title)}</span>
      </button>
      <button class="star edit-control" data-url="${_escape(app.url)}" aria-label="Open ${_escape(app.title)} on startup" aria-pressed="${app.startup}" title="Open on startup">${app.startup ? '★' : '☆'}</button>
      ${builtIn ? '' : '<button class="remove edit-control" data-url="${_escape(app.url)}" aria-label="Remove ${_escape(app.title)}" title="Remove app">×</button><button class="edit edit-control" data-url="${_escape(app.url)}" aria-label="Edit ${_escape(app.title)}">Edit</button>'}
    </article>''';
  }).join('\n');
  final background = safeBookmarkImage(backgroundImage);
  return '''<!doctype html><html><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: http://localhost:* http://127.0.0.1:* http://[::1]:* data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'none'; base-uri 'none'; form-action 'none'">
<title>Nostr Browser New Tab</title>
<style>
:root {font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#19382f;background:#e4eee6;color-scheme:light}
* {box-sizing:border-box} body {margin:0;min-height:100vh;background:linear-gradient(145deg,#dbe8dd,#e9ede2 55%,#c5dbd5);${background == null ? '' : 'background-image:linear-gradient(#edf4e755,#edf4e755),url("${_escape(background)}");background-size:cover;background-position:center;background-attachment:fixed;'}}
main {max-width:1056px;margin:auto;padding:88px 24px 32px}
.settings {position:fixed;top:16px;right:16px;z-index:2;border:1px solid #ffffff88;border-radius:50%;width:44px;height:44px;font-size:24px;color:white;background:#19382f99;box-shadow:0 2px 8px #0006;cursor:pointer}
.grid {display:grid;grid-template-columns:repeat(auto-fill,minmax(148px,1fr));gap:28px 20px;align-items:start}
.app {position:relative;text-align:center;min-width:0;padding:8px}
button {font:inherit} .app-open {border:0;background:transparent;color:inherit;display:flex;flex-direction:column;align-items:center;gap:12px;width:100%;min-height:164px;padding:0 4px 8px;cursor:pointer;border-radius:16px}
.icon {position:relative;width:116px;height:116px;display:grid;place-items:center;font-size:48px;font-weight:600;flex-shrink:0}
.fallback {width:100%;height:100%;display:grid;place-items:center;border-radius:24px;background:#19382fcc;color:white;box-shadow:0 3px 12px #0005}
.icon img {position:absolute;width:100%;height:100%;object-fit:contain;border-radius:20px}.icon:has(img) .fallback {visibility:hidden}
.name {color:${safeLabelColour(labelColour)};text-shadow:0 2px 4px #000,0 0 10px #0009;font-size:14px;font-weight:500;line-height:1.35;overflow-wrap:anywhere;width:100%}
.app-open:hover .icon {filter:brightness(1.08)} button:focus-visible {outline:3px solid white;outline-offset:3px}
.edit-control {display:none;cursor:pointer} .editing .edit-control {display:inline-block} .remove {position:absolute;top:-16px;right:-16px;width:44px;height:44px;border-radius:50%;border:0;background:radial-gradient(circle,#fff5f2 13px,transparent 14px);color:#843c33;font-size:22px;line-height:20px}.remove::after {content:"";position:absolute;inset:8px;border:1px solid #d9b5af;border-radius:50%;pointer-events:none}.edit {border:1px solid #a4c3b0;border-radius:20px;padding:5px 20px;background:#e6f1e9;color:#245447;min-height:44px}
.star {position:absolute;top:-12px;left:-12px;width:44px;height:44px;border-radius:50%;border:1px solid #ffffff88;background:#19382fcc;color:#ffe29a;font-size:26px}.star[aria-pressed="true"] {color:#ffd45b}
#settings-panel {margin-bottom:24px;padding:16px;border-radius:16px;background:#ffffffeb;display:flex;align-items:center;gap:12px;flex-wrap:wrap} #settings-panel[hidden] {display:none} #settings-panel button {background:#fff;border:1px solid #abc2b7;border-radius:20px;padding:8px 16px;cursor:pointer}
@media(max-width:420px) {main {padding:76px 16px}.grid {grid-template-columns:repeat(2,minmax(0,1fr));gap:16px}.app-open {min-height:160px}.icon {width:100px;height:100px}}
${'''
/* Shared brand tokens; the landscape and custom app imagery remain intact. */
:root {${BrowserPalette.cssVariables};color:var(--ink);background:var(--frame)}
body {background-color:var(--frame);background-image:linear-gradient(145deg,#291c3d,#513568 55%,#7040aa);${background == null ? '' : 'background-image:linear-gradient(#291c3d33,#291c3d33),url("${_escape(background)}");'}}
.settings {background:var(--frame);color:var(--lavender);border-color:var(--outline);border-radius:8px;box-shadow:3px 3px 0 #291c3d66}
.fallback {background:var(--active);color:var(--lavender);border:1px solid var(--outline);border-radius:8px;box-shadow:4px 4px 0 #291c3d99}
.app-open {border-radius:8px}
.app-open:hover {background:#291c3d55}.app-open:hover .fallback {background:var(--purple)}
button:focus-visible,input:focus-visible {outline:3px solid var(--orange);outline-offset:3px}
.edit {background:var(--paper);color:var(--ink);border-color:var(--outline);border-radius:6px}
.star {background:var(--frame);color:var(--lavender);border-color:var(--outline)}.star[aria-pressed="true"] {color:var(--orange)}
#settings-panel {background:var(--paper);border:1px solid var(--outline);border-radius:8px;box-shadow:4px 4px 0 #291c3d66}
#settings-panel button {background:var(--paper);color:var(--ink);border-color:var(--outline);border-radius:6px}
#settings-panel button:hover,.edit:hover {background:#ebddf8}
main>p {background:var(--paper);color:var(--ink);padding:16px;border-radius:8px}
'''}
</style></head><body><main>
<button class="settings" aria-label="Edit apps and background" aria-expanded="false" aria-controls="settings-panel">⚙</button>
<div id="settings-panel" hidden><span>Edit your saved apps</span><button data-action="chooseBackground">Choose background</button><button data-action="resetBackground">Default background</button><label>Label colour <input id="label-colour" type="color" value="${safeLabelColour(labelColour)}"></label></div>
<section class="grid" aria-label="Saved apps">$cards</section>
${savedBookmarks.isEmpty ? '<p>No saved apps yet. Use Add bookmark from the browser menu.</p>' : ''}
</main><script>(() => {
let seq=0;
const send=(method,params) => {if(window.WingmanSigner)window.WingmanSigner.postMessage(JSON.stringify({id:'home-tab-'+(++seq),method,params}));};
document.getElementById('label-colour').addEventListener('change',event=>{
 const colour=event.target.value;if(!/^#[0-9a-fA-F]{6}\$/.test(colour))return;
 document.querySelectorAll('.name').forEach(label=>label.style.color=colour);
 send('setLabelColour',{colour});
});
document.querySelectorAll('.icon img').forEach(img => img.addEventListener('error', () => img.remove()));
document.addEventListener('click', event => {
 const target=event.target.closest('button'); if(!target)return;
 if(target.classList.contains('settings')) {const editing=document.body.classList.toggle('editing');target.setAttribute('aria-expanded',String(editing));document.getElementById('settings-panel').hidden=!editing;return;}
 const method=target.dataset.action || (target.classList.contains('star')?'setStartup':target.classList.contains('remove')?'removeBookmark':target.classList.contains('edit')?'editBookmark':target.classList.contains('app-open')?'navigateTab':null);
 if(!method || !window.WingmanSigner)return;
 const params={url:target.dataset.url};
 if(method==='setStartup'){params.enabled=target.getAttribute('aria-pressed')!=='true';target.setAttribute('aria-pressed',String(params.enabled));target.textContent=params.enabled?'★':'☆';}
 send(method,params);
});
})();</script></body></html>''';
}

/// Metadata collection runs in the visited document's ordinary web context.
/// No native HTTP proxy, FIPS grant, authentication, or signing is introduced.
const bookmarkDiscoveryScript = r'''
(() => {
  const pageUrl=location.href;
  const endpoint=new URL(pageUrl);
  if(endpoint.hostname.endsWith('.fips'))return;
  const safe=(raw,base=pageUrl) => {
    try {const u=new URL(raw,base);return u.origin===endpoint.origin && !u.username && !u.password && !u.hostname.endsWith('.fips') ? u.href:null;} catch(_){return null;}
  };
  const publish=iconUrl => {if(iconUrl && location.href===pageUrl && window.WingmanSigner)window.WingmanSigner.postMessage(JSON.stringify({id:'app-icon-'+Date.now(),method:'bookmarkIcon',params:{url:pageUrl,iconUrl}}));};
  const links=Array.from(document.querySelectorAll('link[rel]'));
  const icon=links.find(l=>l.rel.split(/\s+/).includes('apple-touch-icon')) || links.find(l=>l.rel.split(/\s+/).includes('icon'));
  if(icon)publish(safe(icon.href));
  const manifest=links.find(l=>l.rel.split(/\s+/).includes('manifest'));
  const manifestUrl=manifest && safe(manifest.href);
  if(!manifestUrl)return;
  const controller=new AbortController();const timer=setTimeout(()=>controller.abort(),3000);
  fetch(manifestUrl,{credentials:'omit',redirect:'error',signal:controller.signal}).then(async response => {
    if(!response.ok || Number(response.headers.get('content-length'))>131072)return;
    const reader=response.body.getReader();let length=0;const chunks=[];
    while(true){const {value,done}=await reader.read();if(done)break;length+=value.length;if(length>131072){await reader.cancel();return;}chunks.push(value);}
    const data=new Uint8Array(length);let offset=0;for(const chunk of chunks){data.set(chunk,offset);offset+=chunk.length;}
    const result=JSON.parse(new TextDecoder().decode(data));
    const icons=Array.isArray(result.icons)?result.icons:[];
    const candidates=icons.filter(i=>i && typeof i.src==='string').sort((a,b)=>parseInt(b.sizes||'0')-parseInt(a.sizes||'0'));
    for(const candidate of candidates){const url=safe(candidate.src,manifestUrl);if(url){publish(url);break;}}
  }).catch(()=>{}).finally(()=>clearTimeout(timer));
})();
''';
