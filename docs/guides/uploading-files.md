# Uploading Files

Applies to Punch 0.1.

An app that takes files has to answer three questions: who may upload, what may they upload, and how does a large file get stored without tying up the server. Punch's answer is that files never pass through the app. The app decides who may upload what, the browser sends the file straight to S3-compatible storage through a URL signed for that one file, and the app keeps the file's key and name on a record. The server refuses multipart requests altogether, so a form can never carry a file to it.

After reading this guide, you will know:

- how to declare a kind of upload, and grant one in a Command, so a policy and a rate limit decide who gets it;
- how to add a file field to a form, and what happens when someone chooses a file;
- how to keep a file on a record, with a name that may be private, and show it only to people who may see it;
- how to keep an image's size and alt text, and keep files from people until a scan passes them;
- how to give a file up, and how the sweep removes what nobody claimed;
- how to set up a bucket, and work without one in development and specs.

Before you start: you know [Forms](forms.md) and [Authorization and Roles](authorization-and-roles.md). The examples come from the examples app's `Billing::Receipts`: a user keeps receipts, each with a scan or photo of the paper.

## How an upload goes

An upload takes four steps, and the app writes code for only two of them:

1. **Grant.** The browser asks your Command for an upload, naming the file's size and type. The Command calls `Punch::Upload.grant`, which answers with a one-time ticket and a `PUT` URL.
2. **Send.** The browser sends the file to that URL. Both its size and type are part of the URL's signature, so a storage that checks them refuses a body of another size or type; on any storage, the next step does.
3. **Check.** The browser asks Punch to check what arrived. Punch compares its size and type with the grant, reads its first bytes, and copies it to its final place.
4. **Claim.** The form is sent with the ticket in a hidden field. Your Command calls `Punch::Upload.claim` and keeps the file it gets.

Punch's upload script does steps 2 and 3 in the browser, and steps 1 and 3 are the same for every kind of file. What is yours is the rules, the policy, and the record that keeps the file.

## Declaring a kind of upload

A kind of upload is a type with its rules: the largest file in bytes, and the content types it takes. The examples app's receipt scans:

```crystal source=docs/guides/examples/app/billing/receipts/scan.cr
# app/billing/receipts/scan.cr
module Billing::Receipts
  # A scan or photo of a receipt: at most 10 MB, as a PDF, PNG, or JPEG.
  @[Punch::Upload::Rules(max_size: 10_000_000, types: ["application/pdf", "image/png", "image/jpeg"])]
  struct Scan
    include Punch::Upload::Kind
  end
end
```

Declaring a kind has three consequences at boot. `serve` refuses to start without the table Punch keeps uploads in, so add its migration once:

```console
$ punch db:migration --punch uploads
$ punch db:migrate
```

It refuses to start without settings too, so declare them in the app's credentials ([Settings and the bucket](#settings-and-the-bucket)). And every app with a kind runs `Punch::Upload::Sweep`, which is why the job shows up in `payloads.lock.json`.

The kind's name is its type's path, `billing.receipts.scan`, and it is part of every file's key. Renaming the type leaves existing keys as they are, and they stay valid.

## Granting an upload

The app grants uploads in a Command of its own, so its policy decides who may upload and its rate limit how often:

```crystal source=docs/guides/examples/app/billing/receipts/operations/upload_scan.cr
# app/billing/receipts/operations/upload_scan.cr
module Billing::Receipts
  # Hands out an upload of one scan to a signed-in user: where to send the
  # file, and the ticket that later names it. Each user gets 60 an hour.
  # A grant is a few short fields, so its body is limited too: input is
  # parsed before the user is known.
  @[Punch::Authorize(Punch::SignedIn)]
  @[Punch::RateLimit(60, per: 1.hour, by: :actor)]
  @[Punch::BodyLimit(8 * 1024)]
  struct UploadScan < Punch::Command
    struct Input
      include Punch::Input

      getter size : Int64
      getter content_type : String
      # What the file is called on the user's machine.
      getter filename : Punch::Upload::Filename?
    end

    alias Output = Punch::Upload::Grant | Punch::Rejection

    def call(input : Input, db : Punch::Writer, actor : Examples::Actor, _grant : Punch::Grant(UploadScan)) : Output
      Punch::Upload.grant(db, Scan, size: input.size, content_type: input.content_type, filename: input.filename, owner: actor.user.id.to_s)
    end
  end
end
```

