# prelude.bend — the pieces Base does not hand us, kept apart so they can be
# checked on their own.
#
# Two rules of the language shape everything here, and everything in
# kernel.bend:
#
#   - A `match` inspects a parameter or a variable bound by a pattern, never a
#     computed value. A comparison is a computed value, so a guard cannot be
#     matched where it is written.
#   - Mutual recursion is not allowed. So a recursive function cannot hand its
#     guard to a helper and have that helper call back.
#
# Together they rule out the shape a guard usually takes. What is left is to
# keep the recursion direct, inside the `case`, and push the branch into a
# non-recursive combinator: `Ord.then`, `Mb.first`, `Pick.on`. Every such
# combinator takes both sides as values, so both sides are built. That is the
# cost, and it is why the kernel below has no early return anywhere.

import Base

# ---------------------------------------------------------------------------
# Ordering
# ---------------------------------------------------------------------------

# Base has a `Cmp`, but its constructor names are not in the guide, and every
# comparison here goes through this type. Ours, so the file stands alone.
type Ord is Data:
  Lt{}
  Eq{}
  Gt{}

# Lexicographic composition: the first decisive answer wins.
def Ord.then(a: Ord, b: Ord) -> Ord:
  match a:
    case Lt{}:
      Lt{}
    case Gt{}:
      Gt{}
    case Eq{}:
      b

def Ord.is_eq(a: Ord) -> Bool:
  match a:
    case Eq{}:
      True{}
    case Lt{}:
      False{}
    case Gt{}:
      False{}

# ---------------------------------------------------------------------------
# Branching on a computed Bool
# ---------------------------------------------------------------------------

# The workaround the guide prescribes, once, generically: hand the computed
# value to a helper that matches on its parameter. Both arms are values, so
# both are built — never put a recursive call in one.
def Pick.on(-a: Quant, -A: Kind(a), c: Bool, t: A, f: A) -> A:
  match c:
    case True{}:
      t
    case False{}:
      f

def Mb.first(-a: Quant, -A: Kind(a), x: Maybe<a, A>, y: Maybe<a, A>) -> Maybe<a, A>:
  match x:
    case Some{v}:
      Some{v}
    case None{}:
      y

def Mb.is_some(-a: Quant, -A: Kind(a), x: Maybe<a, A>) -> Bool:
  match x:
    case Some{_}:
      True{}
    case None{}:
      False{}

# ---------------------------------------------------------------------------
# Characters and strings
# ---------------------------------------------------------------------------

# ASSUMPTION: `Char.is_eq` and `Char.is_lt` exist, following the Base naming
# convention. `bend base Char` settles it; if Char is not in the is_eq family,
# route through Char.to_u32 here and nothing else changes.
def Chr.cmp(+x: Char, +y: Char) -> Ord:
  Chr.cmp.on(Char.is_eq(x, y), Char.is_lt(x, y))

def Chr.cmp.on(e: Bool, l: Bool) -> Ord:
  match e:
    case True{}:
      Eq{}
    case False{}:
      Pick.on(&2, Ord, l, Lt{}, Gt{})

def Chr.is_digit(+c: Char) -> Bool:
  Bool.and(Char.is_ge(c, '0'), Char.is_le(c, '9'))

def Chr.is_sep(+c: Char) -> Bool:
  Bool.or(Char.is_eq(c, ':'), Char.is_eq(c, '.'))

# Byte order, shorter-is-smaller on a shared prefix. The recursion is direct
# and on the tails, so the termination checker sees a smaller first argument.
def Str.cmp(a: String, b: String) -> Ord:
  match a b:
    case SNil{} SNil{}:
      Eq{}
    case SNil{} SCon{_, _}:
      Lt{}
    case SCon{_, _} SNil{}:
      Gt{}
    case SCon{+x, s} SCon{+y, t}:
      Ord.then(Chr.cmp(x, y), Str.cmp(s, t))

def Str.is_eq(a: String, b: String) -> Bool:
  Ord.is_eq(Str.cmp(a, b))

def Str.rev(s: String) -> String:
  Str.rev.go(s, SNil{})

def Str.rev.go(s: String, acc: String) -> String:
  match s:
    case SNil{}:
      acc
    case SCon{h, t}:
      Str.rev.go(t, SCon{h, acc})

