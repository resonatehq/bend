# PROOF.bend — the proofs of LAWS.bend. OPEN.
#
# Both laws are stated and neither is discharged. `?TODO` leaves a goal open,
# so `bend PROOF.bend` will not say "All terms check" until these are filled.
# That is the honest state of this cut: the claims are pinned down, the
# arguments are not.
#
# What each proof has to do, from reading the kernel rather than from having
# run one:
#
# preserved_settled_promise_record
#   Case on `r`. `PromiseGet` writes nothing, so the committed document is the
#   swept one and the obligation reduces to the sweep case below.
#   `PromiseCreate` reaches `promise_create.existing`, which returns the stored
#   object untouched when the id is present — that branch is reflexivity.
#   `PromiseSettle` reaches `promise_settle.pending`, whose False branch (the
#   promise is not pending, so it is settled) returns without touching the
#   document. The work is the sweep: `sweep.expire.one` rewrites a promise only
#   where `Promise.is_expired` holds, and `is_expired` conjoins
#   `PState.is_pending`, so a settled promise is untouched — that is a lemma
#   about `sweep.expire`, by induction on the object list. Then
#   `trigger_settlement` has to be shown to leave a settled promise's *record*
#   alone: it clears callbacks and listeners, which are not record fields, and
#   `Promise.to_record` drops both. That is the one step where the record
#   projection is doing real work, and it is why the law is about records
#   rather than about promises.
#
# preserved_promise_birth_fields
#   The same case split, and strictly easier: no writer in this cut constructs
#   a `Pr` with a param, tags, timeoutAt or createdAt other than the ones it
#   destructured, except `insert_promise`, which only runs when
#   `Document.get` answered None. `Promise.settle_to`, `clear_callbacks` and
#   `clear_listeners` each pass those four fields through unchanged, so the
#   lemma is one case per writer plus the two list inductions.
#
# Both need the same two lemmas about the document as a list, and those should
# be proved first and separately:
#
#   Objects.put_get   — get(put(os, o), id(o)) is Some{o}, and for any other
#                       id, get is unchanged.
#   Objects.ins_get   — get(insert(os, o), id) is unchanged for id /= id(o).

import Base
import ./prelude.bend as P
import ./kernel.bend as K
import ./LAWS.bend as L

def preserved_settled_promise_record(d, r, now, cfg, id):
  ?TODO

def preserved_promise_birth_fields(d, r, now, cfg, id):
  ?TODO
