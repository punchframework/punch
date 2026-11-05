# Vendored SQLite

| | |
|---|---|
| Version | 3.54.1 |
| Source ID | `2026-10-16 14:45:20 555e07ef33f69a0957d24d8e555b702464a131d6f1607f4c3c1e4551e8e6ca76` |
| From | `https://www.sqlite.org/2026/sqlite-amalgamation-3540100.zip`, 2026-11-01 |
| Checked | The zip's SHA3-256 (`92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30`) against sqlite.org's download page, and `sqlite3.c`'s (`e2b869d3003b33c942b7dd7063604fbc53553e1b66609570df39b9b7b558ee81`) against the 3.54.1 release log |
| Git tag | `version-3.54.1`, commit `57520227c95396ce39ba6ecaac8d475b78dd3964`; not regenerated from it |

Files are the unmodified `sqlite3.c`, `sqlite3.h`, and `shell.c` of the official amalgamation; `SHA256SUMS` records them, and `scripts/build-sqlite.sh` refuses to compile files that do not match. Compile options live in `scripts/build-sqlite.sh`.

The previous release, 3.53.4, was generated from its git tag; on 2026-11-01 its three files were found byte for byte identical to sqlite.org's 3.53.4 amalgamation.

To upgrade: download the amalgamation zip from sqlite.org, check its SHA3-256 against the download page, copy the three files, update this table, and write `SHA256SUMS` again (`sha256sum sqlite3.c sqlite3.h shell.c > SHA256SUMS`).
