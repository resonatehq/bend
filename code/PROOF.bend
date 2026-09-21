# PROOF.bend — the proofs of LAWS.bend. TWO DISCHARGED, FIVE OPEN.
#
# Read the status line above before anything else. `bend PROOF.bend` will not
# say "All terms check" until the `?TODO`s are gone, and the two that are
# written here have never been through a compiler either.
#
# The argument, on paper, for preserved_settled_promise_record. A settled
# promise at `id` has to survive three things in order.
#
# 1. The sweep's phase 1. `sweep.expire` maps `sweep.expire.one` over every
#    object, and rewrites one only where `Promise.is_expired` holds.
#    `is_expired` conjoins `PState.is_pending`, which is False for a settled
#    promise, so `Bool.and` is False and the object passes through.
#    -> expire_one_skips_settled, then expire_preserves_settled by induction.
#
# 2. The sweep's phase 2, and any chain the request runs. `trigger_settlement`
#    can reach our object two ways. It writes `drained` for the settling
#    object, which is a different id — `put_preserves_other`. And `fan_out`
#    reaches our object if it is an awaiter, through `wake`. There
#    `wake.live` is handed `Promise.is_live`, which also conjoins
#    `is_pending`, so a settled awaiter takes the False branch and `out` comes
#    back untouched. That is the same conjunct doing the work as in step 1,
#    and it is the reason the bug that used to sit at that call site —
#    `is_expired` where `is_live` belongs — is not merely a wrong answer but
#    would have made this law false for the expired-but-pending awaiter.
#    -> chain_preserves_record.
#
# 3. The request itself. Case on `r`:
#      PromiseGet     — returns `Res{out, ..}`, the document is the swept one.
#      PromiseCreate  — `promise_create.existing` finds our id present and
#                       returns `Res{out, ..}` without writing. Where the
#                       request's id differs, `insert_promise` inserts under
#                       another id (insert_preserves_other) and every later
#                       `Document.put` writes that id (put_preserves_other).
#      PromiseSettle  — our id: `promise_settle.pending` takes the False
#                       branch, because the promise is not pending, and
#                       returns without writing. This branch *is*
#                       first-writer-wins, and it is one `{==}` once the case
#                       is refined. Another id: `settle` writes there and runs
#                       the chain, which is step 2.
#
# Then `linearize` wraps the result in `Document.with_timer_at`, which does not
# touch objects (timer_at_irrelevant), and emits exactly one SetDocument, so
# `committed_or` never takes its fallback (committed_is_some).
#
# WHERE IT STOPS. Two idioms are missing and both list inductions need them:
#
#   (a) Absurdity. The `Nil{}` base case of expire_preserves_settled has the
#       hypothesis `Objects.get(Nil{}, id) == Some{ob}`, whose left side
#       computes to `None{}`. The case is vacuous and wants an elimination of
#       `{None{} == Some{ob} : Maybe<..>}` into anything. Bend has `{a != b :
#       T}` in its type grammar, so the elimination exists; its spelling is
#       not in the guide's syntax reference.
#
#   (b) Case analysis on a computed Bool inside a proof. `Objects.get` branches
#       through `Mb.first(Objects.hit(Str.is_eq(Object.id(o), id), o), ..)`,
#       and the rule that a `match` inspects a parameter and never a computed
#       value holds in proofs as it does in code. So the `Con{o, rest}` step
#       needs a view lemma — one that takes `Str.is_eq(Object.id(o), id)` as a
#       parameter and is matched there — and the induction is threaded through
#       it. That is a standard shape and writing it blind is where guessing
#       starts, so it is not written.
#
# Neither is a fact about the protocol. Both are the first two things to ask a
# working compiler.

import Base
import ./prelude.bend as P
import ./kernel.bend as K
import ./LAWS.bend as L

# ---------------------------------------------------------------------------
# Discharged
# ---------------------------------------------------------------------------

# A record reads objects and nothing else. Destructuring the document makes
# both sides the same term: `with_timer_at` rebuilds `Doc` with the same `os`,
# and `record_at` reaches for `os` alone.
def timer_at_irrelevant(d, ta, id):
  match d:
    case Doc{os, clk, g, ta0, tn}:
      {==}

# `is_expired` is False by hypothesis, so rewriting the scrutinee to `False{}`
# lets `sweep.expire.one` take its first case, which is `o`.
def expire_one_skips_settled(o, now, h):
  (u, p) = h
  %p : {K/sweep.expire.one(_, o) == o : K/Object}
  {==}

# ---------------------------------------------------------------------------
# Open
# ---------------------------------------------------------------------------

# Induction on `os`. Base case needs (a); step case needs (b).
def expire_preserves_settled(os, now, id, ob, h):
  ?TODO

# Induction on `os`, and (b) twice: once for the `Objects.put` comparison and
# once for the `Objects.get` that follows it.
def put_preserves_other(os, o, id, h):
  ?TODO

# Induction on `os`, and a three-way case on `Dewey.cmp` rather than a Bool,
# which is the easier version of (b) because `Ord` is matched on directly.
def insert_preserves_other(os, o, id, h):
  ?TODO

# The one with real content. Three sub-obligations: `drained` writes one id;
# `fan_out` folds `wake`, which is the identity on a settled awaiter; `notify`
# appends sends and never touches the document.
def chain_preserves_record(out, id2, now, cfg, id):
  ?TODO

# Case on whether `old` equals `min_deadline`, then read the two branches of
# `linearize.on`. Both put exactly one `SetDocument` in the list, so
# `committed` finds it. No induction, just a long computation.
def committed_is_some(old, out, d2):
  ?TODO

def preserved_settled_promise_record(d, r, now, cfg, id, ob, h):
  ?TODO

def preserved_promise_birth_fields(d, r, now, cfg, id, ob):
  ?TODO
