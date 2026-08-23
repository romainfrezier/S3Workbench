import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const dist = join(root, 'dist')
const baseHtml = await readFile(join(dist, 'index.html'), 'utf8')
const { render } = await import(pathToFileURL(join(root, 'dist-server', 'ssr.js')).href)
const siteUrl = (process.env.VITE_SITE_URL || 'https://s3workbench.com').replace(/\/$/, '')
const routes = ['/', '/download/', '/compatibility/', '/security/']
const metadata = {
  '/': { title: 'S3Workbench — Browse object storage like a native Mac app', description: 'A native macOS browser for S3-compatible object storage, with Finder-like navigation, recursive search and a clear metadata inspector.' },
  '/download/': { title: 'Download S3Workbench — Native S3 browser for macOS', description: 'Download S3Workbench for macOS 15 or later on Apple Silicon and browse S3-compatible storage from a focused native Mac app.' },
  '/compatibility/': { title: 'S3-compatible storage compatibility — S3Workbench', description: 'See how S3Workbench handles MinIO, AWS S3, Cloudflare R2, Wasabi, Backblaze B2 and private S3-compatible endpoints.' },
  '/security/': { title: 'Security and privacy — S3Workbench', description: 'S3Workbench keeps credentials in macOS Keychain, uses system TLS trust and redacts secrets from errors and logs.' },
}

const escapeHtml = (value) => value.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
const pages = []
for (const route of routes) {
  const { title, description } = metadata[route]
  const canonical = `${siteUrl}${route}`
  const html = baseHtml.replace('<title>S3Workbench — Browse object storage like a native Mac app</title>', `<title>${escapeHtml(title)}</title>`).replace(/<meta name="description" content="[^"]*" \/>/, `<meta name="description" content="${escapeHtml(description)}" />`).replace(/<meta property="og:title" content="[^"]*" \/>/, `<meta property="og:title" content="${escapeHtml(title)}" />`).replace(/<meta property="og:description" content="[^"]*" \/>/, `<meta property="og:description" content="${escapeHtml(description)}" />`).replace(/<meta property="og:url" content="[^"]*" \/>/, `<meta property="og:url" content="${canonical}" />`).replace(/<meta name="twitter:title" content="[^"]*" \/>/, `<meta name="twitter:title" content="${escapeHtml(title)}" />`).replace(/<meta name="twitter:description" content="[^"]*" \/>/, `<meta name="twitter:description" content="${escapeHtml(description)}" />`).replace('<head>', `<head><link rel="canonical" href="${canonical}" />`).replace('<div id="root"></div>', `<div id="root">${render(route)}</div>`)
  const target = route === '/' ? join(dist, 'index.html') : join(dist, route.slice(1), 'index.html')
  await mkdir(dirname(target), { recursive: true })
  await writeFile(target, html)
  pages.push(`<url><loc>${canonical}</loc></url>`)
}

await writeFile(join(dist, 'sitemap.xml'), `<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${pages.join('')}</urlset>`)
await writeFile(join(dist, 'robots.txt'), `User-agent: *\nAllow: /\nSitemap: ${siteUrl}/sitemap.xml\n`)
