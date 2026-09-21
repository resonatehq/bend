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
# They were first written as decidable predicates held equal to `True{}`,
# mirroring `properties.py`, where every catalogue entry returns a bool.
# Attempting the first proof showed why that is the wrong shape here: to prove
# `pred(..) == True{}` you must reduce `Value.is_eq`, `Entries.is_eq` and
# `String.eq` to `True{}`, which needs a reflexivity lemma for each — an
# equality library, none of it about the protocol. Stated propositionally the
# conclusion is an equality of records, and every case where nothing was
# written is `{==}`, because both sides are the same term.
#
# The predicate form is still right for a falsifiability test, where the point
# is to run it. That is `TESTS.bend`, and it does not exist yet.

import Base
import ./prelude.bend as P
import ./kernel.bend as K

# ---------------------------------------------------------------------------
# The lemmas
# ---------------------------------------------------------------------------

# Objects are the only thing a record reads, and the timer is not one of them.
law timer_at_irrelevant:
  for d: K.Document
  for ta: Maybe<&2, Nat>
  for id: String
  {K.record_at(K.Document.with_timer_at(d, ta), id) == K.record_at(d, id)
    : Maybe<&2, K.PromiseRecord>}

# The sweep rewrites a promise only where `is_expired` holds, and `is_expired`
# conjoins `is_pending`, so a settled promise passes phase 1 untouched.
law expire_one_skips_settled:
  for o: K.Object
  for now: Nat
  for h: {K.Promise.is_expired(K.Object.promise(o), now) == False{} : Bool}
  {K.sweep.expire.one(K.Promise.is_expired(K.Object.promise(o), now), o) == o
    : K.Object}

# A settled promise is not expired, whatever the clock says: `is_expired`
# conjoins `is_pending`, and `Bool.and` is False as soon as its first argument
# is. This is the lemma that feeds the one above.
law settled_is_not_expired:
  for p: K.Promise
  for now: Nat
  for h: {K.PState.is_pending(K.Promise.state(p)) == False{} : Bool}
  {K.Promise.is_expired(p, now) == False{} : Bool}

# Phase 1 never renames anything: both branches of `sweep.expire.one` keep the
# object's id, so a lookup finds the same position before and after the sweep.
law expire_one_keeps_id:
  for b: Bool
  for +o: K.Object
  for now: Nat
  {K.Object.id(K.sweep.expire.one(b, o)) == K.Object.id(o) : String}

# Phase 1, lifted over the list.
law expire_preserves_settled:
  for os: List<&2, K.Object>
  for now: Nat
  for id: String
  for ob: K.Object
  for e: {K.Objects.get(os, id) == Some{ob} : Maybe<&2, K.Object>}
  for h: {K.PState.is_pending(K.Promise.state(K.Object.promise(ob))) == False{} : Bool}
  {K.Objects.get(K.sweep.expire(os, now), id) == Some{ob} : Maybe<&2, K.Object>}

# A write lands on one id and leaves every other lookup alone.
law put_preserves_other:
  for os: List<&2, K.Object>
  for o: K.Object
  for id: String
  for h: {String.eq(K.Object.id(o), id) == False{} : Bool}
  {K.Objects.get(K.Objects.put(os, o), id) == K.Objects.get(os, id)
    : Maybe<&2, K.Object>}

law insert_preserves_other:
  for os: List<&2, K.Object>
  for o: K.Object
  for id: String
  for h: {String.eq(K.Object.id(o), id) == False{} : Bool}
  {K.Objects.get(K.Objects.insert(os, o), id) == K.Objects.get(os, id)
    : Maybe<&2, K.Object>}

# The settlement chain clears callbacks and listeners, and `to_record` drops
# both, so even the settling promise's own record survives it. This is the one
# step where the record projection is doing real work, and it is why the law is
# about records rather than about promises.
law chain_preserves_record:
  for out: K.Out
  for id2: String
  for now: Nat
  for cfg: K.KernelCfg
  for id: String
  {K.record_at(K.Out.doc(K.trigger_settlement(out, id2, now, cfg)), id)
    == K.record_at(K.Out.doc(out), id) : Maybe<&2, K.PromiseRecord>}

# `linearize` puts exactly one SetDocument in the list on both branches, so
# `committed_or` never takes its fallback. Discharging this is what makes
# `step_doc` mean what its name says.
# The case split `committed_is_some` needs is on `Mb.nat_is_eq(..)`, a computed
# value, which a `match` may not inspect. The way through is not to split at
# all: quantify the lemma over every `same` and every `new`, prove it by
# matching those parameters, and instantiate it at the computed pair. That
# dissolves what looked like a blocker.
law committed_is_some.step:
  for same: Bool
  for old: Maybe<&2, Nat>
  for new: Maybe<&2, Nat>
  for out: K.Out
  {K.committed(K.linearize.on(same, old, new, out))
    == Some{K.Document.with_timer_at(K.Out.doc(out), new)} : Maybe<&2, K.Document>}

law committed_is_some:
  for +old: Maybe<&2, Nat>
  for +out: K.Out
  {K.committed(K.linearize(old, out))
    == Some{K.Document.with_timer_at(K.Out.doc(out), K.min_deadline(K.Out.doc(out)))}
    : Maybe<&2, K.Document>}

# ---------------------------------------------------------------------------
# The claims
# ---------------------------------------------------------------------------

law preserved_settled_promise_record:
  for d: K.Document
  for r: K.Req
  for now: Nat
  for cfg: K.KernelCfg
  for id: String
  for ob: K.Object
  for e: {K.Document.get(d, id) == Some{ob} : Maybe<&2, K.Object>}
  for h: {K.PState.is_pending(K.Promise.state(K.Object.promise(ob))) == False{} : Bool}
  {K.record_at(K.step_doc(d, r, now, cfg), id)
    == Some{K.Promise.to_record(id, K.Object.promise(ob))}
    : Maybe<&2, K.PromiseRecord>}

law preserved_promise_birth_fields:
  for d: K.Document
  for r: K.Req
  for now: Nat
  for cfg: K.KernelCfg
  for id: String
  for ob: K.Object
  for e: {K.Document.get(d, id) == Some{ob} : Maybe<&2, K.Object>}
  {K.birth_at(K.step_doc(d, r, now, cfg), id)
    == Some{K.PromiseRecord.birth(K.Promise.to_record(id, K.Object.promise(ob)))}
    : Maybe<&2, K.BirthFields>}
