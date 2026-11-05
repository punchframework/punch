# What an app keeps of an uploaded file, as a group of columns of its own
# table (lib/punch/docs/uploads.md). Declared here once, so an app maps them
# without declaring anything: `punch db:generate` knows these in every app,
# and `punch db:generate` in Punch itself writes composites.gen.cr.
Punch.composite Punch::Upload::File,
  key: Punch::Upload::Key,
  filename: Punch::Upload::Filename,
  size: Int64,
  content_type: String,
  scan_state: Punch::Upload::ScanState?,
  delete_after: Time?

Punch.composite Punch::Upload::PrivateFile,
  key: Punch::Upload::Key,
  filename: Punch::Encrypted(Punch::Upload::Filename),
  size: Int64,
  content_type: String,
  scan_state: Punch::Upload::ScanState?,
  delete_after: Time?

Punch.composite Punch::Upload::ImageFile,
  key: Punch::Upload::Key,
  filename: Punch::Upload::Filename,
  size: Int64,
  content_type: String,
  scan_state: Punch::Upload::ScanState?,
  delete_after: Time?,
  width: Int64?,
  height: Int64?,
  alt: Punch::NonEmptyString?

Punch.composite Punch::Upload::PrivateImageFile,
  key: Punch::Upload::Key,
  filename: Punch::Encrypted(Punch::Upload::Filename),
  size: Int64,
  content_type: String,
  scan_state: Punch::Upload::ScanState?,
  delete_after: Time?,
  width: Int64?,
  height: Int64?,
  alt: Punch::Encrypted(Punch::NonEmptyString)?
