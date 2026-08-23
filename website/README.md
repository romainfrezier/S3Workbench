# S3Workbench website

English React/Vite marketing site for S3Workbench. The build prerenders the
home, download, compatibility and security routes, then generates `sitemap.xml`
and `robots.txt`.

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
