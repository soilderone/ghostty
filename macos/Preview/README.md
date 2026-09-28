# File browser preview

The page the macOS file browser renders previews in (`preview.html`, `preview.css`,
`preview.js`), and the libraries it uses. The build installs this directory as
`share/ghostty/preview` for macOS (see `src/build/GhosttyResources.zig`), which ends up in
`Ghostty.app/Contents/Resources/ghostty/preview`.

Vendored libraries, unmodified, each with its license:

| Library                               | Version | License      | File                                 |
| ------------------------------------- | ------- | ------------ | ------------------------------------ |
| [marked](https://marked.js.org)       | 18.0.14 | MIT          | `vendor/marked/marked.umd.js`        |
| [highlight.js](https://highlightjs.org) | 11.12.0 | BSD-3-Clause | `vendor/highlight.js/highlight.min.js` (`@highlightjs/cdn-assets`, common languages) |
| [mermaid](https://mermaid.js.org)     | 11.17.2 | MIT          | `vendor/mermaid/mermaid.min.js`      |

To update one, download its npm tarball and replace the file with the same file from the new
version.
