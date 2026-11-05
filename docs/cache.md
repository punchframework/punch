# Cache

Learn it in: [Caching](guides/caching.md).

Typed stores for values that are expensive to produce, and conditional requests for Query results.

**What not to cache:** rows. A read from `primary.db` is an in-process lookup, about as fast as a read from the cache. Cache results of outbound calls, heavy aggregates, rendered documents.

## Declaring a store

One store per kind of value, as a constant, with a name that is unique in the app:

```crystal
module Billing::Customers
  STATEMENTS = Punch::Cache(ID, Balances).new("customer_statements", ttl: 1.minute, tier: :both)
end

balances = STATEMENTS.fetch(customer_id) { compute(customer_id) }
```

- **Keys** are `String`, `Int32`, `Int64`, `Bool`, an enum, a domain primitive (typed IDs included), or a tuple of those. Anything else does not compile.
- **Values** must be JSON-serializable and have a JSON Schema (`docs/json-schema.md`): they reach `cache.db` as JSON and come back through the same parsing as everything else, domain primitives through their `parse`. A value type holding a `Punch::Secret` anywhere does not compile, so a decrypted column cannot end up in an unencrypted file.
- **Names** are lowercase letters, digits, and `_`, at most 63 characters. The name and the value type's shape (below) identify the entries in `cache.db`.

| Option | Default | |
|---|---|---|
| `ttl:` | required | How long an entry is used after it was computed |
| `tier:` | `:memory` | `:memory` (this process, fastest, lost on restart), `:durable` (`cache.db`, survives restarts, shared by two processes), `:both` (memory in front of `cache.db`) |
| `max_entries:` | 10,000 | Entries the memory tier holds; beyond that the oldest write goes |
| `durable:` | the attached file | A `Punch::Caches::Durable` of its own, for specs of the cache itself |

Crystal creates a constant on first use, so a store exists, and is listed by `Punch::Caches.stores`, once something touched it.

## Fetching

`fetch(key) { … }` returns the stored value, or runs the block, stores its value, and returns it.

- **Single-flight.** Fibers that miss the same key at once wait for one computation; within a process this is exact, across two processes each checks `cache.db` first and may compute once. An exception in the block reaches every waiting fiber and stores nothing. A block that fetches its own key raises instead of waiting for itself.
- **Inside a Command** the block sees uncommitted data, and a rollback would leave a value nobody committed. Compute in a Query, and invalidate after commit (below).
- `delete(key)` removes one entry from memory and the file; `clear` removes the store's entries; `cached?(key)` says whether a live entry exists, without computing or counting.
- **A changed value type costs nothing.** Each store's entries carry a shape: a fingerprint of the key type and the value's JSON Schema. A new binary with another shape never reads the old entries; it sees misses, and the old ones expire or go first when the file is full. A stored value that no longer parses counts as a miss and as an error in the store's statistics.

## Invalidation by domain events

A committed change makes some entries stale. Name them on an after-commit subscriber (`docs/events.md`) with `@[Punch::Subscriber::Forget]`, and Punch writes its `call`:

```crystal
module Billing::Customers
  STATEMENTS = Punch::Cache(ID, Statement).new("customer_statements", ttl: 1.minute, tier: :both)

  # A sent or paid invoice changes what its customer owes.
  @[Punch::Subscriber::Forget(STATEMENTS, key: customer_id)]
  struct ForgetStatement
    include Punch::Subscriber(BalanceChanged)
  end
end
```

- `key:` names the event's getter. It returns a key of the store, a nilable one (`nil` forgets nothing), or an array of keys. Without `key:`, the whole store is cleared.
- The subscriber listens to one or more events, a marker module, or an abstract event, like any other. A getter the listened type lacks, a key of the wrong type, a `call` of its own, or `@[Punch::Subscriber::Delivery]` do not compile.
- Entries are forgotten once the transaction has committed. A Command that fails or raises forgets nothing, so a reader cannot recompute the entry from data about to roll back.
- **A value computed from data older than a forget is not stored.** A fetch that misses computes inside a read transaction whose snapshot may predate the commit, or while the forget arrives. Punch notes when each read transaction began (outside one, when the fetch began) and when each key was last forgotten; if the key was forgotten since, `fetch` returns the value but does not keep it, and the next fetch computes again. A store remembers its last 1,024 forgotten keys; older ones, and a `clear`, make every reading that began before them store nothing. The span shows `punch.cache.stored: false`. A fetch in another process that misses at the same moment is not covered: its value can land in `cache.db` until it expires.
- `punch events` shows the store next to the subscriber: `after_commit  Billing::Customers::ForgetStatement  (forgets cache customer_statements)`, and `"forgets"` in `--json`.
- Forgetting reaches `cache.db` and the memory of the process that committed. **Another process's memory keeps its entry until it expires:** the server's, when the change is committed by a job in a separate jobs process (`punch jobs`), or the old process's during a handover. Choose `:durable` for a store whose entries must not outlive such a change, or keep its `ttl` short.
- Anything more involved (a key computed from several events, a lookup) is a hand-written after-commit subscriber that calls `delete` or `clear`; `punch events` does not see what it forgets.

