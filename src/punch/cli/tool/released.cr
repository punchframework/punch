require "digest/sha256"
require "file_utils"
require "yaml"

module Punch::CLI
  # The `punch` tools a GitHub release of Punch carries
  # (packaging/build-tool.sh): where an installed one is kept, and how
  # `punch tool:install` fetches one. The handshake runs an installed tool
  # of the app's Punch version (`Handshake.decide`).
  module Released
    # Where release archives come from: `PUNCH_RELEASES_URL` replaces it
    # (https:// or file://, for a mirror).
    BASE = "https://github.com"

    # This build's platform as release archives name it; nil where releases
    # have no tool.
    PLATFORM = {% if flag?(:linux) && flag?(:x86_64) %}
      "linux-x86_64"
    {% elsif flag?(:linux) && flag?(:aarch64) %}
      "linux-aarch64"
    {% elsif flag?(:darwin) && flag?(:aarch64) %}
      "macos-aarch64"
    {% else %}
      nil
    {% end %}.as(String?)

    VERSION = /\A\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?\z/
    # `owner/name`, neither part starting with a dot, so it names no other
    # directory of the cache.
    REPOSITORY = /\A[A-Za-z0-9_-][A-Za-z0-9_.-]*\/[A-Za-z0-9_-][A-Za-z0-9_.-]*\z/

    # Installed tools, by repository and version.
    def self.cache : String
      base = ENV["XDG_CACHE_HOME"]?.presence || File.join(Path.home.to_s, ".cache")
      File.join(base, "punch", "tools")
    end

    # The GitHub repository (`owner/name`) the app in *root* got Punch from,
    # by its `shard.lock`; nil for a path dependency or another host.
    def self.repository(root : String) : String?
      lock = File.join(root, "shard.lock")
      return unless File.file?(lock)

      url = YAML.parse(File.read(lock))["shards"]?.try(&.["punch"]?).try(&.["git"]?).try(&.as_s?)
      repository = url.try(&.match(%r{\Ahttps://github\.com/([^/]+/[^/]+?)(?:\.git)?/?\z})).try(&.[1])
      repository if repository.try(&.matches?(REPOSITORY))
    rescue YAML::ParseException
    end

    # Where the tool of *version* from *repository* is kept.
    def self.path(repository : String, version : String, cache : String = self.cache) : String
      File.join(cache, repository, version, "punch")
    end

    # The installed tool of *version* from *repository*, if there is one.
    def self.installed(repository : String, version : String, cache : String = self.cache) : String?
      tool = path(repository, version, cache)
      tool if File::Info.executable?(tool)
    end

    # Installs the tool of *version* from *repository*'s release for
    # *platform*: the archive and the release's `SHA256SUMS` are fetched,
    # the archive's checksum compared, and the binary moved into the cache
    # only after it reports *version*. Returns its path, and whether it was
    # there already.
    def self.install(repository : String, version : String, cache : String = self.cache,
                     base : String = ENV["PUNCH_RELEASES_URL"]?.presence || BASE,
                     platform : String? = PLATFORM) : {String, Bool} | Failure
      if failure = refusal(repository, version, base)
        return failure
      end
      unless platform
        return Failure.new("no_release_tool", "Releases of Punch carry no tool for this platform. Build it from the app's root with:\n  #{Handshake::BUILD}")
      end

      target = path(repository, version, cache)
      return {target, true} if File::Info.executable?(target)

      # In the cache, so the finished binary is renamed into place.
      work = File.join(cache, ".download-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(work)
      begin
        binary = download(repository, version, "#{base.rchop('/')}/#{repository}/releases/download/v#{version}", "punch-#{version}-#{platform}", work)
        return binary if binary.is_a?(Failure)

        Dir.mkdir_p(File.dirname(target))
        File.rename(binary, target)
        {target, false}
      ensure
        FileUtils.rm_rf(work)
      end
    end

    # Why *repository*, *version*, or *base* cannot name a release.
    private def self.refusal(repository : String, version : String, base : String) : Failure?
      return Failure.usage("invalid_version", "A Punch version is like 0.2.0, got '#{version}'.") unless version.matches?(VERSION)
      return Failure.usage("invalid_repository", "A repository is OWNER/NAME, got '#{repository}'.") unless repository.matches?(REPOSITORY)
      return if base.starts_with?("https://") || base.starts_with?("file://")

      Failure.usage("invalid_releases_url", "PUNCH_RELEASES_URL starts with https:// or file://, got '#{base}'.")
    end

    # The archive *name* from the release at *url*, checked against its
    # `SHA256SUMS` and unpacked in *work*: the path of its `punch`, once it
    # reports *version*.
    private def self.download(repository : String, version : String, url : String, name : String, work : String) : String | Failure
      sums = File.join(work, "SHA256SUMS")
      archive = File.join(work, "#{name}.tar.gz")
      if failure = fetch("#{url}/SHA256SUMS", sums) || fetch("#{url}/#{name}.tar.gz", archive)
        return failure
      end

      expected = listed(sums, "#{name}.tar.gz")
      return Failure.new("no_release_tool", "The release v#{version} of #{repository} lists no #{name}.tar.gz in its SHA256SUMS.") unless expected

      actual = Digest::SHA256.new.file(archive).hexfinal
      unless actual == expected
        return Failure.new("checksum_mismatch", "#{name}.tar.gz from #{url} has SHA-256 #{actual}, but the release's SHA256SUMS says #{expected}. Nothing was installed.")
      end

      output = IO::Memory.new
      unless Process.run("tar", ["-xzf", archive, "-C", work, "#{name}/punch"], output: output, error: output).success?
        return Failure.new("download_failed", "Unpacking #{name}.tar.gz failed: #{output.to_s.strip}")
      end

      binary = File.join(work, name, "punch")
      File.chmod(binary, 0o755)
      output.clear
      Process.run(binary, ["version"], output: output, error: output)
      return binary if output.to_s.starts_with?("punch #{version} ")

      Failure.new("download_failed", "The tool in #{name}.tar.gz does not report Punch #{version}: #{output.to_s.strip}")
    end

    # The SHA-256 that *sums*, a `SHA256SUMS` file, lists for *file*.
    private def self.listed(sums : String, file : String) : String?
      File.read_lines(sums).each do |line|
        sum, _, listed = line.partition(/\s+\*?/)
        return sum.downcase if listed.strip == file
      end
      nil
    end

    # Fetches *url* into *file* with curl, which follows the release's
    # redirect and honours the proxy settings; only https (and file, for a
    # mirror on disk), also after redirects.
    private def self.fetch(url : String, file : String) : Failure?
      error = IO::Memory.new
      status = Process.run("curl", ["--fail", "--silent", "--show-error", "--location",
                                    "--proto", "=https,file", "--proto-redir", "=https",
                                    "--output", file, url], error: error)
      return if status.success?

      Failure.new("download_failed", "Downloading #{url} failed: #{error.to_s.strip}")
    rescue IO::Error
      Failure.new("download_failed", "Installing a released tool needs curl, which was not found.")
    end
  end
end
