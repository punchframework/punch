require "../../src/punch"
require "../i18n/fixture/app/translations.gen"

Punch.translations Fixture::Translations, default: "en"

Punch::I18n.default.t.greeting