## Expiry and size

- **Memory:** at most `max_entries` per store. A write moves its entry to the end; expired entries at the front go first, then the oldest writes. With one time-to-live per store, the oldest write is also the first to expire.
- **`cache.db`:** one size cap for all stores, `PUNCH_CACHE_MB` (256 MiB by default). A write that takes the file over the cap removes expired entries, then those closest to expiry, until it is under 90 % of the cap. The running total is kept by triggers, so two processes agree on it. Expired entries are otherwise removed by `Punch::Caches::Trim`, a recurring job every ten minutes, or by `punch cache:clear --expired`.
- **`Punch::Caches::Trim`** also removes expired entries from the memory of the stores in the process that runs it. Memory stores trim on every write, so this matters for idle stores. A separate jobs process trims its own memory only.
- `cache.db` is Punch's own and is not replicated. Its tables are created by Punch, not by the app's migrations; a file with an older layout is emptied and recreated.

## The app must be correct with an empty cache

The cache is empty after a restore, after `cache:clear`, and in a new process for memory stores. `PUNCH_CACHE=off` makes every fetch compute, and `punch check` runs an app's specs a second time that way (step `nocache`). A spec that checks caching itself branches on `Punch::Caches.enabled?`:

```crystal
if Punch::Caches.enabled?
  stale.should eq(first) # served from the cache
else
  stale.should eq(fresh)
end
```

## Observability

- Every fetch adds `punch.cache.hits` or `punch.cache.misses` to the wide event, and a span `cache <name>` with `punch.cache.result` (`memory`, `durable`, `miss`, `joined`) and, on a miss, `punch.cache.compute_ms`. Reads and writes of `cache.db` are spans of their own (`Punch::Caches::Durable.get`, `.put`).
- `store.stats.snapshot`: hits per tier, misses, joins (waited for another fiber), compute time, evictions, errors, and `hit_rate`, since the process started.
- The ops console's cache page (`/_punch/cache`, `docs/ops.md`) shows these counters and the memory size of every store used in the serving process, the file's bytes against its cap, and its entries per store and shape (a shape the binary no longer writes is marked as earlier). It clears a store from that process's memory and the file. Stores are listed from their first use, since Crystal creates constants then.
- `punch cache:stats` lists entries, expired entries, and bytes per store and shape in `cache.db`; `punch cache:clear [STORE] [--expired]` removes entries. Both work on the file only: memory stores live inside the server process.

## Specs

`require "punch/spec"` attaches an in-memory `cache.db` and empties every store's memory and the file before each example.

- `Punch::Spec.clock` stops time until the example ends; `clock.advance(61.seconds)` lets entries expire.
- `Punch::Spec.without_cache { … }` runs a block with caching off.
- `STORE.cached?(key)` checks that a change forgot an entry: `STATEMENTS.cached?(customer).should be_false` after sending an invoice.

## Conditional requests

A Query result that includes `Punch::HTTP::Versioned` answers `GET` with an `ETag`, and with `304 Not Modified` and no body when the request's `If-None-Match` names the current one. This lives in the HTTP layer and needs no storage.

```crystal
struct Balances
  include JSON::Serializable
  include Punch::HTTP::Versioned

  getter balances : Array(Balance)

  def version : String
    Digest::SHA256.hexdigest(balances.to_json)
  end
end
```

- **The version** is whatever changes whenever the content does: an `updated_at`, a revision number, a digest of the content. It returns `String`, `Int64`, `Int32`, or `Time`.
- **The tag** is weak (`W/"…"`) and covers the result type, the signed-in user, the version, and the running binary (its path, size, and modification time), so users never share a tag and a deployment changes every tag.
- **Headers:** a tagged response carries `Cache-Control: private, no-cache`: a browser may keep it but asks each time, and shared caches do not keep it, since results may depend on the actor. Untagged responses keep the default `no-store`.
- Only results with status 200 can be versioned (a versioned type with another status does not compile), and only `GET` and `HEAD` are conditional; other members of the result union are answered as usual.
- `openapi.json` documents the `ETag` header, the 304 response, and the `If-None-Match` parameter of such operations; the contract check accepts a 304 without a body.
- The result is computed before the tag is compared: a 304 saves the transfer and the client's work, not the server's. Cache the result too when computing it is what costs.
