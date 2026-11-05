-- The organization role between member and administrator is an editor:
-- `punch new` gives every app with organizations the same three roles, and
-- "accountant" was this app's word. A role's name in the data is its type's
-- name, so the assignments are renamed with it; the role's operations are
-- written again at boot.
UPDATE punch_role_assignments SET role = 'accounts.roles.editor' WHERE role = 'accounts.roles.accountant';