`filename` is what the file is called on the user's machine, which Punch's upload script sends, and which is optional for an API client. `owner` names who may claim the upload: here the user's ID. For an anonymous upload, use something only that visitor has. The claim has to name the same owner, so a ticket that leaks is no use to anyone else.

`grant` checks the request against the kind's rules and returns a `Punch::Rejection` when they forbid it, which answers 422 like any refused input: `too_large` or `out_of_range` at `size`, `unsupported_type` at `content_type`. It also refuses, with `too_many_uploads`, an owner who already holds 20 uploads granted and not claimed.

## A file field in a form

An input field of type `Punch::Upload::Ticket` renders as a file control and a hidden field for the ticket. The Command that saves a receipt takes one:

```crystal source=docs/guides/examples/app/billing/receipts/operations/create.cr select=Billing::Receipts::Create elide=call
# app/billing/receipts/operations/create.cr
module Billing::Receipts
  # ...

  # Saves a receipt with the scan its ticket names. The claim is part of
  # this transaction: a refusal after it leaves the ticket claimable.
  @[Punch::Authorize(Punch::SignedIn)]
  struct Create < Punch::Command
    struct Input
      include Punch::Input

      getter description : Punch::NonEmptyString
      getter scan : Punch::Upload::Ticket
    end

    alias Output = Created | Punch::Rejection

    def call(input : Input, db : Punch::Writer, actor : Examples::Actor, _grant : Punch::Grant(Create)) : Output
      # ...
    end
  end
end
```

The page names the granting Command on the field, and the kind's types for the browser's file picker:

```crystal source=docs/guides/examples/app/billing/receipts/pages/create_page.cr select=Billing::Receipts::NewView
# app/billing/receipts/pages/create_page.cr
module Billing::Receipts
  struct NewView
    include Punch::Component

    def initialize(@actor : Examples::Actor)
    end

    def view(v : Punch::View) : Nil
      t = v.t.receipts
      v.render Examples::Layout.new(t.new_receipt, @actor) do
        v.h1 t.new_receipt
        v.form(Create.action) do |form|
          form.field :description
          form.field :scan, accept: Scan.upload_accept, data: {punch_upload: UploadScan.path}
          form.submit t.save
        end
      end
    end
  end

  # ...
end
```

The file control has no `name`, so the file is never part of the form. When someone chooses a file, Punch's script, `punch/uploads.js`, which every page of an app with kinds of upload loads, grants, sends, checks, and puts the ticket into the hidden field. While it works, and after a failure, the file control is invalid, so the browser does not send the form without its file.

The control's `data-punch-upload-state` is `uploading`, `uploaded`, or `failed`, which is all a stylesheet needs to show progress, and it fires `punch:upload` events with `{state, message}`. A form shown again after a refusal keeps its ticket, so nobody has to choose the file twice.

## Claiming the file

The Command that saves the record claims the upload, and keeps the file in its own table:

```crystal source=docs/guides/examples/app/billing/receipts/operations/create.cr select=Billing::Receipts::Create#call
# app/billing/receipts/operations/create.cr
module Billing::Receipts
  # ...

  # Saves a receipt with the scan its ticket names. The claim is part of
  # this transaction: a refusal after it leaves the ticket claimable.
  @[Punch::Authorize(Punch::SignedIn)]
  struct Create < Punch::Command
    # ...

    def call(input : Input, db : Punch::Writer, actor : Examples::Actor, _grant : Punch::Grant(Create)) : Output
      case file = Punch::Upload.claim(db, input.scan, Scan, owner: actor.user.id.to_s)
      in Punch::Invalid then Punch::Rejection.new(Punch::Rejection::Path{"scan"}, file)
      in Punch::Upload::File
        receipt = Punch.cannot_violate(Table.insert(db, user_id: actor.user.id, description: input.description, scan: file, created_at: Time.utc))
        Created.new(Detail.of(receipt))
      end
    end
  end
end
```

