import logoUrl from './media/app-icon-64.webp'
import browser640 from './media/object-browser-640.webp'
import browser768 from './media/object-browser-768.webp'
import browser1229 from './media/object-browser-1229.webp'
import search640 from './media/recursive-search-640.webp'
import search768 from './media/recursive-search-768.webp'
import search1229 from './media/recursive-search-1229.webp'

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
  return <span className="brand-mark"><img src={logoUrl} alt="" width="32" height="32" /></span>
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

function DownloadButton() {
  return <a className="button button-cyan" href={releaseUrl} target="_blank" rel="noreferrer">Download for macOS <span>↗</span></a>
}

function FeatureCard({ title, body }: { title: string; body: string }) {
  return <article className="feature-card"><h2>{title}</h2><p>{body}</p></article>
}

function HomePage() {
  return <>
    <main>
      <section className="hero shell">
        <div className="hero-copy"><h1>Browse S3<br />from your Mac.</h1><p className="hero-lede">Open buckets, search across prefixes and transfer files with a native macOS app.</p><div className="hero-actions"><DownloadButton /><a className="text-link" href={asset('download/')}>Install with Homebrew <span>↗</span></a></div><p className="platform-note">macOS 15+ · Apple Silicon · MIT licensed</p></div>
        <figure className="hero-visual"><a href={asset('screenshots/object-browser.jpg')} aria-label="View full-size S3Workbench screenshot"><img src={browser1229} srcSet={`${browser640} 640w, ${browser768} 768w, ${browser1229} 1229w`} sizes="(max-width: 654px) calc(100vw - 40px), 614px" alt="S3Workbench 0.7.0 browsing studio assets with object metadata and custom headers" fetchPriority="high" width="1229" height="768" /></a><figcaption>S3Workbench 0.7.0 with a local demo bucket.</figcaption></figure>
      </section>

      <section className="section shell" id="workflow" aria-label="What you can do">
        <div className="feature-grid">
          <FeatureCard title="Browse and inspect" body="Navigate buckets and prefixes with keyboard shortcuts, Quick Look and an inspector for object metadata and headers." />
          <FeatureCard title="Search nested prefixes" body="Find an object without opening every folder. Results include the full path, and a local index speeds up repeat searches." />
          <FeatureCard title="Transfer files" body="Upload, download or drag files to Finder. Follow progress, cancel a transfer and choose what happens when a file already exists." />
        </div>
      </section>

      <section className="search-section"><div className="shell search-layout"><div className="search-image"><a href={asset('screenshots/recursive-search.jpg')} aria-label="View full-size recursive search screenshot"><img src={search1229} srcSet={`${search640} 640w, ${search768} 768w, ${search1229} 1229w`} sizes="(max-width: 654px) calc(100vw - 40px), 614px" alt="S3Workbench displaying recursive search results and scan counters" loading="lazy" width="1229" height="768" /></a></div><div className="search-copy"><h2>Search across folders.</h2><p>Search through nested folders without opening each one. Inspect a result in place, or reveal it in its original prefix. Repeat searches use the local index.</p><a className="text-link" href={asset('screenshots/recursive-search.jpg')}>View full-size screenshot <span>↗</span></a></div></div></section>

      <section className="compat-strip shell"><div><h2>Connect to your S3 storage.</h2><p>MinIO, RustFS and hosted S3 endpoints, each with its own connection settings.</p></div><a className="text-link" href={asset('compatibility/')}>See compatibility <span>↗</span></a></section>

      <section className="download-band"><div className="shell download-inner"><div><h2>Download S3Workbench</h2><p>Free and open source. macOS 15+ on Apple Silicon.</p></div><div className="download-actions"><DownloadButton /><a className="text-link" href={asset('download/')}>Installation guide <span>↗</span></a></div></div></section>
    </main>
  </>
}

