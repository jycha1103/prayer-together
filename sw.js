// 오프라인에서도 열리도록 기본 파일을 저장해 둡니다.
const CACHE = 'prayer-together-v41';
const FILES = ['./', './index.html', './manifest.json', './icon.svg', './icon-192.png', './apple-touch-icon.png', './hero.jpg', './water.jpg', './home-bg.jpg', './home-bg1b.jpg', './home-h1.png', './home-h2.png', './home-w3.jpg', './home-pray.jpg', './home-mine.jpg', './home-rooms.jpg', './closet-door.png', './lock-gold.png', './closet-ic.png', './closet-bg.webp', './letter-hero.webp', './letter-face.webp', './letters/p0.webp', './letters/p1.webp', './letters/p2.webp', './letters/p3.webp', './letters/p4.webp', './letters/p5.webp', './letters/p6.webp', './letters/p7.webp', './letters/p8.webp', './letters/p9.webp', './letters/p10.webp', './letters/p11.webp', './letters/leafTR.webp', './pray-head.webp', './pray-foot.webp', './church-logo0.webp', './church-card.webp', './notes/n0.webp', './notes/n1.webp', './notes/n2.webp', './notes/n3.webp', './notes/n4.webp', './notes/n5.webp', './notes/n6.webp', './notes/n7.webp', './notes/n8.webp', './notes/n9.webp', './notes/n10.webp', './notes/n11.webp', './notes/m0.webp', './notes/m1.webp', './notes/m2.webp', './notes/m3.webp', './notes/m4.webp', './notes/m5.webp', './notes/m6.webp', './notes/m7.webp', './notes/m8.webp', './notes/m9.webp', './notes/m10.webp', './notes/m11.webp', './fonts/MaruBuri-Light.woff2', './fonts/MaruBuri-Regular.woff2', './fonts/MaruBuri-Bold.woff2', './config.js', './vendor/supabase.js'];
self.addEventListener('install', e => e.waitUntil(caches.open(CACHE).then(c => c.addAll(FILES))));
self.addEventListener('activate', e => e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))));
self.addEventListener('fetch', e => {
  const u = new URL(e.request.url);
  // 음악은 조금씩 나눠 받아서 저장하지 않고 바로 들려줘요
  if (e.request.method !== 'GET' || u.origin !== location.origin || u.pathname.indexOf('/music/') >= 0) return;
  // 고친 내용이 바로 보이도록 매번 서버에 새 버전이 있는지 물어봐요
  e.respondWith(fetch(e.request, { cache: 'no-cache' }).then(r => { const copy = r.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); return r; }).catch(() => caches.match(e.request)));
});