`file` is a `Punch::Upload::File`, a composite Punch ships, with the key, the name, the size, and the type, and room for a scan's result and a date to delete it after. The record keeps it whole as a group of columns, `file_key`, `file_filename`, and so on, so `Table.insert` takes `file` and nothing can be left behind. `columns.cr` maps it without declaring anything:

```crystal source=docs/guides/examples/app/billing/receipts/columns.cr
# app/billing/receipts/columns.cr
# Which columns of these tables hold which domain types (lib/punch/docs/queries.md).
# Read by `punch db:generate` and required by the app.

Punch.table "receipts", Billing::Receipts,
  id: Billing::Receipts::ID,
  user_id: Accounts::Users::ID,
  description: Punch::NonEmptyString,
  scan: {type: Punch::Upload::File, columns: "file_"},
  created_at: Time
```

`claim` refuses a ticket with `upload_not_found` when it does not exist, belongs to another owner or kind, was claimed already, or is more than an hour old, and with `upload_not_checked` when the file has not been checked yet. Both are values you turn into a rejection at the field, so the form shows them beside the file control.

The claim is part of the Command's transaction. A Command that fails after claiming rolls the claim back, and the ticket can claim again.

## Keeping the file's name

`file.filename` comes from `punch_uploads`, which forgets it at the claim, so keeping `file` is what keeps the name. It is a `Punch::Upload::Filename`, a cleaned version of what the client sent: no directories, control characters, or hidden direction characters, at most 255 bytes. Its extension fits the checked type, so a PDF sent as `report.html` is kept as `report.html.pdf`. A file without a name gets a plain one, such as `file.pdf`, so the column can be `NOT NULL`.

The name is for people, to show and to download under. It names nothing in the storage, so never build a path, a key, or a command from it.

## A file with a private name

A file's name can be personal data, and a bank statement's often holds the account holder's. `Punch::Upload::PrivateFile` has the same columns as `File`, with the name encrypted, so its column is a `BLOB`. The mapping is the only thing that changes:

```crystal source=docs/guides/examples/app/billing/statements/columns.cr
# app/billing/statements/columns.cr
# Which columns of these tables hold which domain types (lib/punch/docs/queries.md).
# Read by `punch db:generate` and required by the app.

Punch.table "statements", Billing::Statements,
  id: Billing::Statements::ID,
  user_id: Accounts::Users::ID,
  file: {type: Punch::Upload::PrivateFile, columns: "file_"},
  created_at: Time
```

A claim always returns a `File`, and `PrivateFile.of` makes it private, since a plain `File` does not go into this column:

```crystal source=docs/guides/examples/app/billing/statements/operations/create.cr select=Billing::Statements::Create#call
# app/billing/statements/operations/create.cr
module Billing::Statements
  # ...

  # Saves a statement with the file its ticket names, private from here on.
  @[Punch::Authorize(Punch::SignedIn)]
  struct Create < Punch::Command
    # ...

    def call(input : Input, db : Punch::Writer, actor : Examples::Actor, _grant : Punch::Grant(Create)) : Output
      case file = Punch::Upload.claim(db, input.document, Document, owner: actor.user.id.to_s)
      in Punch::Invalid then Punch::Rejection.new(Punch::Rejection::Path{"document"}, file)
      in Punch::Upload::File
        statement = Punch.cannot_violate(Table.insert(db, user_id: actor.user.id, file: Punch::Upload::PrivateFile.of(file), created_at: Time.utc))
        Created.new(statement.id)
      end
    end
  end
end
```

`filename` is now a `Punch::Secret`, so showing it takes a visible `unwrap`, and a `PrivateFile` does not go into a JSON answer whole. Its links leave the name out as well, since a URL reaches the page, the browser's history, and the storage's logs: `download: true` saves it under a plain name.

```crystal source=docs/guides/examples/app/billing/statements/results.cr select=Billing::Statements::Detail
# app/billing/statements/results.cr
module Billing::Statements
  # A statement as the API shows it to the user who keeps it: `filename` is
  # decrypted here, and `url` saves the file under a plain name, so the real
  # one is in no link. `Create` does not answer with this: a client's
  # idempotency key would keep the name and the link in plaintext.
  @[Punch::Status(200)]
  record Detail,
    id : ID,
    filename : Punch::Upload::Filename,
    url : String? do
    include JSON::Serializable

    def self.of(statement : Record) : self
      new(statement.id, statement.file.filename.unwrap, Punch::Upload.url?(statement.file, download: true))
    end
  end

  # ...
end
```

