# bend

The Resonate protocol kernel, in Bend.

`resonatehq/durable-execution` builds a durable execution engine in Python:
`code/final/kernel.py` is the protocol's state machine as a pure function,
`engine.py` is the shell that performs its effects, and four layers of evidence
— a 93-entry conformance catalogue, an exhaustive search, a Hypothesis state
machine and a conformance suite — say it is right. This repository asks what
changes when the kernel is written in a language that can prove things instead.

The bet is narrow. The kernel is already pure, first-order, total code with no
clock, no ids and no I/O, and — checked rather than assumed — it contains no
fixpoint iteration: every loop is a fold over a list, and `trigger_settlement`
does not recurse. That is the shape Bend's termination checker accepts. The
shell is straight-line, because the engine deliberately never loops. So the
constraint Bend imposes is one the design had already paid for.

What it buys, if it works: the catalogue's properties stop being sampled and
start being proved. `explore.py` confirms them on 70,869 reachable states to
depth 4. A law has no depth bound.

## Status

`prelude.bend` and `kernel.bend` check. Six of the twelve laws are proven; six
are open. `bend code/PROOF.bend` reports the six.

```
code/prelude.bend   ordering, strings, Dewey ids: what Base does not hand us
code/kernel.bend    the promise half of the protocol
code/LAWS.bend      two claims and the ten lemmas they decompose into
code/PROOF.bend     six discharged, six open, both claims still open
notes/              what Bend forced, and why each fork went the way it did
```

`kernel.bend` covers `promise.get`, `promise.create`, `promise.settle`, the
settlement chain, and the sweep's expiry phases. A targeted promise is born
with a task, because that is when the task exists, but the twelve task
operations and the sweep's retry and lease phases are not here. Neither is the
codec: nothing in this cut serializes anything, which is the point of starting
here rather than there.

## Checking it

```
bend code/kernel.bend        # does it check?
bend code/PROOF.bend         # "All terms check" once the laws are discharged
bend base Char               # settles assumption 1 in notes/001
```

`bend-lang.com` is unreachable from this environment and the compiler is not on
npm, but `git clone https://github.com/bendlang/bend` works and `bun
bend2/main.ts` is the CLI. `notes/002` records what the first real run changed:
definitions must precede use, a recursive function's branch helper takes the
recursive result as a parameter, and a fold's shrinking argument must come
first.

## The two laws

```
preserved_settled_promise_record    settle is first-writer-wins
preserved_promise_birth_fields      create is idempotent
```

Post 001 rests the whole design on those two sentences. They are entries 361
and 350 of `properties.py`, sampled on every step of every test over there.
Here they are claims about every document, every request and every instant.
Discharging them is the milestone that decides whether the rest of the kernel
is worth writing in this language; nothing else in this repository matters
until they check.

Neither is discharged yet. Six of the ten lemmas under them are:
`timer_at_irrelevant`, `settled_is_not_expired`, `expire_one_skips_settled`,
`expire_one_keeps_id`, `committed_is_some` and its step lemma.

The four that remain are the ones that look an id up in a list, and they all
want the same missing piece: a reflection lemma for `String.eq`, tying the
decidable equality to propositional equality. Base has only `Equal.cong`,
`Equal.sym` and `Equal.trans`, so that lemma is ours to prove. It is the next
piece of work, and `notes/002` says why.

Attempting the first proof has already paid for itself once: `wake` was handed
`Promise.is_expired` where it needed `Promise.is_live`, which is not its
negation. A suspended awaiter was never resumed and an expired-but-pending one
was resumed where the sweep should have fulfilled it. The argument for the law
walks straight through that call site, which is how it surfaced.
