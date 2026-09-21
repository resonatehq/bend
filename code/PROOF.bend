import Base
import ./prelude.bend as P
import ./kernel.bend as K
import ./LAWS.bend as L

def L.timer_at_irrelevant(d, ta, id):
  match d:
    case K.Doc{os, clk, g, ta0, tn}:
      {==}

def L.settled_is_not_expired(p, now, h):
  %Equal.sym(Bool, K.PState.is_pending(K.Promise.state(p)), False{}, h) :
    {Bool.and(_, Cmp.is_ge(Nat.cmp(now, K.Promise.timeout_at(p)))) == False{} : Bool}
  {==}

def L.expire_one_skips_settled(o, now, h):
  %Equal.sym(Bool, K.Promise.is_expired(K.Object.promise(o), now), False{}, h) :
    {K.sweep.expire.one(_, o) == o : K.Object}
  {==}

def L.expire_one_keeps_id(b, o, now):
  match b:
    case True{}:
      match o:
        case K.Ob{i, pr, tk}:
          {==}
    case False{}:
      {==}

def L.expire_preserves_settled(os, now, id, ob, e, h):
  ?TODO

def L.put_preserves_other(os, o, id, h):
  ?TODO

def L.insert_preserves_other(os, o, id, h):
  ?TODO

def L.chain_preserves_record(out, id2, now, cfg, id):
  ?TODO

def L.committed_is_some.step(same, old, new, out):
  match same new:
    case True{} None{}:
      {==}
    case True{} Some{at}:
      {==}
    case False{} None{}:
      {==}
    case False{} Some{at}:
      {==}

def L.committed_is_some(old, out):
  L.committed_is_some.step(K.Mb.nat_is_eq(old, K.min_deadline(K.Out.doc(out))),
    old, K.min_deadline(K.Out.doc(out)), out)

def L.preserved_settled_promise_record(d, r, now, cfg, id, ob, e, h):
  ?TODO

def L.preserved_promise_birth_fields(d, r, now, cfg, id, ob, e):
  ?TODO
