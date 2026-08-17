# MacPad Family GitHub Pages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish one accessible, dependency-free GitHub Pages landing page for MacPad and MacPad Mobile.

**Architecture:** A new `anvilfilbert/anvilfilbert.github.io` repository serves a single semantic HTML document with one focused stylesheet and approved local image assets. GitHub's official Pages actions validate and deploy `main`; application repositories retain canonical product, support, license, and installation details.

**Tech Stack:** HTML5, CSS, shell validation, GitHub Actions, GitHub Pages

## Global Constraints

- Canonical URL is `https://anvilfilbert.github.io/`.
- No JavaScript, framework, package manager, generated output, analytics, cookies, advertising, forms, accounts, remote fonts, or third-party runtime requests.
- MacPad and MacPad Mobile remain separate codebases with no implied state synchronization.
- MacPad Mobile remains source/local-Xcode-only until TestFlight or App Store availability is verified.
- Site source and documentation use Apache-2.0; names, logos, icons, screenshots, and branding remain excluded and all rights reserved.
- Every image needs descriptive alternative text; focus, contrast, reduced motion, narrow layout, and link behavior must be verified.

---

### Task 1: Static Site Repository and Validation Contract

**Files:**
- Create: `README.md`
- Create: `LICENSE`
- Create: `.gitignore`
- Create: `scripts/validate-site.sh`

**Interfaces:**
- Consumes: Public repositories `anvilfilbert/MacPad` and `anvilfilbert/MacPad-Mobile`.
- Produces: `scripts/validate-site.sh`, a zero-dependency validation entrypoint used locally and by CI.

- [ ] **Step 1: Create the public user-site repository locally**

Run:

```sh
gh repo create anvilfilbert/anvilfilbert.github.io \
  --public \
  --description "Official home of MacPad and MacPad Mobile." \
  --clone
```

Expected: a new clean repository whose default branch becomes `main` after the first push.

- [ ] **Step 2: Write the validation script before site files**

Create an executable `scripts/validate-site.sh` that uses `set -euo pipefail`,
requires `index.html`, `styles.css`, and every declared asset, rejects `http://`,
remote `<script>`, analytics/cookie terms, personal paths, and signing identifiers,
and checks the exact MacPad and MacPad Mobile repository links with `rg`.

- [ ] **Step 3: Run validation to establish the missing-site failure**

Run:

```sh
./scripts/validate-site.sh
```

Expected: nonzero exit with `Required site file is missing: index.html`.

- [ ] **Step 4: Add repository documentation and licensing**

Document `python3 -m http.server 8000` as the local preview command. State that
product details are canonical in the two app repositories. Copy the canonical
Apache-2.0 license and add the code-versus-branding boundary to `README.md`.

- [ ] **Step 5: Commit the contract**

```sh
git add .gitignore LICENSE README.md scripts/validate-site.sh
git commit -m "Define MacPad family site contract"
```

### Task 2: Accessible MacPad Family Landing Page

**Files:**
- Create: `index.html`
- Create: `styles.css`
- Create: `assets/macpad-logo.png`
- Create: `assets/macpad-desktop.png`
- Create: `assets/macpad-mobile-icon.png`
- Create: `assets/macpad-mobile-iphone.png`
- Create: `assets/macpad-mobile-ipad.png`

**Interfaces:**
- Consumes: Approved images from the two existing local repositories.
- Produces: One responsive document with `#macpad` and `#macpad-mobile` anchors.

- [ ] **Step 1: Copy only approved existing brand assets**

Copy MacPad's logo and review screenshot plus MacPad Mobile's default icon,
iPhone screenshot, and iPad screenshot into `assets/` using the exact names
listed above. Do not alter or regenerate artwork.

- [ ] **Step 2: Implement semantic page structure**

Create `index.html` with a skip link, one header, one main, one footer, ordered
heading levels, a family introduction, and two platform-specific article
sections. Link MacPad's primary action to
`https://github.com/anvilfilbert/MacPad/releases/latest` and MacPad Mobile's
primary action to
`https://github.com/anvilfilbert/MacPad-Mobile#install-locally-with-xcode`.
Add source, support, security, license, and issue links for each product.

- [ ] **Step 3: Implement the editorial workspace visual system**

Create `styles.css` with graphite and warm-paper custom properties, blue-ink
accents, asymmetric document panels, responsive CSS Grid, visible keyboard
focus, minimum 44-pixel primary action targets, `prefers-reduced-motion`, and a
single-column layout below 760 pixels. Use native font stacks only.

