// يجعل البرنامج قابلًا للتثبيت كتطبيق. يجلب أحدث نسخة من الإنترنت دائمًا، ويستخدم النسخة المحفوظة فقط لو الإنترنت مقطوع.
// لا يتدخل أبدًا في الاتصال بقاعدة البيانات (Supabase).
const C = 'qattami-shell-v2';
// نحفظ نسخة من البرنامج فور التثبيت حتى يفتح بدون إنترنت من أول مرة
self.addEventListener('install', e => { self.skipWaiting(); e.waitUntil(caches.open(C).then(c => c.add('./')).catch(() => {})); });
self.addEventListener('activate', e => e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== C).map(k => caches.delete(k)))).then(() => self.clients.claim())));
self.addEventListener('fetch', e => {
  const u = new URL(e.request.url);
  if (e.request.method !== 'GET' || u.origin !== self.location.origin) return;
  e.respondWith(fetch(e.request).then(r => { const c = r.clone(); caches.open(C).then(x => x.put(e.request, c)); return r; })
    .catch(() => caches.match(e.request).then(r => r || caches.match('./'))));
});