`Create` answers with the ID alone, and `Show` has the name. An idempotent answer is stored as it is, so a name in it would stay in plaintext whenever a client sends a key ([Uploads: File names](../uploads.md#file-names)).

## Images

An image needs more than a file: its size, so a page can reserve room for it, and alt text for readers who cannot see it. `Punch::Upload::ImageFile` is a `File` with `width`, `height`, and `alt`, and `PrivateImageFile` a `PrivateFile` with the same three, its alt text encrypted, since it describes a private image.

The examples app's logos:

```crystal source=docs/guides/examples/app/billing/logos/columns.cr
# app/billing/logos/columns.cr
# Which columns of these tables hold which domain types (lib/punch/docs/queries.md).
# Read by `punch db:generate` and required by the app.

Punch.table "logos", Billing::Logos,
  id: Billing::Logos::ID,
  user_id: Accounts::Users::ID,
  image: {type: Punch::Upload::ImageFile, columns: "image_"}
```

`ImageFile.of` makes one of a claimed file, and refuses a file that is not an image, a side that cannot be, and alt text over 1,000 characters:

```crystal source=docs/guides/examples/app/billing/logos/operations/create.cr select=Billing::Logos::Create#call
# app/billing/logos/operations/create.cr
module Billing::Logos
  # ...

  # Saves a logo with the file its ticket names. The client measured the
  # image, so its size is what the client says; the alt text is the user's.
  @[Punch::Authorize(Punch::SignedIn)]
  struct Create < Punch::Command
    # ...

    def call(input : Input, db : Punch::Writer, actor : Examples::Actor, _grant : Punch::Grant(Create)) : Output
      file = Punch::Upload.claim(db, input.picture, Picture, owner: actor.user.id.to_s)
      return Punch::Rejection.new(Punch::Rejection::Path{"picture"}, file) if file.is_a?(Punch::Invalid)

      image = Punch::Upload::ImageFile.of(file, alt: input.alt, width: input.width, height: input.height)
      return Punch::Rejection.new(Punch::Rejection::Path{"picture"}, image) if image.is_a?(Punch::Invalid)

      logo = Punch.cannot_violate(Table.insert(db, user_id: actor.user.id, image: image))
      Created.new(logo.id, image.alt, image.width, image.height)
    end
  end
end
```

Punch does not read images, so `width` and `height` are `nil` until you set them. Here the client measured the image, so they are only what it says: use them to lay out a page, not to decide anything.

## Scanning files for malware

Punch does not scan files, but it keeps a file that is waiting for a scan away from people. A kind says it is scanned with `scan: true`:

```crystal source=docs/guides/examples/app/billing/id_scans/photo.cr
# app/billing/id_scans/photo.cr
module Billing::IdScans
  # A photo of an identity document: at most 8 MB, as a JPEG or PNG. The app
  # scans these, so a claimed one starts `pending`.
  @[Punch::Upload::Rules(max_size: 8_000_000, types: ["image/jpeg", "image/png"], scan: true)]
  struct Photo
    include Punch::Upload::Kind
  end
end
```

A claimed file of such a kind starts `pending`, and only a `clean` one is linked to. `url` and `href` raise `Punch::Upload::NotServable` for any other, so in pages and answers use `url?` and `href?`, which answer `nil`:

```crystal source=docs/guides/examples/app/billing/id_scans/results.cr select=Billing::IdScans::Detail
# app/billing/id_scans/results.cr
module Billing::IdScans
  # An ID scan as the API shows it: `url` only once the scan passed it.
  @[Punch::Status(200)]
  record Detail,
    id : ID,
    state : Punch::Upload::ScanState?,
    url : String? do
    include JSON::Serializable

    def self.of(scan : Record) : self
      new(scan.id, scan.photo.scan_state, Punch::Upload.url?(scan.photo, download: true))
    end
  end

  # ...
end
```

Scanning is a job of yours, which the Command that claims the file enqueues. It fetches the file with `unscanned: true`, the one way to a file nobody has passed yet, and saves the result in a transaction of its own, reading the record again so it does not overwrite what changed during the scan:

```crystal illustrative="the shape of a scanning job; Scanner stands for yours"
# app/billing/id_scans/jobs/scan_photo.cr
module Billing::IdScans
  record ScanPhoto, id_scan_id : ID do
    include Punch::Job

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      scan = job.read { |db| Table.find(db, id_scan_id) } || return discard("id scan #{id_scan_id} is gone")
      verdict = Scanner.check(Punch::Upload.url(scan.photo.key, unscanned: true))

      job.write do |db|
        current = Table.find(db, id_scan_id)
        if current && current.photo.key == scan.photo.key
          Punch.cannot_violate(Table.update(db, current.copy_with(photo: current.photo.scanned(verdict))))
          Punch::Upload.purge(db, current.photo) if verdict.quarantined?
        end
      end
      nil
    end
  end
end
```

A URL signed before a quarantine stays good until it expires, so URLs of a scanned kind's files last at most an hour. `purge` gives the file up whoever's it is, and the sweep deletes it, which ends those URLs too. Keep the file instead if you need it as evidence, and accept that hour.

A file with no state in a scanned kind is not served either, so setting `scan: true` on a kind that already has files hides them until you mark them `pending` and scan them ([Uploads: Scanning files](../uploads.md#scanning-files)).

`delete_after`, on every kept file, is a date for your own retention rules. Punch only stores it.

## Showing a file

`Punch::Upload.href(file)` is a link or image source that fetches the file from the storage for an hour. `Punch::Upload.url(file)` is the same as a string, for JSON. `href?` and `url?` answer `nil` for a file that is not servable, and work for every kind:

```crystal source=docs/guides/examples/app/billing/receipts/results.cr select=Billing::Receipts::Detail
# app/billing/receipts/results.cr
module Billing::Receipts
  # A receipt as the API shows it. `scan_url` fetches the scan from the
  # storage for the next hour; a client asks again for a new one.
  @[Punch::Status(200)]
  record Detail,
    id : ID,
    description : Punch::NonEmptyString,
    scan_name : Punch::Upload::Filename,
    scan_type : String,
    scan_size : Int64,
    scan_url : String? do
    include JSON::Serializable

    def self.of(receipt : Record) : self
      scan = receipt.scan
      new(receipt.id, receipt.description, scan.filename, scan.content_type, scan.size, Punch::Upload.url?(scan))
    end
  end

  # ...
end
```

Signing is local: neither the storage nor the database is asked, so nothing checks the viewer when a link is made. What protects a file is the policy on the page or operation that shows its link. The page for a receipt is open only to the user who keeps it:

```crystal source=docs/guides/examples/app/billing/receipts/policies.cr
# app/billing/receipts/policies.cr
module Billing::Receipts
  # A receipt is seen and deleted by the user who keeps it; to anyone else
  # it does not exist (404).
  struct Own
    include Punch::Policy

    def self.check(actor : Examples::Actor, db : Punch::Reader | Punch::Writer, operation : Punch::Operation.class, *,
                   receipt_id : ID) : Punch::Policy::Decision
      Table.find(db, receipt_id).try(&.user_id) == actor.user.id ? allow : not_found
    end
  end
end
```

```crystal source=docs/guides/examples/app/billing/receipts/pages/show_page.cr
# app/billing/receipts/pages/show_page.cr
module Billing::Receipts
  @[Punch::Status(200)]
  struct DetailView
    include Punch::Component

    def initialize(@receipt : Record, @actor : Examples::Actor)
    end

    def view(v : Punch::View) : Nil
      t = v.t.receipts
      v.render Examples::Layout.new(@receipt.description.to_s, @actor) do
        v.h1 @receipt.description.to_s
        if link = Punch::Upload.href?(@receipt.scan, download: true)
          v.p { v.a @receipt.scan.filename.to_s, href: link }
        end
        v.form(Destroy.action(receipt_id: @receipt.id)) { |form| form.submit t.delete }
      end
    end
  end

  # One receipt, with a link that fetches its scan from the storage. Only
  # the user who keeps it gets here, so the link reaches no one else.
  @[Punch::Authorize(Own)]
  @[Punch::Forms(Destroy)]
  struct ShowPage < Punch::Page
    alias Input = Show::Input

    alias Output = DetailView | NotFound

    def call(input : Input, db : Punch::Reader, actor : Examples::Actor) : Output
      receipt = Table.find(db, input.receipt_id)
      receipt ? DetailView.new(receipt, actor) : NotFound.new
    end

    # After a deleted receipt, a new one.
    def self.redirect(result : Nil) : Punch::Href
      CreatePage.href
    end
  end
end
```

`expires:` sets how long a URL works, up to 7 days. `download: true` makes the browser save the file under its name, a `PrivateFile` under a plain one, and `download: name` under that `Filename`. Files are served by the storage, from its origin, never the app's. PDFs and most images (PNG, JPEG, GIF, WebP, AVIF) are shown inline, and everything else downloads, HEIC among them. Script in a file cannot run in your pages.

## Giving a file up

When a record goes, its file should too. `Punch::Upload.discard` marks the file in the Command's transaction:

```crystal source=docs/guides/examples/app/billing/receipts/operations/destroy.cr select=Billing::Receipts::Destroy#call
# app/billing/receipts/operations/destroy.cr
module Billing::Receipts
  # Deletes a receipt and gives up its scan: the sweep deletes the file
  # from the storage after this transaction commits.
  @[Punch::Authorize(Own)]
  struct Destroy < Punch::Command
    # ...

    def call(input : Input, db : Punch::Writer, actor : Examples::Actor, _grant : Punch::Grant(Destroy)) : Output
      receipt = Table.find(db, input.receipt_id) || return NotFound.new

      Table.delete(db, receipt.id)
      Punch::Upload.discard(db, receipt.scan, owner: actor.user.id.to_s)
      nil
    end
  end
end
```

`Punch::Upload::Sweep`, which runs every ten minutes, deletes the file from the storage after the commit, so a Command that fails keeps its file. It also removes what was granted and never claimed within the hour. A storage it cannot reach leaves those rows for the next run. `discard` returns whether the key was a claimed file of that owner, and another owner's key changes nothing. A job with no owner at hand uses `purge`.

## Settings and the bucket

Uploads are configured as a group in the app's credentials:

```crystal source=docs/guides/examples/app/credentials.cr
# app/credentials.cr
# What the app needs from its deployment, checked at boot: each value from
# the environment first (MAIL__FROM), then from the encrypted
# config/credentials/<env>.yml.enc. `punch creds:check` shows where each
# came from (lib/punch/docs/credentials.md).
struct Examples::Credentials
  include Punch::Credentials

  # Signs and encrypts what the app hands out; rotated with `punch
  # keys:rotate` (lib/punch/docs/keys.md).
  getter secret_key_base : Punch::KeyRing
  # The key of public IDs (`public_id "inv"` on an ID type); never
  # rotated, since every public ID depends on it (lib/punch/docs/keys.md).
  getter public_id_key : Punch::PublicIDKey
  # How mail leaves the app: captured in development
  # (MAIL__DELIVERY=capture, shown at /_punch/mail), sent by SMTP in
  # production (lib/punch/docs/mail.md).
  getter mail : Punch::Mailer::Settings
  # Where uploaded files go (lib/punch/docs/uploads.md): `local` in
  # development and test, a bucket in production.
  getter uploads : Punch::Upload::Settings
  # Where alerts for the people who run the app go
  # (`Operators::AlertOperators`); without one, nobody is alerted.
  getter alert_to : Punch::Email?
end
```

In development, `storage: local` keeps files in `uploads/` in `PUNCH_STORAGE`, and the app answers the signed requests itself with the same checks a bucket makes. Boot refuses `local` outside development and test. In production, name a bucket:

```yaml illustrative="the uploads group of a production credentials file"
uploads:
  storage: s3
  bucket: example-uploads
  region: eu-central-1
  access_key_id: AKIA…
  secret_access_key: …
```

`endpoint` and `path_style` cover S3-compatible providers such as Cloudflare R2, Backblaze B2, Hetzner, and MinIO; [Uploads: Settings](../uploads.md#settings) has the table.

The bucket needs four things:

- **Private.** No public access: every file is read through a signed URL.
- **Its own keys,** for this bucket alone, that may put, get, and delete objects. Not the backup's keys.
- **CORS,** so your pages may send files and read the answers ([Setting up the bucket](../uploads.md#setting-up-the-bucket)).
- **A lifecycle rule** that deletes objects under `pending/` a day after they were created, for what the sweep cannot know about.

The bucket is not part of `punch restore`, so keep its versioning or replication with the provider. A restored database may name files discarded since, and lack keys of files claimed since.

## Uploading without a browser

An API client or an agent takes the same steps by hand: `POST` the granting Command, `PUT` the file to `url` with every header in `headers`, exactly, then `POST /_punch/uploads/check` with `{"ticket": "upl_…"}`, and send the ticket in the Command that saves the record. The check answers 200, or a problem such as 409 `upload_incomplete` when nothing has arrived yet, or 422 `upload_mismatch` when the file was deleted and has to be sent again. It is Punch's own route, so it is not in `openapi.json` ([Uploads: Without a browser](../uploads.md#without-a-browser)).

## Testing uploads

Specs never reach a bucket. `Punch::Spec.uploads` keeps files in a temporary directory, and `Punch::Spec.upload` sends a file as a browser would and asks for the check, so the example starts with a checked upload and a ticket:

```crystal source=docs/guides/examples/spec/billing/receipts/upload_spec.cr select=PNG,FILENAME,#uploaded,Billing::Receipts::Create
# spec/billing/receipts/upload_spec.cr
private PNG = "\x89PNG\r\n\x1A\n".to_slice + Bytes.new(24, 7_u8)

private FILENAME = ExamplesSpec.parse(Punch::Upload::Filename, "Taxi Hamburg.png")

# A scan of *user*'s, granted and sent to the storage, as a browser does.
private def uploaded(user : Accounts::Users::Record) : Punch::Upload::Grant
  Punch::Spec.uploads
  grant = Punch::Spec.db.write do |db|
    Punch::Upload.grant(db, Billing::Receipts::Scan, size: PNG.size, content_type: "image/png", owner: user.id.to_s, filename: FILENAME)
  end.as(Punch::Upload::Grant)
  Punch::Spec.upload(grant, PNG, Punch::Spec.db).should be_a(Punch::Upload::Checked)
  grant
end

# ...

describe Billing::Receipts::Create do
  it "saves a receipt with the scan its ticket names, once" do
    user = AccountsSpec.user
    client = Punch::Spec.client.sign_in(user.id)
    grant = uploaded(user)

    created = client.post(Billing::Receipts::Create.path, json: {description: "Taxi", scan: grant.ticket.value})
    created.status.should eq(HTTP::Status::CREATED)
    created.json["receipt"]["scan_type"].should eq("image/png")
    created.json["receipt"]["scan_size"].should eq(PNG.size)
    created.json["receipt"]["scan_name"].should eq("Taxi Hamburg.png")

    again = client.post(Billing::Receipts::Create.path, json: {description: "Taxi", scan: grant.ticket.value})
    again.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    again.json["errors"][0]["code"].should eq("upload_not_found")
  end

  it "refuses another user's ticket" do
    grant = uploaded(AccountsSpec.user)
    refused = AccountsSpec.client.post(Billing::Receipts::Create.path, json: {description: "Taxi", scan: grant.ticket.value})
    refused.json["errors"][0]["path"].should eq(JSON.parse(%(["scan"])))
    refused.json["errors"][0]["code"].should eq("upload_not_found")
  end
end

# ...
```

The file has to start the way its type says. A PNG in a spec needs the PNG signature; an empty byte slice is refused like any other mismatch.

## Common mistakes

**Taking a key from a request.** A key names a stored file and `url` signs it without asking who wants it, so a client that could send one could read another user's file:

```crystal fails=spec/fail/upload_key_in_input.cr
struct Detach
  include Punch::Input

  getter scan : Punch::Upload::Key
end

Detach.from_json(%({"scan": "scans/aaaaaaaaaaaaaaaaaaaaaaaaaa"}))
```

```text
Punch: Detach#scan takes a Punch::Upload::Key, the key of a stored file
```

Take the ID of the record that holds the key, load the record as the viewer may, and use its key.

**Allowing a type that runs script.** A kind cannot take HTML, SVG, XML, or JavaScript:

```crystal fails=spec/fail/upload_kind_html.cr
@[Punch::Upload::Rules(max_size: 1_000_000, types: ["image/png", "text/html"])]
struct Page
  include Punch::Upload::Kind
end

Punch::Upload.kinds
```

```text
@[Punch::Upload::Rules] on Page: Punch does not take "text/html"
```

Upload such files as `application/octet-stream`, which always downloads.

**Sending the form before the file arrived.** A client that claims before it checks gets a refusal at the field:

```text message=src/punch/locales/en.yml
Has not finished uploading. Wait for it, then send the form again.
```

The browser's form waits by itself. An API client has to finish the check first.

**Letting a client set a file's state.** A client must not call its own file clean:

```crystal fails=spec/fail/upload_scan_state_in_input.cr
# A client must not name the state of its own file.
struct Scanned
  include Punch::Input

  getter state : Punch::Upload::ScanState
end

Scanned.from_json(%({"state": "clean"}))
```

```text
Punch: Scanned#state takes a Punch::Upload::ScanState
```

Only your scanning job sets a state.

**Calling `href` in a list of a scanned kind.** One waiting file raises `Punch::Upload::NotServable`, a 500 for everyone who opens the list, and any user can upload one. Use `href?`.

**Adding a route that streams files.** Reading a file through the app ties up a connection and memory for as long as the transfer takes. Link to the storage with `Punch::Upload.href`, and put the link only on pages whose viewer may see the file.

**Deleting a record without discarding its file.** The file stays in the bucket for good, and nothing will ever sweep it, since the sweep removes only unclaimed and discarded files. Call `discard` in the same Command.

## Limits

- Punch compares a file's first bytes with its declared type. A file that starts as its type and holds something else later passes. Scan for malware in a job that reads the file from the storage.
- There is no image processing or resizing.
- One `PUT` is the only way up, so a file is at most 5 GB. There are no multipart or resumable uploads.
- Files are not part of the backup.
- Punch does not scan files, read an image's size, or act on `delete_after`.
- A nilable private file cannot be mapped yet: keep an optional private file in a child table.
- Quarantine stops new links, not URLs already signed, which last at most an hour for a scanned kind.
- A file shown inline has no name of its own: saved from the browser, it gets its upload ID. `download:` names a download.

## Rules

- Declare a kind per use, with the smallest size and the fewest types that work. ([Declaring a kind of upload](#declaring-a-kind-of-upload))
- Grant in a Command with a policy and a rate limit. ([Granting an upload](#granting-an-upload))
- Name the same owner when you grant, claim, and discard. ([Claiming the file](#claiming-the-file))
- Use `url?` and `href?` for a kind that is scanned; pass `unscanned: true` only in the job that scans. ([Scanning files for malware](#scanning-files-for-malware))
- Keep the claimed `file` whole, and never build a path, key, or command from its name. ([Keeping the file's name](#keeping-the-files-name))
- Keep a file as a `PrivateFile` when its name can be personal data. ([A file with a private name](#a-file-with-a-private-name))
- Never take a key from a request; load the record that holds it. ([Common mistakes](#common-mistakes))
- Put a file's URL only on a page whose viewer may see the file. ([Showing a file](#showing-a-file))
- Discard a file in the Command that deletes its record. ([Giving a file up](#giving-a-file-up))
- Keep multipart refused, and never add a route that streams a file. ([How an upload goes](#how-an-upload-goes))
- Keep the bucket private, with keys of its own. ([Settings and the bucket](#settings-and-the-bucket))

## Reference

- [Uploads](../uploads.md): every rule, setting, provider, and answer of the check.
- [HTTP](../http.md): the refusal of multipart requests.
- [Credentials](../credentials.md): how a group of settings is declared and read.
- Next: [Forms](forms.md) for the rest of what a form can do, or [Securing Punch Applications](securing-punch-applications.md).
