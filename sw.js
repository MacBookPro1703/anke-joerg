// Anke & Jörg – Service Worker (Offline-Start + Push)
const CACHE = 'aj-v17';
const SHELL = ['./', './index.html', './manifest.json', './icon-192.png?v=4', './icon-512.png?v=4'];
self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const req = e.request; if (req.method !== 'GET') return;
  const u = new URL(req.url);
  if (u.hostname === 'cdn.jsdelivr.net' || u.hostname === 'cdnjs.cloudflare.com' || u.hostname.endsWith('gstatic.com') || u.hostname === 'fonts.googleapis.com') {
    e.respondWith(caches.match(req).then(r => r || fetch(req).then(res => { const c = res.clone(); caches.open(CACHE).then(ca => ca.put(req, c)); return res; })));
    return;
  }
  if (u.origin !== location.origin) return;
  e.respondWith(fetch(req, { cache:'no-store' }).then(res => { const c = res.clone(); caches.open(CACHE).then(ca => ca.put(req, c)); return res; })
    .catch(() => caches.match(req).then(r => r || caches.match('./index.html'))));
});
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data.json(); } catch (_) { d = { title: 'Anke & Jörg', body: e.data ? e.data.text() : '' }; }
  const sos = d.kind === 'sos';
  e.waitUntil(self.registration.showNotification(d.title || 'Anke & Jörg', {
    body: d.body || '', tag: d.tag || d.kind || 'aj', renotify: true,
    icon: 'icon-192.png', badge: 'icon-192.png',
    vibrate: sos ? [700, 200, 700, 200, 700, 200, 700, 200, 1500] : [200, 100, 200],
    requireInteraction: sos, data: { kind: d.kind || '' }
  }));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  e.waitUntil(clients.matchAll({ type: 'window', includeUncontrolled: true }).then(cs => {
    for (const c of cs) { if ('focus' in c) return c.focus(); }
    return clients.openWindow('./');
  }));
});