def Str.is_nonempty(s: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{_, _}:
      True{}

# Every character a digit, and at least one. `"".is_digits` is False, which is
# what `resonate:delay` validation wants.
def Str.is_digits(s: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{+h, t}:
      Bool.and(Chr.is_digit(h), Str.is_digits.rest(t))

def Str.is_digits.rest(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{+h, t}:
      Bool.and(Chr.is_digit(h), Str.is_digits.rest(t))

# ---------------------------------------------------------------------------
# Lists
# ---------------------------------------------------------------------------

def Lst.rev(-a: Quant, -A: Kind(a), xs: List<a, A>) -> List<a, A>:
  Lst.rev.go(a, A, xs, Nil{})

def Lst.rev.go(-a: Quant, -A: Kind(a), xs: List<a, A>, acc: List<a, A>) -> List<a, A>:
  match xs:
    case Nil{}:
      acc
    case Con{h, t}:
      Lst.rev.go(a, A, t, Con{h, acc})

def Lst.snoc(-a: Quant, -A: Kind(a), xs: List<a, A>, x: A) -> List<a, A>:
  match xs:
    case Nil{}:
      Con{x, Nil{}}
    case Con{h, t}:
      Con{h, Lst.snoc(a, A, t, x)}

def Lst.cat(-a: Quant, -A: Kind(a), xs: List<a, A>, ys: List<a, A>) -> List<a, A>:
  match xs:
    case Nil{}:
      ys
    case Con{h, t}:
      Con{h, Lst.cat(a, A, t, ys)}

def Lst.has_str(xs: List<&2, String>, +s: String) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{+h, t}:
      Bool.or(Str.is_eq(h, s), Lst.has_str(t, s))

# Insert into a list already sorted by `Str.cmp`, keeping it sorted and
# dropping a duplicate. The sorted-unique invariant is what makes a tag map an
# ordered assoc list rather than a Base `Map`: the codec needs a canonical
# order anyway, and `Map.get` hands the map back beside its result, which
# threads awkwardly through a guard chain.
def Str.set.insert(xs: List<&2, String>, +s: String) -> List<&2, String>:
  match xs:
    case Nil{}:
      Con{s, Nil{}}
    case Con{+h, t}:
      Str.set.insert.on(Str.cmp(h, s), h, t, s)

def Str.set.insert.on(o: Ord, +h: String, t: List<&2, String>, +s: String) -> List<&2, String>:
  match o:
    case Eq{}:
      Con{h, t}
    case Lt{}:
      Con{h, Str.set.insert(t, s)}
    case Gt{}:
      Con{s, Con{h, t}}

# ---------------------------------------------------------------------------
# Dewey ids
# ---------------------------------------------------------------------------

# `run:2:1` sorts under `run:2`, and `o:2` before `o:10`, because a segment of
# digits compares as a number and sorts before any segment that is not.
def Dewey.split(s: String) -> List<&2, String>:
  Dewey.split.go(s, SNil{}, Nil{})

def Dewey.split.go(s: String, cur: String, acc: List<&2, String>) -> List<&2, String>:
  match s:
    case SNil{}:
      Lst.rev(&2, String, Con{Str.rev(cur), acc})
    case SCon{+h, t}:
      Dewey.split.go.on(Chr.is_sep(h), h, t, cur, acc)

def Dewey.split.go.on(sep: Bool, h: Char, t: String, cur: String,
  acc: List<&2, String>) -> List<&2, String>:
  match sep:
    case True{}:
      Dewey.split.go(t, SNil{}, Con{Str.rev(cur), acc})
    case False{}:
      Dewey.split.go(t, SCon{h, cur}, acc)

# A digit segment ranks before a non-digit one; two digit segments compare as
# numbers. `Nat.read` answers a Maybe, and a segment that passed `is_digits`
# always reads, so the None case is unreachable and answers Eq.
def Dewey.seg_cmp(+x: String, +y: String) -> Ord:
  Dewey.seg_cmp.on(Str.is_digits(x), Str.is_digits(y), x, y)

def Dewey.seg_cmp.on(dx: Bool, dy: Bool, +x: String, +y: String) -> Ord:
  match dx dy:
    case True{} True{}:
      Dewey.num_cmp(Nat.read(x), Nat.read(y))
    case True{} False{}:
      Lt{}
    case False{} True{}:
      Gt{}
    case False{} False{}:
      Str.cmp(x, y)

def Dewey.num_cmp(x: Maybe<&2, Nat>, y: Maybe<&2, Nat>) -> Ord:
  match x y:
    case Some{+a} Some{+b}:
      Dewey.num_cmp.on(Nat.is_eq(a, b), Nat.is_lt(a, b))
    case Some{_} None{}:
      Eq{}
    case None{} Some{_}:
      Eq{}
    case None{} None{}:
      Eq{}

def Dewey.num_cmp.on(e: Bool, l: Bool) -> Ord:
  match e:
    case True{}:
      Eq{}
    case False{}:
      Pick.on(&2, Ord, l, Lt{}, Gt{})

def Dewey.segs_cmp(xs: List<&2, String>, ys: List<&2, String>) -> Ord:
  match xs ys:
    case Nil{} Nil{}:
      Eq{}
    case Nil{} Con{_, _}:
      Lt{}
    case Con{_, _} Nil{}:
      Gt{}
    case Con{+x, s} Con{+y, t}:
      Ord.then(Dewey.seg_cmp(x, y), Dewey.segs_cmp(s, t))

def Dewey.cmp(+x: String, +y: String) -> Ord:
  Dewey.segs_cmp(Dewey.split(x), Dewey.split(y))

# Everything before the first ':'. The routing key, and the reason one document
# can answer any single operation.
def Dewey.origin(s: String) -> String:
  Str.rev(Dewey.origin.go(s, SNil{}))

def Dewey.origin.go(s: String, acc: String) -> String:
  match s:
    case SNil{}:
      acc
    case SCon{+h, t}:
      Dewey.origin.go.on(Char.is_eq(h, ':'), h, t, acc)

def Dewey.origin.go.on(hit: Bool, h: Char, t: String, acc: String) -> String:
  match hit:
    case True{}:
      acc
    case False{}:
      Dewey.origin.go(t, SCon{h, acc})
