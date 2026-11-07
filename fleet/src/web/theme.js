// The two files the dashboard shares with every page. They are served from
// memory with a one-year cache and a version query, so a browser fetches them
// once per deploy and never revalidates them.

'use strict';

const CSS = `
:root{
  --bg:#fbfbfc; --panel:#ffffff; --ink:#16181d; --muted:#5d6472; --line:#e4e6ec;
  --accent:#f2763f; --accent-ink:#ffffff; --ok:#1f9d55; --warn:#c2740a; --bad:#cc3340;
  --code:#f2f3f6; --radius:10px;
}
@media (prefers-color-scheme: dark){
  :root{
    --bg:#0e0f12; --panel:#16181d; --ink:#e8eaee; --muted:#98a0ae; --line:#262a32;
    --code:#1d2027; --ok:#3ecf7a; --warn:#e0a33a; --bad:#ff6b76;
  }
}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{
  margin:0; background:var(--bg); color:var(--ink);
  font:15px/1.55 ui-sans-serif,-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;
  font-variant-numeric:tabular-nums;
}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
code,kbd,pre{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.86em}
pre{background:var(--code);border:1px solid var(--line);border-radius:8px;padding:.7rem .8rem;overflow:auto}
code{background:var(--code);border-radius:4px;padding:.08em .3em}
pre code{background:none;padding:0}
header.top{
  position:sticky;top:0;z-index:5;background:var(--panel);border-bottom:1px solid var(--line);
  display:flex;align-items:center;gap:1rem;padding:.6rem 1rem;flex-wrap:wrap;
}
header.top .brand{display:flex;align-items:center;gap:.55rem;font-weight:650;letter-spacing:.01em}
header.top .brand svg{width:20px;height:20px;color:var(--accent)}
header.top nav{display:flex;gap:.15rem;flex-wrap:wrap;margin-left:.5rem}
header.top nav a{padding:.32rem .6rem;border-radius:7px;color:var(--muted);font-weight:520}
header.top nav a:hover{background:var(--code);text-decoration:none;color:var(--ink)}
header.top nav a.active{background:var(--code);color:var(--ink)}
header.top .spacer{margin-left:auto}
header.top form{display:inline}
main{max-width:1080px;margin:0 auto;padding:1.4rem 1rem 4rem}
h1{font-size:1.45rem;margin:.2rem 0 1rem;letter-spacing:-.01em}
h2{font-size:1.08rem;margin:1.6rem 0 .6rem}
h3{font-size:.96rem;margin:1.2rem 0 .4rem}
p{margin:.5rem 0}
.muted{color:var(--muted)}
.small{font-size:.85rem}
.grid{display:grid;gap:.8rem;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));margin-bottom:1rem}
.stat{background:var(--panel);border:1px solid var(--line);border-radius:var(--radius);padding:.8rem .9rem}
.stat span{display:block;color:var(--muted);font-size:.78rem;text-transform:uppercase;letter-spacing:.04em}
.stat b{display:block;font-size:1.4rem;font-weight:650;margin-top:.15rem}
.panel{background:var(--panel);border:1px solid var(--line);border-radius:var(--radius);padding:1rem;margin:1rem 0}
table{width:100%;border-collapse:collapse}
th,td{text-align:left;padding:.5rem .4rem;border-bottom:1px solid var(--line);vertical-align:top}
th{font-size:.76rem;text-transform:uppercase;letter-spacing:.05em;color:var(--muted);font-weight:600}
tr:last-child td{border-bottom:0}
td.num,th.num{text-align:right}
.dot{display:inline-block;width:.55rem;height:.55rem;border-radius:50%;margin-right:.4rem;vertical-align:middle;background:var(--muted)}
.dot.online{background:var(--ok)}
.dot.offline{background:var(--bad)}
.dot.mining{background:var(--ok);box-shadow:0 0 0 3px color-mix(in srgb,var(--ok) 22%,transparent)}
.dot.warn{background:var(--warn)}
.tag{display:inline-block;font-size:.72rem;font-weight:650;padding:.06em .45em;border-radius:999px;border:1px solid var(--line);color:var(--muted);background:var(--code)}
.tag.on{color:var(--ok);border-color:color-mix(in srgb,var(--ok) 40%,var(--line))}
.tag.bad{color:var(--bad);border-color:color-mix(in srgb,var(--bad) 45%,var(--line));cursor:help}
.forms{display:grid;gap:1rem;grid-template-columns:repeat(auto-fit,minmax(260px,1fr))}
label{display:block;font-size:.82rem;color:var(--muted);margin-bottom:.2rem}
input,select,button{font:inherit;color:inherit}
input,select{
  width:100%;background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:.47rem .55rem;
}
input:focus,select:focus{outline:2px solid color-mix(in srgb,var(--accent) 45%,transparent);outline-offset:1px}
button{
  background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:.44rem .8rem;cursor:pointer;
  font-weight:560;
}
button:hover{border-color:var(--accent);color:var(--accent)}
button.primary{background:var(--accent);border-color:var(--accent);color:var(--accent-ink)}
button.primary:hover{filter:brightness(.95);color:var(--accent-ink)}
button.danger{color:var(--bad);border-color:color-mix(in srgb,var(--bad) 40%,var(--line))}
button.danger:hover{background:var(--bad);color:#fff;border-color:var(--bad)}
.actions{display:flex;gap:.5rem;flex-wrap:wrap;margin:.6rem 0}
form.inline{display:flex;gap:.4rem;align-items:center;margin:0}
input.narrow{width:5.5rem}
.flash{border-left:3px solid var(--ok);background:var(--panel);padding:.6rem .8rem;border-radius:6px;margin:0 0 1rem}
.flash.bad{border-color:var(--bad)}
.kv{display:grid;grid-template-columns:max-content 1fr;gap:.35rem 1rem;margin:.4rem 0}
.kv dt{color:var(--muted)}
.kv dd{margin:0}
.queue{list-style:none;margin:.3rem 0;padding:0}
.queue li{padding:.28rem 0;border-bottom:1px dashed var(--line);font-size:.88rem}
footer{max-width:1080px;margin:0 auto;padding:0 1rem 2rem;color:var(--muted);font-size:.82rem}
.empty{color:var(--muted);padding:1rem 0}
@media (max-width:640px){
  main{padding:1rem .7rem 3rem}
  .grid{grid-template-columns:repeat(2,minmax(0,1fr))}
  header.top{padding:.5rem .7rem}
}
@media print{header.top,footer,.actions,button{display:none}}
`;

// Progressive enhancement only: a copy button for the copy-paste blocks on the
// enrolment and download pages. Nothing on the dashboard needs JavaScript, and
// the CSP allows no third-party script at all.
const JS = `
(function(){
  function copy(text, button){
    var done = function(){ button.textContent = 'copied'; setTimeout(function(){ button.textContent = 'copy'; }, 1200); };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done);
      return;
    }
    var area = document.createElement('textarea');
    area.value = text; document.body.appendChild(area); area.select();
    try { document.execCommand('copy'); done(); } catch (e) {}
    document.body.removeChild(area);
  }
  document.addEventListener('click', function(event){
    var button = event.target.closest('[data-copy]');
    if (!button) return;
    event.preventDefault();
    var value = button.getAttribute('data-copy');
    if (value === 'previous') {
      var pre = button.previousElementSibling;
      value = pre ? pre.textContent : '';
    }
    if (value) copy(value, button);
  });
})();
`;

module.exports = { CSS, JS };
