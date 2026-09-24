import { access, readFile } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import { join } from 'node:path'

const dist = fileURLToPath(new URL('../dist/', import.meta.url))
const routes = ['/', '/download/', '/compatibility/', '/security/']
const nginx = await readFile(fileURLToPath(new URL('../dist-server/nginx.conf', import.meta.url)), 'utf8')
const fileFor = (route) => join(dist, route === '/' ? 'index.html' : `${route.slice(1)}index.html`)
for (const route of routes) {
  const file = fileFor(route)
  await access(file)
  const html = await readFile(file, 'utf8')
  if (!html.includes('<html lang="en">')) throw new Error(`${route}: missing language`)
  if (!html.includes('<link rel="canonical"')) throw new Error(`${route}: missing canonical`)
  if (!html.includes('<meta name="description"')) throw new Error(`${route}: missing description`)
  if (!html.includes('<script type="application/ld+json">')) throw new Error(`${route}: missing structured data`)
  if (/<script\b[^>]*\bsrc=/.test(html)) throw new Error(`${route}: unnecessary client JavaScript`)
  if (!html.includes('href="#main-content"') || !/<main[^>]*id="main-content"[^>]*tabindex="-1"/.test(html)) throw new Error(`${route}: missing keyboard skip target`)
  if (route !== '/') {
    const current = html.match(/<a[^>]*aria-current="page"[^>]*>/g)
    if (current?.length !== 1 || !current[0].includes(`href="${route}"`)) throw new Error(`${route}: incorrect current-page navigation`)
  }
  if (route === '/download/' && (!html.includes('id="homebrew"') || !/<pre[^>]*tabindex="0"[^>]*aria-label="Homebrew installation commands"/.test(html))) throw new Error('download: missing accessible Homebrew instructions')
  if (!html.includes('<h1')) throw new Error(`${route}: missing prerendered content`)
  if (/<link[^>]*rel="stylesheet"/.test(html)) throw new Error(`${route}: render-blocking stylesheet`)
  const css = html.match(/<style>([\s\S]*?)<\/style>/)?.[1]
  if (!css || !nginx.includes(`'sha256-${createHash('sha256').update(css).digest('base64')}'`)) throw new Error(`${route}: stylesheet blocked by CSP`)
  const logo = html.match(/<img[^>]*src="([^"]*app-icon-64[^"]*\.webp)"/)
  if (!logo) throw new Error(`${route}: missing lightweight logo`)
  if ((await readFile(join(dist, logo[1]))).length > 10_000) throw new Error(`${route}: oversized logo`)
  if (route === '/') {
    if (!html.includes('href="/download/#homebrew"')) throw new Error('home: Homebrew link must target installation instructions')
    const screenshots = html.match(/<img[^>]*srcSet="[^"]*\.webp[^>]*sizes="[^"]+"/g)
    if (screenshots?.length !== 2) throw new Error('home: missing responsive screenshots')
  }
}
const sitemap = await readFile(join(dist, 'sitemap.xml'), 'utf8')
for (const route of routes) if (!sitemap.includes(`<loc>https://s3workbench.com${route}</loc>`)) throw new Error(`sitemap: missing ${route}`)
const robots = await readFile(join(dist, 'robots.txt'), 'utf8')
if (!robots.includes('Sitemap: https://s3workbench.com/sitemap.xml')) throw new Error('robots: missing sitemap')
console.log(`SEO checks passed for ${routes.length} routes`)
