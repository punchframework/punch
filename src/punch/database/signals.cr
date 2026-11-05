module Punch
  class Database
    # What a database's writer reports, read by `Metrics::Registry#collect`:
    #
    # - writes waiting for the writer, counted from `write` until the writer
    #   takes them (also those blocked on a full queue);
    # - frames in the WAL not yet copied into the database file, as of the
    #   last commit or checkpoint, and the WAL file's size;
    # - how long each checkpoint took, and whether it copied every frame.
    #
    # The writer checkpoints itself (`Config#checkpoint_pages`) instead of
    # SQLite's automatic checkpoint, so it can time it, and does so after
    # handing the triggering write its answer.
    class Signals
      getter queued = Atomic(Int32).new(0)
      getter frames = Database::Driver::WalFrames.new
      @complete = Metrics::Histogram.new
      @incomplete = Metrics::Histogram.new

      # :nodoc:
      def checkpointed(seconds : Float64, log : Int32, checkpointed : Int32) : Nil
        frames.value.set(log - checkpointed)
        (checkpointed >= log ? @complete : @incomplete).record(seconds)
      end

      # Checkpoints so far, and how many of them left frames behind.
      def checkpoints : {UInt64, UInt64}
        {@complete.count + @incomplete.count, @incomplete.count}
      end

      # :nodoc:
      def observe(registry : Metrics::Registry, database : Database) : Nil
        attributes = Metrics::Attributes{"db.namespace" => database.name}
        registry.observe("db.client.connection.pending_requests", :gauge, "{request}",
          "Writes waiting for the database's writer") do |recorder|
          next if database.closed?
          recorder.record(queued.get, attributes.merge({"db.client.connection.pool.name" => "#{database.name} writer"} of String => Metrics::Value))
        end
        return if database.memory?

        registry.observe("punch.db.size", :gauge, "By", "Size of the database file, without its WAL") do |recorder|
          next if database.closed?
          recorder.record(File.info?(database.path).try(&.size) || 0_i64, attributes)
        end
        wal = "#{database.path}-wal"
        registry.observe("punch.db.wal.size", :gauge, "By", "Size of the database's WAL file") do |recorder|
          next if database.closed?
          recorder.record(File.info?(wal).try(&.size) || 0_i64, attributes)
        end
        registry.observe("punch.db.wal.frames", :gauge, "{frame}",
          "WAL frames not yet copied into the database file, as of the last commit or checkpoint") do |recorder|
          next if database.closed?
          recorder.record(frames.value.get, attributes)
        end
        registry.observe("punch.db.checkpoint.duration", :histogram, "s",
          "Duration of the writer's WAL checkpoints; incomplete ones left frames a reader still needed") do |recorder|
          next if database.closed?
          {true => @complete, false => @incomplete}.each do |complete, histogram|
            next if histogram.count == 0
            recorder.record(histogram.snapshot, attributes.merge({"punch.db.checkpoint.complete" => complete} of String => Metrics::Value))
          end
        end
      end
    end
  end
end
