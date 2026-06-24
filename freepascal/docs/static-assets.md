# WeKan-Lite — static assets (public/) — v0.1

Companion to `web-stack-decision.md` (Decision 4). How the development-time files under
`public/` are served, and how they get into the single binary. Code: `wlstatic.pas`; generator
`../tools/genassets.py`.

`public/` holds robots.txt, favicons/PWA icons, `css/`, `js/` (incl. the vendored
`interact.js`), `font/` arrow GIFs, the OpenAPI `api/`, and `i18n/` (the bulk — ~21 MB of
translation JSON). They are served at a configurable URL mount (default `/`), so:

- `public/robots.txt`     → `http://<host>/robots.txt`
- `public/js/interact.js` → `http://<host>/js/interact.js`
- `public/css/reset.css`  → `http://<host>/css/reset.css`

Assets are **global** (identical for every tenant) and are served *before* tenant resolution.

## Two sources, tried in order (`wlstatic.ServeStatic`)

1. **Embedded** — when built with `-dWLEMBED`, the generated `wlassets` unit reads files
   bundled into the executable as FPC resources (`{$R wlpublic.res}`) and registers
   `wlstatic.EmbeddedLookup`. True single binary; nothing on disk.
2. **Disk** — otherwise (dev, and any target without a resource compiler) read from a
   configurable `public/` directory next to the binary.

Path traversal is rejected (`..`, absolute, NUL); MIME type is by extension (`MimeForName`).

### Why not embed as Pascal `const` byte arrays?
`public/` is ~24 MB; byte-array literals would balloon the source past what FPC can compile.
FPC **resources** bundle the real bytes with no source bloat, so embedding uses those.

## Configuration

| Env var | Default | Meaning |
|---------|---------|---------|
| `WEKANLITE_STATIC_URL` | `/` | URL mount the `public/` tree is served under |
| `WEKANLITE_PUBLIC` | `public` | on-disk assets dir (disk mode only) |

## Build

**Disk mode (default, dev, any target):** just ship the binary next to `public/`.
```
fpc -O3 -Xs -o wekanlite wlhttp.lpr
./wekanlite                      # serves ./public/* ; WEKANLITE_PUBLIC overrides the dir
```

**Embedded single binary (release):**
```
python3 tools/genassets.py public wlassets.pas wlpublic.rc   # index unit + resource script
fpcres wlpublic.rc -o wlpublic.res -of res                   # compile resources
fpc -dWLEMBED -O3 -Xs -o wekanlite wlhttp.lpr                # embed + build
./wekanlite                      # serves from inside the exe; no public/ needed
```
Verified on FPC 3.2.3 (aarch64): with `public/` deleted, the `-dWLEMBED` binary still serves
`/robots.txt` and `/js/interact.js` from the executable.

### Size note (retro targets)
Embedding all of `public/` adds ~24 MB to the binary, most of it `i18n/`. For an Amiga 68k or
other small target, either keep disk mode (binary + `public/` folder) or run `genassets.py`
against a trimmed `public/` (e.g. only the needed languages).

## Translations index
`public/languages.json` (the language list consumed for i18n) is generated from WeKan's
`imports/i18n/languages.js` by `../convert-languages.py`; re-run it to pick up new languages.
