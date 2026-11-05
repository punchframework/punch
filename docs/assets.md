# Assets

Learn it in: [Assets and JavaScript](guides/assets-and-javascript.md).

Stylesheets, images, fonts, and JavaScript modules are files in one directory of the app. They are embedded in the binary when it is compiled, served under URLs that carry a fingerprint of their content, and cached by browsers for a year. There is no build step and no Node: CSS is plain CSS, JavaScript is ES modules loaded through an import map. Turbo comes with Punch.

## Declaring the directory

Once per app, at the top level of a file the app requires:

```crystal
# app/setup.cr
Punch.assets "assets"   # relative to this file: app/assets/
```

Every file below it is an asset, named by its path there: `app.css`, `images/logo.svg`, `controllers/hello.js`. Files starting with a dot are left out. Names use letters, digits, `_`, `-`, `.`, and `@`. The extension decides the content type; one Punch does not serve does not compile:

| Extension | Content type | Compressed |
|---|---|---|
| `css` | `text/css` | yes |
| `js` | `text/javascript` (ES modules) | yes |
| `json`, `map` | `application/json` | yes |
| `txt` | `text/plain` | yes |
| `svg` | `image/svg+xml` | yes |
| `ico` | `image/vnd.microsoft.icon` | yes |
| `webmanifest` | `application/manifest+json` | yes |
| `png`, `jpg`, `jpeg`, `gif`, `webp`, `avif` | images | no |
| `woff2`, `woff` | fonts | no |

HTML is not an asset: pages are operations.

A build embeds the assets, so changing one means compiling again, except under `punch dev`: its builds (`-Dpunch_dev`) check the directory at compile time as every build does, but read the files while the app runs, so a changed file is served at its new fingerprinted URL without a build, and an open page reloads itself (`docs/tooling.md`). A new or removed file still needs a build, which `punch dev` starts.

## Referring to an asset

`Punch.asset("app.css")` names an asset, checked at compile time: a name that is not in the directory does not compile. Its type follows the extension: `Asset::Stylesheet`, `Asset::Script`, or `Asset::Static`.

```crystal
v.document(@title, stylesheets: {Punch.asset("app.css")}, script: Punch.asset("application.js")) do
  v.header do
    v.img src: Punch.asset("images/logo.svg").href, alt: "Invoicing"
  end
  v.main { yield }
end
```

- `stylesheets:` takes stylesheets only, `script:` one module; anything else does not compile.
- `asset.href` is a `Punch::Href` for `src:` and `href:` attributes; `asset.url` is the path as a string.
- `v.img` needs `src:` and `alt:`; `alt: ""` marks an image as decoration.

## URLs and caching

An asset's URL is its path with the first 16 hex digits of the SHA-256 of its content before the extension: `/assets/images/logo-7aba511c6c5684d7.svg`. A changed file gets a new URL, so responses carry `Cache-Control: public, max-age=31536000, immutable`. Text formats are also kept gzip-compressed and sent that way to clients that accept it, with `Vary: Accept-Encoding`.

Only the current fingerprint is served. The plain name, an old fingerprint, and anything else under `/assets/` answer 404. During a deploy, pages from the old binary ask the old process for their assets; Turbo reloads a page when the assets it tracks change (`data-turbo-track="reload"`, written on every stylesheet and script).

No operation can be routed under `/assets/`; the router refuses to start with one.

Fingerprints, compressed copies, and the import map are computed once per process, on first use, in a few milliseconds.

## Stylesheets

A stylesheet refers to other assets by relative paths, and Punch rewrites them to the fingerprinted URLs:

```css
@import "base.css";
.brand { background: url(images/logo.svg) no-repeat; }
```

The stylesheet's own fingerprint is taken after the rewrite, so it changes when an image it uses changes. Absolute URLs, `data:` URLs, and fragments stay as they are. A relative reference that names no asset stays too and is listed by `bin/app assets` under "Unresolved"; a spec can check `Punch::Assets.table.unresolved.should be_empty`.

## JavaScript and the import map

JavaScript is ES modules, loaded by the browser as they are. Every `.js` asset is in the document's import map under its path without `.js`; Turbo is `@hotwired/turbo`:

```js
// app/assets/application.js
import "@hotwired/turbo"            // already loaded by Punch; importing it again is harmless
import { hello } from "controllers/hello"
```

Import other modules by these bare names, not by relative paths: a relative import resolves against the fingerprinted URL and names a file that is not served. A library vendored as one ES module file goes into the directory under the name it is imported by, such as `@hotwired/stimulus.js`.

Every document loads Turbo (`turbo: false` leaves it out) and the `script:` module, after the import map. In an app with kinds of upload, it also loads Punch's `punch/uploads.js` (`docs/uploads.md`).

## Turbo

Punch vendors Turbo's ES module build, `vendor/turbo/turbo.js`, unchanged from the npm package (version and checksums in `vendor/turbo/PROVENANCE.md`, its MIT license in `vendor/turbo/LICENSE`). `scripts/vendor-turbo.sh VERSION` updates it: it checks the package against the registry's integrity value and writes `src/punch/assets/turbo.cr`. A spec checks the embedded file against its SHA-256. An app cannot ship its own `@hotwired/turbo`.

## Content-Security-Policy

Scripts and styles come from the app's own origin only. Two inline pieces are allowed by their SHA-256, never by `unsafe-inline` or a nonce:

- the import map, the one inline script, the same in every document of a binary;
- the stylesheet of Turbo's progress bar, which Turbo writes into a `<style>` element.

```
default-src 'self'; script-src 'self' 'sha256-…'; style-src 'self' 'sha256-…'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'self'
```

With uploads in an S3 bucket, the default policy also allows the bucket for `connect-src`, `img-src`, and `media-src` (`docs/uploads.md`, "Showing and downloading").

An app that replaces the header (`SecurityHeaders.new({"Content-Security-Policy" => ...})`) must keep both sources: `Punch::HTTP::SecurityHeaders.content_security_policy` is the default, and `Punch::Assets.csp` the part for scripts and styles. Inline event handlers and `style` attributes do not compile in views.

## Command line

`bin/app assets` lists every asset with its URL and sizes, the import map, and unresolved references in stylesheets; `--json` for programs.

## Tracing

An asset request's wide event is named `GET /assets/*`, with `punch.surface` `asset` and `punch.asset` the asset's name.

## Specs

Assets are served through the router like everything else:

```crystal
css = Punch::Spec.client.get(Punch.asset("app.css").url)
css.headers["Content-Type"].should eq("text/css; charset=utf-8")
page.should have_element("head link[rel=stylesheet][href='#{Punch.asset("app.css").url}']")
```
