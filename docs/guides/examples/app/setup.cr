# Every declaration that configures Punch for this app, in one place.
require "punch/ops/console"

# Stylesheets and images, embedded in the binary with fingerprinted URLs
# (lib/punch/docs/assets.md). Turbo comes with Punch.
Punch.assets "assets"

# The app's translations (lib/punch/docs/translations.md): `punch i18n:generate`
# writes Examples::Translations to translations.gen.cr from
# config/locales/*.yml. Views reach them as `v.t`, other code as
# `locale.t`.
Punch.translations Examples::Translations, default: "en"

# What the app needs from its deployment (`Examples::Credentials`).
Punch.credentials Examples::Credentials

# The binary carries its migrations and applies them at boot
# (lib/punch/docs/deployment.md).
Punch.migrations "../db/migrations"

# API tokens read `exa_…`, so people and secret scanners can tell whose
# they are.
Punch::Auth.config = Punch::Auth::Config.new(token_prefix: "exa")

# A browser without a session that asks for a page needing one comes here
# (lib/punch/docs/auth.md).
Punch::Pages.sign_in = Accounts::Sessions::CreatePage.href

# The ops console (lib/punch/docs/ops.md): named once, with the app's actor. Users
# holding `Accounts::Roles::Operator` may use it, in every environment.
Punch::Ops::Console.mount Examples::Actor, Punch::Ops::Console::ByRole
