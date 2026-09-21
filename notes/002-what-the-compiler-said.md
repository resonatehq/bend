# 002 — what the compiler said

`notes/001` was written without a Bend toolchain. The compiler is reachable
after all — `git clone https://github.com/bendlang/bend` works through the
session's git proxy where `curl` does not, and `bun bend2/main.ts` is the CLI.
This is what it changed.

## Three rules nobody wrote down where I was looking

**Definitions must precede use.** Not just mutual recursion — *any* forward
reference is rejected: "expected: a defined name". Every file reads bottom up,
leaves first. Base does the same, which is why it is full of `String.cmp.rec`,
`String.cmp.fin`, `Nat.read.if`: the branch helper is defined before the
function that computes the branch. `kernel.bend` had to be topologically
sorted, and now is.

**A recursive function's branch helper takes the recursive result as a
parameter.** The combination of "a `match` may not inspect a computed value"
and "mutual recursion is not allowed" has exactly one way through, and Base
shows it: the helper is defined first and receives the already-computed
recursive call.

```python
def Objects.put.if(b: Bool, x: Object, rest: List<&2, Object>, o: Object,
  done: List<&2, Object>) -> List<&2, Object>:
  ...
def Objects.put(os: List<&2, Object>, +o: Object) -> List<&2, Object>:
  match os:
    case Con{+x, +rest}:
      Objects.put.if(String.eq(Object.id(x), Object.id(o)), x, rest, o,
        Objects.put(rest, o))
```

The recursion is direct, in an argument. The cost is that `done` is always
built, so there is no early exit: `Objects.put` walks the whole list even after
it has found its id.

**The shrinking argument must come first.** "Arguments are read left to right:
each passed unchanged until one shrinks." So a fold cannot carry its
accumulator in front of the list it is consuming. `fan_out`, `notify` and
`sweep.chains` all had the accumulator first and all had to be flipped:

```python
fan_out(wake(out, a, id, now, cfg), rest, id, now, cfg)   # rejected
fan_out(rest, wake(out, a, id, now, cfg), id, now, cfg)   # accepted
```

A destructuring `let` is also a match, so `(c, a) = Bool.pick(..)` is rejected
for the same reason a `match` on a computed value is. Two `Bool.pick`s, one per
component, is the way.

## Corrections to notes/001

- **Module access is `M.x`, not `M/x`.** `P/Str.is_eq` parses as division and
  the error is about a missing type annotation for `/`, which is a long way
  from the cause.
- **`Char` is in the `is_eq` family** — assumption 1 in `notes/001` is
  resolved. `Char.is_lt` and `Char.is_ge` are *not*; `Char.is_digit`,
  `is_alpha`, `is_upper`, `is_lower` and `Char.cmp` are. `Char.cmp` returns
  `(Char & Char) & Cmp`, handing the arguments back, which is what affinity
  looks like in a signature.
- **Base is much larger than the guide's prose suggests.** `String.eq`,
  `String.order`, `String.split`, `Cmp` with `LT/EQ/GT`, `Bool.pick`,
  `Maybe.or`, `List.append`, `Nat.cmp`. Most of `prelude.bend` was deleted;
  what is left is `Cmp.then`, digit checking, sorted insert, and Dewey ids.
- **`Emit` is taken.** Base declares it; our effect is now `Deliver`.
- **24 `+` annotations** were needed that I had not written. The affine checker
  is precise and the message names the variable and the line.

## The blocker that was not one

`notes/001` and the first `PROOF.bend` said the list inductions were blocked on
"case analysis of a computed `Bool` inside a proof", because the
match-a-parameter rule holds in proofs too.

It is not a blocker. You do not split on the computed value — you quantify the
lemma over every value and instantiate it at the computed one:

```python
law committed_is_some.step:
  for same: Bool
  for new: Maybe<&2, Nat>
  ...
  {K.committed(K.linearize.on(same, old, new, out)) == Some{..} : ..}

def L.committed_is_some(old, out):
  L.committed_is_some.step(K.Mb.nat_is_eq(old, K.min_deadline(K.Out.doc(out))),
    old, K.min_deadline(K.Out.doc(out)), out)
```

The helper matches `same` because `same` is *its* parameter. That is the whole
trick, and it is why `committed_is_some` is discharged.

## The blocker that is one

`put_preserves_other` is not. Its `True` case knows
`String.eq(Object.id(x), Object.id(o))` is `True` and
`String.eq(Object.id(o), id)` is `False`, and needs
`String.eq(Object.id(x), id) == False` — transitivity of `String.eq`, a
*reflection* lemma tying the decidable equality to propositional equality.

Base does not have it. `bend base` lists exactly three equality lemmas —
`Equal.cong`, `Equal.sym`, `Equal.trans` — plus `Nat.ge_refl`, `Nat.max_ge_l`,
`Nat.max_ge_r`, `U32.add_comm` and `Word.add_comm`. So `String.eq` reflection
is ours to prove, by induction on `String` down through `Char.is_eq` to
`U32.is_eq`, and it is the next real piece of work. Every remaining lemma that
looks up an id needs it.

## How a proof fills a law

`def L.<name>`, with the importing alias — the guide says "`law sorted` is
proven by `def Laws.sorted`" and means the module prefix literally. A bare
`def <name>` in `PROOF.bend` fails with "no law named <name> is in scope".
Constructors from an imported module need the prefix too: `case K.Doc{..}`.
