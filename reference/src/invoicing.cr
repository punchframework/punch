# The app's code, without the command line, so specs can require it.
# `app/requires.gen.cr` requires every file under app/ in the order of its
# kind (lib/punch/docs/structure.md).
require "punch"
require "../app/requires.gen"
