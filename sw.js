/* 맞수 서비스 워커: 한 번 열면 오프라인에서도 실행. 배포 때마다 VERSION만 올리세요. */
const VERSION='matsu-v0.6.0';
const CORE=['./','index.html','config.js','manifest.webmanifest','icons/icon.svg','icons/icon-192.png','icons/icon-512.png'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(VERSION).then(c=>c.addAll(CORE)).then(()=>self.skipWaiting()))});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==VERSION).map(k=>caches.delete(k)))).then(()=>self.clients.claim()))});
self.addEventListener('fetch',e=>{
  const r=e.request;if(r.method!=='GET')return;
  const u=new URL(r.url);
  if(u.origin!==location.origin)return;               /* 폰트 등 외부 요청은 건드리지 않음 */
  e.respondWith(fetch(r).then(res=>{                  /* 네트워크 우선, 실패하면 캐시 */
    const copy=res.clone();caches.open(VERSION).then(c=>c.put(r,copy)).catch(()=>{});return res
  }).catch(()=>caches.match(r).then(m=>m||caches.match('index.html'))));
});
