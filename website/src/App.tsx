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
    <a className="button button-small button-cyan" href={releaseUrl} target="_blank" rel="noreferrer">Download</a>
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

function BrowserMockup() {
  return <div className="browser-mockup" aria-label="S3Workbench object browser preview">
    <div className="mockup-topbar"><span className="traffic"><i /><i /><i /></span><span className="mockup-title">S3Workbench</span><span className="mockup-search">⌕ Search below this prefix</span></div>
    <div className="mockup-body">
      <aside className="mockup-sidebar"><div className="mockup-sidebar-title">Connections</div><div className="mockup-connection"><span className="connection-dot" />Local Demo<small>127.0.0.1</small></div><div className="mockup-connection muted"><span className="connection-dot purple" />Production R2<small>eu-west-1</small></div></aside>
      <div className="mockup-content"><div className="mockup-breadcrumb"><span>demo-assets</span><b>/</b><span>reports</span><b>/</b><strong>2026</strong></div><div className="mockup-table-head"><span>Name</span><span>Size</span><span>Modified</span><span>Storage class</span></div>{['weekly-report-08.json', 'weekly-report-09.json', 'operations-report.pdf', 'status.json', 'uptime.csv'].map((name, index) => <div className={`mockup-row ${index === 2 ? 'selected' : ''}`} key={name}><span><b className="file-glyph">{index === 2 ? '◇' : '▱'}</b>{name}</span><span>{['262 KB', '279 KB', '786 KB', '229 KB', '197 KB'][index]}</span><span>13 Aug 2026</span><span>STANDARD</span></div>)}<div className="mockup-counter">25 scanned · 7 matches</div></div>
      <aside className="mockup-inspector"><div className="inspector-file">◇</div><strong>operations-report.pdf</strong><button type="button">Quick Look</button><h4>Metadata</h4><p>Size <b>786 KB</b></p><p>Content type <b>application/pdf</b></p><p>Storage class <b>STANDARD</b></p><h4>Headers</h4><p>ETag <b>"38852c…c8ff-1"</b></p></aside>
    </div>
  </div>
}

function FeatureCard({ label, title, body, accent }: { label: string; title: string; body: string; accent?: string }) {
  return <article className="feature-card"><span className={`feature-label ${accent ?? ''}`}>{label}</span><h3>{title}</h3><p>{body}</p></article>
}

function HomePage() {
  return <>
    <main>
      <section className="hero shell">
        <div className="hero-copy"><p className="eyebrow"><span />NATIVE S3 BROWSER / MACOS</p><h1>Object storage, <em>without the fog.</em></h1><p className="hero-lede">Browse buckets, prefixes and metadata with the clarity of a native Mac app. S3Workbench keeps the cloud out of your way.</p><div className="hero-actions"><DownloadButton /><a className="text-link" href="#workflow">See how it works <span>↓</span></a></div><p className="platform-note"><span className="signal-dot" />macOS 15+ · Apple Silicon · MIT licensed</p></div>
        <figure className="hero-visual"><BrowserMockup /><figcaption><span className="caption-mark">S3://</span><span>One focused window for the storage you already own.</span></figcaption></figure>
      </section>

      <section className="signal-band"><div className="shell signal-inner"><p>Keep the native workflow. Change the endpoint.</p><span className="signal-readout">S3 / READY</span></div></section>

      <section className="section shell" id="workflow"><div className="section-intro"><p className="eyebrow"><span />THE WORKFLOW</p><h2>Find the object. Keep the context.</h2><p>Connections, prefixes, search and inspection belong in one predictable desktop workflow — not a browser tab maze.</p></div><div className="feature-grid"><FeatureCard label="01 / BROWSE" title="Navigate like Finder." body="Move through buckets and prefixes with native tables, breadcrumbs, keyboard commands, Quick Look and an inspector that stays beside your work." /><FeatureCard label="02 / SEARCH" title="Search below the prefix." body="Scan recursively with progressive results, complete pagination and visible counters. Cancel safely when the answer is already clear." accent="cyan" /><FeatureCard label="03 / TRANSFER" title="Move data with guardrails." body="Upload, stream downloads, drag to Finder and resolve collisions before anything is replaced. Progress and cancellation stay visible." accent="violet" /></div></section>

      <section className="showcase shell"><div className="showcase-copy"><p className="eyebrow"><span />OBJECT INSPECTION</p><h2>Every file has a place — and a readable surface.</h2><p>Open metadata, headers, storage class and timestamps without losing the path that got you there.</p><a className="text-link" href={asset('download/')}>Download S3Workbench <span>↗</span></a></div><div className="showcase-image"><img src={asset('screenshots/object-browser.png')} alt="S3Workbench displaying a bucket with the object inspector open" /><span className="image-tag">INSPECTOR / LIVE CONTEXT</span></div></section>

      <section className="search-section"><div className="shell search-layout"><div className="search-image"><img src={asset('screenshots/recursive-search.png')} alt="S3Workbench displaying recursive search results and scan counters" /><span className="image-tag">SEARCH / 25 SCANNED</span></div><div className="search-copy"><p className="eyebrow"><span />RECURSIVE SEARCH</p><h2>Search the tree, not just the row.</h2><p>When the key is somewhere below the current prefix, let S3Workbench walk the hierarchy and bring back the path. Results stay bounded, progressive and cancellable.</p><div className="search-stat"><strong>7</strong><span>matches<br />from one focused query</span></div></div></div></section>

      <section className="compat-strip shell"><div><p className="eyebrow"><span />S3-COMPATIBLE BY DEFAULT</p><h2>Local MinIO, private infrastructure or hosted storage.</h2></div><a className="text-link" href={asset('compatibility/')}>See compatibility <span>↗</span></a></section>

      <section className="download-band"><div className="shell download-inner"><div><p className="eyebrow eyebrow-light"><span />READY WHEN YOU ARE</p><h2>Give your storage a proper Mac window.</h2></div><div className="download-actions"><DownloadButton light /><a className="support-link" href={supportUrl} target="_blank" rel="noreferrer">Support the project ↗</a></div></div></section>
    </main>
  </>
}

