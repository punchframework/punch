-- name: ChoiceBySession :one
-- The organization a session chose last; whether its user still holds a
-- role there is the caller's to check.
SELECT organization_id FROM organization_choices WHERE session_id = :session_id;

-- name: ChoiceByToken :one
-- The organization an API token chose last.
SELECT organization_id FROM organization_choices WHERE api_token_id = :api_token_id;

-- name: Mine :many
-- The organizations a user holds a role on, by name.
-- sort: the organizations of one user, a few rows
-- param user_id: Int64
SELECT organizations.* FROM organizations
WHERE organizations.id IN (
  SELECT p.resource_id FROM punch_permissions p
  WHERE p.user_id = :user_id AND p.resource_type = 'accounts.organizations')
ORDER BY organizations.name, organizations.id;

-- name: ChooseForSession :exec
INSERT INTO organization_choices (session_id, organization_id) VALUES (:session_id, :organization_id)
ON CONFLICT (session_id) DO UPDATE SET organization_id = excluded.organization_id;

-- name: ChooseForToken :exec
INSERT INTO organization_choices (api_token_id, organization_id) VALUES (:api_token_id, :organization_id)
ON CONFLICT (api_token_id) DO UPDATE SET organization_id = excluded.organization_id;
