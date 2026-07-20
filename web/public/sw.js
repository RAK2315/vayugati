// Deliberately minimal (Phase 12): a real offline-asset app shell / precache
// is out of scope for this pass - this file exists only to satisfy the
// browser's PWA installability criteria (a fetch handler is part of that
// check on Chrome/Android), which reduces IndexedDB storage-eviction risk
// for the offline mission queue (lib/offlineSync.ts) on installed/high-
// engagement origins. It never caches anything and never serves a response
// the network didn't provide - a network failure here fails exactly like a
// normal fetch would, never a silently stale cached page.
self.addEventListener('fetch', (event) => {
  event.respondWith(fetch(event.request))
})
