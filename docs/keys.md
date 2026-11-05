# Key ring

Learn it in: [Credentials and Keys](guides/credentials-and-keys.md), [Column Encryption and Blind Indexes](guides/column-encryption.md).

One root secret per app, many derived keys. The key ring signs the few values that must be stateless, such as a link to an invoice, encrypts columns (`Punch::Encrypted`, `docs/queries.md`), and hashes their blind indexes (`Punch::BlindIndex`). Sessions, one-time tokens, and API tokens are random values stored hashed; they do not depend on it, so rotating it signs nobody out.

## Declaring

The ring is a credential with a fixed name:

```crystal
struct Invoicing::Credentials
  include Punch::Credentials

  getter secret_key_base : Punch::KeyRing
end
```

It is loaded at boot like every credential, from `SECRET_KEY_BASE` or the encrypted file, and becomes `Punch::KeyRing.current`. A key ring under another name, optional, or inside `Secret` does not compile. Its text form, one key per line (commas also separate, for a variable):

```text
2:2026-10-09:<64 hexadecimal characters>:pending
1:2026-07-01:<64 hexadecimal characters>
```

ID, creation date, key, and `pending` for a key that is accepted but does not sign yet. The first key that is not pending signs and encrypts; every key verifies and decrypts. `creds:check` and `punch keys` never show the keys.

## Signing and encrypting

```crystal
signer = Punch::KeyRing.current.signer("invoice_link")
token = signer.sign_text(invoice.id.value.to_s, expires_at: Time.utc + 30.days)
signer.verify_text(token) # => "42", or nil

encryptor = Punch::KeyRing.current.encryptor("column:customers.email")
encryptor.decrypt(encryptor.encrypt(bytes)) # => bytes, or nil
```

- **One purpose, one key.** Each purpose (lowercase letters, digits, `_ . : -`) gets its own key, derived with HKDF from the root key with an info that also names the algorithm and format version. A token made for `invoice_link` does not verify as `unsubscribe`, and a signing key never encrypts.
- **Signed is not hidden.** Anyone holding a signed token can read its payload. Sign IDs, not secrets.
- **Failures are `nil`,** without a reason: forged, damaged, expired, signed for another purpose, or under a retired key look the same from outside.
- **Expiry** is part of the signed message (`expires_at:`). Verification takes `now:`, for specs.

Formats, version 1. Signed: `version | key id (4) | expires (8, Unix seconds, 0 = never) | payload | HMAC-SHA256 (32)`; text is URL-safe Base64 without padding. Encrypted: `version | key id (4) | nonce (12) | ciphertext | tag (16)`, AES-256-GCM with a random nonce. Blind index: `version | key id (4) | HMAC-SHA256 of the value (32)`, from `ring.blind_index(purpose)`, whose `digest` hashes under the signing key and `digests` under every key, signing key first. The key ID tells which root key to use, so nothing is tried in turn.

## Rotating

Every rotation is three steps, each followed by a build and a deploy:

| Step | Command | Effect |
|---|---|---|
| 1 | `punch keys:rotate` | adds a new key, pending: every process accepts it, none signs with it |
| 2 | `punch keys:promote` | the new key signs; the old one is still accepted |
| 3 | `punch keys:retire ID` | removes the old key: what it signed no longer verifies |

Step 1 exists for the handover: while two processes run, the old one must accept what the new one signs, so the new key reaches every process before it signs anything. Retire once nothing signed with the old key is still needed; for links valid for 30 days, 30 days after step 2. An encrypted column keeps a value under the key that wrote it until the row is written again, so retiring that key makes the value unreadable: `db:audit` lists each encrypted column's values per key, and a key retires safely once no column has values under it. A blind index works the same way: a write hashes under the signing key, a lookup tries every key, and `db:audit` lists each blind index's hashes per key. While old rows keep hashes under the old key, a unique index sees the same value under two keys as two values. So between steps 2 and 3, run `punch db:encrypt` (`docs/queries.md`), which encrypts and hashes every row again under the signing key and reports what it cannot; the nightly job does the same. Retire when `db:audit` shows no value under the old key.

`punch keys` lists the ring with each key's state and age. `punch keys:rotate --revoke`, after a compromise, replaces every key at once: everything signed or encrypted under the old keys stops opening, including encrypted columns and every authenticator app's secret (users with a second factor then cannot finish signing in until theirs is set up again, `docs/auth.md`), so it is a last resort. `keys:retire` on a pending key abandons a rotation. The first `keys:rotate` on a file without a ring creates key 1, signing at once.

All keys commands take `--env NAME` and `--json`, and edit the encrypted file of that environment. If a deployment sets `SECRET_KEY_BASE`, update it as well; the commands remind you.

## The public-ID key

Public IDs (`public_id "inv"`, `docs/core-types.md`) have a key of their own, outside the ring:

```crystal
struct Invoicing::Credentials
  include Punch::Credentials

  getter secret_key_base : Punch::KeyRing
  getter public_id_key : Punch::PublicIDKey
end
```

It is 64 hexadecimal characters, from `PUBLIC_ID_KEY` or the encrypted file, and never shows in `creds:check`. `punch new` writes one per environment; `punch keys:public-id --env NAME` writes it for an app that has none. It does not rotate, because every public ID handed out depends on it: in links, bookmarks, other systems' records. `punch keys:public-id --replace` makes a new one, after a leak or before any public ID has left the app; every public ID then changes and the old ones no longer resolve.

Under a different name, optional, or inside `Secret`, the field does not compile. An app that declares `public_id` on an ID type but has no key does not boot.

## Observing

`ring.uses` counts, per key, the messages each key opened while it was not the signing key, since the process started; an old key that is still in use is not safe to retire. Each such use also sets `punch.key_ring.old_key_id` on the request's wide event. The ops console's keys page (`/_punch/keys`, `docs/ops.md`) shows each key's age and role with the serving process's count.

## Testing

`Punch::Spec.credentials` loads `secret_key_base` and `public_id_key` from the YAML and sets `Punch::KeyRing.current` and the key of public IDs. A fixed key in `spec/spec_helper.cr` is fine; it signs nothing real. To test a rotation, set `Punch::KeyRing.current` to a ring with more keys and restore it afterwards (see the reference app's `spec/billing/sharing_api_spec.cr`).

## Limits

- Key IDs are not remembered after a key is removed: after an abandoned rotation, the next key may reuse the pending key's ID. A process that still holds the abandoned key rejects what the new one signs instead of accepting it.
- The standard library has no additional authenticated data, so an encrypted value can be copied between rows of the same purpose and still decrypt.
- Random 96-bit nonces: NIST's limit is 2^32 messages per key. Rotation resets the count.
