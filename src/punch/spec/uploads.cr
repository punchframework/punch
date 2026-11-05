module Punch::Spec
  # Keeps this spec binary's uploads in *directory*, local storage as in
  # development, whatever the credentials say, and returns the storage.
  #
  # ```
  # Punch::Spec.uploads
  # grant = Punch::Upload.grant(db, Scan, size: 8, content_type: "image/png", owner: "1").as(Punch::Upload::Grant)
  # Punch::Spec.upload(grant, PNG_BYTES, database)
  # ```
  def self.uploads(directory : String = ::File.tempname("punch-uploads")) : Upload::LocalStorage
    Upload::LocalStorage.new(directory).tap { |storage| Upload.storage = storage }
  end

  # Sends *content* as a browser would for *grant*, then asks for the
  # check: what the check answers. Raises, as the storage would refuse
  # it, when *content* is not the granted size or *content_type* not the
  # granted type.
  def self.upload(grant : Upload::Grant, content : String | Bytes, database : Database,
                  content_type : String = grant.headers["Content-Type"]) : Upload::Checked | Upload::Refused
    storage = Upload.storage.as?(Upload::LocalStorage) || raise ArgumentError.new("Punch::Spec.upload needs local storage: call Punch::Spec.uploads first")
    uri = URI.parse(grant.url)
    object = URI.decode(uri.path.lchop(Upload::LOCAL_PATH))
    params = storage.verify("PUT", object, uri.query_params, Time.utc) || raise ArgumentError.new("the grant's URL has expired or is not signed")
    bytes = content.to_slice
    raise ArgumentError.new("the storage refuses #{bytes.size} bytes: the grant is for #{params["size"]}") unless bytes.size.to_s == params["size"]
    raise ArgumentError.new("the storage refuses #{content_type}: the grant is for #{params["type"]}") unless content_type == params["type"]

    storage.write(object, IO::Memory.new(bytes), bytes.size.to_i64, content_type)
    Upload.check(database, grant.ticket)
  end
end
