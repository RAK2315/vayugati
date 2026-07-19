# Vayu Gati brand assets

**Real logo artwork is now in this repository**, supplied by the project
owner (Phase 11 UI redesign): `logo.png` — the "two flowing wave shapes" /
curved wordmark referenced in `docs/vayu-gati-product-plan-v2.md` §19,
dark-brown (`#422B1C`-ish) lettering.

## `logo.png`

The single source of truth for every branding placement in the app — icon
rail, top bar, login screen — per the explicit instruction to use the
same image everywhere rather than commissioning separate icon/wordmark
variants. Every component renders it through `LogoMark` / `LogoWordmark`
in [`../src/components/AppShell.tsx`](../src/components/AppShell.tsx), so
replacing this one file is still the only thing that needs to change if
the artwork is ever updated.

**Provenance**: supplied as a flat PNG export with a solid sky-blue
(`#C7EAF9`-ish) background. The background was made transparent with a
tolerance-based flood-fill matching that flat colour (a mechanical
background-strip, not a redraw or approximation of the artwork itself) so
it sits cleanly on the app's white surfaces. Original export dimensions:
2143×1467.

## Still a placeholder

- `favicon.svg` — not yet derived from the real logo (still the earlier
  generated wave-motif placeholder). The real logo's wide 2-line wordmark
  doesn't crop cleanly into a square favicon without further design work;
  worth a follow-up pass if a proper favicon crop is wanted.

## If the artwork changes again

Replace `logo.png` with the new export. If it has a solid-colour
background that needs stripping, sample the exact background pixel and
flood-fill it to transparent with a small tolerance (10-15) rather than
hand-editing the artwork.
