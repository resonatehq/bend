# LAWS.bend — what the kernel must never do, as claims.
#
# These are post 001's load-bearing properties, and entries in
# `resonatehq/durable-execution`'s conformance catalogue, where they are
# sampled on every step of every test and confirmed on 70,869 reachable states
# to depth 4. A law is the same statement with no depth bound.
#
#   preserved_settled_promise_record    settle is first-writer-wins
#   preserved_promise_birth_fields      create is idempotent
#
# The form changed once already. They were first stated as decidable
# predicates held equal to `True{}`, mirroring `properties.py`, where every
# catalogue entry returns a bool. Attempting the first proof showed why that is
# the wrong shape here: to prove `pred(..) == True{}` you must reduce
# `Value.is_eq`, `Entries.is_eq` and `Str.is_eq` to `True{}`, which needs a
# reflexivity and congruence lemma for each — a small equality library, none of
# it about the protocol, all of it bottoming out in Base facts about
# `Char.is_eq` and `Nat.is_eq` that would have to be found or assumed.
#
# Stated propositionally, the conclusion is an equality of *records*, and the
# cases where nothing was written discharge by `{==}` — both sides are the same
# term. The equality library is not needed because the equality is the
# proposition rather than a function that decides it. The predicate form is
# still the right one for a falsifiability test, where the point is to run it.

import Base
import ./prelude.bend as P
import ./kernel.bend as K

# ---------------------------------------------------------------------------
# The lemmas the proofs decompose into
# ---------------------------------------------------------------------------

# Objects are the only thing a record reads, and the timer is not one of them.
law timer_at_irrelevant:
  for d: K/Document
  for ta: Maybe<&2, Nat>
  for id: String
  {K/record_at(K/Document.with_timer_at(d, ta), id) == K/record_at(d, id)
    : Maybe<&2, K/PromiseRecord>}

# The sweep rewrites a promise only where `is_expired` holds, and `is_expired`
# conjoins `is_pending`, so a settled promise passes through phase 1 untouched.
law expire_one_skips_settled:
  for o: K/Object
  for now: Nat
  for h: Unit where {K/Promise.is_expired(K/Object.promise(o), now) == False{} : Bool}
  {K/sweep.expire.one(K/Promise.is_expired(K/Object.promise(o), now), o) == o : K/Object}

# Phase 1, lifted over the list. Induction on `os`.
law expire_preserves_settled:
  for os: List<&2, K/Object>
  for now: Nat
  for id: String
  for ob: K/Object where {K/Objects.get(os, id) == Some{ob} : Maybe<&2, K/Object>}
  for h: Unit where
    {K/PState.is_pending(K/Promise.state(K/Object.promise(ob))) == False{} : Bool}
  {K/Objects.get(K/sweep.expire(os, now), id) == Some{ob} : Maybe<&2, K/Object>}

# A write lands on one id and leaves every other lookup alone.
law put_preserves_other:
  for os: List<&2, K/Object>
  for o: K/Object
  for id: String
  for h: Unit where {P/Str.is_eq(K/Object.id(o), id) == False{} : Bool}
  {K/Objects.get(K/Objects.put(os, o), id) == K/Objects.get(os, id)
    : Maybe<&2, K/Object>}

law insert_preserves_other:
  for os: List<&2, K/Object>
  for o: K/Object
  for id: String
  for h: Unit where {P/Str.is_eq(K/Object.id(o), id) == False{} : Bool}
  {K/Objects.get(K/Objects.insert(os, o), id) == K/Objects.get(os, id)
    : Maybe<&2, K/Object>}

# The settlement chain clears callbacks and listeners, and `to_record` drops
# both, so even the settling promise's own record survives it. This is the one
# step where the record projection is doing real work, and it is why the law is
# about records rather than about promises.
law chain_preserves_record:
  for out: K/Out
  for id2: String
  for now: Nat
  for cfg: K/KernelCfg
  for id: String
  {K/record_at(K/Out.doc(K/trigger_settlement(out, id2, now, cfg)), id)
    == K/record_at(K/Out.doc(out), id) : Maybe<&2, K/PromiseRecord>}

# `linearize` emits exactly one SetDocument on both branches, so the fallback
# in `committed_or` is never taken. Discharging this is what makes `step_doc`
# mean what its name says.
law committed_is_some:
  for old: Maybe<&2, Nat>
  for out: K/Out
  for d2: K/Document where {K/committed(K/linearize(old, out)) == Some{d2}
    : Maybe<&2, K/Document>}
  {d2 == K/Document.with_timer_at(K/Out.doc(out), K/min_deadline(K/Out.doc(out)))
    : K/Document}

# ---------------------------------------------------------------------------
# The claims
# ---------------------------------------------------------------------------

law preserved_settled_promise_record:
  for d: K/Document
  for r: K/Req
  for now: Nat
  for cfg: K/KernelCfg
  for id: String
  for ob: K/Object where {K/Document.get(d, id) == Some{ob} : Maybe<&2, K/Object>}
  for h: Unit where
    {K/PState.is_pending(K/Promise.state(K/Object.promise(ob))) == False{} : Bool}
  {K/record_at(K/step_doc(d, r, now, cfg), id)
    == Some{K/Promise.to_record(id, K/Object.promise(ob))}
    : Maybe<&2, K/PromiseRecord>}

law preserved_promise_birth_fields:
  for d: K/Document
  for r: K/Req
  for now: Nat
  for cfg: K/KernelCfg
  for id: String
  for ob: K/Object where {K/Document.get(d, id) == Some{ob} : Maybe<&2, K/Object>}
  {K/birth_at(K/step_doc(d, r, now, cfg), id)
    == Some{K/PromiseRecord.birth(K/Promise.to_record(id, K/Object.promise(ob)))}
    : Maybe<&2, K/BirthFields>}
