# Examples

<!-- What the app is for, in a sentence or two. -->

A [Punch](lib/punch/README.md) app.

## Run it

```sh
shards install
punch dev
```

`punch dev` migrates the development database, regenerates what is generated, builds, and serves on http://localhost:3000, again on every change. Sign in as `admin@example.test` with the password in `storage/seed-password` (`db/seeds.cr`, development only); that user holds `Accounts::Roles::Operator`, so the ops console at `/_punch` is open to them.

Without the `punch` tool on your `PATH`, get the one that matches `lib/punch` after `shards install`, and run it by path:

```sh
scripts/punch-tool.sh
lib/punch/bin/punch dev
```

The script puts the tool of the app's Punch release at `lib/punch/bin/punch`, checked against the release's `SHA256SUMS`. Where Punch is a path dependency, or with `--build`, it builds the tool from `lib/punch` instead.

## Check it

```sh
punch check
```

Format, lint, the generated files, the build, the specs, and the rest, as CI runs it.

## Deploy it

`punch new` wrote no recipe. `lib/punch/docs/deployment.md` has the Kamal and the systemd one.

Before the first deploy, start the production credentials with `punch creds:init --env production` and `punch keys:rotate --env production`, and set what `punch creds:check --env production` lists as missing, such as the mail settings (`punch creds:set mail.from --env production`, the value on stdin). The key, `config/credentials/production.key`, is never committed: keep it somewhere safe, and give it to the deployment as `PUNCH_MASTER_KEY`.

## Work on it

`AGENTS.md` is the guide for people and coding agents: where code goes, the loop, and the rules. Punch's documentation is in `lib/punch/docs/`.
