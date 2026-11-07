# Branding assets

The library logo uses the tiled libtmux mark and cog. The large tile uses
GitHub Linguist's Haskell color. Supporting shades and geometry come from
the [libtmux asset kit](https://github.com/libtmux/assets).

[`assets/source.json`](assets/source.json) records the source revision, original
paths, sizes, and SHA-256 digests. The directory includes SVG and PNG logos,
favicons, touch and maskable icons, manifests, and light/dark social cards.

The root README uses these local files.
`.github/social-preview.png` copies the library's 1200 × 630 light Open Graph
card for manual upload in GitHub's Social preview settings. The dedicated
1280 × 640 GitHub cards remain in the central kit.

The generic manifests start at `/`; a documentation publisher must adjust
`id`, `start_url`, and `scope` to its deployment path before linking them.