- [ ] **Step 4: Run local static validation**

```sh
./scripts/validate-site.sh
```

Expected: `MacPad family site validation passed.`

- [ ] **Step 5: Inspect narrow and desktop renders**

Serve with `python3 -m http.server 8000`, capture 390-by-844 and 1440-by-1100
screenshots, and verify no horizontal overflow, clipped content, missing image,
or hidden focus state.

- [ ] **Step 6: Commit the page**

```sh
git add index.html styles.css assets scripts/validate-site.sh
git commit -m "Build MacPad family landing page"
```

### Task 3: GitHub Pages Validation and Deployment

**Files:**
- Create: `.github/workflows/check.yml`
- Create: `.github/workflows/pages.yml`

**Interfaces:**
- Consumes: `scripts/validate-site.sh` and repository root static files.
- Produces: Required site validation and GitHub Pages deployment from `main`.

- [ ] **Step 1: Add pull-request validation**

Create `check.yml` for `pull_request` and `push` that checks out the repository
and runs `./scripts/validate-site.sh` on `ubuntu-latest` with read-only contents
permission.

- [ ] **Step 2: Add least-privilege Pages deployment**

Create `pages.yml` for `push` to `main` and `workflow_dispatch`. Grant
`contents: read`, `pages: write`, and `id-token: write`; configure Pages, upload
the repository root with `actions/upload-pages-artifact`, and deploy with
`actions/deploy-pages`. Pin official actions to immutable commit SHAs.

- [ ] **Step 3: Validate workflow syntax and site contract**

Run:

```sh
ruby -e 'require "yaml"; ARGV.each { |path| YAML.load_file(path, aliases: true) }' \
  .github/workflows/check.yml \
  .github/workflows/pages.yml
./scripts/validate-site.sh
git diff --check
```

Expected: site validation and diff check succeed. YAML files contain only
GitHub-owned pinned actions.

- [ ] **Step 4: Commit workflows**

```sh
git add .github/workflows
git commit -m "Deploy MacPad family site with GitHub Pages"
```

### Task 4: Publish and Verify the Pages Site

**Files:**
- Modify remotely: repository Pages settings

**Interfaces:**
- Consumes: clean local `main` with three reviewed commits.
- Produces: live `https://anvilfilbert.github.io/` deployment.

- [ ] **Step 1: Push the site**

```sh
git push -u origin main
```

- [ ] **Step 2: Configure GitHub Actions as Pages build source**

Use the GitHub Pages API for `anvilfilbert/anvilfilbert.github.io`, selecting
the workflow build type. Do not configure a custom domain yet.

- [ ] **Step 3: Wait for both workflows**

Run `gh run watch --exit-status` for the validation and Pages runs. Expected:
both complete successfully.

- [ ] **Step 4: Verify the live site**

Request `https://anvilfilbert.github.io/`, require HTTP 200, verify the title,
both product anchors, local asset responses, and absence of third-party runtime
requests. Inspect narrow and desktop live screenshots.

### Task 5: Link Both Application Repositories to the Shared Site

**Files:**
- Modify: MacPad Mobile `README.md`
- Modify: MacPad `README.md`
- Modify remotely: both GitHub repository homepage URLs

**Interfaces:**
- Consumes: verified live Pages URL.
- Produces: reciprocal navigation from both app repositories and their GitHub About panels.

- [ ] **Step 1: Add the canonical family-site link to both READMEs**

Add `https://anvilfilbert.github.io/` to each existing `MacPad family` section
without duplicating product content.

- [ ] **Step 2: Verify documentation changes**

Run `git diff --check` in both repositories and confirm both reciprocal app
links plus the family-site link are present.

- [ ] **Step 3: Publish focused pull requests**

Commit each README independently, push `codex/link-macpad-family-site`, create
one pull request per repository, wait for required checks, and merge with merge
commits. Delete merged remote and local branches.

- [ ] **Step 4: Set GitHub homepage metadata**

Set both repositories' homepage URL to `https://anvilfilbert.github.io/` through
`gh repo edit`, preserving their existing descriptions and topics.

- [ ] **Step 5: Final verification**

Confirm both app repositories and the site repository have clean synchronized
`main` branches, no open site PRs, successful latest checks, and working links
to the shared family site.
