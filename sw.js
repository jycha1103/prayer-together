// 오프라인에서도 열리도록 기본 파일을 저장해 둡니다.
const CACHE = 'prayer-together-v3';
const FILES = ['./', './index.html', './manifest.json', './icon.svg', './config.js', './vendor/supabase.js'];
self.addEventListener('install', e => e.waitUntil(caches.open(CACHE).then(c => c.addAll(FILES))));
self.addEventListener('activate', e => e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))));
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET' || new URL(e.request.url).origin !== location.origin) return;
  // 고친 내용이 바로 보이도록 매번 서버에 새 버전이 있는지 물어봐요
  e.respondWith(fetch(e.request, { cache: 'no-cache' }).then(r => { const copy = r.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); return r; }).catch(() => caches.match(e.request)));
});
