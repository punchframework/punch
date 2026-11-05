lib LibPunchStatfs
  {% if flag?(:darwin) && flag?(:x86_64) %}
    fun statfs = "statfs$INODE64"(path : UInt8*, buf : Void*) : Int32
  {% elsif flag?(:linux) || flag?(:darwin) %}
    fun statfs(path : UInt8*, buf : Void*) : Int32
  {% end %}
end

module Punch
  class Database
    # Which filesystem a database directory is on, and whether SQLite's WAL
    # mode can be trusted there. WAL relies on shared memory (`-shm`) and
    # POSIX locks that network and virtual filesystems do not honour: on
    # virtiofs, read transactions have seen inconsistent snapshots.
    # Punch refuses such directories at boot.
    module Filesystem
      record Verdict, directory : String, type : String, refused : Bool

      # statfs `f_type` magic numbers from Linux's `magic.h`.
      LINUX_REFUSED = {
            0x6969_i64 => "nfs",
            0x517B_i64 => "smb",
        0xFF534D42_i64 => "cifs",
        0xFE534D42_i64 => "smb2",
        0x01021997_i64 => "9p",
        0x65735546_i64 => "fuse", # also virtiofs, sshfs, and other FUSE filesystems
        0x00C36400_i64 => "ceph",
        0x5346414F_i64 => "afs",
        0x73757245_i64 => "coda",
        0x0BD00BD0_i64 => "lustre",
        0x01161970_i64 => "gfs2",
        0x7461636F_i64 => "ocfs2",
        0x6B414653_i64 => "kafs",
        0x13661366_i64 => "vboxsf",
      }

      LINUX_NAMES = {
            0xEF53_i64 => "ext4",
        0x58465342_i64 => "xfs",
        0x9123683E_i64 => "btrfs",
        0x01021994_i64 => "tmpfs",
        0x794C7630_i64 => "overlayfs",
        0x2FC12FC1_i64 => "zfs",
        0xF2F52010_i64 => "f2fs",
      }

      # macOS `f_fstypename` values.
      DARWIN_REFUSED = %w[nfs smbfs afpfs webdav cifs ftp]

      # Checks the directory that holds *path*.
      def self.check(path : String) : Verdict
        directory = File.dirname(File.expand_path(path))
        raise Database::Error.new("database directory #{directory} does not exist", code: 14) unless Dir.exists?(directory)
        type, refused = probe(directory)
        Verdict.new(directory, type, refused)
      end

      # Raises `FilesystemError` unless *path* is on a filesystem WAL works on.
      def self.check!(path : String) : Nil
        verdict = check(path)
        return unless verdict.refused

        raise FilesystemError.new(
          "#{verdict.directory} is on #{verdict.type}, a shared or virtual filesystem where SQLite's WAL " \
          "snapshots are not reliable. Put the database on local disk (lib/punch/docs/persistence.md).", code: 14)
      end

      # :nodoc:
      def self.classify_linux(magic : Int64) : {String, Bool}
        if name = LINUX_REFUSED[magic]?
          {name, true}
        else
          {LINUX_NAMES[magic]? || "0x#{magic.to_s(16)}", false}
        end
      end

      # The size of the filesystem holding *directory* and the bytes
      # available to an unprivileged process there, or `nil` where unknown.
      def self.space(directory : String) : {Int64, Int64}?
        {% if flag?(:linux) %}
          buffer = uninitialized StaticArray(UInt8, 512)
          return unless LibPunchStatfs.statfs(directory, buffer.to_unsafe) == 0

          # struct statfs: f_type, f_bsize, f_blocks, f_bfree, f_bavail, 8 bytes each.
          fields = buffer.to_unsafe.as(UInt64*)
          {(fields[2] &* fields[1]).to_i64, (fields[4] &* fields[1]).to_i64}
        {% elsif flag?(:darwin) %}
          buffer = uninitialized StaticArray(UInt8, 2400)
          return unless LibPunchStatfs.statfs(directory, buffer.to_unsafe) == 0

          # struct statfs (64-bit inodes): f_bsize (4 bytes), f_iosize, then f_blocks, f_bfree, f_bavail.
          block = buffer.to_unsafe.as(UInt32*).value.to_u64
          fields = (buffer.to_unsafe + 8).as(UInt64*)
          {(fields[0] &* block).to_i64, (fields[2] &* block).to_i64}
        {% else %}
          nil
        {% end %}
      end

      private def self.probe(directory : String) : {String, Bool}
        {% if flag?(:linux) %}
          buffer = uninitialized StaticArray(UInt8, 512)
          raise RuntimeError.from_errno("statfs #{directory}") unless LibPunchStatfs.statfs(directory, buffer.to_unsafe) == 0
          classify_linux(buffer.to_unsafe.as(LibC::Long*).value.to_i64 & 0xFFFFFFFF_i64)
        {% elsif flag?(:darwin) %}
          # struct statfs (64-bit inodes): f_fstypename is 16 bytes at offset 72.
          buffer = uninitialized StaticArray(UInt8, 2400)
          raise RuntimeError.from_errno("statfs #{directory}") unless LibPunchStatfs.statfs(directory, buffer.to_unsafe) == 0
          name = String.new(buffer.to_unsafe + 72)
          {name, DARWIN_REFUSED.includes?(name) || name.includes?("fuse")}
        {% else %}
          {"unknown", false}
        {% end %}
      end
    end
  end
end
