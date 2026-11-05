require "../spec_helper"

module UploadSpec
  PNG  = "\x89PNG\r\n\x1A\n".to_slice + Bytes.new(24, 7_u8)
  PDF  = "%PDF-1.7\n%âãÏÓ\n1 0 obj\n".to_slice
  HTML = "<html><script>alert(1)</script>".to_slice

  @[Punch::Upload::Rules(max_size: 1_000, types: ["image/png", "application/pdf"])]
  struct Scan
    include Punch::Upload::Kind
  end

  @[Punch::Upload::Rules(max_size: 1_000, types: ["image/png"], scan: true)]
  struct Scanned
    include Punch::Upload::Kind
  end

  @[Punch::Upload::Rules(max_size: 5_000_000_000, types: ["text/csv", "application/octet-stream"])]
  struct Import
    include Punch::Upload::Kind
  end

  @[Punch::Public]
  @[Punch::RateLimitExempt("a spec fixture")]
  struct Attach < Punch::Command
    struct Input
      include Punch::Input

      getter scan : Punch::Upload::Ticket
    end

    def call(input : Input, db : Punch::Writer) : Nil
    end
  end

  @[Punch::Public]
  struct AttachPage < Punch::Page
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader) : AttachForm
      AttachForm.new
    end
  end

  struct AttachForm
    include Punch::Component

    def view(v : Punch::View) : Nil
      v.document("Attach") do
        v.form(Attach.action) do |form|
          form.field :scan, accept: Scan.upload_accept, data: {punch_upload: "/scans/uploads"}
        end
      end
    end
  end

  def self.with_db(&)
    path = File.tempname("upload-spec", ".sql")
    File.write(path, Punch::Upload.sql)
    previous = Punch::Spec.schema
    Punch::Spec.schema = path
    directory = File.tempname("upload-spec-files")
    storage = Punch::Spec.uploads(directory)
    begin
      yield storage
    ensure
      Punch::Spec.schema = previous
      Punch::Upload.storage = nil
      File.delete(path)
      FileUtils.rm_rf(directory)
    end
  end

  def self.grant(owner : String = "user-1", size : Int = PNG.size, type : String = "image/png", now : Time = Time.utc) : Punch::Upload::Grant
    Punch::Spec.db.write { |db| Punch::Upload.grant(db, Scan, size: size, content_type: type, owner: owner, now: now) }.as(Punch::Upload::Grant)
  end

  def self.rows : Array({String, String})
    Punch::Spec.db.read do |db|
      db.query_all("SELECT kind, state FROM punch_uploads ORDER BY created_at") { |row| {row.read(String), row.read(String)} }
    end
  end

  def self.files(directory : String) : Array(String)
    Dir.glob("#{directory}/**/*").select { |path| File.file?(path) && !path.ends_with?(".meta") }.map(&.lchop(directory + "/")).sort!
  end

  # A stand-in for an S3 endpoint that keeps objects in memory and answers
  # HEAD, ranged GET, PUT (and copy), and DELETE, recording each request.
  class S3
    record Received, method : String, resource : String, headers : ::HTTP::Headers

    getter received = [] of Received
    getter objects = {} of String => {Bytes, ::HTTP::Headers}
    getter port : Int32

    def initialize
      @server = ::HTTP::Server.new do |context|
        request = context.request
        @received << Received.new(request.method, request.resource, request.headers.dup)
        case request.method
        when "HEAD"   then head(request.path, context.response)
        when "GET"    then get(request, context.response)
        when "PUT"    then request.headers["x-amz-copy-source"]? ? copy(request, context.response) : store(request)
        when "DELETE" then @objects.delete(request.path).tap { context.response.status_code = 204 }
        end
      end
      @port = @server.bind_tcp("127.0.0.1", 0).port
      spawn { @server.listen }
    end

    private def head(key : String, response : ::HTTP::Server::Response) : Nil
      found = @objects[key]? || return response.status_code = 404
      response.headers["Content-Type"] = found[1]["Content-Type"]
      response.headers["ETag"] = found[1]["ETag"]
      response.content_length = found[0].size
    end

    private def get(request : ::HTTP::Request, response : ::HTTP::Server::Response) : Nil
      found = @objects[request.path]? || return response.status_code = 404
      return response.status_code = 412 unless request.headers["If-Match"]? == found[1]["ETag"]

      bytes = request.headers["Range"]?.try { |text| text[/bytes=0-(\d+)/, 1].to_i + 1 } || found[0].size
      response.status_code = 206
      response.write(found[0][0, {bytes, found[0].size}.min])
    end

    private def copy(request : ::HTTP::Request, response : ::HTTP::Server::Response) : Nil
      found = @objects[URI.decode(request.headers["x-amz-copy-source"])]?
      unless found && request.headers["x-amz-copy-source-if-match"]? == found[1]["ETag"]
        response.status_code = 412
        return response.print "<Error><Code>PreconditionFailed</Code></Error>"
      end
      @objects[request.path] = {found[0], ::HTTP::Headers{"Content-Type" => request.headers["Content-Type"], "ETag" => found[1]["ETag"],
                                                          "Content-Disposition" => request.headers["Content-Disposition"]}}
      response.print "<CopyObjectResult><ETag>#{found[1]["ETag"]}</ETag></CopyObjectResult>"
    end

    private def store(request : ::HTTP::Request) : Nil
      body = request.body.try(&.getb_to_end) || Bytes.empty
      @objects[request.path] = {body, ::HTTP::Headers{"Content-Type" => request.headers["Content-Type"]? || "binary/octet-stream", "ETag" => %("#{Digest::MD5.hexdigest(body)}")}}
    end

    def storage : Punch::Upload::S3Storage
      bucket = Punch::S3::Bucket.new("uploads", "eu-central-1", URI.parse("http://127.0.0.1:#{@port}"), true)
      Punch::Upload::S3Storage.new(bucket, Punch::S3::SigV4::Credentials.new("AKIDSPEC", "spec-secret", nil), "app/", 5.seconds)
    end

    def put(key : String, body : Bytes, type : String) : Nil
      @objects["/uploads/#{key}"] = {body, ::HTTP::Headers{"Content-Type" => type, "ETag" => %("#{Digest::MD5.hexdigest(body)}")}}
    end

    def close : Nil
      @server.close unless @server.closed?
    end
  end
