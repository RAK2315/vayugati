# Vayu Gati brand assets — placeholder notice

**No official Vayu Gati logo artwork exists in this repository.** The files in
this folder are clearly-labelled placeholders built from the brand tokens
(`#422B1C` dark brown, `#C4F1FF` sky blue, `#F6EFE4` warm cream) and a generic
"flowing wave" motif described in the product plan. They are intentionally
simple typographic/geometric marks — **not** an attempt to redraw the real
Vayu Gati logo, because the real artwork (the "two flowing wave shapes" /
curved wordmark referenced in `docs/vayu-gati-product-plan-v2.md` §19) has
never been supplied to this repository.

## What exists today (placeholder, generated)

- `icon-compact-placeholder.svg` — compact wave-motif mark, dark-brown-on-cream.
  Used for the left icon rail and as the favicon source until real artwork
  arrives.
- `favicon.svg` — the same mark, sized for browser tabs.

## Exact files needed to replace the placeholders

When real brand artwork is available, add these exact filenames to this
folder and nothing else needs to change — every component in `web/src`
that renders a logo does so through `LogoMark` / `LogoWordmark` in
[`../src/components/AppShell.tsx`](../src/components/AppShell.tsx), which
should be pointed at these files instead of the inline placeholder SVG:

| Filename | Purpose | Spec |
|---|---|---|
| `logo-wordmark-primary.svg` | Login screen, brand surfaces | Dark-brown ("#422B1C") full curved wordmark on cream/white |
| `logo-wordmark-alt.svg` | Dark surfaces | Sky-blue ("#C4F1FF") mark on dark brown |
| `logo-icon-compact.svg` | App icon rail, small nav contexts | The two flowing wave shapes only, no wordmark, transparent background |
| `favicon.svg` / `favicon-32.png` / `favicon-192.png` | Browser tab / PWA icon | Square crop of the compact icon |

Do not hand-redraw the curved wordmark from memory or approximation — replace
the placeholder only once the real vector artwork is supplied.
