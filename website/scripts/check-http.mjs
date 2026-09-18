import assert from 'node:assert/strict'

const baseUrl = process.argv[2]
assert.ok(baseUrl, 'Usage: node scripts/check-http.mjs http://127.0.0.1:8080')
const request = (path) => fetch(new URL(path, baseUrl), {
  redirect: 'manual',
  signal: AbortSignal.timeout(5000),
})

for (const path of ['/', '/download/', '/compatibility/', '/security/']) {
  const response = await request(path)
  assert.equal(response.status, 200, path)
  assert.match(response.headers.get('content-security-policy'), /script-src 'none'/, `${path}: scripts blocked`)
  assert.match(response.headers.get('content-security-policy'), /frame-ancestors 'none'/, `${path}: framing blocked`)
  assert.match(response.headers.get('content-security-policy'), /require-trusted-types-for 'script'/, `${path}: trusted types`)
  assert.equal(response.headers.get('cross-origin-opener-policy'), 'same-origin', path)
  assert.ok((await response.text()).includes(`href="https://s3workbench.com${path}"`), `${path}: canonical`)
}
for (const path of ['/download', '/compatibility', '/security']) {
  const response = await request(`${path}?source=test`)
  assert.equal(response.status, 301, path)
  assert.equal(response.headers.get('location'), `${path}/?source=test`, `${path}: relative redirect preserves HTTPS and query`)
}
for (const path of ['/missing-page', '/missing-page/', '/download/missing/', '/assets/missing.js', '/screenshots/missing.jpg']) {
  const response = await request(path)
  assert.equal(response.status, 404, path)
  assert.equal(response.headers.get('x-content-type-options'), 'nosniff', `${path}: headers on errors`)
}
for (const [path, type] of [['/robots.txt', 'text/plain'], ['/sitemap.xml', 'application/xml']]) {
  const response = await request(path)
  assert.equal(response.status, 200, path)
  assert.equal(response.headers.get('content-type'), type, `${path}: single content type`)
}
assert.equal((await request('/healthz')).status, 200)
const home = await fetch(new URL('/', baseUrl), { headers: { 'Accept-Encoding': 'gzip' } })
assert.equal(home.headers.get('content-encoding'), 'gzip', 'HTML compression')
const html = await home.text()
const assets = [...new Set(html.match(/\/assets\/[^"\s,]+\.(?:png|webp|css)/g))]
assert.ok(assets.length > 0, 'page assets')
for (const path of assets) {
  const response = await request(path)
  assert.equal(response.status, 200, path)
  assert.equal(response.headers.get('cache-control'), 'public, max-age=31536000, immutable', path)
  assert.equal(response.headers.get('x-content-type-options'), 'nosniff', `${path}: inherited headers`)
}
console.log('HTTP checks passed: routes, SEO files, compression, asset caching and security headers')
