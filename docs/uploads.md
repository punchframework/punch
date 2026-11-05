# Uploads

Learn it in: [Uploading Files](guides/uploading-files.md).

Files go from the browser straight to S3-compatible storage, never through the app. The app decides who may upload what, Punch signs a URL that takes exactly one file of the size and type the app allowed, checks what arrived, and hands the app the file to keep on a record: its key, name, size, and type. Everything else the app does with a file, such as listing, showing, or deleting it, goes through that record.

The app's server still rejects `multipart/form-data` (`docs/http.md`), so a form never carries a file to the app.

## How an upload goes

1. **Grant.** The browser asks the app's granting Command for an upload, with the file's size and type. The Command calls `Punch::Upload.grant`, which checks them against the kind's rules, records the upload in `punch_uploads`, and returns a `Punch::Upload::Grant`: a ticket, a `PUT` URL valid for ten minutes, and the headers to send. `Content-Length` and `Content-Type` are among the URL's signed headers, so a storage that checks them refuses a body of another size or type ([How providers enforce the size](#how-providers-enforce-the-size)).
2. **Send.** The browser sends the file to the URL. The bytes go to `pending/<id>` in the bucket; the key is Punch's, never the client's.
3. **Check.** The browser sends the ticket to `POST /_punch/uploads/check`. Punch asks the storage what arrived: its size and type must be the granted ones, and its first bytes must be a file of that type (`%PDF-` for a PDF, the PNG signature for a PNG). Punch then copies it, as of the version it read, to `files/<kind>/<id>`, with its type and a `Content-Disposition`, and deletes the pending object. One check runs at a time per upload, and an upload is copied once: a file sent again to the URL never reaches the checked copy. Only checked copies are ever served.
4. **Claim.** The form is sent with the ticket in a hidden field. The Command that saves the record calls `Punch::Upload.claim`, which takes the checked upload for the app and returns a `Punch::Upload::File`. The app keeps it whole, as a group of columns of its own table ([Keeping a file](#keeping-a-file)).

What is granted and never claimed within the hour is removed by `Punch::Upload::Sweep`, from the storage and from `punch_uploads`, and so is what the app gives up with `Punch::Upload.discard` or `purge`.

## Declaring a kind

A kind of upload is a type with its rules: the largest file in bytes and the content types it takes.

```crystal
# app/expenses/receipts/scan.cr
module Expenses::Receipts
  # A scan or photo of a receipt.
  @[Punch::Upload::Rules(max_size: 10_000_000, types: ["application/pdf", "image/png", "image/jpeg"])]
  struct Scan
    include Punch::Upload::Kind
  end
end
```

- `scan: true` says the app scans these files ([Scanning files](#scanning-files)).
- `max_size` is an integer literal, at most 5 GB (`5_000_000_000`), the most S3 takes in one `PUT`.
- `types` come from the list Punch can check by their first bytes: `application/pdf`, `image/png`, `image/jpeg`, `image/gif`, `image/webp`, `image/avif`, `image/heic`, `text/plain`, `text/csv`, `application/zip`, the Office Open XML and OpenDocument formats, `audio/mpeg`, `video/mp4`, and `application/octet-stream` for anything else. A type that runs script in a browser (HTML, SVG, XML, JavaScript) does not compile: upload such files as `application/octet-stream`.
- The kind's name is its type's path, lowercase with dots (`expenses.receipts.scan`). It is part of every key, so a renamed kind's files keep the old name in their keys, which stay valid.
- A kind without rules, a type Punch does not take, or a `max_size` that is not a literal does not compile.

## Granting

The app grants uploads in a Command of its own, so its policy decides who may upload and its rate limit how often:

```crystal
# app/expenses/receipts/operations/upload_scan.cr
module Expenses::Receipts
  # Hands out an upload of a receipt scan.
  @[Punch::Authorize(ByRole)]
  @[Punch::RateLimit(60, per: 1.hour, by: :actor)]
  @[Punch::BodyLimit(8 * 1024)]
  struct UploadScan < Punch::Command
    struct Input
      include Punch::Input

      getter size : Int64
      getter content_type : String
      getter filename : Punch::Upload::Filename?
    end

    alias Output = Punch::Upload::Grant | Punch::Rejection

    def call(input : Input, db : Punch::Writer, actor : Expenses::Actor) : Output
      Punch::Upload.grant(db, Scan, size: input.size, content_type: input.content_type, filename: input.filename, owner: actor.user_id.to_s)
    end
  end
end
```

- `filename` is what the file is called on the client's machine; Punch's upload script sends it. Without one the file gets a plain name, such as `file.pdf`.
- `owner` names who may claim the upload: the user's ID, or for anonymous uploads something only that visitor has. The claim must name the same owner.
- The grant is refused, as a `Punch::Rejection`, with `too_large` or `out_of_range` at `size`, `unsupported_type` at `content_type`, and `too_many_uploads` as a whole while the owner has `Punch::Upload.pending_limit` (20) uploads granted and not claimed.
- The answer is 201 with the grant:

```json
{
  "ticket": "upl_…",
  "method": "PUT",
  "url": "https://example-uploads.s3.eu-central-1.amazonaws.com/pending/k3…?X-Amz-Algorithm=…",
  "headers": {"Content-Type": "image/png", "Content-Length": "48213"},
  "expires_at": "2026-11-03T10:20:00Z",
  "check": "/_punch/uploads/check"
}
```

## The form

An input field of type `Punch::Upload::Ticket` renders as a file control and a hidden field for the ticket:

```crystal
struct Create < Punch::Command
  struct Input
    include Punch::Input

    getter description : Punch::NonEmptyString
    getter scan : Punch::Upload::Ticket
  end
  # …
end

# in the page's view
v.form(Create.action) do |form|
  form.field :description
  form.field :scan, accept: Scan.upload_accept, data: {punch_upload: UploadScan.path}
  form.submit "Save"
end
```

- The file control has no `name`, so the file itself is never sent with the form. `data: {punch_upload: …}` names the granting Command; `Scan.upload_accept` lists the kind's types for the browser's file picker.
- Punch's upload script (`punch/uploads.js`, loaded on every page of an app with kinds of upload) does the rest when a file is chosen: grant, send, check, and the ticket into the hidden field. While it works, and after a failure, the file control is invalid, so the browser does not send the form without the file. The control's `data-punch-upload-state` is `uploading`, `uploaded`, or `failed` (style it with `[data-punch-upload-state=failed]`), and it fires `punch:upload` events with `{state, message}`.
- A form shown again after a refusal keeps the ticket, so the file need not be chosen again.

## Claiming

The Command that saves the record claims the upload and keeps the file:

```crystal
def call(input : Input, db : Punch::Writer, actor : Expenses::Actor) : Output
  case file = Punch::Upload.claim(db, input.scan, Scan, owner: actor.user_id.to_s)
  in Punch::Invalid then Punch::Rejection.new(Punch::Rejection::Path{"scan"}, file)
  in Punch::Upload::File
    Table.insert(db, description: input.description, scan: file, created_at: Time.utc)
    # …
  end
end
```

- `file` is a `Punch::Upload::File`, which the record keeps whole: see [Keeping a file](#keeping-a-file). Punch forgets the name at the claim, so a Command that does not keep `file` loses it.
- A `Punch::Upload::Key` on its own is a `TEXT` column mapped to that type, for an app that wants nothing else of a file, in a kind that is not scanned.
- A key names a stored file, and `url` signs it without asking who wants it, so a key never comes from a request: an input field of type `Punch::Upload::Key` does not compile. Take the ID of the record that holds the key, load the record as the viewer may, and use its key.
- `claim` refuses with `upload_not_found` (no such ticket, another owner or kind, claimed already, or more than an hour since the grant) or `upload_not_checked` (the file has not been checked yet). A ticket claims once.
- The claim is part of the Command's transaction: a Command that fails rolls it back, and the ticket can claim again.

## Keeping a file

Punch ships four composites (`docs/composites.md`), so an app maps a file as a group of columns without declaring anything, and `punch db:generate` knows them all:

| Type | Name | Also holds |
|---|---|---|
| `Punch::Upload::File` | plain `TEXT` | |
| `Punch::Upload::PrivateFile` | encrypted `BLOB` | |
| `Punch::Upload::ImageFile` | plain `TEXT` | `width`, `height`, `alt` |
| `Punch::Upload::PrivateImageFile` | encrypted `BLOB` | `width`, `height`, and an encrypted `alt` |

```sql
CREATE TABLE receipts (
  id                INTEGER PRIMARY KEY,
  description       TEXT    NOT NULL,
  file_key          TEXT    NOT NULL,
  file_filename     TEXT    NOT NULL,
  file_size         INTEGER NOT NULL,
  file_content_type TEXT    NOT NULL,
  file_scan_state   TEXT,
  file_delete_after TEXT,
  created_at        TEXT    NOT NULL
) STRICT;
```

```crystal
Punch.table "receipts", Expenses::Receipts,
  id: Expenses::Receipts::ID,
  description: Punch::NonEmptyString,
  scan: {type: Punch::Upload::File, columns: "file_"},
  created_at: Time
```

- The record holds one field, `scan : Punch::Upload::File`, with `key`, `filename`, `size`, `content_type`, `scan_state`, and `delete_after`. `Table.insert` takes it whole, and queries can use each column, so `sum(file_size)` is a quota and an index on `file_key` finds the record of a file. A record with several files has a child table with one group per row.
- **`PrivateFile`** is for a name that is personal data. Its `<prefix>filename` column is an encrypted `BLOB`, so `filename` is a `Punch::Secret(Punch::Upload::Filename)`, and a claimed file becomes one with `Punch::Upload::PrivateFile.of(file)`. A plain `File` does not go into a private column, and a `PrivateFile` does not go into an answer whole, or through `Punch::Stored.dump`: pick the fields, and `unwrap` the name where it is shown. Renaming the column changes its key, as for any encrypted column (`docs/queries.md`).
- **`delete_after`** is a date for the app's own retention rules, `nil` by default. Punch only stores it: nothing deletes a file when it passes.
- Where a plain file may be absent, map `Punch::Upload::File?`. The generator prints the `CHECK` that keeps its columns all set or all `NULL`. A nilable private group cannot be mapped yet, since that `CHECK` would read an encrypted column: keep an optional private file in a child table.

## Images

`Punch::Upload::ImageFile.of(file, alt:, width:, height:)` makes an image of a claimed file, and `PrivateImageFile.of` a private one. Each returns `self | Punch::Invalid`: `not_an_image` when the file's type is not `image/…`, `out_of_range` for a side outside 1 to 1,000,000, `too_long` for alt text over 1,000 characters.

- The columns are those of a file, plus `<prefix>width` and `<prefix>height` (`INTEGER`), and `<prefix>alt` (`TEXT`, or a `BLOB` in a `PrivateImageFile`, whose alt text describes a private image).
- **Punch does not read images.** All three are `nil` until the app sets them, from a job that reads the file, or from its client. A size from a client is what the client says: use it to lay out a page, and cap what a page shows with CSS.
- `alt` is text from a user. Views escape it, like any value.

## Scanning files

Punch does not scan, but it keeps a file that is waiting for a scan away from people. A kind says it is scanned:

```crystal
@[Punch::Upload::Rules(max_size: 8_000_000, types: ["image/jpeg", "image/png"], scan: true)]
struct Photo
  include Punch::Upload::Kind
end
```

- **`scan: true` starts a claimed file `pending`,** in its `scan_state`. A kind without it keeps `nil`, and behaves as if nothing were scanned.
- **Only a `clean` file of a scanned kind is linked to.** `url(file)` and `href(file)` raise `Punch::Upload::NotServable` for one that is `pending` or `quarantined`. `url?(file)` and `href?(file)` answer `nil` instead, and `file.servable?` says which: use those in pages and answers, or one waiting file fails a whole list for every viewer.
- **No state fails closed.** A file with a `nil` state in a scanned kind is not servable, as a row from before the kind was scanned, or a hand-written insert, would be. A key whose kind no longer exists counts as scanned once the app scans any kind. After setting `scan: true` on a kind, mark what is there: `UPDATE receipts SET file_scan_state = 'pending' WHERE file_scan_state IS NULL`.
- **A bare key is refused too.** `url(key)` of a scanned kind raises `NotServable`, since a key says nothing of a scan. Only the job that reads a file to scan it passes `unscanned: true`.
- **Saving a result:** `file.scanned(Punch::Upload::ScanState::CLEAN)` returns the file with its state. Read the record again in the transaction that saves it: the scan takes a while, and a whole-row `update` from before it would write back what it read. Check that `file.key` is still the key you scanned.
- **A URL signed before a quarantine stays good until it expires,** so URLs of a scanned kind's files last at most an hour, whatever `expires:` says. `quarantined` stops new links, and only deleting the object ends the old ones: `Punch::Upload.purge(db, file)` gives a file up whoever's it is, and the sweep deletes it within ten minutes. It leaves your record's row as it is.
- A client cannot name a state: a `Punch::Upload::ScanState` in an input does not compile.

## File names

A file's name comes from the client, so `Punch::Upload::Filename.parse` cleans it:

- **Directories go:** only what follows the last `/` or `\` stays.
- **What is invisible goes:** bytes that are not UTF-8, format characters such as the bidirectional controls that make `fdp.exe` read `exe.pdf`, and default-ignorable characters are removed. Look-alikes from other scripts stay. Control characters and line breaks, NUL among them, become a space, and runs of space become one.
- **Dots and spaces at either end go,** so `.htaccess` is `htaccess`.
- **It fits:** at most 255 bytes, shortened before the extension (an extension over 32 bytes goes too). More than 4,096 bytes, or nothing left, is `invalid_filename`, 422 at the field.
- **The extension fits the checked type.** `grant` appends the type's usual extension to a name that lacks one of the type's, so a PDF sent as `report.html` is saved as `report.html.pdf`, not as a page. The type always comes from the check; a name never decides one. `application/octet-stream` keeps its name as it is.

The name is for people: to show, and to download under. It names nothing in the storage, so never build a path, an object key, or a command line from it, keep it away from tools that process the file, and treat it as text from a stranger wherever an agent or a spreadsheet reads it.

- **`application/octet-stream` keeps any extension,** so a kind that takes it lets a client hand another user `setup.exe`. It is always a download, so it never runs in your origin or the storage's, but a file saved from it runs on the machine that opens it. Do not offer such a kind for files that reach other people.
- **Links to a file fit the name too.** `href(file, download: name)` fits a `Filename` to the file's type with `name.for(content_type)`, also one from a rename. Only `href(key, download: text)`, for an app that keeps a bare key, sends a name as it is, encoded for the header. A type Punch does not know gets `.bin`.

A file name can be personal data (`Sick note Ada Lovelace.pdf`). Keep such a file as a `PrivateFile`. That protects the column, not these other copies:

- **`punch_uploads`** holds the name in plaintext from the grant until the claim, or until the sweep after the claim window: about an hour, and ten minutes more while jobs run. What Litestream replicated keeps it for the replica's retention.
- **A URL with a name** carries it in its query, so it reaches the page, the browser's history, and the storage provider's logs. `href(private_file, download: true)` uses a plain name, such as `file.pdf`, for that reason; passing the real one is your decision.
- **An idempotent Command's answer** is stored as it is, for at least 24 hours, with any name or link in it, whenever a client sends a key. With a name that is personal data, leave it out of the Command's answer, and let a Query show it.
- **A job or event payload** stores a plain `File` as it is, name included. A `PrivateFile` in a payload does not compile, since its name is a secret. Pass the record's ID.

The name is not on wide events.

## Showing and downloading

`Punch::Upload.href(file)` is a link or image source that fetches the file from the storage for an hour; `Punch::Upload.url(file)` is the same as a string. `href?` and `url?` answer `nil` for a file that is not servable ([Scanning files](#scanning-files)). `href` and `url` also take a bare `Punch::Upload::Key`, for an app that keeps nothing else, with `download:` a `String`; `href?` and `url?` take only a file.

```crystal
v.img src: Punch::Upload.href(photo.image), alt: photo.image.alt.to_s
if link = Punch::Upload.href?(receipt.scan, download: true)
  v.a receipt.scan.filename.to_s, href: link
end
```

- Signing is local: neither the storage nor the database is asked. Put a file's URL only into a page whose viewer may see the file, as for anything else on the page.
- `expires:` sets how long the URL works (at most 7 days, and an hour for a file of a scanned kind); `download: true` makes the browser save the file under its name (a `PrivateFile` under a plain one), and `download: name` under that `Filename`. A file shown inline has no name of its own: saved from the browser, it gets its upload ID.
- Files are served by the storage, from its origin, never the app's. PDFs and images (PNG, JPEG, GIF, WebP, AVIF) are shown inline; everything else downloads. With an S3 bucket, the pages' Content-Security-Policy allows the bucket for `connect-src`, `img-src`, and `media-src`, and nothing else: its origin and the prefix where the bucket is in the host name, and the bucket's path too where it is in the path (`path_style`), since other buckets share that host.

## Giving files up

```crystal
Punch::Upload.discard(db, receipt.scan, owner: actor.user_id.to_s)
```

`discard` marks the file in the Command's transaction; the sweep deletes it from the storage within ten minutes of the commit. It returns whether the key was a claimed file of that owner; another owner's key changes nothing.

A job acting for the app, with no owner at hand, uses `Punch::Upload.purge(db, file)`, which takes the file whoever's it is. It returns whether the key was a claimed file. Neither touches the record: the row that named the file is the app's to change.

`Punch::Upload::Sweep` runs every ten minutes in every app with kinds of upload. It deletes from the storage, then from `punch_uploads`, what was granted and not claimed within an hour, and what was given up. It also deletes a pending file of another size than was granted, once the upload's `PUT` URL has expired. A storage that cannot be reached leaves those rows for the next run.

## Settings

Uploads are configured in the app's credentials, as a group (`docs/credentials.md`):

```crystal
struct Expenses::Credentials
  include Punch::Credentials

  getter uploads : Punch::Upload::Settings
end
```

```yaml
uploads:
  storage: s3
  bucket: example-uploads
  region: eu-central-1
  access_key_id: AKIA…
  secret_access_key: …
```

| Setting | Default | |
|---|---|---|
| `storage` | | `s3`, or `local` in development and test |
| `bucket` | | The bucket's name |
| `endpoint` | AWS's for `region` | The storage's endpoint: `https://` and a host. Plain `http` only to `localhost` |
| `region` | `us-east-1` | The bucket's region; `auto` for Cloudflare R2 |
| `path_style` | `false` | The bucket in the path instead of the host name, for MinIO and stores without per-bucket host names |
| `prefix` | none | Where in the bucket Punch's objects go, such as `expenses/`, for a bucket shared with other uses |
| `access_key_id`, `secret_access_key` | | The keys that sign URLs and requests |

Each value can come from the environment, as every credential: `UPLOADS__STORAGE=local`, `UPLOADS__SECRET_ACCESS_KEY=…`. Boot refuses `local` outside development and test, and an app with kinds of upload but no settings.

| Provider | `endpoint` | `region` |
|---|---|---|
| AWS S3 | leave out | the bucket's region |
| Cloudflare R2 | `https://<account>.r2.cloudflarestorage.com` | `auto` |
| Backblaze B2 | `https://s3.<region>.backblazeb2.com` | the bucket's region, such as `eu-central-003` |
| Hetzner Object Storage | `https://<location>.your-objectstorage.com` | the location, such as `fsn1` |
| MinIO | its URL | its region; `path_style: true` |

The table `punch_uploads` comes from `punch db:migration --punch uploads`; `serve` refuses to start without it once the app declares a kind, and `punch check` (step `punchtables`) names a column it lacks.

### Setting up the bucket

- **Private.** No public access: every file is read through a signed URL.
- **Its own keys.** Use keys for this bucket alone that may put, get, and delete objects (`s3:PutObject`, `s3:GetObject`, `s3:DeleteObject`), not the backup's keys.
- **CORS**, so pages of the app may send files and read the answers:

```json
[{
  "AllowedOrigins": ["https://expenses.example.org"],
  "AllowedMethods": ["PUT", "GET"],
  "AllowedHeaders": ["Content-Type"],
  "MaxAgeSeconds": 3600
}]
```

- **A lifecycle rule** that deletes objects under `pending/` (after the prefix, if any) a day after they were created. The sweep removes pending objects of uploads that were never claimed; the rule removes the rest: a file a client sends again to its URL after the check, within the URL's ten minutes, and what a process never got to.

### How providers enforce the size

The `PUT` URL signs `Content-Length`, and a storage that checks signed headers (AWS S3 among them) refuses a body of any other length. Whether another provider does has not been tested, so count on the rest:

- **Before anything is copied,** the check reads the object's size and deletes what does not match. A file of another size is never checked, claimed, or served, whatever the storage takes.
- **If the check never comes,** `Punch::Upload::Sweep` deletes the file within ten minutes of the URL's expiry. Until then a client that holds a grant can keep up to the storage's largest `PUT` in the bucket, so a provider that does not check the header counts such bytes on the bill for that long. `pending_limit` and the granting Command's rate limit bound how many.

Presigned `POST` policies, which state a range of sizes, are not used: several S3-compatible providers do not support them.

## Processing uploaded files

Punch never opens an uploaded file with another program. An app that does hands a stranger's file to a tool with far more reach than a web page: ImageMagick and FFmpeg pick what to run from the file's content or name, and some of their formats read or write other files, fetch URLs, or run scripts. A crafted upload can read secrets from the server or write files to it this way.

The check does not make a file safe for such a tool. It reads the first 512 bytes, so it refuses a script or playlist declared as an image or video, but an `application/pdf` is still a PDF, which image tools hand to Ghostscript, and `application/octet-stream` and `text/plain` take almost anything.

- **Name the format.** Tell the tool what the file is, from the upload's checked type, and never let it guess: `magick png:input.bin output.webp`; `ffmpeg -f mp4 -protocol_whitelist file -i input.bin …`.
- **Keep the client's file name away from the tool.** Write the file to a name the job makes up, with no extension from the client. An extension can pick the decoder.
- **Deny what you do not use.** Give ImageMagick a `policy.xml` that denies at least the `MSL` and `MVG` coders, the `gs` delegate, the PostScript and PDF coders, and `@` indirection. Distribution packages do not deny them all. Build FFmpeg without AviSynth.
- **Allow only what you process.** Process the kinds you mean to, by their checked type. Skip `application/octet-stream` and text.
- **Take the secrets away.** Run the tool as its own process, with no credentials in its environment, read access to nothing it does not need, no network, and time and memory limits. A job that passes it the bytes and reads the result is enough: the tool should not be able to reach the app's keys or its database.
- **Limit the work.** A small file can decode to an enormous image. Set the tool's limits on width, height, and memory.

## Development and specs

With `storage: local`, files are kept in `uploads/` in `PUNCH_STORAGE`, and the app answers the signed `PUT` and `GET` itself, below `/_punch/uploads/local/`, with the same checks as a bucket: signature, expiry, size, and type. The signing key is new in every process, so URLs from before a restart stop working.

In specs, `Punch::Spec.uploads` keeps uploads in a temporary directory, and `Punch::Spec.upload` sends a file as a browser would and asks for the check:

```crystal
Punch::Spec.uploads
grant = Punch::Spec.db.write { |db| Punch::Upload.grant(db, Scan, size: png.size, content_type: "image/png", owner: "1") }.as(Punch::Upload::Grant)
Punch::Spec.upload(grant, png, Punch::Spec.db).should be_a(Punch::Upload::Checked)
response = client.request("POST", Receipts::Create.path, json: {description: "Taxi", scan: grant.ticket.value})
```

Specs never reach a real bucket: Punch's own specs answer S3's requests with a stand-in server (`spec/upload/upload_spec.cr`).

## Without a browser

API clients and agents take the same steps:

1. `POST` the granting Command with `{"size": …, "content_type": …}`; the answer is the grant.
2. `PUT` the file to `url` with every header in `headers`, exactly.
3. `POST /_punch/uploads/check` with `{"ticket": "upl_…"}`. The answer is 200 with the size and type, or a problem: 404 `upload_not_found`, 409 `upload_incomplete` (nothing has arrived yet), 409 `upload_checking` (another check of it runs; ask again shortly), 422 `upload_mismatch` (the file was deleted; send it again while the URL works), 502 `upload_storage_unavailable`, 429 `rate_limited` (60 checks a minute per client address).
4. Send the ticket in the Command that saves the record.

The check is not part of `openapi.json`: it is Punch's, the same in every app. Its wide event is named `POST /_punch/uploads/check`, with `punch.surface` `upload`, and `punch.upload.kind` for a file that passed.

## What Punch does not do

- **Look inside files.** The check compares the first bytes with the declared type, which stops a page or script from being uploaded as an image. A file that starts as its type and holds something else later passes. Files are served from the storage's origin, so script in one runs there and never in the app's pages. Scan for malware in a job that reads the file from the storage ([Scanning files](#scanning-files)), and process files as [Processing uploaded files](#processing-uploaded-files) says.
- **Serve through the app.** There is no route that streams a file from the storage; links go to the storage.
- **Keep files with the backup.** The bucket is not part of `punch restore`; keep its versioning or replication with the provider. A restored database may name keys of files discarded since, and lack keys of files claimed since.