const pageContent: Record<Exclude<Page, 'home'>, { eyebrow: string; title: string; intro: string; sections: { label: string; title: string; body: string }[] }> = {
  download: { eyebrow: 'INSTALLATION', title: 'A native Mac app for the storage you already use.', intro: 'Download the latest public release, open the archive and move S3Workbench to Applications. No account is required.', sections: [{ label: 'REQUIREMENTS', title: 'macOS 15 or later on Apple Silicon.', body: 'S3Workbench is built for current Apple Silicon Macs. The public release is distributed as a versioned DMG with a SHA-256 checksum.' }, { label: 'INSTALL', title: 'Open, drag, connect.', body: 'Open the DMG, drag S3Workbench to Applications, launch it and add an S3-compatible connection with its endpoint, region and access policy.' }, { label: 'SOURCE', title: 'Public, inspectable, reproducible.', body: 'The source code, release assets and conservative compatibility notes are published on GitHub under the MIT License.' }] },
  compatibility: { eyebrow: 'COMPATIBILITY', title: 'S3-compatible first. AWS-specific assumptions last.', intro: 'Each connection keeps its own endpoint, region, addressing policy and TLS policy. Configure the server you actually run.', sections: [{ label: 'TESTED', title: 'MinIO is covered locally.', body: 'The automated integration suite covers authentication, restricted roots, pagination, unusual object names, metadata, transfers, presigned GET and multipart uploads against MinIO.' }, { label: 'CONFIGURE', title: 'Bring your endpoint.', body: 'AWS S3, Cloudflare R2, Wasabi, Backblaze B2 and private S3 implementations can be configured with their compatible endpoint and addressing requirements.' }, { label: 'HONEST LIMITS', title: 'Compatibility claims stay evidence-based.', body: 'MinIO is the only provider covered by the automated suite today. Other providers are configuration-compatible but remain provider-dependent until tested with live credentials.' }] },
  security: { eyebrow: 'SECURITY', title: 'The credentials stay in the Keychain. The workflow stays on your Mac.', intro: 'S3Workbench is deliberately transparent about where credentials, signatures and object data are handled.', sections: [{ label: 'CREDENTIALS', title: 'Secrets do not live in profile JSON.', body: 'Access keys are stored in macOS Keychain items under opaque connection identifiers. Configuration metadata never contains the secret access key.' }, { label: 'TRANSPORT', title: 'System trust is the default.', body: 'HTTPS and system TLS verification are the normal path. A custom CA can be scoped to one connection; disabling TLS verification is not supported.' }, { label: 'SURFACE', title: 'Errors are redacted before they surface.', body: 'Authorization headers, credentials, signatures, session tokens and presigned query values are removed from surfaced errors and logs.' }] },
}

function InformationPage({ page }: { page: Exclude<Page, 'home'> }) {
  const content = pageContent[page]
  return <main className="info-page shell"><p className="eyebrow"><span />{content.eyebrow}</p><h1>{content.title}</h1><p className="info-lede">{content.intro}</p><div className="info-list">{content.sections.map((section, index) => <article className="info-item" key={section.label}><span className="info-index">0{index + 1}</span><div><span className="info-label">{section.label}</span><h2>{section.title}</h2><p>{section.body}</p>{page === 'download' && index === 2 && <a className="text-link" href={githubUrl} target="_blank" rel="noreferrer">Open GitHub <span>↗</span></a>}</div></article>)}</div><div className="info-actions"><DownloadButton /><a className="text-link" href={asset('')}>Back to home <span>↗</span></a></div></main>
}

function StructuredData({ page }: { page: Page }) {
  const data = { '@context': 'https://schema.org', '@type': 'SoftwareApplication', name: 'S3Workbench', operatingSystem: 'macOS 15 or later', applicationCategory: 'DeveloperApplication', description: 'A native macOS browser for S3-compatible object storage.', url: `${siteUrl}${page === 'home' ? '/' : `/${page}/`}`, downloadUrl: releaseUrl, license: `${githubUrl}/blob/main/LICENSE`, offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' }, author: { '@type': 'Person', name: 'Romain Frezier', url: 'https://github.com/romainfrezier' } }
  return <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(data) }} />
}

export default function App({ pathname }: { pathname?: string }) {
  const page = pageFromPath(pathname ?? (typeof window === 'undefined' ? '/' : window.location.pathname))
  return <><Header page={page} /><StructuredData page={page} />{page === 'home' ? <HomePage /> : <InformationPage page={page} />}<Footer /></>
}
