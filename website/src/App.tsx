import './App.css'

const releaseUrl = 'https://github.com/romainfrezier/S3Workbench/releases/latest'
const githubUrl = 'https://github.com/romainfrezier/S3Workbench'
const supportUrl = 'https://buymeacoffee.com/romainfrezier'
const siteUrl = 'https://s3workbench.com'

type Page = 'home' | 'download' | 'compatibility' | 'security'

const asset = (name: string) => `${import.meta.env.BASE_URL}${name}`.replace(/\/\/+/g, '/')

function pageFromPath(pathname: string): Page {
  if (pathname.startsWith('/download')) return 'download'
  if (pathname.startsWith('/compatibility')) return 'compatibility'
  if (pathname.startsWith('/security')) return 'security'
  return 'home'
}

function Logo() {
  return <span className="brand-mark"><img src={asset('s3workbench-icon.png')} alt="" /></span>
}

function Header({ page }: { page: Page }) {
  return <header className="site-header shell">
    <a className="brand" href={asset('')} aria-label="S3Workbench home"><Logo /><span>S3Workbench</span></a>
    <nav aria-label="Main navigation">
      <a className={page === 'compatibility' ? 'active' : ''} href={asset('compatibility/')}>Compatibility</a>
      <a className={page === 'security' ? 'active' : ''} href={asset('security/')}>Security</a>
      <a href={githubUrl} target="_blank" rel="noreferrer">GitHub ↗</a>
    </nav>
    <a className="button button-small button-cyan" href={asset('download/')}>Download</a>
  </header>
}

function Footer() {
  return <footer className="site-footer shell">
    <div className="footer-brand"><Logo /><span>S3Workbench</span></div>
    <p>A native macOS browser for S3-compatible object storage.</p>
    <div className="footer-links"><a href={asset('download/')}>Download</a><a href={githubUrl} target="_blank" rel="noreferrer">GitHub ↗</a><a className="support-link" href={supportUrl} target="_blank" rel="noreferrer">Support the project ↗</a><span>MIT License</span></div>
  </footer>
}

function DownloadButton({ light = false }: { light?: boolean }) {
  return <a className={`button ${light ? 'button-light' : 'button-cyan'}`} href={releaseUrl} target="_blank" rel="noreferrer">Download latest release <span>↗</span></a>
}

function FeatureCard({ label, title, body, accent }: { label: string; title: string; body: string; accent?: string }) {
  return <article className="feature-card"><span className={`feature-label ${accent ?? ''}`}>{label}</span><h3>{title}</h3><p>{body}</p></article>
}

function HomePage() {
  return <>
    <main>
      <section className="hero shell">
        <div className="hero-copy"><p className="eyebrow">NATIVE S3 BROWSER / MACOS</p><h1>S3 storage.<br />Made for Mac.</h1><p className="hero-lede">Find the right object, inspect its details and move files with confidence. A focused native app for the storage you already use.</p><div className="hero-actions"><DownloadButton /><a className="text-link" href={asset('download/')}>Install with Homebrew <span>↗</span></a></div><p className="platform-note"><span className="signal-dot" />macOS 15+ · Apple Silicon · MIT licensed</p></div>
        <figure className="hero-visual"><a href={asset('screenshots/object-browser.jpg')} aria-label="View full-size S3Workbench screenshot"><img src={asset('screenshots/object-browser.jpg')} alt="S3Workbench 0.7.0 browsing studio assets with object metadata and custom headers" fetchPriority="high" width="1229" height="768" /></a><figcaption><span className="caption-mark">S3://</span><span>S3Workbench 0.7.0 · Real app, demo data.</span></figcaption></figure>
      </section>

      <section className="signal-band"><div className="shell signal-inner"><p>Keep the native workflow. Change the endpoint.</p><span className="signal-readout">S3 / READY</span></div></section>

      <section className="section shell" id="workflow"><div className="section-intro"><p className="eyebrow">THE WORKFLOW</p><h2>Find the object. Keep the context.</h2><p>Connections, prefixes, search and inspection belong in one predictable desktop workflow — not a browser tab maze.</p></div><div className="feature-grid"><FeatureCard label="Browse" title="Navigate like Finder." body="Move through buckets and prefixes with native tables, breadcrumbs, keyboard commands, Quick Look and an inspector that stays beside your work." /><FeatureCard label="Search" title="Search below the prefix." body="Find objects across nested prefixes, then reuse the local index for your next search. See progress as results arrive and stop the scan whenever you need." accent="cyan" /><FeatureCard label="Transfer" title="Move data with guardrails." body="Upload, stream downloads, drag to Finder and resolve collisions before anything is replaced. Progress and cancellation stay visible." accent="violet" /></div></section>

      <section className="search-section"><div className="shell search-layout"><div className="search-image"><a href={asset('screenshots/recursive-search.jpg')} aria-label="View full-size recursive search screenshot"><img src={asset('screenshots/recursive-search.jpg')} alt="S3Workbench displaying recursive search results and scan counters" loading="lazy" width="1229" height="768" /></a></div><div className="search-copy"><p className="eyebrow">RECURSIVE SEARCH</p><h2>Find it. Keep the full path.</h2><p>Search through nested folders without opening each one. Inspect a result in place, or reveal it in its original prefix. The local index keeps repeat searches close at hand.</p><a className="text-link" href={asset('screenshots/recursive-search.jpg')}>Explore the search view <span>↗</span></a></div></div></section>

      <section className="compat-strip shell"><div><p className="eyebrow">S3-COMPATIBLE BY DEFAULT</p><h2>MinIO. RustFS. Your S3 endpoint.</h2></div><a className="text-link" href={asset('compatibility/')}>See compatibility <span>↗</span></a></section>

      <section className="download-band"><div className="shell download-inner"><div><p className="eyebrow eyebrow-light">READY WHEN YOU ARE</p><h2>Give your storage a proper Mac window.</h2></div><div className="download-actions"><DownloadButton light /><a className="support-link" href={supportUrl} target="_blank" rel="noreferrer">Support the project ↗</a></div></div></section>
    </main>
  </>
}

