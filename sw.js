const CACHE_NAME = 'simple-study-v1';
const APP_SHELL = ['./', './index.html', './manifest.json', './icon.svg'];

self.addEventListener('install', event => {
    event.waitUntil(caches.open(CACHE_NAME).then(cache => cache.addAll(APP_SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', event => {
    event.waitUntil(
        caches.keys()
            .then(keys => Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k))))
            .then(() => self.clients.claim())
    );
});

// Network-first for the page itself, so the live app is always used when online and a stale cached copy
// only ever shows up with no connection at all (letting a reload offline still open to cached flashcard
// data in localStorage, instead of the browser's own offline error page). Everything else (CDN scripts,
// fonts) is cache-first with a background revalidation fetch.
self.addEventListener('fetch', event => {
    const req = event.request;
    if (req.method !== 'GET') return;

    if (req.mode === 'navigate' || req.destination === 'document') {
        event.respondWith(
            fetch(req)
                .then(res => { const copy = res.clone(); caches.open(CACHE_NAME).then(c => c.put(req, copy)); return res; })
                .catch(() => caches.match('./index.html'))
        );
        return;
    }

    event.respondWith(
        caches.match(req).then(cached => {
            const fetchPromise = fetch(req)
                .then(res => { if (res.ok) { const copy = res.clone(); caches.open(CACHE_NAME).then(c => c.put(req, copy)); } return res; })
                .catch(() => cached);
            return cached || fetchPromise;
        })
    );
});
