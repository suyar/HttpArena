---
title: Leaderboard
layout: wide
toc: false
---

<style>
article > h1.hx\:text-center { display: none; }
article > br { display: none; }
article { max-width: 100% !important; }
</style>

<div style="margin-bottom:1.5rem;">
<h1 class="not-prose hx:text-4xl hx:font-bold hx:leading-none hx:tracking-tighter hx:md:text-5xl hx:py-2 hx:bg-clip-text hx:text-transparent hx:bg-gradient-to-r hx:from-gray-900 hx:to-gray-600 hx:dark:from-gray-100 hx:dark:to-gray-400">Leaderboard</h1>

{{< round-selector >}}

<div class="lb-card" style="margin-top:0.75rem; padding:0.35rem;">
<div id="http-version-tabs" style="display:flex; gap:0.35rem;">
<span class="http-ver active" data-ver="composite">Composite</span>
<span class="http-ver" data-ver="h1">HTTP/1.1</span>
<span class="http-ver" data-ver="h2">HTTP/2</span>
<span class="http-ver" data-ver="h3">HTTP/3</span>
</div>
</div>
<style>
.http-ver {
  flex: 1;
  text-align: center;
  padding: 0.65rem 1.2rem;
  font-size: 0.9rem;
  font-weight: 600;
  color: #64748b;
  cursor: pointer;
  border-radius: 4px;
  background: transparent;
  transition: all 0.2s ease;
  user-select: none;
  letter-spacing: -0.01em;
}
.http-ver:hover { color: #1e293b; background: rgba(255,255,255,0.5); }
.http-ver[data-ver="h1"].active { color: #1e40af; background: rgba(59,130,246,0.1); box-shadow: 0 2px 8px rgba(59,130,246,0.15), 0 1px 3px rgba(0,0,0,0.08); font-weight: 700; }
.http-ver[data-ver="h2"].active { color: #92400e; background: rgba(234,179,8,0.12); box-shadow: 0 2px 8px rgba(234,179,8,0.15), 0 1px 3px rgba(0,0,0,0.08); font-weight: 700; }
.http-ver[data-ver="h3"].active { color: #166534; background: rgba(34,197,94,0.12); box-shadow: 0 2px 8px rgba(34,197,94,0.15), 0 1px 3px rgba(0,0,0,0.08); font-weight: 700; }
.http-ver[data-ver="composite"].active { color: #9a3412; background: rgba(249,115,22,0.12); box-shadow: 0 2px 8px rgba(249,115,22,0.15), 0 1px 3px rgba(0,0,0,0.08); font-weight: 700; }
html.dark .http-ver { color: #64748b; }
html.dark .http-ver:hover { color: #94a3b8; background: rgba(255,255,255,0.03); }
html.dark .http-ver[data-ver="h1"].active { color: #60a5fa; background: rgba(59,130,246,0.15); }
html.dark .http-ver[data-ver="h2"].active { color: #fbbf24; background: rgba(234,179,8,0.15); }
html.dark .http-ver[data-ver="h3"].active { color: #4ade80; background: rgba(34,197,94,0.15); }
html.dark .http-ver[data-ver="composite"].active { color: #fb923c; background: rgba(249,115,22,0.15); }
</style>
<script>
(function() {
  var tabs = document.querySelectorAll('.http-ver');
  tabs.forEach(function(tab) {
    tab.addEventListener('click', function() {
      tabs.forEach(function(t) { t.classList.remove('active'); });
      tab.classList.add('active');
      var ver = tab.dataset.ver;
      document.getElementById('lb-wrapper').style.display = ver === 'h1' ? '' : 'none';
      document.getElementById('lb-h2-wrapper').style.display = ver === 'h2' ? '' : 'none';
      document.getElementById('lb-h3-wrapper').style.display = ver === 'h3' ? '' : 'none';
      document.getElementById('lb-composite-wrapper').style.display = ver === 'composite' ? '' : 'none';
    });
  });
})();
</script>
</div>

<div id="lb-wrapper" style="display:none;">
{{< leaderboard >}}
</div>

<div id="lb-h2-wrapper" style="display:none;">
{{< leaderboard-h2 >}}
</div>

<div id="lb-h3-wrapper" style="display:none;">
<div style="margin-top:1rem; border:1.5px solid rgba(234,179,8,0.3); border-radius:0.75rem; background:linear-gradient(135deg, rgba(234,179,8,0.04) 0%, rgba(251,191,36,0.08) 100%); padding:2.5rem 2rem; text-align:center;">
<div style="display:inline-flex; align-items:center; justify-content:center; width:3rem; height:3rem; border-radius:50%; background:rgba(234,179,8,0.12); margin-bottom:1rem;">
<span style="font-size:1.4rem; line-height:1;">🚧</span>
</div>
<div style="font-size:1.5rem; font-weight:700; color:#92400e; letter-spacing:-0.01em;">HTTP/3 Benchmarks</div>
<div style="display:inline-block; margin-top:0.5rem; padding:0.25rem 0.75rem; font-size:0.8rem; font-weight:600; text-transform:uppercase; letter-spacing:0.05em; border-radius:999px; background:rgba(234,179,8,0.15); color:#b45309;">Work in progress</div>
<div style="color:#64748b; margin-top:1.25rem; max-width:560px; margin-left:auto; margin-right:auto; line-height:1.7; font-size:1.05rem;">
HTTP/3 runs over <strong>QUIC</strong> (UDP-based transport with built-in TLS 1.3). We've tested both <strong>oha</strong> and <strong>h2load</strong> with QUIC support, but neither can generate enough load to saturate high-performance servers — making the results unreliable for fair comparison.
</div>
<div style="color:#94a3b8; margin-top:1.5rem; font-size:0.95rem;">
We'll add HTTP/3 benchmarks once mature load generators become available.<br>
Know of a good HTTP/3 load testing tool? <a href="https://github.com/MDA2AV/HttpArena/issues" target="_blank" rel="noreferrer" style="color:#3b82f6; text-decoration:none; font-weight:500;">Open an issue</a> and let us know!
</div>
</div>
</div>

<div id="lb-composite-wrapper">
{{< leaderboard-composite >}}
</div>