const pageContent: Record<Exclude<Page, 'home'>, { eyebrow: string; title: string; intro: string; sections: { label: string; title: string; body: string }[] }> = {
  download: { eyebrow: 'INSTALLATION', title: 'A native Mac app for the storage you already use.', intro: 'Install with Homebrew or download the DMG. Connect directly to your storage with your own credentials. No S3Workbench account required.', sections: [{ label: 'REQUIREMENTS', title: 'macOS 15 or later on Apple Silicon.', body: 'S3Workbench is built for current Apple Silicon Macs. The public release is distributed as a versioned DMG with a SHA-256 checksum.' }, { label: 'INSTALL', title: 'Homebrew or a simple drag to Applications.', body: 'Use the Homebrew commands below, or open the DMG and drag S3Workbench to Applications. Homebrew upgrades preserve your connections, preferences and Keychain credentials.' }, { label: 'SOURCE', title: 'Open source. Yours to inspect.', body: 'Source code and versioned releases are public under the MIT License. The community build is ad-hoc signed and is not notarized by Apple. Homebrew verifies its SHA-256; macOS Gatekeeper still applies.' }] },
  compatibility: { eyebrow: 'YOUR STORAGE', title: 'Your S3 workspaces. One Mac app.', intro: 'Move between local development, your own infrastructure and hosted object storage. Keep the same native workflow, with connection settings tailored to each endpoint.', sections: [{ label: 'SELF-HOSTED', title: 'A natural fit for MinIO and RustFS.', body: 'Point S3Workbench at your server, choose its port and connect. Path-style addressing supports local and private endpoints, with a custom CA option for your own HTTPS infrastructure.' }, { label: 'HOSTED STORAGE', title: 'Bring your S3 endpoint.', body: 'Configure Amazon S3, Cloudflare R2, Wasabi or Backblaze B2 with the endpoint and signing region supplied by your provider. Each saved connection keeps its own settings and Keychain credentials.' }, { label: 'SCOPED ACCESS', title: 'Go straight to your bucket or prefix.', body: 'Working with limited permissions? Open a /bucket/prefix directly without needing access to list every bucket. Browse, search, inspect metadata and transfer files from one focused window.' }] },
  security: { eyebrow: 'SECURITY', title: 'The credentials stay in the Keychain. The workflow stays on your Mac.', intro: 'S3Workbench is deliberately transparent about where credentials, signatures and object data are handled.', sections: [{ label: 'CREDENTIALS', title: 'Secrets do not live in profile JSON.', body: 'Access keys are stored in macOS Keychain items under opaque connection identifiers. Configuration metadata never contains the secret access key.' }, { label: 'TRANSPORT', title: 'System trust is the default.', body: 'HTTPS and system TLS verification are the normal path. A custom CA can be scoped to one connection; disabling TLS verification is not supported.' }, { label: 'SURFACE', title: 'Errors are redacted before they surface.', body: 'Authorization headers, credentials, signatures, session tokens and presigned query values are removed from surfaced errors and logs.' }] },
}

function InformationPage({ page }: { page: Exclude<Page, 'home'> }) {
  const content = pageContent[page]
  return <main className="info-page shell"><p className="eyebrow">{content.eyebrow}</p><h1>{content.title}</h1><p className="info-lede">{content.intro}</p><div className="info-list">{content.sections.map((section, index) => <article className="info-item" key={section.label}><span className="info-index">0{index + 1}</span><div><span className="info-label">{section.label}</span><h2>{section.title}</h2><p>{section.body}</p>{page === 'download' && index === 1 && <pre className="install-command"><code>{'brew tap romainfrezier/s3workbench\nbrew install --cask s3-workbench'}</code></pre>}{page === 'download' && index === 2 && <a className="text-link" href={githubUrl} target="_blank" rel="noreferrer">Open GitHub <span>↗</span></a>}</div></article>)}</div>{page === 'compatibility' && <p className="evidence-note">See the <a href={`${githubUrl}/blob/main/docs/TESTING.md`}>integration coverage and provider validation notes</a> for tested versions, operations and setup details.</p>}<div className="info-actions"><DownloadButton /><a className="text-link" href={asset('')}>Back to home <span>↗</span></a></div></main>
}

function StructuredData({ page }: { page: Page }) {
  const data = { '@context': 'https://schema.org', '@type': 'SoftwareApplication', name: 'S3Workbench', operatingSystem: 'macOS 15 or later', applicationCategory: 'DeveloperApplication', description: 'A native macOS browser for S3-compatible object storage.', url: `${siteUrl}${page === 'home' ? '/' : `/${page}/`}`, downloadUrl: releaseUrl, license: `${githubUrl}/blob/main/LICENSE`, offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' }, author: { '@type': 'Person', name: 'Romain Frezier', url: 'https://github.com/romainfrezier' } }
  return <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(data) }} />
}

export default function App({ pathname }: { pathname?: string }) {
  const page = pageFromPath(pathname ?? (typeof window === 'undefined' ? '/' : window.location.pathname))
  return <><Header page={page} /><StructuredData page={page} />{page === 'home' ? <HomePage /> : <InformationPage page={page} />}<Footer /></>
}
