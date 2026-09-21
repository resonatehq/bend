# LAWS.bend — what the kernel must never do, as claims.
#
# These two are post 001's load-bearing properties, and they are entries in
# `resonatehq/durable-execution`'s conformance catalogue — where they are
# sampled on every step of every test, and confirmed on 70,869 reachable states
# to depth 4. A law is the same statement quantified over every document, every
# request and every instant, with no depth bound.
#
#   preserved_settled_promise_record    settle is first-writer-wins
#   preserved_promise_birth_fields      create is idempotent
#
# Each is stated as a decidable predicate held equal to True, which is the same
# shape the Python catalogue uses (`properties.py` entries return bool), so the
# two can be read side by side.

import Base
import ./prelude.bend as P
import ./kernel.bend as K

# ---------------------------------------------------------------------------
# The predicates
# ---------------------------------------------------------------------------

# A promise that is already settled in `d` has the same record in the document
# the step commits. Vacuously true where the promise is absent or pending.
def Laws.settled_preserved(+d: K/Document, +r: K/Req, +now: Nat, +cfg: K/KernelCfg,
  +id: String) -> Bool:
  Laws.settled_preserved.on(K/Document.get(d, id),
    K/committed(K/Step.fx(K/handle_external(d, r, now, cfg))), id)

def Laws.settled_preserved.on(before: Maybe<&2, K/Object>, after: Maybe<&2, K/Document>,
  +id: String) -> Bool:
  match before after:
    case Some{+ob} Some{+d2}:
      Laws.settled_preserved.both(
        K/PState.is_pending(K/Promise.state(K/Object.promise(ob))), ob, d2, id)
    case Some{_} None{}:
      False{}
    case None{} _:
      True{}

def Laws.settled_preserved.both(pending: Bool, +ob: K/Object, +d2: K/Document,
  +id: String) -> Bool:
  match pending:
    case True{}:
      True{}
    case False{}:
      Laws.same_record(K/Promise.to_record(id, K/Object.promise(ob)),
        K/Document.get(d2, id), id)

def Laws.same_record(rec: K/PromiseRecord, after: Maybe<&2, K/Object>, +id: String) -> Bool:
  match after:
    case None{}:
      False{}
    case Some{ob}:
      K/PromiseRecord.is_eq(rec, K/Promise.to_record(id, K/Object.promise(ob)))

# A promise present in `d` keeps its param, tags, timeoutAt and createdAt in
# the document the step commits, whatever the request was.
def Laws.birth_preserved(+d: K/Document, +r: K/Req, +now: Nat, +cfg: K/KernelCfg,
  +id: String) -> Bool:
  Laws.birth_preserved.on(K/Document.get(d, id),
    K/committed(K/Step.fx(K/handle_external(d, r, now, cfg))), id)

def Laws.birth_preserved.on(before: Maybe<&2, K/Object>, after: Maybe<&2, K/Document>,
  +id: String) -> Bool:
  match before after:
    case Some{+ob} Some{+d2}:
      Laws.same_birth(K/Promise.to_record(id, K/Object.promise(ob)),
        K/Document.get(d2, id), id)
    case Some{_} None{}:
      False{}
    case None{} _:
      True{}

def Laws.same_birth(rec: K/PromiseRecord, after: Maybe<&2, K/Object>, +id: String) -> Bool:
  match after:
    case None{}:
      False{}
    case Some{ob}:
      K/PromiseRecord.born_eq(rec, K/Promise.to_record(id, K/Object.promise(ob)))

# ---------------------------------------------------------------------------
# The claims
# ---------------------------------------------------------------------------

law preserved_settled_promise_record:
  for d: K/Document
  for r: K/Req
  for now: Nat
  for cfg: K/KernelCfg
  for id: String
  {Laws.settled_preserved(d, r, now, cfg, id) == True{} : Bool}

law preserved_promise_birth_fields:
  for d: K/Document
  for r: K/Req
  for now: Nat
  for cfg: K/KernelCfg
  for id: String
  {Laws.birth_preserved(d, r, now, cfg, id) == True{} : Bool}
