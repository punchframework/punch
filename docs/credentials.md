# Credentials

Learn it in: [Credentials and Keys](guides/credentials-and-keys.md), [Configuring Punch Applications](guides/configuring-punch-applications.md).

What an app needs from its deployment, API keys and settings alike, is declared as a type and checked before the app starts. Each value comes from the environment first, then from the environment's encrypted file, which is compiled into the binary. Only the key is supplied at runtime.

## Declaring

```crystal
# app/credentials.cr
struct Invoicing::Credentials
  include Punch::Credentials

  getter issuer : Issuer
  getter stripe : Stripe

  struct Issuer
    include Punch::Credentials

    getter name : Punch::NonEmptyString
    getter vat_id : Punch::NonEmptyString? # optional
  end

  struct Stripe
    include Punch::Credentials

    getter secret_key : Punch::Secret(String)
    getter timeout : Int32 = 10 # optional, with a default
  end
end

Punch.credentials Invoicing::Credentials
```

Three rules:

1. **The variable is the path in capitals joined by `__`.** `stripe.secret_key` is `STRIPE__SECRET_KEY`. A set, non-empty variable wins over the file.
2. **A field is required unless it is nilable or has a default.** Every missing or malformed value stops the boot, all of them reported at once, and so does a key in the file that no field declares (a misspelt key would otherwise leave a default in place silently).
3. **Anything that must not leak is a `Punch::Secret(T)`.** It cannot be serialized, prints as `[REDACTED]`, and `creds:check` shows where it came from but not its value.

Field types: `String`, `Bool`, `Int32`, `Int64`, `Float64`, enums (by snake_case name), domain primitives, `Punch::Secret` of one of these, the key ring `secret_key_base : Punch::KeyRing` (`docs/keys.md`), and nested types that include `Punch::Credentials` (groups, the mappings in the file). Groups cannot be optional; make their fields optional instead. Anything else does not compile.

Values are parsed exactly as path and query parameters are (`docs/input.md`): `true` and `false`, JSON number grammar, enum names. The YAML file is read as text, so `no` stays the string `no` and `2026-10-09` is not a date until a field's type says so. A top-level field may not read a standard variable such as `PATH`, `HOME`, or `HOST`; put it into a group.

Read them anywhere after boot:

```crystal
Invoicing::Credentials.current.stripe.secret_key.unwrap
```

`current` is set once, before the server starts, and is read-only afterwards. Reading it before the boot raises `Punch::Credentials::NotLoaded`, a bug.

## Files and keys

| File | Holds | Committed |
|---|---|---|
| `config/credentials/<env>.yml.enc` | the YAML, encrypted | yes |
| `config/credentials/<env>.key` | 64 hexadecimal characters | **never** |

`PUNCH_ENV` selects the environment (`development` by default). `PUNCH_MASTER_KEY`, when set, is used instead of the key file; deployments use it. `Punch.credentials` compiles in the files of `development`, `test`, and `production`; name others with `environments: %w[development test staging production]`.

Because the file is compiled in, changing a credential means a new build. A value that must change without a deploy belongs in an environment variable, which is looked up first.

The format is one line of Base64 over `version | key id | nonce | ciphertext | tag`, AES-256-GCM under a key derived from the master key with HKDF for this purpose only. The key id is a fingerprint of the master key, so a wrong key is reported as such, not as damage.

## Commands

| Command | Does |
|---|---|
| `punch creds:init [--env E]` | A new key file (mode 0600) and an empty encrypted file; adds `/config/credentials/*.key` to `.gitignore` |
| `punch creds:edit [--env E]` | Opens the decrypted YAML in `$VISUAL` or `$EDITOR`; writes nothing if the YAML is invalid. The decrypted file is in `$XDG_RUNTIME_DIR` or `/dev/shm` where there is one, never kept: `punch` ignores Ctrl-C and hang-ups while the editor runs, then removes it |
| `punch creds:set PATH [--env E]` | Sets one value from stdin, so it stays out of shell history: `pass stripe | punch creds:set stripe.secret_key`. Comments in the file are not kept |
| `punch creds:unset PATH [--env E]` | Removes a value or a group |
| `punch creds:show [--env E] [--reveal]` | The file's keys, every value redacted unless `--reveal` |
| `punch creds:rekey [--env E]` | Re-encrypts under a new key and writes the key file; deployments need the new `PUNCH_MASTER_KEY` with the next build |
| `bin/app creds:check [--env E]` | In the app's binary: loads the credentials as `serve` does and shows where each value came from |

`--env` defaults to `PUNCH_ENV`, then `development`. All but `creds:edit` have `--json`.

`punch check` has a `creds` step when `config/credentials/` exists: no key file may be committed or left unignored, every file whose key file is present must open, and the built app's `creds:check` must pass for those environments.

## Testing

```crystal
# spec/spec_helper.cr
Punch::Spec.credentials(Invoicing::Credentials, <<-YAML)
  issuer:
    name: Example Consulting GmbH
  YAML
```

It loads the type from the YAML (and from `env:`, a Hash, instead of the process environment), makes it `current`, and fails the example with every problem. Tests need no key and no file.

## Limits

- Credentials are read once at boot; there is no reloading.
- `Secret` keeps values out of logs and responses, not out of memory: Crystal strings are immutable and garbage collected.
- The key ring for signing and encryption is the credential `secret_key_base`; see `docs/keys.md`.
