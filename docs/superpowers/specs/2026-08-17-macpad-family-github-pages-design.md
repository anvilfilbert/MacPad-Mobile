# MacPad Family GitHub Pages Site Design

## Goal

Publish one fast, accessible website that presents MacPad for macOS and MacPad
Mobile for iPhone and iPad as related products without implying shared runtime
state, automatic synchronization, or identical platform behavior.

The canonical site will be `https://anvilfilbert.github.io/`, served from a new
public `anvilfilbert/anvilfilbert.github.io` repository through GitHub Pages.

## Scope

The first version is a single responsive landing page. It includes:

- A shared MacPad family introduction.
- A MacPad section with its existing macOS screenshot, platform summary,
  repository link, and latest GitHub release download.
- A MacPad Mobile section with its current iPhone and iPad screenshots,
  platform summary, repository link, and local Xcode installation link.
- Clear statements that the apps are separate codebases and do not
  automatically synchronize open documents, tabs, settings, or recovery data.
- Links to each project's support, security, source license, and issue tracker.

The site will not include analytics, cookies, advertising, forms, accounts,
downloads copied from GitHub Releases, or duplicated product documentation.

## Visual Direction

Use a refined editorial workspace aesthetic derived from the existing MacPad
document-and-pen identity. A graphite canvas, warm paper surfaces, blue ink
accents, restrained depth, and asymmetric document panels distinguish the site
without imitating an Apple product page. MacPad and MacPad Mobile retain their
own screenshots and icons inside one consistent visual system.

Typography uses native, privacy-preserving font stacks. The design uses no
remote font, image, script, or tracking dependency. Motion is limited to CSS
entrance and hover transitions and is disabled by `prefers-reduced-motion`.

## Architecture

The website is a dependency-free static site:

- `index.html` contains semantic product and navigation structure.
- `styles.css` contains responsive layout, theme, and motion.
- `assets/` contains optimized copies of approved existing brand images.
- `.github/workflows/pages.yml` deploys through GitHub's official Pages
  actions using least-privilege permissions.
- `README.md` documents local preview and deployment ownership.
- `LICENSE` applies Apache-2.0 to site source and documentation while excluding
  names, logos, icons, screenshots, and other branding or artwork.

No build tool, package manager, framework, or generated output is required.
Local preview uses a standard static HTTP server.

## Content Ownership

Product facts remain canonical in each application repository. The website
summarizes them and links to those sources instead of duplicating full support,
privacy, installation, or release documentation. MacPad's download button
targets its latest GitHub Release. MacPad Mobile remains labeled as a source and
local-Xcode installation until TestFlight or App Store availability is verified.

## Accessibility and Quality

- Semantic landmarks and heading order.
- Keyboard-visible focus states and no pointer-only interaction.
- Descriptive alternative text for every product image.
- WCAG AA text contrast at minimum.
- Responsive layout from narrow phones through large desktop displays.
- No horizontal overflow at 320 CSS pixels.
- Reduced-motion support.
- Static asset paths and all internal/external links verified before publish.
- GitHub Pages deployment must complete successfully before the site is called
  live.

## Deployment and Failure Handling

Create the repository with Pages deployment through GitHub Actions. The
workflow publishes only on `main` changes and supports manual dispatch. A
failed validation or deployment leaves the previous successful site live and
reports a failing Actions run; there is no fallback deployment path.

Repository settings will use GitHub Actions as the Pages build source. Branch
protection and automated dependency updates are unnecessary because the site
has no dependencies, but pull-request checks will validate whitespace, paths,
HTML structure, and links.

## Acceptance Criteria

- `https://anvilfilbert.github.io/` serves the shared landing page over HTTPS.
- Both product sections render correctly on phone and desktop widths.
- MacPad download and repository links resolve to `anvilfilbert/MacPad`.
- MacPad Mobile repository and local Xcode installation links resolve to
  `anvilfilbert/MacPad-Mobile`.
- No analytics, cookies, third-party runtime requests, personal details, or
  signing identifiers are present.
- GitHub Pages deployment and repository checks pass.
- Both app READMEs link to the shared site after it is live.