const pageContent: Record<Exclude<Page, 'home'>, { title: string; intro: string; sections: { title: string; body: string }[] }> = {
  download: { title: 'Install S3Workbench.', intro: 'Install with Homebrew or download the DMG. Connect directly to your storage with your own credentials. No S3Workbench account required.', sections: [{ title: 'macOS 15 or later on Apple Silicon.', body: 'S3Workbench is built for current Apple Silicon Macs. The public release is distributed as a versioned DMG with a SHA-256 checksum.' }, { title: 'Homebrew or a simple drag to Applications.', body: 'Use the Homebrew commands below, or open the DMG and drag S3Workbench to Applications. Homebrew upgrades preserve your connections, preferences and Keychain credentials.' }, { title: 'Source code and signing.', body: 'Source code and versioned releases are public under the MIT License. The community build is ad-hoc signed and is not notarized by Apple. Homebrew verifies its SHA-256; macOS Gatekeeper still applies.' }] },
  compatibility: { title: 'Connect your storage.', intro: 'Move between local development, your own infrastructure and hosted object storage. Keep the same native workflow, with connection settings tailored to each endpoint.', sections: [{ title: 'MinIO and RustFS.', body: 'Point S3Workbench at your server, choose its port and connect. Path-style addressing supports local and private endpoints, with a custom CA option for your own HTTPS infrastructure.' }, { title: 'Hosted S3 storage.', body: 'Configure Amazon S3, Cloudflare R2, Wasabi or Backblaze B2 with the endpoint and signing region supplied by your provider. Each saved connection keeps its own settings and Keychain credentials.' }, { title: 'Go straight to your bucket or prefix.', body: 'Working with limited permissions? Open a /bucket/prefix directly without needing access to list every bucket. Browse, search, inspect metadata and transfer files from one focused window.' }] },
  security: { title: 'Credentials and security.', intro: 'S3Workbench is deliberately transparent about where credentials, signatures and object data are handled.', sections: [{ title: 'Credentials in macOS Keychain.', body: 'Access keys are stored in macOS Keychain items under opaque connection identifiers. Configuration metadata never contains the secret access key.' }, { title: 'System trust is the default.', body: 'HTTPS and system TLS verification are the normal path. A custom CA can be scoped to one connection; disabling TLS verification is not supported.' }, { title: 'Errors are redacted before they surface.', body: 'Authorization headers, credentials, signatures, session tokens and presigned query values are removed from surfaced errors and logs.' }] },
}

function InformationPage({ page }: { page: Exclude<Page, 'home'> }) {
  const content = pageContent[page]
  return <main className="info-page shell"><h1>{content.title}</h1><p className="info-lede">{content.intro}</p><div className="info-list">{content.sections.map((section, index) => <article className="info-item" key={section.title}><div><h2>{section.title}</h2><p>{section.body}</p>{page === 'download' && index === 1 && <pre className="install-command"><code>{'brew tap romainfrezier/s3workbench\nbrew trust --cask romainfrezier/s3workbench/s3-workbench\nbrew install --cask s3-workbench'}</code></pre>}{page === 'download' && index === 2 && <a className="text-link" href={githubUrl} target="_blank" rel="noreferrer">Open GitHub <span>↗</span></a>}</div></article>)}</div>{page === 'compatibility' && <p className="evidence-note">See the <a href={`${githubUrl}/blob/main/docs/TESTING.md`}>integration coverage and provider validation notes</a> for tested versions, operations and setup details.</p>}<div className="info-actions"><DownloadButton /><a className="text-link" href={asset('')}>Back to home <span>↗</span></a></div></main>
}

function StructuredData({ page }: { page: Page }) {
  const data = { '@context': 'https://schema.org', '@type': 'SoftwareApplication', name: 'S3Workbench', operatingSystem: 'macOS 15 or later', applicationCategory: 'DeveloperApplication', description: 'A native macOS browser for S3-compatible object storage.', url: `${siteUrl}${page === 'home' ? '/' : `/${page}/`}`, downloadUrl: releaseUrl, license: `${githubUrl}/blob/main/LICENSE`, offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' }, author: { '@type': 'Person', name: 'Romain Frezier', url: 'https://github.com/romainfrezier' } }
  return <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(data) }} />
}

export default function App({ pathname }: { pathname?: string }) {
  const page = pageFromPath(pathname ?? (typeof window === 'undefined' ? '/' : window.location.pathname))
  return <><Header page={page} /><StructuredData page={page} />{page === 'home' ? <HomePage /> : <InformationPage page={page} />}<Footer /></>
}
