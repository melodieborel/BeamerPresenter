# BeamerPresenter (Mélodie's fork) — project notes for Claude

This is a personal fork of [tamling/BeamerPresenter](https://github.com/tamling/BeamerPresenter),
adopted as the base for Mélodie's own Beamer/PDF presenter tool instead of
continuing to extend the older AppKit-based `mbPresentation` project. This file
is intentionally gitignored — it's local guidance for this fork, not synced
upstream or shared in the repo history.

## Objectives

- Keep the macOS app as the primary target. The iOS and Linux ports came with
  the upstream project; don't spend effort keeping them in sync unless asked.
- Near-term: add support for embedding and controlling **movies/video** in a
  deck, and viewing/manipulating **3D objects** (e.g. USDZ), with both
  automatic and manual playback/rotation. Neither exists upstream yet (video
  is listed as a roadmap idea there; 3D isn't mentioned at all).
- Preserve what already works well: the double-width Beamer notes-pane
  detection, `.tex`/`\note{}` extraction, timer, thumbnail strip, and
  whiteboard.
- The "Night Console" dark/lime theme from upstream is a minor aesthetic
  dislike, not a functional problem — fine to adjust `Theme.swift`/fonts later
  without treating it as urgent.

## Preferences

- Swift, following the existing file-per-feature structure under
  `Sources/BeamerPresenter/`. Prefer `async`/`await` over Combine for new code
  (upstream already leans on Combine in a couple of places — no need to rip
  that out, just don't add more of it).
- No speculative abstractions or unused feature flags. Match the scope of a
  change to what was actually asked.
- Minimal comments — only for non-obvious rationale (a heuristic's threshold,
  a workaround, a hidden constraint), not restating what the code already
  says.
- Verify changes by building (`swift build`) and running before calling
  something done; this app has no automated test suite yet.

## Versioning (kept from upstream, still applies to the macOS target)

Every change that lands in `main` bumps the app version:

- **Smaller changes** (bugfixes, behaviour tweaks, UI polish): bump the minor
  version — `3.1` → `3.2`.
- **Larger changes** (new features, redesigns, breaking changes): bump the
  major version — `3.x` → `4.0`.

The version lives in `Resources/Info.plist` (`CFBundleShortVersionString` /
`CFBundleVersion`, increment the build number by 1 on every bump). Add a
matching entry at the top of `CHANGELOG.md` (`## vX.Y — YYYY-MM-DD`)
describing the change. Ignore the iOS/Linux version files unless those ports
are actually being touched.
