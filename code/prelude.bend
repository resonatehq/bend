# prelude.bend — the few things Base does not hand us.
#
# Three rules of the language shape this file and kernel.bend:
#
#   - A `match` inspects a parameter or a variable bound by a pattern, never a
#     computed value. So a guard is computed in one def and matched in another,
#     which is why Base is full of `X.y.if` and `X.y.fin` and so is this.
#   - Mutual recursion is not allowed. So a recursive function cannot hand its
#     guard to a helper and have that helper call back; the recursion stays
#     direct inside the `case`, and the branch goes into `Bool.pick` or
#     `Maybe.or`, both of which build both sides.
#   - A name must be defined before it is used. Every file here reads bottom
#     up: leaves first, entry points last.

import Base

# Lexicographic composition: the first decisive answer wins.
def Cmp.then(a: Cmp, b: Cmp) -> Cmp:
  match a:
    case LT{}:
      LT{}
    case GT{}:
      GT{}
    case EQ{}:
      b

def Str.is_digits.go(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{+h, t}:
      Bool.and(Char.is_digit(h), Str.is_digits.go(t))

# Every character a digit, and at least one, so "" is not digits — which is
# what `resonate:delay` validation wants.
def Str.is_digits(s: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{+h, t}:
      Bool.and(Char.is_digit(h), Str.is_digits.go(t))

def Str.set.insert.if(o: Cmp, +h: String, t: List<&2, String>, +s: String,
  rest: List<&2, String>) -> List<&2, String>:
  match o:
    case EQ{}:
      Con{h, t}
    case LT{}:
      Con{h, rest}
    case GT{}:
      Con{s, Con{h, t}}

# Insert into a list already sorted by `String.order`, keeping it sorted and
# dropping a duplicate. A task's `resumes` is a set in the protocol and an
# ordered list here, because the codec needs a canonical order anyway.
def Str.set.insert(xs: List<&2, String>, +s: String) -> List<&2, String>:
  match xs:
    case Nil{}:
      Con{s, Nil{}}
    case Con{+h, +t}:
      Str.set.insert.if(String.order(h, s), h, t, s, Str.set.insert(t, s))

# ---------------------------------------------------------------------------
# Dewey ids
# ---------------------------------------------------------------------------

def Dewey.is_sep(+c: Char) -> Bool:
  Bool.or(Char.is_eq(c, ':'), Char.is_eq(c, '.'))

# The branch picks the next accumulator pair; the recursion stays here, on a
# structurally smaller `s`. Routing it through a helper that called back would
# be mutual recursion, which the language does not allow.
def Dewey.split.go(s: String, +cur: String, +acc: List<&2, String>) -> List<&2, String>:
  match s:
    case SNil{}:
      List.reverse(&2, String, Con{String.reverse(cur), acc})
    case SCon{+h, t}:
      Dewey.split.go(t,
        Bool.pick(String, Dewey.is_sep(h), SNil{}, SCon{h, cur}),
        Bool.pick(List<&2, String>, Dewey.is_sep(h),
          Con{String.reverse(cur), acc}, acc))

def Dewey.split(s: String) -> List<&2, String>:
  Dewey.split.go(s, SNil{}, Nil{})

def Dewey.num_cmp(x: Maybe<&2, Nat>, y: Maybe<&2, Nat>) -> Cmp:
  match x y:
    case Some{a} Some{b}:
      Nat.cmp(a, b)
    case Some{_} None{}:
      EQ{}
    case None{} Some{_}:
      EQ{}
    case None{} None{}:
      EQ{}

def Dewey.seg_cmp.if(dx: Bool, dy: Bool, +x: String, +y: String) -> Cmp:
  match dx dy:
    case True{} True{}:
      Dewey.num_cmp(Nat.read(x), Nat.read(y))
    case True{} False{}:
      LT{}
    case False{} True{}:
      GT{}
    case False{} False{}:
      String.order(x, y)

# A digit segment ranks before a non-digit one; two digit segments compare as
# numbers. A segment that passed `is_digits` always reads, so `Dewey.num_cmp`'s
# None cases are unreachable.
def Dewey.seg_cmp(+x: String, +y: String) -> Cmp:
  Dewey.seg_cmp.if(Str.is_digits(x), Str.is_digits(y), x, y)

def Dewey.segs_cmp(xs: List<&2, String>, ys: List<&2, String>) -> Cmp:
  match xs ys:
    case Nil{} Nil{}:
      EQ{}
    case Nil{} Con{_, _}:
      LT{}
    case Con{_, _} Nil{}:
      GT{}
    case Con{+x, s} Con{+y, t}:
      Cmp.then(Dewey.seg_cmp(x, y), Dewey.segs_cmp(s, t))

def Dewey.cmp(+x: String, +y: String) -> Cmp:
  Dewey.segs_cmp(Dewey.split(x), Dewey.split(y))

def Dewey.origin.go(s: String, +acc: String) -> String:
  match s:
    case SNil{}:
      acc
    case SCon{+h, t}:
      Bool.pick(String, Char.is_eq(h, ':'), acc, Dewey.origin.go(t, SCon{h, acc}))

# Everything before the first ':'. The routing key, and the reason one document
# can answer any single operation.
def Dewey.origin(s: String) -> String:
  String.reverse(Dewey.origin.go(s, SNil{}))
