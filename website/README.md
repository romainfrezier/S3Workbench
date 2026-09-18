# S3Workbench website

English React/Vite marketing site for S3Workbench. The build prerenders the
home, download, compatibility and security routes, then generates `sitemap.xml`
and `robots.txt`.
Production pages are static HTML with native links: React runs during the build
and in the development server, without a client JavaScript bundle on the page.
The build inlines the small stylesheet and generates `dist-server/nginx.conf`
with its CSP hash; the Docker image uses this generated configuration.

```bash
npm install
npm run dev
npm run typecheck
npm run lint
npm run build
npm run test
```

The container build uses `VITE_SITE_URL=https://s3workbench.com` and serves the
generated static site with Nginx. The image is published as
`ghcr.io/romainfrezier/s3workbench-site:<version>`.

To check a running website container (including redirects and real 404s):

```bash
node scripts/check-http.mjs http://127.0.0.1:8080
```

Pull requests run this check against the built container in CI.

The small icons in `src/media/` reuse the native app's 64px and 256px icons.
The displayed logo is a lossless WebP copy of the 64px PNG.
Responsive screenshot variants keep the original JPEGs available for full-size
viewing. Regenerate them with `cwebp` when updating the screenshots:

```bash
for name in object-browser recursive-search; do
  for width in 640 768 1229; do
    cwebp -q 85 -resize "$width" 0 "public/screenshots/$name.jpg" -o "src/media/$name-$width.webp"
  done
done
```
