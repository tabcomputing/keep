# Keep

*A commit log for a file.*

Keep gives one document the shape Delta Lake gives a table: the truth is an
**append-only log of commits**, each an atomic set of typed **actions**; the
current state is the **fold** of the log; a **checkpoint** caches that fold as
of some commit. Reverting a commit appends a mark rather than erasing anything,
so the log only grows and every past state is reachable. Backup, history, undo,
time travel and audit stop being features and become properties.

The log is a [C0DATA](https://github.com/c0data) stream-mode file: one
ETB-committed block per commit, so a crash mid-append leaves a torn tail that
readers skip and the next writer truncates. Keep knows commits, actions, revert
marks, locking, versions and checkpoints. Your application supplies the action
vocabulary and the fold.

```crystal
require "keep"

log = Keep::Log.open("book.log")

log.append(at: "2026-09-21 16:26", origin: "cli", kind: "ledger", summary: "Market run ($48.20)") do |c|
  c.action("record", 41, "2026-09-03", "Market run", nil, ["Expenses:Food", "4820", "Assets:Checking", "-4820"])
end

# Rebuild state: fold every non-reverted commit's actions, in order.
book = Book.new
version = log.fold(book) { |state, action| state.apply(action) }

# …or only what's new since a checkpoint.
if log.replay_needed?(version)          # a revert reached back past it
  book = Book.new
  version = log.fold(book) { |s, a| s.apply(a) }
else
  version = log.fold(book, after: version) { |s, a| s.apply(a) }
end
Keep::Checkpoint.write("book.json", version, book.to_json)

log.revert(41, at: now, origin: "cli", kind: "ledger", summary: "Undid #41")   # a mark, not a deletion
log.commits.each { |c| puts "#{c.seq}  #{c.at}  #{c.origin}  #{c.summary}#{c.reverted? ? "  (reverted)" : ""}" }
```

## The log on disk

```
␝keep/1␗
␞commit␟1␟2026-09-21 16:26␟cli␟ledger␟Market run ($48.20)
␞record␟41␟2026-09-03␟Market run␟␟␂Expenses:Food␟4820␟Assets:Checking␟-4820␃␗
␞commit␟2␟2026-09-21 16:31␟cli␟ledger␟Undid #41
␞revert␟1␗
```

A preamble block names the format. Each commit is a block: a `commit` record
(`seq`, `at`, `origin`, `kind`, `summary`) then one record per action — the
action's name, then its positional fields. A field is a string or a flat list
(an STX/ETX scope). Numbers travel as text; an empty field is the absence of a
value. `revert` / `unrevert` are keep's own actions and are reserved.

Sequence numbers are dense and assigned under an advisory lock on the log, so
several processes may append to the same log safely.

## API

- `Keep::Log.open(path)` — create (with preamble) or repair, then open.
- `log.append(at:, origin:, kind:, summary:) { |c| c.action(name, *fields) }` → `Commit`
- `log.revert(seq, …)` / `log.unrevert(seq, …)` — append a mark.
- `log.commits`, `log.each_commit(after:)`, `log.commit(seq)`, `log.version`
- `log.fold(state, after: 0) { |state, action| … }` → version folded to.
- `log.replay_needed?(version)` — a mark after `version` targets a commit at or before it.
- `log.lock { … }` — the advisory lock, for append-plus-checkpoint sections.
- `Keep::Checkpoint.write(path, version, state_json)` / `.read(path)` → `{version, state_json}`
- `Keep::Action` — `name`, `a[i]`, `a[i]?`, `a.list(i)`; `Keep::Commit` — `seq at origin kind summary actions reverted? reverts unreverts mark?`

## Development

```sh
shards install
crystal spec
```

## Contributing

1. Fork it (<https://github.com/tabcomputing/keep/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Thomas Sawyer](https://github.com/transfire) - creator and maintainer
