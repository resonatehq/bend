# 001 — what Bend forced

Four places where the language did not let the Python be transcribed, and what
was done instead. Each cost something; two of them paid for themselves.

## No early return, and the guard chain becomes a combinator

Two rules compose into one large constraint:

- *"A `match` inspects a parameter or a variable bound by a pattern, never a
  computed value."* A comparison is a computed value, so a guard cannot be
  matched where it is written. The guide's remedy is to pass it to a helper
  that matches on its parameter.
- *"Mutual recursion is not allowed."* So a recursive function cannot hand its
  guard to a helper and have that helper call back.

Together they rule out the shape a guard usually takes. What is left is to keep
the recursion direct, inside the `case`, and push the branch into a
non-recursive combinator — `Ord.then`, `Mb.first`, `Pick.on` in
`prelude.bend`. Every one of those takes both sides as values, so **both sides
are built**. There is no early return anywhere in `kernel.bend`.

The cost is real: `Tags.get` walks the whole list whether or not it found the
key, and `promise_create`'s four validation guards are four helpers deep. The
cost is also bounded — a tag map is a handful of entries, a frontier is one
origin's objects.

What it bought: `promise_create`'s validation had to come out as a function of
the request alone (`pc_reject : Req -> Maybe<Reply>`), separate from the
transition, because there was nowhere to put an early return. That is better
than the Python, where four `return Reply.err(400, ...)` statements are
interleaved with the work. The alternatives were `@unsafe`, which forfeits the
whole reason for being here, and threading a `Result` through every step, which
is the same thing with more ceremony.

## No record-update syntax

`Promise` has nine fields and the kernel changes one or two at a time. Bend has
constructor syntax and nothing else, so every change rebuilds the whole
constructor. The mitigation is a small set of named shapes —
`Promise.settle_to`, `Promise.clear_callbacks`, `Object.with_task`,
`Document.with_objects` — one per change the kernel actually makes, rather than
one per field.

This is pure cost, about sixty lines of it, and it is the change most likely to
rot: add a field to `Promise` and every one of those helpers has to learn it.
Worth revisiting if Bend grows an update form.

## Instants are `Nat`, not a 64-bit integer

Bend has `U32`, `Nat` and `F32`. There is no `U64`. Epoch milliseconds do not
fit in `U32` — 4,294,967,295 ms is 49.7 days — so every instant in the document
(`timeout_at`, `created_at`, `settled_at`, `retry_at`, `lease_at`, `now`) is
`Nat`.

That is the right answer regardless: every one of them is non-negative by
construction, and `Nat` says so in the type rather than in a comment. The thing
to watch is the codec, which is not written yet: `Nat` past `256n` is
`U32.to_nat` underneath, up to `4294967295n`, so how a `Nat` larger than that
is written down and read back is an open question and the first thing to settle
when the codec starts.

## The reply is typed, and a 400 moved

`kernel.py` replies with `dict[str, Any]`. Bend has no `Any`, so `Reply` names
its payloads: `RPromise{PromiseRecord}`, `RUnit`, `RErr{status, message}`.

One check disappeared on the way. `promise_settle` in Python starts with
`if r.state not in SETTLE_STATES: return Reply.err(400, ...)`, because
`rejected_timedout` is server-owned and a client must not be able to write it.
Here `PromiseSettle` carries a `SettleState`, which has three constructors and
no fourth, so the state is unrepresentable rather than rejected. The 400 does
not vanish — it moves to the codec, which is where a malformed request should
be refused. Note it: the conformance suite will look for that 400 on the wire,
and the wire is where it now lives.

## Tags are a sorted assoc list, not a Base `Map`

Base has a string-keyed `Map` with `new set get has del keys`. Two reasons it
is not used here. `Map.get` *"takes a default, and `get` and `has` hand the map
back beside their result"* — sound under affinity, and awkward to thread
through a guard chain that is already four helpers deep. And the codec needs
tags in a canonical order anyway, so the sorted-unique invariant has to exist
somewhere; an assoc list carries it in the representation rather than in a
sorting step at encode time.

Revisit if tag maps ever get large. They will not.

## What is assumed about Base

Twelve names, all from the documented `Type.verb` family, none verified against
a running compiler:

```
Bool.and  Bool.or
Nat.add  Nat.is_eq  Nat.is_lt  Nat.is_le  Nat.is_ge  Nat.read
Char.is_eq  Char.is_lt  Char.is_le  Char.is_ge
```

**Assumption 1**, the only one that looks shaky: the guide lists the `is_eq`
family for `Nat`, `U32` and `F32`, and does not say `Char` is in it. `Char` is
its own type in the term grammar. If `bend base Char` says otherwise, route
`Chr.cmp` and `Chr.is_digit` in `prelude.bend` through `Char.to_u32` and
nothing else in either file changes.

`Ord` is defined here rather than taken from Base's `Cmp`, because every
comparison in both files goes through it and the guide does not name `Cmp`'s
constructors. Swap it for `Cmp` once they are known.