end

describe Punch::S3::SigV4 do
  it "presigns as AWS's published example of a presigned URL" do
    credentials = Punch::S3::SigV4::Credentials.new("AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", nil)
    query = Punch::S3::SigV4.presign("GET", "examplebucket.s3.amazonaws.com", "/test.txt", {} of String => String, ::HTTP::Headers.new,
      credentials, "us-east-1", Time.utc(2013, 5, 24), 86400.seconds)
    query.should eq("X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request" \
                    "&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host" \
                    "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")
  end

  it "signs the headers it is given, so the storage refuses a body of another size" do
    credentials = Punch::S3::SigV4::Credentials.new("AKID", "secret", "token")
    bucket = Punch::S3::Bucket.new("uploads", "auto", URI.parse("https://account.r2.cloudflarestorage.com"), false)
    url = URI.parse(bucket.presign("PUT", "app/pending/k", credentials, now: Time.utc, expires: 10.minutes,
      headers: ::HTTP::Headers{"Content-Length" => "8", "Content-Type" => "image/png"}))
    url.host.should eq("uploads.account.r2.cloudflarestorage.com")
    url.path.should eq("/app/pending/k")
    url.query_params["X-Amz-SignedHeaders"].should eq("content-length;content-type;host")
    url.query_params["X-Amz-Expires"].should eq("600")
    url.query_params["X-Amz-Security-Token"].should eq("token")
    expect_raises(ArgumentError) { bucket.presign("GET", "k", credentials, now: Time.utc, expires: 8.days) }
  end
end

