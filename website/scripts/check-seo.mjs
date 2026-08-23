import { access, readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { join } from 'node:path'

const dist = fileURLToPath(new URL('../dist/', import.meta.url))
const routes = ['/', '/download/', '/compatibility/', '/security/']
const fileFor = (route) => join(dist, route === '/' ? 'index.html' : `${route.slice(1)}index.html`)
for (const route of routes) {
  const file = fileFor(route)
  await access(file)
  const html = await readFile(file, 'utf8')
  if (!html.includes('<html lang="en">')) throw new Error(`${route}: missing language`)
  if (!html.includes('<link rel="canonical"')) throw new Error(`${route}: missing canonical`)
  if (!html.includes('<meta name="description"')) throw new Error(`${route}: missing description`)
  if (!html.includes('<script type="application/ld+json">')) throw new Error(`${route}: missing structured data`)
}
const sitemap = await readFile(join(dist, 'sitemap.xml'), 'utf8')
for (const route of routes) if (!sitemap.includes(`<loc>https://s3workbench.com${route}</loc>`)) throw new Error(`sitemap: missing ${route}`)
const robots = await readFile(join(dist, 'robots.txt'), 'utf8')
if (!robots.includes('Sitemap: https://s3workbench.com/sitemap.xml')) throw new Error('robots: missing sitemap')
console.log(`SEO checks passed for ${routes.length} routes`)
