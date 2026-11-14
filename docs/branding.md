# Branding assets

- The logo uses the tiled libtmux mark and cog. The large tile uses GitHub
  Linguist's Haskell color. Shades and geometry come from the
  [libtmux asset kit](https://github.com/libtmux/assets).
- [`assets/source.json`](assets/source.json) records the source revision,
  original paths, sizes and SHA-256 digests.
- The directory holds SVG and PNG logos, favicons, touch and maskable icons,
  manifests, and light/dark social cards. The root README uses these files.
- `.github/social-preview.png` is the 1200 × 630 light Open Graph card, for
  manual upload in GitHub's Social preview settings. The 1280 × 640 GitHub
  cards stay in the central kit.
- The manifests start at `/`. A documentation publisher must adjust `id`,
  `start_url` and `scope` to its deployment path before linking them.