describe Punch::Upload do
  it "reads a kind's rules from its annotation" do
    rules = UploadSpec::Scan.upload_rules
    rules.name.should eq("upload_spec.scan")
    rules.max_size.should eq(1_000)
    rules.types.should eq(["image/png", "application/pdf"])
    UploadSpec::Scan.upload_accept.should eq("image/png,application/pdf")
    Punch::Upload.kinds.keys.should contain("upload_spec.import")
    Punch::Upload.used?.should be_true
    # The sweep is a recurring job only where kinds exist.
    Punch::Job::Queue.tasks.map(&.type).should contain("Punch::Upload::Sweep")
  end

  it "checks first bytes against each type" do
    Punch::Upload::TYPES.keys.sort!.should eq(Punch::Upload::TYPE_NAMES.sort)
    check = ->(type : String, bytes : Bytes) { Punch::Upload::TYPES[type].check.call(bytes) }
    check.call("image/png", UploadSpec::PNG).should be_true
    check.call("image/png", UploadSpec::PDF).should be_false
    check.call("application/pdf", UploadSpec::PDF).should be_true
    check.call("image/jpeg", Bytes[0xFF, 0xD8, 0xFF, 0xE0]).should be_true
    check.call("image/gif", "GIF89a...".to_slice).should be_true
    check.call("image/webp", "RIFF\0\0\0\0WEBPVP8 ".to_slice).should be_true
    check.call("image/avif", "\0\0\0\x1Cftypavif".to_slice).should be_true
    check.call("text/csv", "name,amount\nAda,12\n".to_slice).should be_true
    check.call("text/csv", "a\0b".to_slice).should be_false
    check.call("text/plain", ("a" * 511 + "\xC3").to_slice).should be_true # cut off at the end of what was read
    check.call("text/plain", "caf\xC3".to_slice).should be_false
    check.call("text/plain", "\xFF\xFEa".to_slice).should be_false
    check.call("application/zip", "PK\u{3}\u{4}rest".to_slice).should be_true
    check.call("application/octet-stream", UploadSpec::HTML).should be_true
    Punch::Upload::Storage.disposition("image/png").should eq("inline")
    Punch::Upload::Storage.disposition("text/csv").should eq("attachment")
    Punch::Upload::Storage.disposition("application/octet-stream").should eq("attachment")
  end

  it "grants, checks, and claims an upload" do
    UploadSpec.with_db do |storage|
      grant = UploadSpec.grant
      grant.ticket.value.should match(Punch::Upload::Ticket::PATTERN)
      grant.headers.should eq({"Content-Type" => "image/png", "Content-Length" => UploadSpec::PNG.size.to_s})
      grant.check.should eq("/_punch/uploads/check")
      grant.url.should start_with("/_punch/uploads/local/pending/")
      grant.to_json.should_not contain("digest")
      grant.ticket.inspect.should_not contain(grant.ticket.value)

      # Not yet checked: the app cannot claim it.
      Punch::Spec.db.write { |db| Punch::Upload.claim(db, grant.ticket, UploadSpec::Scan, owner: "user-1") }.should be_invalid("upload_not_checked")

      checked = Punch::Spec.upload(grant, UploadSpec::PNG, Punch::Spec.db).as(Punch::Upload::Checked)
      checked.size.should eq(UploadSpec::PNG.size)
      checked.to_json.should eq(%({"size":#{UploadSpec::PNG.size},"content_type":"image/png"}))
      # Checking again answers the same.
      Punch::Upload.check(Punch::Spec.db, grant.ticket).should be_a(Punch::Upload::Checked)
      UploadSpec.files(storage.directory).should eq(["files/upload_spec.scan/#{UploadSpec.files(storage.directory).first.split('/').last}"])

      Punch::Spec.db.write { |db| Punch::Upload.claim(db, grant.ticket, UploadSpec::Scan, owner: "user-2") }.should be_invalid("upload_not_found")
      Punch::Spec.db.write { |db| Punch::Upload.claim(db, grant.ticket, UploadSpec::Import, owner: "user-1") }.should be_invalid("upload_not_found")
      file = Punch::Spec.db.write { |db| Punch::Upload.claim(db, grant.ticket, UploadSpec::Scan, owner: "user-1") }.as(Punch::Upload::File)
      file.key.kind.should eq("upload_spec.scan")
      file.content_type.should eq("image/png")
      Punch::Upload::Key.parse(file.key.value).should eq(file.key)
      # A ticket claims once.
      Punch::Spec.db.write { |db| Punch::Upload.claim(db, grant.ticket, UploadSpec::Scan, owner: "user-1") }.should be_invalid("upload_not_found")
      Punch::Upload.check(Punch::Spec.db, grant.ticket).should eq(Punch::Upload::Refused.new(:not_found, "upload_not_found"))
      UploadSpec.rows.should eq([{"upload_spec.scan", "claimed"}])

      # The signed URL serves the checked file, sandboxed.
      url = URI.parse(Punch::Upload.url(file.key, download: "scan \"1\".png"))
      response = Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db), openapi: nil).get(url.path, query: url.query_params.to_h)
      response.status.should eq(HTTP::Status::OK)
      response.body.to_slice.should eq(UploadSpec::PNG)
      response.headers["Content-Type"].should eq("image/png")
      response.headers["Content-Disposition"].should eq(%(attachment; filename="scan _1_.png"; filename*=UTF-8''scan%20%221%22.png))
      response.headers["Content-Security-Policy"].should eq("default-src 'none'; sandbox")
    end
  end

  it "refuses a grant the kind's rules forbid, and too many waiting uploads" do
    UploadSpec.with_db do
      Punch::Spec.db.write { |db| Punch::Upload.grant(db, UploadSpec::Scan, size: 1_001, content_type: "image/png", owner: "u") }
        .should be_rejected("size", code: "too_large")
      Punch::Spec.db.write { |db| Punch::Upload.grant(db, UploadSpec::Scan, size: 0, content_type: "image/png", owner: "u") }
        .should be_rejected("size", code: "out_of_range")
      Punch::Spec.db.write { |db| Punch::Upload.grant(db, UploadSpec::Scan, size: 10, content_type: "text/html", owner: "u") }
        .should be_rejected("content_type", code: "unsupported_type")
      Punch::Upload.pending_limit.times { UploadSpec.grant("busy") }
      Punch::Spec.db.write { |db| Punch::Upload.grant(db, UploadSpec::Scan, size: 10, content_type: "image/png", owner: "busy") }
        .should be_rejected(code: "too_many_uploads")
      UploadSpec.grant("other").should be_a(Punch::Upload::Grant)
    end
  end

  it "deletes what does not match the grant, and what has not arrived is incomplete" do
    UploadSpec.with_db do |storage|
      grant = UploadSpec.grant(size: UploadSpec::PDF.size)
      Punch::Upload.check(Punch::Spec.db, grant.ticket).should eq(Punch::Upload::Refused.new(:conflict, "upload_incomplete"))
      Punch::Spec.upload(grant, UploadSpec::PDF, Punch::Spec.db).should eq(Punch::Upload::Refused.new(:unprocessable_entity, "upload_mismatch"))
      UploadSpec.files(storage.directory).should be_empty
      # The storage refuses another size or type outright.
      expect_raises(ArgumentError, /refuses 31 bytes/) { Punch::Spec.upload(UploadSpec.grant, UploadSpec::HTML, Punch::Spec.db) }
      expect_raises(ArgumentError, /refuses text\/html/) { Punch::Spec.upload(UploadSpec.grant, UploadSpec::PNG, Punch::Spec.db, "text/html") }
    end
  end

  it "sweeps what was never claimed and what the app discarded" do
    UploadSpec.with_db do |storage|
      past = Time.utc - 2.hours
      old = UploadSpec.grant(now: past)
      # Sent, never checked.
      storage.write(URI.parse(old.url).path.lchop(Punch::Upload::LOCAL_PATH), IO::Memory.new(UploadSpec::PNG), UploadSpec::PNG.size.to_i64, "image/png")
      kept = UploadSpec.grant
      Punch::Spec.upload(kept, UploadSpec::PNG, Punch::Spec.db)
      file = Punch::Spec.db.write { |db| Punch::Upload.claim(db, kept.ticket, UploadSpec::Scan, owner: "user-1") }.as(Punch::Upload::File)
      Punch::Spec.db.write { |db| Punch::Upload.claim(db, old.ticket, UploadSpec::Scan, owner: "user-1") }.should be_invalid("upload_not_found")

      Punch::Upload::Sweep.run(Punch::Spec.db).should eq(1)
      UploadSpec.rows.should eq([{"upload_spec.scan", "claimed"}])
      Punch::Spec.db.write { |db| Punch::Upload.discard(db, file.key, owner: "user-2") }.should be_false
      Punch::Spec.db.write { |db| Punch::Upload.discard(db, file.key, owner: "user-1") }.should be_true
      Punch::Spec.db.write { |db| Punch::Upload.discard(db, file.key, owner: "user-1") }.should be_false
      Punch::Upload::Sweep.run(Punch::Spec.db).should eq(1)
      UploadSpec.rows.should be_empty
      UploadSpec.files(storage.directory).should be_empty
    end
  end

  it "deletes a pending file of another size once its URL has expired" do
    UploadSpec.with_db do |storage|
      past = Time.utc - 11.minutes
      sent = ->(grant : Punch::Upload::Grant, bytes : Bytes) do
        storage.write(URI.parse(grant.url).path.lchop(Punch::Upload::LOCAL_PATH), IO::Memory.new(bytes), bytes.size.to_i64, "image/png")
      end
      large = UploadSpec.grant(now: past)
      sent.call(large, UploadSpec::PNG + UploadSpec::PNG)
      slow = UploadSpec.grant(now: past)
      sent.call(slow, UploadSpec::PNG)
      fresh = UploadSpec.grant
      sent.call(fresh, UploadSpec::PNG + UploadSpec::PNG)
      UploadSpec.grant(now: past) # nothing arrived

      Punch::Upload::Sweep.trim(Punch::Spec.db).should eq(1)
      Punch::Upload::Sweep.trim(Punch::Spec.db).should eq(0)
      Punch::Upload.check(Punch::Spec.db, large.ticket).as(Punch::Upload::Refused).code.should eq("upload_incomplete")
      Punch::Upload.check(Punch::Spec.db, slow.ticket).should be_a(Punch::Upload::Checked)
    end
  end

  it "takes names and keys that are not UTF-8 without raising" do
    bad = String.new(Bytes[0x61, 0xFF, 0x00])
    Punch::Upload.attachment(bad).should eq(%(attachment; filename="a__"; filename*=UTF-8''a%EF%BF%BD%00))
    ::HTTP::Headers.new.valid_value?(Punch::Upload.attachment(bad)).should be_true
    Punch::Upload::Ticket.parse(bad).should be_invalid("invalid_upload")
    Punch::Upload::Key.parse(bad).should be_invalid("invalid_upload")
    Punch::Upload::Storage.valid_object?(bad).should be_false
    Punch::Upload::Storage.pending?(bad).should be_false
  end

  describe Punch::Upload::Filename do
    it "keeps what a person calls a file" do
      {"Rechnung März 2026.pdf", "scan (1).PNG", "résumé.final.docx", "レシート.jpg"}.each do |name|
        Punch::Upload::Filename.parse(name).as(Punch::Upload::Filename).value.should eq(name)
      end
    end

    it "takes off directories, control and direction characters, and dots at the ends" do
      {
        "../../etc/passwd"       => "passwd",
        "C:\\fakepath\\scan.png" => "scan.png",
        "a\u0000b\r\nc.png"      => "a b c.png",
        "invoice\u{202E}fdp.exe" => "invoicefdp.exe",
        "zero\u{200B}width.png"  => "zerowidth.png",
        "  .htaccess. "          => "htaccess",
        "many   spaces.png"      => "many spaces.png",
        "e\u0301.png"            => "\u00E9.png",
      }.each do |raw, clean|
        Punch::Upload::Filename.parse(raw).as(Punch::Upload::Filename).value.should eq(clean)
      end
    end

    it "refuses a name with nothing left, and takes bytes that are not UTF-8" do
      ["", "   ", "..", "dir/", "\u0000", "\u{202E}"].each { |raw| Punch::Upload::Filename.parse(raw).should be_invalid("invalid_filename") }
      Punch::Upload::Filename.parse(String.new(Bytes[0x61, 0xFF, 0x2E, 0x70, 0x6E, 0x67])).as(Punch::Upload::Filename).value.should eq("a.png")
    end

    it "shortens a long name before its extension, on a character" do
      name = Punch::Upload::Filename.parse("ä#{"ü" * 200}.pdf").as(Punch::Upload::Filename).value
      name.bytesize.should be <= 255
      name.valid_encoding?.should be_true
      name.should end_with(".pdf")
      Punch::Upload::Filename.parse(name).as(Punch::Upload::Filename).value.should eq(name)
    end

    it "fits the name to the type the check accepts" do
      parse = ->(raw : String) { Punch::Upload::Filename.parse(raw).as(Punch::Upload::Filename) }
      parse.call("report.html").for("application/pdf").value.should eq("report.html.pdf")
      parse.call("noextension").for("image/png").value.should eq("noextension.png")
      parse.call("scan.PDF").for("application/pdf").value.should eq("scan.PDF")
      parse.call("photo.jpeg").for("image/jpeg").value.should eq("photo.jpeg")
      parse.call("anything.bin").for("application/octet-stream").value.should eq("anything.bin")
      parse.call("#{"a" * 255}").for("image/png").value.bytesize.should be <= 255
      parse.call("#{"a" * 255}").for("image/png").value.should end_with(".png")
    end

    it "costs the same whatever a stranger sends" do
      started = Time.instant
      Punch::Upload::Filename.parse("a" * 1_048_576).should be_invalid("invalid_filename")
      name = Punch::Upload::Filename.parse("a" * Punch::Upload::Filename::MAX_RAW_BYTES).as(Punch::Upload::Filename)
      name.value.bytesize.should be <= Punch::Upload::Filename::MAX_BYTES
      (Time.instant - started).should be < 100.milliseconds
    end

    it "does not show a whole name in inspect" do
      Punch::Upload::Filename.parse("Sick note Ada.pdf").as(Punch::Upload::Filename).inspect.should eq("Punch::Upload::Filename(…)")
    end

    it "takes off what fonts draw as nothing" do
      Punch::Upload::Filename.parse("a\u{3164}\u{34F}\u{FE0F}b.pdf").as(Punch::Upload::Filename).value.should eq("ab.pdf")
      Punch::Upload::Filename.parse("\u{3164}").should be_invalid("invalid_filename")
    end

    it "has extensions for every type Punch takes" do
      Punch::Upload::EXTENSIONS.keys.sort!.should eq(Punch::Upload::TYPE_NAMES.sort)
    end
  end

  it "hands the file name to the claim and forgets it there" do
    UploadSpec.with_db do
      name = Punch::Upload::Filename.parse("Scan Müller.html").as(Punch::Upload::Filename)
      grant = Punch::Spec.db.write do |db|
        Punch::Upload.grant(db, UploadSpec::Scan, size: UploadSpec::PNG.size, content_type: "image/png", owner: "user-1", filename: name)
      end.as(Punch::Upload::Grant)
      Punch::Spec.upload(grant, UploadSpec::PNG, Punch::Spec.db)

      file = Punch::Spec.db.write { |db| Punch::Upload.claim(db, grant.ticket, UploadSpec::Scan, owner: "user-1") }.as(Punch::Upload::File)
      file.filename.value.should eq("Scan Müller.html.png")
      Punch::Spec.db.read(&.query_one?("SELECT count(*) FROM punch_uploads WHERE filename IS NOT NULL", &.read(Int64))).should eq(0)
    end
  end

  it "carries a hostile name from the grant to the download header" do
    hostile = {
      "a\u0000b.pdf"                                        => "a b.pdf",
      String.new(Bytes[0x61, 0xFF, 0x2E, 0x70, 0x64, 0x66]) => "a.pdf",
      "x\r\nSet-Cookie: a=b.pdf"                            => "x Set-Cookie: a=b.pdf",
      "../x"                                                => "x.pdf",
      "\"><script>.pdf"                                     => "\"><script>.pdf",
    }
    hostile.each do |raw, clean|
      UploadSpec.with_db do
        name = Punch::Upload::Filename.parse(raw).as(Punch::Upload::Filename)
        grant = Punch::Spec.db.write do |db|
          Punch::Upload.grant(db, UploadSpec::Scan, size: UploadSpec::PDF.size, content_type: "application/pdf", owner: "user-1", filename: name)
        end.as(Punch::Upload::Grant)
        Punch::Spec.upload(grant, UploadSpec::PDF, Punch::Spec.db).should be_a(Punch::Upload::Checked)
        file = Punch::Spec.db.write { |db| Punch::Upload.claim(db, grant.ticket, UploadSpec::Scan, owner: "user-1") }.as(Punch::Upload::File)
        file.filename.value.should eq(clean)
        # What the app reads back from its own column parses to the same name.
        Punch::Upload::Filename.parse(file.filename.value).as(Punch::Upload::Filename).should eq(file.filename)

        response = Punch::Spec.client.request("GET", Punch::Upload.url(file, download: true))
        response.status.should eq(HTTP::Status::OK)
        header = response.headers["Content-Disposition"]
        header.should start_with(%(attachment; filename="))
        ::HTTP::Headers.new.valid_value?(header).should be_true
        header.should_not contain("\r")
        header.should_not contain("\n")
        header.should_not contain(%("><))
        response.headers["Set-Cookie"]?.should be_nil
        response.headers["Content-Type"].should start_with("application/pdf")
      end
    end
  end

  describe "a claimed file kept whole" do
    claimed = ->(name : String) do
      filename = Punch::Upload::Filename.parse(name).as(Punch::Upload::Filename)
      grant = Punch::Spec.db.write do |db|
        Punch::Upload.grant(db, UploadSpec::Scan, size: UploadSpec::PNG.size, content_type: "image/png", owner: "user-1", filename: filename)
      end.as(Punch::Upload::Grant)
      Punch::Spec.upload(grant, UploadSpec::PNG, Punch::Spec.db)
      Punch::Spec.db.write { |db| Punch::Upload.claim(db, grant.ticket, UploadSpec::Scan, owner: "user-1") }.as(Punch::Upload::File)
    end
    disposition = ->(url : String) { Punch::Spec.client.request("GET", url).headers["Content-Disposition"] }

    it "shows a file, and saves it under its name" do
      UploadSpec.with_db do
        file = claimed.call("scan.png")
        disposition.call(Punch::Upload.url(file)).should eq("inline")
        disposition.call(Punch::Upload.url(file, download: true)).should contain(%(filename="scan.png"))
      end
    end

    it "fits a name the app passes to the file's type" do
      UploadSpec.with_db do
        file = claimed.call("scan.png")
        renamed = Punch::Upload::Filename.parse("page.html").as(Punch::Upload::Filename)
        disposition.call(Punch::Upload.url(file, download: renamed)).should contain(%(filename="page.html.png"))
      end
    end

    it "keeps a private file's name out of its URLs unless the app passes one" do
      UploadSpec.with_db do
        file = Punch::Upload::PrivateFile.of(claimed.call("Sick note Ada.png"))
        file.filename.should be_a(Punch::Secret(Punch::Upload::Filename))
        {Punch::Upload.url(file), Punch::Upload.url(file, download: true)}.each(&.should_not(contain("Ada")))
        disposition.call(Punch::Upload.url(file, download: true)).should contain(%(filename="file.png"))
        disposition.call(Punch::Upload.url(file, download: file.filename.unwrap)).should contain("Ada")
      end
    end

    it "does not fit a name to a type Punch does not take, and keeps it from opening" do
      name = Punch::Upload::Filename.parse("a.html").as(Punch::Upload::Filename)
      name.for("text/x-evil").value.should eq("a.html.bin")
    end

    it "gives a file up through the file itself" do
      UploadSpec.with_db do
        file = claimed.call("scan.png")
        Punch::Spec.db.write { |db| Punch::Upload.discard(db, Punch::Upload::PrivateFile.of(file), owner: "user-1") }.should be_true
      end
    end
  end

  describe "a scanned kind" do
    scanned_file = -> do
      grant = Punch::Spec.db.write do |db|
        Punch::Upload.grant(db, UploadSpec::Scanned, size: UploadSpec::PNG.size, content_type: "image/png", owner: "user-1")
      end.as(Punch::Upload::Grant)
      Punch::Spec.upload(grant, UploadSpec::PNG, Punch::Spec.db)
      Punch::Spec.db.write { |db| Punch::Upload.claim(db, grant.ticket, UploadSpec::Scanned, owner: "user-1") }.as(Punch::Upload::File)
    end

    it "starts pending, is served only once clean, and never when quarantined" do
      UploadSpec.with_db do
        file = scanned_file.call
        file.scan_state.should eq(Punch::Upload::ScanState::PENDING)
        file.servable?.should be_false
        expect_raises(Punch::Upload::NotServable, "is pending") { Punch::Upload.url(file) }
        expect_raises(Punch::Upload::NotServable) { Punch::Upload.href(file, download: true) }

        quarantined = file.scanned(Punch::Upload::ScanState::QUARANTINED)
        expect_raises(Punch::Upload::NotServable, "is quarantined") { Punch::Upload.url(quarantined) }
        expect_raises(Punch::Upload::NotServable) { Punch::Upload.url(Punch::Upload::PrivateFile.of(quarantined)) }

        Punch::Upload.url(file.scanned(Punch::Upload::ScanState::CLEAN)).should contain("files")
      end
    end

    it "does not serve a file with no state, or a bare key, of a scanned kind" do
      UploadSpec.with_db do
        file = scanned_file.call
        none = file.copy_with(scan_state: nil).as(Punch::Upload::File)
        none.servable?.should be_false
        expect_raises(Punch::Upload::NotServable) { Punch::Upload.url(none) }
        expect_raises(Punch::Upload::NotServable) { Punch::Upload.url(file.key) }
        expect_raises(Punch::Upload::NotServable) { Punch::Upload.href(file.key) }
        Punch::Spec.client.request("GET", Punch::Upload.url(file.key, unscanned: true)).status.should eq(HTTP::Status::OK)
      end
    end

    it "treats a kind it no longer knows as scanned, since the app scans others" do
      UploadSpec.with_db do
        file = scanned_file.call
        gone = file.copy_with(key: Punch::Upload::Key.parse("old.kind/#{"a" * 26}").as(Punch::Upload::Key), scan_state: nil).as(Punch::Upload::File)
        gone.servable?.should be_false
      end
    end

    it "answers nil where a file waits" do
      UploadSpec.with_db do
        file = scanned_file.call
        Punch::Upload.url?(file).should be_nil
        Punch::Upload.href?(file).should be_nil
        clean = file.scanned(Punch::Upload::ScanState::CLEAN)
        Punch::Upload.url?(clean).should_not be_nil
        Punch::Upload.href?(clean).should_not be_nil
      end
    end

    it "gives a clean file's URLs a short life, and purges a file whoever's it is" do
      UploadSpec.with_db do
        clock = Punch::Spec.clock
        file = scanned_file.call.scanned(Punch::Upload::ScanState::CLEAN)
        url = Punch::Upload.url(file, expires: 7.days)
        Punch::Spec.client.request("GET", url).status.should eq(HTTP::Status::OK)
        clock.advance(61.minutes)
        Punch::Spec.client.request("GET", url).status.should eq(HTTP::Status::FORBIDDEN)

        Punch::Spec.db.write { |db| Punch::Upload.purge(db, file) }.should be_true
        Punch::Upload::Sweep.run(Punch::Spec.db)
        UploadSpec.rows.should be_empty
      end
    end

    it "keeps its state through the other kinds of file" do
      UploadSpec.with_db do
        file = scanned_file.call
        image = Punch::Upload::ImageFile.of(file, width: 800_i64, height: 600_i64).as(Punch::Upload::ImageFile)
        image.servable?.should be_false
        Punch::Upload::PrivateImageFile.of(file).as(Punch::Upload::PrivateImageFile).scan_state.should eq(Punch::Upload::ScanState::PENDING)
      end
    end

    it "takes only its three states" do
      Punch::Upload::ScanState.parse("infected").should be_invalid("invalid_choice")
      Punch::Upload::ScanState.parse("clean").should eq(Punch::Upload::ScanState::CLEAN)
    end
  end

  it "reads a stored date that cannot be as a row error, naming no value" do
    {"2026-02-31T00:00:00Z", "2026-01-01T00:00:00+99:99"}.each do |raw|
      expect_raises(Punch::Database::RowError, "invalid_time") { Punch::Stored.load(Time, raw, "receipts", "file_delete_after", 1_i64) }
    end
  end

  describe "an image" do
    file_of = ->(type : String) do
      Punch::Upload::File.build(key: Punch::Upload::Key.parse("a.b/#{"a" * 26}").as(Punch::Upload::Key),
        filename: Punch::Upload::Filename.default(type), size: 1_i64, content_type: type).as(Punch::Upload::File)
    end

    it "keeps its size and alt text, and encrypts the alt text of a private one" do
      alt = Punch::NonEmptyString.parse("A receipt").as(Punch::NonEmptyString)
      image = Punch::Upload::ImageFile.of(file_of.call("image/png"), alt: alt, width: 800_i64, height: 600_i64).as(Punch::Upload::ImageFile)
      {image.width, image.height, image.alt}.should eq({800, 600, alt})

      secret = Punch::Upload::PrivateImageFile.of(file_of.call("image/png"), alt: alt).as(Punch::Upload::PrivateImageFile)
      (secret.alt || fail "no alt").unwrap.should eq(alt)
      secret.inspect.should_not contain("A receipt")
      secret.width.should be_nil
    end

    it "refuses what is not an image, and sides that cannot be" do
      Punch::Upload::ImageFile.of(file_of.call("application/pdf")).should be_invalid("not_an_image")
      Punch::Upload::PrivateImageFile.of(file_of.call("application/pdf")).should be_invalid("not_an_image")
      Punch::Upload::ImageFile.of(file_of.call("image/png"), width: 0_i64).should be_invalid("out_of_range")
      Punch::Upload::ImageFile.of(file_of.call("image/png"), height: -1_i64).should be_invalid("out_of_range")
      long = Punch::NonEmptyString.parse("a" * 1_001).as(Punch::NonEmptyString)
      Punch::Upload::ImageFile.of(file_of.call("image/png"), alt: long).should be_invalid("too_long")
      Punch::Upload::PrivateImageFile.of(file_of.call("image/png"), alt: long).should be_invalid("too_long")
    end
  end

  it "forgets an expired upload's name even when the storage cannot be reached" do
    UploadSpec.with_db do
      name = Punch::Upload::Filename.parse("Sick note Ada.pdf").as(Punch::Upload::Filename)
      past = Time.utc - 2.hours
      Punch::Spec.db.write do |db|
        Punch::Upload.grant(db, UploadSpec::Scan, size: UploadSpec::PDF.size, content_type: "application/pdf", owner: "user-1", filename: name, now: past)
      end
      Punch::Upload::Sweep.forget_names(Punch::Spec.db).should eq(1)
      Punch::Spec.db.read(&.query_one?("SELECT count(*) FROM punch_uploads WHERE filename IS NOT NULL", &.read(Int64))).should eq(0)
    end
  end

  it "gives a file without a name a plain one of its type" do
    UploadSpec.with_db do
      grant = UploadSpec.grant
      Punch::Spec.upload(grant, UploadSpec::PNG, Punch::Spec.db)
      file = Punch::Spec.db.write { |db| Punch::Upload.claim(db, grant.ticket, UploadSpec::Scan, owner: "user-1") }.as(Punch::Upload::File)
      file.filename.value.should eq("file.png")
    end
  end

  it "downloads under a kept name" do
    UploadSpec.with_db do
      grant = UploadSpec.grant
      Punch::Spec.upload(grant, UploadSpec::PNG, Punch::Spec.db)
      file = Punch::Spec.db.write { |db| Punch::Upload.claim(db, grant.ticket, UploadSpec::Scan, owner: "user-1") }.as(Punch::Upload::File)
      Punch::Spec.client.request("GET", Punch::Upload.url(file, download: true)).headers["Content-Disposition"].should contain(%(filename="file.png"))
    end
  end

  it "answers the check over HTTP, only from its own site" do
    UploadSpec.with_db do
      grant = UploadSpec.grant
      uri = URI.parse(grant.url)
      client = Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db), openapi: nil)
      put = client.request("PUT", uri.path, query: uri.query_params.to_h, body: String.new(UploadSpec::PNG),
        headers: ::HTTP::Headers{"Content-Type" => "image/png"})
      put.status.should eq(HTTP::Status::OK)
      # Tampered parameters break the signature.
      tampered = uri.query_params.to_h.merge({"size" => "999"})
      client.request("PUT", uri.path, query: tampered, body: "x" * 999, headers: ::HTTP::Headers{"Content-Type" => "image/png"}).status.should eq(HTTP::Status::FORBIDDEN)
      # A pending file is never served.
      client.get(uri.path, query: uri.query_params.to_h).status.should eq(HTTP::Status::FORBIDDEN)

      client.request("POST", "/_punch/uploads/check", json: {ticket: grant.ticket.value},
        headers: ::HTTP::Headers{"Origin" => "https://elsewhere.example"}).status.should eq(HTTP::Status::FORBIDDEN)
      client.request("GET", "/_punch/uploads/check").status.should eq(HTTP::Status::METHOD_NOT_ALLOWED)
      client.request("POST", "/_punch/uploads/check", json: {ticket: "upl_nope"}).body.should contain(%("code":"invalid_upload"))
      not_utf8 = client.request("POST", "/_punch/uploads/check", body: %({"ticket":"upl_#{String.new(Bytes[0xFF])}"}))
      not_utf8.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
      # JSON that is not an object is refused, not a 500.
      ["[1]", %("x"), "1", "null"].each do |body|
        client.request("POST", "/_punch/uploads/check", body: body, headers: ::HTTP::Headers{"Content-Type" => "application/json"})
          .status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
      end
      client.request("POST", "/_punch/uploads/check", json: {ticket: Punch::Upload::Ticket.generate.value}).status.should eq(HTTP::Status::NOT_FOUND)
      checked = client.request("POST", "/_punch/uploads/check", json: {ticket: grant.ticket.value})
      checked.status.should eq(HTTP::Status::OK)
      checked.trace.try(&.root.attributes["http.route"]).should eq("/_punch/uploads/check")
      UploadSpec.rows.should eq([{"upload_spec.scan", "checked"}])
    end
  end

  it "checks and copies through S3, signed, against the ETag it read" do
    s3 = UploadSpec::S3.new
    UploadSpec.with_db do
      storage = s3.storage
      Punch::Upload.storage = storage
      grant = UploadSpec.grant
      url = URI.parse(grant.url)
      url.host.should eq("127.0.0.1")
      url.path.should start_with("/uploads/app/pending/")
      s3.put(url.path.lchop("/uploads/"), UploadSpec::PNG, "image/png")

      Punch::Upload.check(Punch::Spec.db, grant.ticket).should be_a(Punch::Upload::Checked)
      s3.received.map(&.method).should eq(%w[HEAD GET PUT DELETE])
      head, get, copy, _ = s3.received
      head.headers["Authorization"].should start_with("AWS4-HMAC-SHA256 Credential=AKIDSPEC/")
      get.headers["Range"].should eq("bytes=0-511")
      get.headers["If-Match"].should eq(s3.objects.values.first[1]["ETag"])
      get.headers["Accept-Encoding"]?.should be_nil
      copy.headers["x-amz-metadata-directive"].should eq("REPLACE")
      copy.headers["x-amz-copy-source-if-match"].should eq(get.headers["If-Match"])
      copy.headers["Content-Disposition"].should eq("inline")
      s3.objects.keys.should eq(["/uploads/app/files/upload_spec.scan/#{url.path.split('/').last}"])

      # The page may send files to the bucket and show them from it.
      # The bucket is in the path, so the policy names its path, not the shared host.
      Punch::HTTP::SecurityHeaders.content_security_policy.should contain("connect-src 'self' http://127.0.0.1:#{s3.port}/uploads/app/;")
      Punch::HTTP::SecurityHeaders.content_security_policy.should contain("img-src 'self' http://127.0.0.1:#{s3.port}/uploads/app/;")
      file = Punch::Spec.db.write { |db| Punch::Upload.claim(db, grant.ticket, UploadSpec::Scan, owner: "user-1") }.as(Punch::Upload::File)
      Punch::Upload.url(file.key).should contain("/uploads/app/files/upload_spec.scan/")

      # A bucket that cannot be reached answers 502.
      second = UploadSpec.grant
      s3.close
      Punch::Upload.check(Punch::Spec.db, second.ticket).should eq(Punch::Upload::Refused.new(:bad_gateway, "upload_storage_unavailable"))
    end
  ensure
    s3.try(&.close)
  end

  it "runs one check at a time, and never copies a file sent again after the check" do
    UploadSpec.with_db do |storage|
      grant = UploadSpec.grant
      pending = URI.parse(grant.url).path.lchop(Punch::Upload::LOCAL_PATH)
      storage.write(pending, IO::Memory.new(UploadSpec::PNG), UploadSpec::PNG.size.to_i64, "image/png")
      # Another check holds the upload.
      Punch::Spec.db.write(&.exec("UPDATE punch_uploads SET state = 'checking', checking_since = ?", Time.utc.to_unix_ms))
      Punch::Upload.check(Punch::Spec.db, grant.ticket).should eq(Punch::Upload::Refused.new(:conflict, "upload_checking"))
      Punch::Spec.db.write { |db| Punch::Upload.claim(db, grant.ticket, UploadSpec::Scan, owner: "user-1") }.should be_invalid("upload_not_checked")
      # A check that died gives the upload up after its lease.
      Punch::Upload.check(Punch::Spec.db, grant.ticket, Time.utc + Punch::Upload::CHECK_LEASE).should be_a(Punch::Upload::Checked)
      final = "files/upload_spec.scan/#{pending.split('/').last}"
      File.read(File.join(storage.directory, final)).to_slice.should eq(UploadSpec::PNG)

      # Sent again to the URL, same size and type: the checked copy stays.
      other = "\x89PNG\r\n\x1A\n".to_slice + Bytes.new(24, 9_u8)
      storage.write(pending, IO::Memory.new(other), other.size.to_i64, "image/png")
      Punch::Upload.check(Punch::Spec.db, grant.ticket).should be_a(Punch::Upload::Checked)
      File.read(File.join(storage.directory, final)).to_slice.should eq(UploadSpec::PNG)
    end
  end

  it "gives an upload back when nothing arrived, so it can be checked again" do
    UploadSpec.with_db do
      grant = UploadSpec.grant
      Punch::Upload.check(Punch::Spec.db, grant.ticket).should eq(Punch::Upload::Refused.new(:conflict, "upload_incomplete"))
      Punch::Spec.upload(grant, UploadSpec::PNG, Punch::Spec.db).should be_a(Punch::Upload::Checked)
    end
  end

  it "limits checks per client address" do
    UploadSpec.with_db do
      Punch::Upload::Endpoint.limiter.reset
      client = Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db), openapi: nil)
      ticket = Punch::Upload::Ticket.generate.value
      60.times { client.request("POST", "/_punch/uploads/check", json: {ticket: ticket}).status.should eq(HTTP::Status::NOT_FOUND) }
      limited = client.request("POST", "/_punch/uploads/check", json: {ticket: ticket})
      limited.status.should eq(HTTP::Status::TOO_MANY_REQUESTS)
      limited.headers["Retry-After"]?.should_not be_nil
    ensure
      Punch::Upload::Endpoint.limiter.reset
    end
  end

  it "names a bucket in the path in the Content-Security-Policy" do
    shared = Punch::S3::Bucket.new("uploads", "eu-central-003", URI.parse("https://s3.eu-central-003.backblazeb2.com"), true)
    shared.csp_source.should eq("https://s3.eu-central-003.backblazeb2.com/uploads/")
    shared.csp_source("app/").should eq("https://s3.eu-central-003.backblazeb2.com/uploads/app/")
    own = Punch::S3::Bucket.new("uploads", "eu-central-1", URI.parse("https://s3.eu-central-1.amazonaws.com"), false)
    own.csp_source.should eq("https://uploads.s3.eu-central-1.amazonaws.com")
    own.csp_source("app/").should eq("https://uploads.s3.eu-central-1.amazonaws.com/app/")
  end

  it "refuses settings that do not fit together" do
    load = ->(env : Hash(String, String)) do
      Punch::Upload::Settings.load(Punch::Credentials::Source.open("test", nil, env)).as(Punch::Upload::Settings)
    end
    load.call({"STORAGE" => "local"}).problems("uploads").should be_empty
    load.call({"STORAGE" => "s3"}).problems("uploads").join("\n").should contain("uploads.bucket (UPLOADS__BUCKET) must be set")
    insecure = load.call({"STORAGE" => "s3", "BUCKET" => "files", "ACCESS_KEY_ID" => "AKID", "SECRET_ACCESS_KEY" => "s", "ENDPOINT" => "http://storage.example"})
    insecure.problems("uploads").should eq(["uploads.endpoint must be https: browsers send files and keys sign requests to it (plain http only to localhost)"])
    load.call({"STORAGE" => "local", "PREFIX" => "../up/"}).problems("uploads").size.should eq(1)

    Punch::Upload.configure(load.call({"STORAGE" => "local"}))
    Punch::Upload.problems("production").should eq(["uploads.storage is local in production: files would pass through the app and stay on its disk; set s3"])
    Punch::Upload.problems("development").should be_empty
  ensure
    Punch::Upload.storage = nil
  end

  it "renders an upload field as a file control and a hidden ticket" do
    html = Punch::Spec.render(UploadSpec::AttachForm.new)
    html.should match(/<input type="file" id="([^"]+)" required data-punch-upload-ticket="\1-ticket" data-punch-upload-busy="The file is still uploading." data-punch-upload-failed="[^"]+" accept="image\/png,application\/pdf" data-punch-upload="\/scans\/uploads">/)
    html.should_not match(/type="file" name=/)
    html.should match(/<input type="hidden" name="scan" id="[^"]+-ticket">/)
    html.should contain(%(<script type="module" src="#{Punch::Assets.uploads.url}"))
  end
end
