module Punch
  # Where each name in a type's name starts: Punch's macros write every
  # type they name as `{{ type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}`,
  # so `Mailer::Welcome` becomes `::Mailer::Welcome` and
  # `Punch::Paged(Mailer::Row) | Nil` becomes
  # `::Punch::Paged(::Mailer::Row) | ::Nil`.
  #
  # Code a macro writes is resolved where it expands. Inside Punch's own
  # modules, an unqualified `Mailer::Welcome` would find `Punch::Mailer`
  # first, so an app module named like one of Punch's (`Mailer`, `Auth`,
  # `Events`, ...) would fail to compile or, worse, reach Punch's type of
  # the same name. Global names resolve from the top level wherever they
  # expand (AGENTS.md, "Names in macros").
  NAME_STARTS = /(?<![\w:])(?=[A-Z])/
end
