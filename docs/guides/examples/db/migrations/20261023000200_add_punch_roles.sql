-- Roles (lib/punch/docs/authorization.md): who holds which role, on which
-- resource, until when; the operations of each role, written
-- by Punch from the code; and the permissions that follow.
CREATE TABLE punch_role_assignments (
  id            INTEGER PRIMARY KEY,
  user_id       INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  role          TEXT    NOT NULL,
  resource_type TEXT,
  resource_id   INTEGER,
  expires_at    TEXT,
  assigned_by   INTEGER REFERENCES users (id) ON DELETE SET NULL,
  created_at    TEXT    NOT NULL,
  CHECK ((resource_type IS NULL) = (resource_id IS NULL))
) STRICT;

CREATE UNIQUE INDEX punch_role_assignments_unique
  ON punch_role_assignments (user_id, role, ifnull(resource_type, ''), ifnull(resource_id, 0));
CREATE INDEX punch_role_assignments_by_resource ON punch_role_assignments (resource_type, resource_id);

CREATE TABLE punch_role_operations (
  role      TEXT NOT NULL,
  operation TEXT NOT NULL,
  PRIMARY KEY (role, operation)
) STRICT, WITHOUT ROWID;

CREATE VIEW punch_permissions (user_id, operation, resource_type, resource_id, role) AS
  SELECT a.user_id, o.operation, a.resource_type, a.resource_id, a.role
  FROM punch_role_assignments a JOIN punch_role_operations o ON o.role = a.role
  WHERE (a.expires_at IS NULL OR a.expires_at > strftime('%Y-%m-%dT%H:%M:%S', 'now'));
