/* =====================================================================
   Mahyra Massage — Service Worker
   Menyimpan kerangka aplikasi supaya terbuka cepat, dan menampilkan
   notifikasi saat ada penugasan baru.

   Taruh berkas ini di akar situs, sejajar dengan office.html
   dan terapis.html, agar cakupannya meliputi seluruh halaman.
   ===================================================================== */
const VERSI = 'mahyra-v3';
const INTI  = ['/logo.png', '/manifest-office.json', '/manifest-terapis.json'];

self.addEventListener('install', e => {
  self.skipWaiting();
  e.waitUntil(caches.open(VERSI).then(c => c.addAll(INTI).catch(() => {})));
});

self.addEventListener('activate', e => {
  e.waitUntil((async () => {
    const kunci = await caches.keys();
    await Promise.all(kunci.filter(k => k !== VERSI).map(k => caches.delete(k)));
    await self.clients.claim();
  })());
});

/* Jaringan didahulukan agar data selalu segar; cache dipakai bila jaringan mati. */
self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET') return;
  if (url.origin !== self.location.origin) return;          // Supabase & CDN lewat jaringan
  if (url.pathname.startsWith('/rest/') ||
      url.pathname.startsWith('/auth/')) return;

  e.respondWith((async () => {
    try {
      const jawab = await fetch(e.request);
      if (jawab && jawab.status === 200) {
        const salinan = jawab.clone();
        caches.open(VERSI).then(c => c.put(e.request, salinan));
      }
      return jawab;
    } catch (_) {
      const tersimpan = await caches.match(e.request);
      if (tersimpan) return tersimpan;
      return caches.match('/terapis') || caches.match('/office') || Response.error();
    }
  })());
});

/* Notifikasi dari halaman (dipakai portal terapis saat ada orderan baru) */
self.addEventListener('message', e => {
  const d = e.data || {};
  if (d.tipe !== 'notif') return;
  self.registration.showNotification(d.judul || 'Mahyra Massage', {
    body: d.pesan || '',
    icon: '/logo.png',
    badge: '/logo.png',
    tag: d.tag || 'mahyra',
    renotify: true,
    vibrate: [90, 60, 90],
    data: { url: d.url || '/terapis' }
  });
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const tujuan = (e.notification.data && e.notification.data.url) || '/terapis';
  e.waitUntil((async () => {
    const daftar = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of daftar) {
      if (c.url.includes(tujuan) && 'focus' in c) return c.focus();
    }
    return self.clients.openWindow(tujuan);
  })());
});
