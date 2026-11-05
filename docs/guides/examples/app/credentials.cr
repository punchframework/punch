# What the app needs from its deployment, checked at boot: each value from
# the environment first (MAIL__FROM), then from the encrypted
# config/credentials/<env>.yml.enc. `punch creds:check` shows where each
# came from (lib/punch/docs/credentials.md).
struct Examples::Credentials
  include Punch::Credentials

  # Signs and encrypts what the app hands out; rotated with `punch
  # keys:rotate` (lib/punch/docs/keys.md).
  getter secret_key_base : Punch::KeyRing
  # The key of public IDs (`public_id "inv"` on an ID type); never
  # rotated, since every public ID depends on it (lib/punch/docs/keys.md).
  getter public_id_key : Punch::PublicIDKey
  # How mail leaves the app: captured in development
  # (MAIL__DELIVERY=capture, shown at /_punch/mail), sent by SMTP in
  # production (lib/punch/docs/mail.md).
  getter mail : Punch::Mailer::Settings
  # Where uploaded files go (lib/punch/docs/uploads.md): `local` in
  # development and test, a bucket in production.
  getter uploads : Punch::Upload::Settings
  # Where alerts for the people who run the app go
  # (`Operators::AlertOperators`); without one, nobody is alerted.
  getter alert_to : Punch::Email?
end
