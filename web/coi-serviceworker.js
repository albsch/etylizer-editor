// Cross-origin-isolation service worker, github pages recommendation

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'deregister') {
    self.registration.unregister().then(() =>
      self.clients.matchAll()).then((clients) =>
      clients.forEach((c) => c.navigate(c.url)));
  }
});

self.addEventListener('fetch', (event) => {
  const r = event.request;
  // Don't touch range requests / non-http(s) / cache-only cross-origin reads.
  if (r.cache === 'only-if-cached' && r.mode !== 'same-origin') return;

  event.respondWith(
    fetch(r).then((response) => {
      if (response.status === 0) return response;
      const headers = new Headers(response.headers);
      headers.set('Cross-Origin-Embedder-Policy', 'require-corp');
      headers.set('Cross-Origin-Opener-Policy', 'same-origin');
      headers.set('Cross-Origin-Resource-Policy', 'cross-origin');
      return new Response(response.body, {
        status: response.status,
        statusText: response.statusText,
        headers
      });
    }).catch((e) => { console.error('coi-serviceworker fetch failed', e); throw e; })
  );
});
