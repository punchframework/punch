require "./trace"
require "./metrics"
require "./backup/config"
require "./backup/encryption"
require "./backup/litestream"
require "./backup/sidecar"
require "./backup/verification_status"
require "./backup/monitor"

# Backups of the database files with Litestream: its configuration generated
# from `PUNCH_BACKUP_URL`, Litestream supervised as a sidecar, replication
# lag as a metric, the bucket's encryption and missing replicas as health
# checks. The restore check (`backup/verification.cr`) needs the database
# layer and is required after it. Details in `docs/backup.md`.
module Punch::Backup
  # The storage directory of this process (`PUNCH_STORAGE`), where the
  # restore check and a restore leave their reports; set by `serve` and
  # `jobs`, read by the ops console.
  class_property storage : String? = nil

  # The replicas' monitor of this process, set by `serve` and `jobs`;
  # read by `Ops::Notify`.
  class_property monitor : Monitor? = nil
end
