# 3Dmol.js Roadmap — Quick Look App + Upstream Vision

Two tracks: (A) **make QuickLookProtein the best possible *Quick Look* experience for molecular files** without turning it into PyMOL, plus a "wholesome pivot" — what the app could grow into while staying true to its character. (B) **Upstream contributions that matter at a 5-10 year horizon** — the changes that decide whether 3Dmol.js is still the default web molecular viewer in 2030.

Source: full sweep of `3dmol.org/doc/index.html`, every `*Spec` interface, the `$3Dmol` namespace, tutorials, plus the local viewer at `Xcode/Shared/Assets/3Dmol_viewer.html` and the `ViewerOptions` plumbing. Upstream state checked against [3dmol/3Dmol.js](https://github.com/3dmol/3Dmol.js) as of 2026-05.

## Current upstream state (2026-05)

- **Latest release**: 2.5.4 (2026-01-22). 4 releases/year cadence. License BSD-3-Clause.
- **Language**: ~95% TypeScript. Migration is essentially complete (only `SurfaceWorker.js` and `exporter.js` remain JS in `src/`).
- **Build**: webpack 5, ships both UMD (`build/3Dmol.js`) **and ES6 modules** (PR #831, May 2025). Types emitted to `build/types/`.
- **Tests**: Jest 29 + `glcheck` (custom WebGL regression harness). CI on every PR via GitHub Actions, Node 20.
- **jQuery**: no longer required at runtime for 3Dmol 2.x — `createViewer(document.getElementById('div'))` works directly. Only the legacy `createViewer($(...))` form still pulls jQuery. **The app can drop its inlined jQuery 3.6 in the 2.5.x upgrade.**
- **npm**: `3dmol` (not `3Dmol.js`). Recommended CDN: jsdelivr (the 3dmol.org self-hosted CDN is unreliable per issue #841).
- **Maintainer activity**: dkoes (David Koes, Pitt) responds within hours-to-days. PRs from known contributors merge in 1–2 weeks. No stale human PRs in the queue.
- **Explicit `help wanted` issues**: #3 (full editor), #7 (better zoomTo), #166 (per-atom opacity), #293 (tube cartoons), #299 (coordination polyhedra), #368 (partial/transition-state bonds). No formal `good first issue` label.
- **Hot area right now**: aromatic-bond visualization rewrite (PR #852 + #842/#845–848, dxdc, Feb 2026) — directly relevant to small-molecule previews.

---

# What QuickLookProtein is, and is not

**Is:** press Space in Finder → see a structure → press Space again → it's gone. Read-only. Instant. Zero workflow state. Thumbnails generated headlessly, under 500 ms, with no UI. Settings exist but exist to set defaults, not to be configured per-preview.

**Is not:** a workbench. Not PyMOL, ChimeraX, Mol*, or PyMOL Web. There is no "open file → manipulate → save" loop. Anything that asks the user to interact during the preview window is out of scope; anything that improves the first 800 ms of the preview is in scope.

Two filters every Track A item passes:
1. **Does it improve the default render?** (better looking, more correct, more informative without user input)
2. **Or: does it extend the Quick Look behaviour itself** — more file types, better thumbnails, richer Spotlight metadata, OS-level integration the user already expects from Preview.app?

If neither: it belongs in the main app, or it doesn't belong in this product at all.

---

# Track A — QuickLookProtein, true to form

## Phase A0 — Upgrade and de-jQuery (foundation, one PR)

Before any feature work, lift the bundled engine and shed the jQuery legacy.

- **Pin to 3Dmol 2.5.4** (currently shipping a heavily pre-2.x build). Aromatic-bond rendering alone (PR #852) noticeably improves small-molecule previews.
- **Drop the inlined jQuery 3.6** from `Xcode/Shared/Assets/3Dmol.js`. 3Dmol 2.x's `createViewer` accepts a DOM element directly — `var element = document.getElementById('3dviewer')` replaces `var element = $('#3dviewer')` in `3Dmol_viewer.html`. The load-bearing comment block at the top of the file becomes a deletion. Saves ~85KB of bundled JS.
- **Switch to the ESM build** (PR #831 made this real in May 2025). One `<script type="module">` instead of UMD.
- **Pin verification**: add `scripts/check-3dmol-upstream.sh` that diffs `Xcode/Shared/Assets/3Dmol_VERSION.txt` against the latest GitHub tag.
- **Test before rolling**: cartoon rendering for nucleic acids and viewergrid behavior changed between 2.5.0 → 2.5.3; regression-check the bundled corpus.

## Phase A1 — Smarter defaults (no new UI, just better automatic choices)

The single biggest payoff. The app already classifies atoms into polymer / ligand / metal / water / buffer; lean into it.

- **pLDDT auto-detection.** If file looks like an AlphaFold/ESMFold model (single chain, B-factor range 0–100, no experimental method header), apply the canonical pLDDT palette automatically. Zero UI, zero settings; the file just renders correctly. In 2026 a majority of `.pdb` files users open are predicted structures — this is the most impactful single change in the whole roadmap.
- **B-factor coloring** as a detected-default when B factors are nonzero and informative (range > 5).
- **Auto-orient by principal axes** so 1CRN always lands in the same canonical pose regardless of how the PDB was written. Currently a fresh-from-RCSB file and a re-saved file render differently; that should never happen.
- **Smart thumbnail style per format**: cartoon+surface for proteins, ball-and-stick+VDW surface for small molecules, sticks+CPK for organics, sphere for ionic. Currently one-size-fits-all.
- **Cube → isosurface, not atoms-only**. A `.cube` file today renders as bare atoms because we never call `addVolumetricData`. This is the single "looks broken vs. real chemistry tool" gap. Fix: auto-pick a reasonable isoval (e.g. 0.02), two-color (+/−), opacity 0.5.

## Phase A2 — Visual quality

Same content, better-looking output. All "set the default and forget":

- **Outline shading** via `setViewStyle({style: 'outline'})` — the "cartoon-with-black-edge" look that makes proteins instantly more readable. One line, big perceptual win.
- **Ambient occlusion** when WebGL2 is available; auto-fallback. Adds depth without user input.
- **High-DPI render path** for retina thumbnails. Current PNG bridge runs at logical resolution; `viewer.resize()` with `devicePixelRatio * 2` doubles thumbnail sharpness with no perceptible cost.
- **Surface quality ladder** — `setDefaultCartoonQuality` keyed to atom count so big complexes don't melt the GPU but small molecules look pristine.
- **Spin-as-APNG thumbnail** (optional setting). `apngURI(60)` gives Finder gallery view a spinning preview for the cost of one PNG. Genuinely magical for a Quick Look thumbnail.

## Phase A3 — Format reach (extending the Quick Look behaviour itself)

The Quick Look promise is "any structure file you have, Space-bar previews it." Bring more files into that promise:

- **Cryo-EM density** (`.ccp4 / .mrc / .map`) — depends on Track B landing volumetric format support upstream, then add the UTIs.
- **Electronic structure** outputs (`.out`, `.fchk`, `.molden`) — parsed in Swift to extract geometry; let 3Dmol render the molecule even when the file is a 200 MB Gaussian log.
- **Crystal CIFs done right** — biological assembly preferred over asymmetric unit (parser option `doAssembly: true`); user can flip it in Settings if they need ASU.
- **Trajectory first frames** for `.xtc / .dcd / .trr` — Quick Look only ever shows one frame, but right now those files don't preview at all. Render the first frame (or last, configurable) and label "frame 1 of N" in the info overlay. Depends on Track B trajectory parsers.
- **Sequence files** (`.fasta`, `.gb`, `.fastq`-with-structure-link) — preview a folded structure via AlphaFold lookup. Half-jokingly: Quick Look as the world's most casual structure-prediction front-end.

## Phase A4 — Spotlight + Finder depth

Quick Look's siblings. The app already ships an MDImporter; expand what it indexes:

- **Sequence-aware search**: index residue sequence + extracted motifs (kinase domains, signal peptides, transmembrane helices) so `mdfind "kinase domain"` returns every PDB on disk that has one. Heuristic via signature residue patterns — not a UniProt mirror.
- **Ligand inventory** indexed per file — search "ATP" and find every structure containing ATP. Massive for chemistry workflows.
- **Quality metadata** — average pLDDT for predictions, resolution for experimental, R-free for refined. Sortable in Finder.
- **Finder Quick Actions** (right-click menu, no app launch): "Save as PNG", "Save chain A as PDB", "Open in PyMOL". Each is one `pdbData(sel)` or `pngURI()` call.

## Phase A5 — Subtle in-preview affordances (sparingly)

Quick Look itself adds buttons to its title bar (Open, Share, Markup for PDFs). We can match that pattern *without* building a chrome-heavy UI:

- **System Share button** in the QL title bar → PNG / APNG / USDZ. Pure system integration, looks like Preview.app exporting a PDF.
- **Hide-water / hide-hydrogens / hide-ligand** as a single discreet pill in the corner (the `#controls` skeleton is already in the HTML). Three toggles, not a "panel."
- **Style cycler** — one keystroke (or one tap) cycles cartoon → stick → sphere → surface. No menus. Mimics how Preview's rotate button works.

Anything more interactive than this belongs in the main app, not the preview.

---

## The wholesome pivot — "Preview.app for molecules"

The current identity is "a Quick Look plugin." The wholesome version is **"the molecular file experience on macOS"** — an ambient OS behaviour, not an app you launch.

That reframing unlocks features that genuinely fit Quick Look character:

- **AR Quick Look via USDZ export.** This is the killer feature. macOS and iOS already ship AR Quick Look as a system service: any USDZ file opens in 3D in iMessage, Notes, Safari, Mail. If QuickLookProtein converts PDB → USDZ in the share sheet, **a user can drag a structure into iMessage and the recipient sees it spinning in AR on their iPhone with zero installs.** No other molecular software can do this because they're not OS-integrated. This is the single most "wholesome" thing the app could do — molecules become first-class citizens of Apple's content pipeline.
- **Markup parity with PDFs.** When you Quick Look a PDF you get a Markup button. We could ship the same: tap an atom in QL, type a comment, save annotations as xattr metadata. Notes stay with the file. Other Macs with the plugin show them too.
- **Continuity Camera moonshot.** Point an iPhone at a printed molecular figure → the Mac instantly Quick Looks the live 3D model. Apple already does this for documents; the framework is generic. Long-tail but uniquely Apple-native.
- **Reading List for structures.** A system action: "Save for offline" any RCSB ID; appears in a dedicated Finder folder that the indexer treats like local files.
- **iCloud Drive previews.** Quick Look files inline in Files.app on iPhone/iPad via a sibling iOS extension. Same renderer, same defaults — molecules become as universal as PDFs across the Apple device set.
- **Vision Pro preview.** Spatial Quick Look — point at a `.pdb` in Files.app on visionOS, see it floating in your room. visionOS already exposes the Quick Look API for USDZ; we just have to produce one.

This pivot is wholesome because every item *strengthens the Quick Look character* — it makes the app more invisible, more system-integrated, more "everywhere files live." It's the opposite of becoming a workbench.

## App-track release plan

| Release | Phases | Theme |
|---|---|---|
| 1.8.0 | A0 | "Upgrade to 3Dmol 2.5.4, drop jQuery" |
| 1.8.1 | A1 | "Smarter defaults" — pLDDT auto, principal-axes orient, cube → isosurface |
| 1.9.0 | A2 | "Visual quality" — outline, AO, high-DPI, APNG thumbnails |
| 1.9.1 | A3 | "More formats fit the Space-bar promise" |
| 1.9.2 | A4 | "Spotlight + Finder Quick Actions" |
| 2.0.0 | A5 + wholesome pivot pt.1 | "Share / USDZ / AR Quick Look" — major version |
| 2.1.x | wholesome pivot pt.2 | iCloud Drive, iOS extension, visionOS |

Everything explicitly dropped from earlier drafts (selection text input, measurement tools, dihedral picker, contact maps, linked viewers, drawing/annotation, fetch-by-PDB-ID inside the preview, persistent per-file view state, vibrational mode playback, principal-axes arrows, pocket detection, H-bond visualization) belongs in the main settings app or in a future *companion* tool — not in the Quick Look extension. That self-restraint is the product.

---

# Track B — Upstream Vision for 3Dmol.js

The previous draft listed worthy contributions (WebGPU, WASM parsers, mmCIF, headless rendering, plugin API, AlphaFold features, accessibility). Those are still on the list. But the *visionary* framing is much bigger than that.

3Dmol.js's role today is "a working WebGL molecular viewer." The question worth asking is:

> What would make 3Dmol.js the **canonical molecular rendering primitive of the web** — the way `<img>` is the canonical image primitive — for the next decade?

Ten moonshots. Each could be a multi-year initiative. Each has a small first-PR foothold so progress is incremental.

## Warm-up: ship three small PRs first to build review trust

Before opening any moonshot RFC, land a handful of small PRs against actually-labeled issues. dkoes is responsive but doesn't know us yet; doing the warm-ups buys credibility.

- **#166 per-atom opacity** (`help wanted`, 3 comments) — add an `opacity` field to atom style specs, propagate through `src/WebGL/materials`. Directly useful for the app (dim non-active-site residues). Well-scoped, dkoes labeled it himself.
- **#513 RGBA color support** (8 comments, repeatedly requested) — pair with #166. Both touch `GLModel.ts` and the materials layer.
- **#8 Gaussian fchk parser** — ~300 LOC, mirrors `src/parsers/CUBE.ts`. Pure text parsing, easy to test, directly extends Quick Look format reach.
- **Aromatic-bond polish** — extend PR #852 with edge-case fixes (fused rings, non-planar rings, dashed-bond stability). The area is hot and dxdc/dkoes are actively reviewing.
- **#79 spectrum coloring for all styles** — currently only some styles honor `color: 'spectrum'`. Surgical fix.

These five PRs give you a track record before tabling B1–B10.

## B1 — `<mol-view>` as a Web Component standard

**Vision.** Not a library you import and call `createViewer`. A standard HTML element. `<mol-view src="1crn.pdb" style-default="cartoon" color="plddt">` renders a fully interactive structure with three lines of HTML, no JS, no setup. Citable in papers. Indexable by search engines. Embeddable in Notion, Substack, MDN. The 3KB shell lazy-loads the engine only when scrolled into view.

**Why it's visionary.** Every other molecular viewer demands you learn its API. A Web Component demands you learn HTML — which everyone already knows. The first molecular library to do this credibly becomes the default reach for anyone embedding a structure on the web, period.

**First PR.** Wrap `viewer_3Dmoljs` (the existing declarative `data-*` mode) in a `customElements.define('mol-view', ...)` shim. Ship as `@3dmol/element` companion package.

## B2 — WebGPU + ML-on-GPU compute

**Vision.** WebGPU's killer use case isn't faster rendering — it's *compute shaders running on the same GPU as the rendering*. That unlocks:

- Marching cubes / SES surface generation in a compute pass (currently CPU-bound, 3 seconds for large complexes).
- Within-distance selection as a kernel over atom coordinates (currently O(n²) JS).
- **A distilled folding model running directly against a sequence the user pastes into the viewer.** ESMFold-small and AlphaFold-distilled variants are ~600M-parameter models; with 4-bit quantization they fit in 4GB browser VRAM. Fold + render in one tab, no server, no API key.

**Why it's visionary.** This collapses the structure-prediction stack from "submit to server, wait, download, render" to "type sequence, see structure." 3Dmol becomes the first inference-capable molecular viewer.

**First PR.** WebGPU compute path for surface generation behind a `useWebGPU: 'auto'` flag. Then a `viewer.fold(sequence)` method that uses a tiny model first (just to prove the pipeline), bigger ones later.

## B3 — Differentiable rendering

**Vision.** `viewer.renderDifferentiable()` returns gradients of the rendered image w.r.t. atom coordinates. Suddenly the renderer is part of the ML training loop:

- Structure refinement against cryo-EM density: render → compute pixel loss vs. observed density → backprop → adjust positions → repeat.
- Sequence design that optimizes for a target rendered appearance ("design a protein that *looks like* this sketch").
- Direct integration with PyTorch / JAX via WebGPU tensor interop.

**Why it's visionary.** No molecular viewer is differentiable today. The first one to be becomes the canonical "rendering primitive" that ML researchers reach for. Drug discovery, protein design, structural ML — all of it suddenly has a citable visualization stack instead of matplotlib hacks.

**First PR.** Tiny demo: `viewer.gradients({atom: 0, axis: 'x'})` via finite differences. Then port one shader to a differentiable formulation as proof of concept.

## B4 — Format universality via WASM RDKit + OpenBabel + gemmi

**Vision.** Stop maintaining 14 hand-written parsers. Link once to the canonical implementations (RDKit-WASM for cheminformatics, OpenBabel for everything else, gemmi for mmCIF + maps) and *every* chemistry/biology file ever invented becomes a 3Dmol input. SMILES, InChI, CHEMDRAW, MAE, MAESTRO, SYBYL, CCDC ASER, anything.

**Why it's visionary.** Eliminates the long-tail format-support burden that has held 3Dmol back vs. ChimeraX/Mol*. Aligns 3Dmol with the broader cheminformatics ecosystem. RDKit-WASM is already production-grade as of 2024.

**First PR.** `@3dmol/parsers-rdkit` companion that adds `addModelFromSMILES` and `addModelFromInChI` using RDKit-WASM. Other formats roll in over time.

## B5 — Molecular Scene as an interchange format

**Vision.** glTF is the standard scene-interchange format for general 3D. Molecular scenes don't have one. Today, "send me your figure" means sending a PyMOL `.pse`, a ChimeraX session, a Mol* JSON, an offline screenshot, or *the entire PDB + a verbal description of how it was styled*. None of these are interoperable.

A **Molecular Scene** spec — say, `.molscene` — captures structure + style + view + selection + annotations in one citable, archivable, replayable bundle. Every viewer can read and write it. 3Dmol publishes the reference implementation and the spec.

**Why it's visionary.** Replaces static figure files in journals. *"Click figure 2 → manipulate it in your browser."* Could be co-developed with the PDB and major journals (eLife, Nature, ACS). Pivots 3Dmol from "a viewer" to "the standard-bearer for how molecular figures are shipped." There is genuinely no incumbent here.

**First PR.** Write the spec as a one-page Markdown RFC. Implement export/import in 3Dmol. Get one journal to commit to a pilot.

## B6 — Multi-scale rendering

**Vision.** Biology lives across scales: atoms, residues, domains, complexes, organelles, cells, tissues. Today's tools do *one* scale. Real biology needs all of them simultaneously, with seamless level-of-detail transitions. Zoom out of a ribosome → coarse-grain bead model → entire cell context → entire tissue context, all in one continuous camera move.

**Why it's visionary.** Cryo-electron tomography and integrative structural biology live at this multi-scale problem. Whoever solves the rendering side becomes the default tool of integrative biology — currently the fastest-growing area of structural science.

**First PR.** Coarse-grain bead style as a new `AtomStyleSpec` variant. Then LOD transitions driven by camera distance.

## B7 — Streaming + cloud-native architecture

**Vision.** AlphaFold DB ships 200M+ structures. Nobody downloads even 0.01% of them. The viewer should be able to stream *partial* structures from cloud storage as the user explores — only fetch the bytes you're looking at, like Google Earth for molecules. Combined with B5's scene format, an entire screening campaign or virtual library exists as a streamable resource, not a giant download.

**Why it's visionary.** Post-PDB era. The data has outgrown the "download then view" model. The viewer that nails streaming becomes the only viable interface to AlphaFold DB / ESM Atlas at full resolution.

**First PR.** Range-request streaming for MMTF/BCIF (binary formats with offset metadata). Then a partial-structure subset query API.

## B8 — Web XR / spatial computing as a first-class target

**Vision.** Not "VR mode bolted on" — a second render target alongside the canvas, sharing one scene graph. Atoms are real objects in your room (Vision Pro), or floating in front of you (Quest 3), or on the museum kiosk's holographic display. Education, public engagement, teaching, accessibility — entirely new audiences.

**Why it's visionary.** Spatial computing is the next computing paradigm and every major OS now ships an XR runtime. The molecular viewer that takes XR seriously becomes the default teaching tool of structural biology. Pairs naturally with App Track A's USDZ pivot.

**First PR.** WebXR canvas target. Then hand-controller picking. Then collaborative multi-user sessions.

## B9 — Reproducibility infrastructure for science

**Vision.** Every published structural-biology paper today has a figure that cannot be reproduced from the supplementary materials. The viewer that fixes this — by being the *citable* primitive every paper uses — becomes infrastructure, not software.

Concretely: a 3Dmol-rendered figure embedded in a paper carries a DOI-resolvable scene URL (B5 format) + a content hash + a version pin. Click the figure → archived viewer renders it identically forever, even after 3Dmol itself has changed.

**Why it's visionary.** Solves a chronic problem in science publishing. Aligns 3Dmol with open-science initiatives, replication crisis solutions, FAIR principles. Funding agencies (NIH, NSF, Wellcome) actively fund this kind of work — there's a real path to grant support for the maintainers.

**First PR.** A `scene-archive` mode that bundles the 3Dmol bundle + the scene + a content hash into a single self-contained HTML file, archivable on Zenodo.

## B10 — Accessibility, narrative, and reach

**Vision.** Structures are deeply visual; they shouldn't be unusable for blind/low-vision scientists, and they shouldn't be unsharable on platforms that don't render WebGL. Static SVG export for papers and slides. Screen-reader summaries (`viewer.describe()` → "4-helix bundle, two zinc ions, three disulfides"). Keyboard navigation through residues. Sonification of B-factor across the camera path. A 1KB ASCII-art mode for terminals and email. Color-blind-safe palettes auto-selected from system accessibility settings.

**Why it's visionary.** Universal access is a moral floor, not a feature. Doing it first and visibly puts 3Dmol on the right side of an issue the field has chronically ignored.

**First PR.** `viewer.describe(format)` over the existing scene graph. SVG export is next.

## Upstream-track suggested phasing

| Quarter | Moonshots seeded | Theme |
|---|---|---|
| Q1 | B1 + B5 (RFC) + B10 first PRs | "Standards & access" |
| Q2 | B4 (RDKit-WASM) + B7 (streaming proto) | "Reach the long tail of files & scale" |
| Q3 | B2 (WebGPU compute) + B8 (WebXR proto) | "New platforms" |
| Q4 | B6 (multi-scale) + B9 (reproducibility infra) | "Science integration" |
| Year 2 | B2 (in-browser folding) + B3 (differentiable) | "The viewer becomes inference" |

Order: standardize first (B1, B5), expand format & scale reach (B4, B7), open new platforms (B2-rendering, B8), integrate with science workflows (B6, B9), then the most speculative — in-browser inference and differentiable rendering (B2-ML, B3) — once the foundation is solid.

---

# How the two tracks compound

Every B-track moonshot eventually feeds A-track quality:

- B1 (`<mol-view>`) → makes the bundled viewer HTML 90% smaller in the app.
- B2 (WebGPU compute) → the app drops its 3000-atom surface cap entirely.
- B4 (RDKit-WASM parsers) → every new chemistry file format Quick Look gains comes for free.
- B5 (Molecular Scene format) → "Save as scene" share-sheet item in the app.
- B6 (multi-scale) → opens cellular-tomography Quick Look as a product line.
- B7 (streaming) → Quick Look an RCSB URL drag from Safari directly.
- B8 (WebXR) → AR Quick Look pivot (App A5) becomes spatial Quick Look on Vision Pro.
- B10 (accessibility) → VoiceOver finally describes molecular previews on macOS.

**Track A pulls; Track B pushes.** The app keeps its Quick Look character — minimal, instant, system-integrated — while pulling forward upstream changes that justify themselves on their own merits. In a decade, QuickLookProtein is the reference downstream consumer of a 3Dmol.js that has itself become the canonical molecular rendering primitive of the web.
