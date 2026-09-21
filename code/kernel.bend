# kernel.bend — the protocol's state machine, as a pure function.
#
#   sweep(doc, now, cfg)                -> Out              every deadline at or before `now`
#   handle_internal(doc, now, cfg)      -> List<Effect>     the sweep, linearized
#   handle_external(doc, req, now, cfg) -> Step             the sweep, then one request
#
# Neither reads a clock, generates an id, or does I/O. Everything a decision
# implies comes back as an Effect for the shell to perform, in order: arm the
# new timer, commit the document, clear the old timer, send.
#
# Transcribed from resonatehq/durable-execution, code/final/kernel.py.
#
# THIS CUT is the promise half: promise.get, promise.create, promise.settle,
# the settlement chain, and the sweep's expiry phases. A targeted promise is
# still born with a task, because that is when the task exists, but the twelve
# task operations and the sweep's retry and lease phases are not here.

import Base
import ./prelude.bend as P

# --------------------------------------------------------------------------
# Types
# --------------------------------------------------------------------------

type PState is Data:
  Pending{}
  Resolved{}
  Rejected{}
  RejectedCanceled{}
  RejectedTimedout{}

# What a caller is allowed to settle a promise to. `rejected_timedout` is
# server-owned and absent by construction, so the kernel's 400 for an invalid
# settle state is gone: the wire decoder either produces one of these three or
# it rejects the request. The check moves to the codec, where it belongs.
type SettleState is Data:
  SResolved{}
  SRejected{}
  SRejectedCanceled{}

type TState is Data:
  TPending{}
  TAcquired{}
  TSuspended{}
  THalted{}
  TFulfilled{}

type Entry is Data:
  E{key: String, val: String}

type Value is Data:
  V{headers: List<&2, Entry>, data: Maybe<&2, String>}

type Promise is Data:
  Pr{
    state: PState,
    param: Value,
    value: Value,
    tags: List<&2, Entry>,
    timeout_at: Nat,
    created_at: Nat,
    settled_at: Maybe<&2, Nat>,
    callbacks: List<&2, String>,
    listeners: List<&2, String>,
  }

type Task is Data:
  Tk{
    state: TState,
    version: Nat,
    pid: Maybe<&2, String>,
    ttl: Maybe<&2, Nat>,
    resumes: List<&2, String>,
    retry_at: Maybe<&2, Nat>,
    lease_at: Maybe<&2, Nat>,
  }

type Object is Data:
  Ob{id: String, promise: Promise, task: Maybe<&2, Task>}

type Document is Data:
  Doc{
    objects: List<&2, Object>,
    clock: Nat,
    gen: Nat,
    timer_at: Maybe<&2, Nat>,
    timer_name: Maybe<&2, String>,
  }

type KernelCfg is Data:
  Cfg{retry_timeout: Nat, preload_limit: Nat}

type PromiseRecord is Data:
  PRec{
    id: String,
    state: PState,
    param: Value,
    value: Value,
    tags: List<&2, Entry>,
    timeout_at: Nat,
    created_at: Nat,
    settled_at: Maybe<&2, Nat>,
  }

# The Python kernel replies with `dict[str, Any]`. Here the payload is typed,
# which is not a translation artefact: it means the kernel can no longer put a
# shape on the wire that the codec has not been told about.
type Reply is Data:
  RPromise{promise: PromiseRecord}
  RUnit{}
  RErr{status: Nat, message: String}

type Msg is Data:
  MExecute{task_id: String, version: Nat}
  MUnblock{record: PromiseRecord}

type Send is Data:
  Sd{address: String, msg: Msg}

type Effect is Data:
  SetDocument{doc: Document}
  SetTimeout{at: Nat}
  DelTimeout{at: Nat}
  Deliver{send: Send}

# A decision in progress: the document being built and the messages it owes.
type Out is Data:
  Out{doc: Document, sends: List<&2, Send>}

type Step is Data:
  Step{fx: List<&2, Effect>, reply: Reply}

# What an operation returns: the decision it made, and the answer to the
# caller. `handle_external` is the only thing that turns one into effects.
type Res is Data:
  Res{out: Out, reply: Reply}

type Req is Data:
  PromiseGet{id: String}
  PromiseCreate{id: String, timeout_at: Nat, param: Value, tags: List<&2, Entry>}
  PromiseSettle{id: String, state: SettleState, value: Value}

# What a create wrote and nothing after it may touch, as a value, so that
# "the birth fields are preserved" is one equation rather than four.
type BirthFields is Data:
  Birth{param: Value, tags: List<&2, Entry>, timeout_at: Nat, created_at: Nat}

# --------------------------------------------------------------------------
# Definitions
# --------------------------------------------------------------------------

def SettleState.to_state(s: SettleState) -> PState:
  match s:
    case SResolved{}:
      Resolved{}
    case SRejected{}:
      Rejected{}
    case SRejectedCanceled{}:
      RejectedCanceled{}

def PState.is_pending(s: PState) -> Bool:
  match s:
    case Pending{}:
      True{}
    case Resolved{}:
      False{}
    case Rejected{}:
      False{}
    case RejectedCanceled{}:
      False{}
    case RejectedTimedout{}:
      False{}

def Value.empty() -> Value:
  V{Nil{}, None{}}

def Document.empty() -> Document:
  Doc{Nil{}, 0n, 0n, None{}, None{}}

def KernelCfg.default() -> KernelCfg:
  Cfg{30000n, 10n}

def KernelCfg.retry_timeout(c: KernelCfg) -> Nat:
  match c:
    case Cfg{+r, _}:
      r

def TAG_TARGET() -> String:
  "resonate:target"

def TAG_TIMER() -> String:
  "resonate:timer"

def TAG_DELAY() -> String:
  "resonate:delay"

def TAG_BRANCH() -> String:
  "resonate:branch"

def TAG_SCOPE() -> String:
  "resonate:scope"

def TAG_EXTERNAL() -> String:
  "resonate:external"

def Tags.hit(b: Bool, +v: String) -> Maybe<&2, String>:
  match b:
    case True{}:
      Some{v}
    case False{}:
      None{}

# Tags are an assoc list kept sorted by key. The recursion stays direct and the
# branch goes into `Mb.first`, so the whole list is walked either way; a tag
# map is a handful of entries.
def Tags.get(ts: List<&2, Entry>, +k: String) -> Maybe<&2, String>:
  match ts:
    case Nil{}:
      None{}
    case Con{E{+key, +val}, rest}:
      Maybe.or(&2, String, Tags.hit(String.eq(key, k), val), Tags.get(rest, k))

def Tags.is.on(got: Maybe<&2, String>, +v: String) -> Bool:
  match got:
    case None{}:
      False{}
    case Some{+g}:
      String.eq(g, v)

def Tags.is(ts: List<&2, Entry>, +k: String, +v: String) -> Bool:
  Tags.is.on(Tags.get(ts, k), v)

def Promise.state(p: Promise) -> PState:
  match p:
    case Pr{+st, _, _, _, _, _, _, _, _}:
      st

def Promise.tags(p: Promise) -> List<&2, Entry>:
  match p:
    case Pr{_, _, _, +tg, _, _, _, _, _}:
      tg

def Promise.timeout_at(p: Promise) -> Nat:
  match p:
    case Pr{_, _, _, _, +to, _, _, _, _}:
      to

def Promise.created_at(p: Promise) -> Nat:
  match p:
    case Pr{_, _, _, _, _, +ca, _, _, _}:
      ca

def Promise.callbacks(p: Promise) -> List<&2, String>:
  match p:
    case Pr{_, _, _, _, _, _, _, +cb, _}:
      cb

def Promise.target(p: Promise) -> Maybe<&2, String>:
  Tags.get(Promise.tags(p), TAG_TARGET())

def Promise.is_timer(p: Promise) -> Bool:
  Tags.is(Promise.tags(p), TAG_TIMER(), "true")

# An expiring promise tagged as a timer resolves instead of rejecting.
def Promise.timeout_state(p: Promise) -> PState:
  Bool.pick(PState, Promise.is_timer(p), Resolved{}, RejectedTimedout{})

# Only a pending promise with a target has a deadline the sweep fires; an
# undispatched promise expires lazily, when someone reads it.
def Promise.timeout_armed(+p: Promise) -> Bool:
  Bool.and(PState.is_pending(Promise.state(p)),
    Maybe.is_some(&2, String, Promise.target(p)))

def Promise.is_expired(+p: Promise, +now: Nat) -> Bool:
  Bool.and(PState.is_pending(Promise.state(p)),
    Nat.is_ge(now, Promise.timeout_at(p)))

# Not the negation of `is_expired`: a settled promise is neither expired nor
# live. The sweep asks the first question, the settlement chain asks this one,
# and conflating them silently stops every resume.
def Promise.is_live(+p: Promise, +now: Nat) -> Bool:
  Bool.and(PState.is_pending(Promise.state(p)),
    Nat.is_lt(now, Promise.timeout_at(p)))

# No record-update syntax in the language, so every change rebuilds the whole
# constructor. These are the only three shapes this cut needs.
def Promise.settle_to(p: Promise, st: PState, v: Value, at: Nat) -> Promise:
  match p:
    case Pr{_, param, _, tg, to, ca, _, cb, ls}:
      Pr{st, param, v, tg, to, ca, Some{at}, cb, ls}

def Promise.clear_callbacks(p: Promise) -> Promise:
  match p:
    case Pr{st, param, v, tg, to, ca, sa, _, ls}:
      Pr{st, param, v, tg, to, ca, sa, Nil{}, ls}

def Promise.clear_listeners(p: Promise) -> Promise:
  match p:
    case Pr{st, param, v, tg, to, ca, sa, cb, _}:
      Pr{st, param, v, tg, to, ca, sa, cb, Nil{}}

def Promise.listeners(p: Promise) -> List<&2, String>:
  match p:
    case Pr{_, _, _, _, _, _, _, _, +ls}:
      ls

def Task.state(t: Task) -> TState:
  match t:
    case Tk{+st, _, _, _, _, _, _}:
      st

def Task.version(t: Task) -> Nat:
  match t:
    case Tk{_, +v, _, _, _, _, _}:
      v

# settlement_enqueued: pid, ttl, resumes and both deadlines go at once.
def Task.fulfil(t: Task) -> Task:
  Tk{TFulfilled{}, Task.version(t), None{}, None{}, Nil{}, None{}, None{}}

def Task.arm_retry(t: Task, at: Nat) -> Task:
  match t:
    case Tk{st, v, pid, ttl, rs, _, _}:
      Tk{st, v, pid, ttl, rs, Some{at}, None{}}

def Task.resume_now(t: Task, +id: String, at: Nat) -> Task:
  Tk{TPending{}, Task.version(t), None{}, None{}, Con{id, Nil{}}, Some{at}, None{}}

def Task.add_resume(t: Task, +id: String) -> Task:
  match t:
    case Tk{st, v, pid, ttl, rs, ra, la}:
      Tk{st, v, pid, ttl, P.Str.set.insert(rs, id), ra, la}

def Task.retry_at(t: Task) -> Maybe<&2, Nat>:
  match t:
    case Tk{_, _, _, _, _, +ra, _}:
      ra

def Task.lease_at(t: Task) -> Maybe<&2, Nat>:
  match t:
    case Tk{_, _, _, _, _, _, +la}:
      la

def Promise.to_record(+id: String, p: Promise) -> PromiseRecord:
  match p:
    case Pr{st, param, v, tg, to, ca, sa, _, _}:
      PRec{id, st, param, v, tg, to, ca, sa}

def Step.fx(s: Step) -> List<&2, Effect>:
  match s:
    case Step{+f, _}:
      f

def Step.reply(s: Step) -> Reply:
  match s:
    case Step{_, +y}:
      y

def Document.objects(d: Document) -> List<&2, Object>:
  match d:
    case Doc{+os, _, _, _, _}:
      os

def Document.timer_at(d: Document) -> Maybe<&2, Nat>:
  match d:
    case Doc{_, _, _, +ta, _}:
      ta

def Document.with_objects(d: Document, os: List<&2, Object>) -> Document:
  match d:
    case Doc{_, clk, g, ta, tn}:
      Doc{os, clk, g, ta, tn}

def Document.with_timer_at(d: Document, ta: Maybe<&2, Nat>) -> Document:
  match d:
    case Doc{os, clk, g, _, tn}:
      Doc{os, clk, g, ta, tn}

def Objects.hit(b: Bool, o: Object) -> Maybe<&2, Object>:
  match b:
    case True{}:
      Some{o}
    case False{}:
      None{}

def Object.id(o: Object) -> String:
  match o:
    case Ob{+id, _, _}:
      id

def Objects.get(os: List<&2, Object>, +id: String) -> Maybe<&2, Object>:
  match os:
    case Nil{}:
      None{}
    case Con{+o, rest}:
      Maybe.or(&2, Object, Objects.hit(String.eq(Object.id(o), id), o),
        Objects.get(rest, id))

def Object.promise(o: Object) -> Promise:
  match o:
    case Ob{_, +p, _}:
      p

def Object.task(o: Object) -> Maybe<&2, Task>:
  match o:
    case Ob{_, _, +t}:
      t

def Object.with_promise(o: Object, p: Promise) -> Object:
  match o:
    case Ob{id, _, t}:
      Ob{id, p, t}

def Object.with_task(o: Object, t: Maybe<&2, Task>) -> Object:
  match o:
    case Ob{id, p, _}:
      Ob{id, p, t}

def Document.get(d: Document, +id: String) -> Maybe<&2, Object>:
  Objects.get(Document.objects(d), id)

def Objects.put.if(b: Bool, x: Object, rest: List<&2, Object>, o: Object,
  done: List<&2, Object>) -> List<&2, Object>:
  match b:
    case True{}:
      Con{o, rest}
    case False{}:
      Con{x, done}

# Replace the object with this id, in place. Nothing happens if it is absent:
# every caller here has just looked it up.
def Objects.put(os: List<&2, Object>, +o: Object) -> List<&2, Object>:
  match os:
    case Nil{}:
      Nil{}
    case Con{+x, +rest}:
      Objects.put.if(String.eq(Object.id(x), Object.id(o)), x, rest, o,
        Objects.put(rest, o))

def Document.put(+d: Document, o: Object) -> Document:
  Document.with_objects(d, Objects.put(Document.objects(d), o))

def Objects.insert.if(c: Cmp, x: Object, rest: List<&2, Object>, o: Object,
  done: List<&2, Object>) -> List<&2, Object>:
  match c:
    case LT{}:
      Con{x, done}
    case EQ{}:
      Con{x, rest}
    case GT{}:
      Con{o, Con{x, rest}}

# Ordered insert, by Dewey id.
def Objects.insert(os: List<&2, Object>, +o: Object) -> List<&2, Object>:
  match os:
    case Nil{}:
      Con{o, Nil{}}
    case Con{+x, +rest}:
      Objects.insert.if(P.Dewey.cmp(Object.id(x), Object.id(o)), x, rest, o,
        Objects.insert(rest, o))

def Document.insert(+d: Document, o: Object) -> Document:
  Document.with_objects(d, Objects.insert(Document.objects(d), o))

def Mb.min(x: Maybe<&2, Nat>, y: Maybe<&2, Nat>) -> Maybe<&2, Nat>:
  match x y:
    case None{} None{}:
      None{}
    case None{} Some{b}:
      Some{b}
    case Some{a} None{}:
      Some{a}
    case Some{+a} Some{+b}:
      Some{Bool.pick(Nat, Nat.is_le(a, b), a, b)}

def Mb.nat_is_eq(x: Maybe<&2, Nat>, y: Maybe<&2, Nat>) -> Bool:
  match x y:
    case None{} None{}:
      True{}
    case None{} Some{_}:
      False{}
    case Some{_} None{}:
      False{}
    case Some{a} Some{b}:
      Nat.is_eq(a, b)

def Object.promise_deadline.on(armed: Bool, at: Nat) -> Maybe<&2, Nat>:
  match armed:
    case True{}:
      Some{at}
    case False{}:
      None{}

def Object.promise_deadline(+o: Object) -> Maybe<&2, Nat>:
  Object.promise_deadline.on(Promise.timeout_armed(Object.promise(o)),
    Promise.timeout_at(Object.promise(o)))

def Object.task_deadline(t: Maybe<&2, Task>) -> Maybe<&2, Nat>:
  match t:
    case None{}:
      None{}
    case Some{+tk}:
      Mb.min(Task.retry_at(tk), Task.lease_at(tk))

def Object.deadline(+o: Object) -> Maybe<&2, Nat>:
  Mb.min(Object.promise_deadline(o), Object.task_deadline(Object.task(o)))

def min_deadline.go(os: List<&2, Object>) -> Maybe<&2, Nat>:
  match os:
    case Nil{}:
      None{}
    case Con{o, rest}:
      Mb.min(Object.deadline(o), min_deadline.go(rest))

# Promise deadlines, task retries and task leases. The shell keeps one timer
# per origin, and this is it.
def min_deadline(d: Document) -> Maybe<&2, Nat>:
  min_deadline.go(Document.objects(d))

def Out.doc(o: Out) -> Document:
  match o:
    case Out{+d, _}:
      d

def Out.sends(o: Out) -> List<&2, Send>:
  match o:
    case Out{_, +s}:
      s

def send_execute.to(a: Maybe<&2, String>, +out: Out, +id: String, version: Nat) -> Out:
  match a:
    case None{}:
      out
    case Some{addr}:
      Out{Out.doc(out), List.append(&2, Send, Out.sends(out),
        Con{Sd{addr, MExecute{id, version}}, Nil{}})}

def send_execute.on(o: Maybe<&2, Object>, out: Out, +id: String, version: Nat) -> Out:
  match o:
    case None{}:
      out
    case Some{ob}:
      send_execute.to(Promise.target(Object.promise(ob)), out, id, version)

# A promise with no target has nowhere to send.
def send_execute(+out: Out, +id: String, version: Nat) -> Out:
  send_execute.on(Document.get(Out.doc(out), id), out, id, version)

def Task.fulfil_maybe(t: Maybe<&2, Task>) -> Maybe<&2, Task>:
  match t:
    case None{}:
      None{}
    case Some{tk}:
      Some{Task.fulfil(tk)}

def buffer(+out: Out, ob: Object, tk: Task, +id: String) -> Out:
  Out{Document.put(Out.doc(out), Object.with_task(ob, Some{Task.add_resume(tk, id)})),
    Out.sends(out)}

def wake.state(st: TState, +out: Out, +ob: Object, +tk: Task, +awaiter: String, +id: String,
  +now: Nat, +cfg: KernelCfg) -> Out:
  match st:
    case TSuspended{}:
      send_execute(
        Out{
          Document.put(Out.doc(out),
            Object.with_task(ob, Some{Task.resume_now(tk, id,
              Nat.add(now, KernelCfg.retry_timeout(cfg)))})),
          Out.sends(out)},
        awaiter, Task.version(tk))
    case TPending{}:
      buffer(out, ob, tk, id)
    case TAcquired{}:
      buffer(out, ob, tk, id)
    case THalted{}:
      buffer(out, ob, tk, id)
    case TFulfilled{}:
      out

def wake.live(live: Bool, out: Out, +ob: Object, +tk: Task, +awaiter: String, +id: String,
  +now: Nat, +cfg: KernelCfg) -> Out:
  match live:
    case False{}:
      out
    case True{}:
      wake.state(Task.state(tk), out, ob, tk, awaiter, id, now, cfg)

def wake.task(mt: Maybe<&2, Task>, out: Out, +ob: Object, +awaiter: String, +id: String,
  +now: Nat, +cfg: KernelCfg) -> Out:
  match mt:
    case None{}:
      out
    case Some{+tk}:
      # The awaiter is itself settled or past its deadline: a sweep will fulfil
      # it rather than resume it.
      wake.live(Promise.is_live(Object.promise(ob), now), out, ob, tk, awaiter, id, now, cfg)

def wake.on(mo: Maybe<&2, Object>, out: Out, +awaiter: String, +id: String, +now: Nat,
  +cfg: KernelCfg) -> Out:
  match mo:
    case None{}:
      out
    case Some{+ob}:
      wake.task(Object.task(ob), out, ob, awaiter, id, now, cfg)

def wake(+out: Out, +awaiter: String, +id: String, +now: Nat, +cfg: KernelCfg) -> Out:
  wake.on(Document.get(Out.doc(out), awaiter), out, awaiter, id, now, cfg)

# resumption_enqueued: every awaiter registered against `id` observes the
# settlement, in registration order, whatever state its task is in. A halted
# awaiter buffers the resume and sees it when it continues.
def fan_out(awaiters: List<&2, String>, out: Out, +id: String, +now: Nat,
  +cfg: KernelCfg) -> Out:
  match awaiters:
    case Nil{}:
      out
    case Con{+a, rest}:
      fan_out(rest, wake(out, a, id, now, cfg), id, now, cfg)

# listener_unblocked: hand the settled promise to everyone listening.
def notify(addresses: List<&2, String>, +out: Out, +rec: PromiseRecord) -> Out:
  match addresses:
    case Nil{}:
      out
    case Con{a, rest}:
      notify(rest, Out{Out.doc(out),
        List.append(&2, Send, Out.sends(out), Con{Sd{a, MUnblock{rec}}, Nil{}})},
        rec)

def trigger_settlement.go(+out: Out, +ob: Object, +id: String, +now: Nat,
  +cfg: KernelCfg) -> Out:
  # Its own task is done, its callbacks and listeners are taken, in one write.
  +drained = Object.with_task(
    Object.with_promise(ob,
      Promise.clear_listeners(Promise.clear_callbacks(Object.promise(ob)))),
    Task.fulfil_maybe(Object.task(ob)))
  fanned = fan_out(Promise.callbacks(Object.promise(ob)),
    Out{Document.put(Out.doc(out), drained), Out.sends(out)}, id, now, cfg)
  notify(Promise.listeners(Object.promise(ob)), fanned,
    Promise.to_record(id, Object.promise(drained)))

def trigger_settlement.on(mo: Maybe<&2, Object>, out: Out, +id: String, +now: Nat,
  +cfg: KernelCfg) -> Out:
  match mo:
    case None{}:
      out
    case Some{+ob}:
      trigger_settlement.go(out, ob, id, now, cfg)

# The settlement chain, in one pass and in this order: fulfil the promise's own
# task, wake its awaiters, notify its listeners. It does not recurse: waking an
# awaiter re-dispatches it, it does not settle it.
def trigger_settlement(+out: Out, +id: String, +now: Nat, +cfg: KernelCfg) -> Out:
  trigger_settlement.on(Document.get(Out.doc(out), id), out, id, now, cfg)

def settle.on(mo: Maybe<&2, Object>, +out: Out, +id: String, st: PState, v: Value,
  +now: Nat, +cfg: KernelCfg) -> Out:
  match mo:
    case None{}:
      out
    case Some{+ob}:
      trigger_settlement(
        Out{
          Document.put(Out.doc(out),
            Object.with_promise(ob, Promise.settle_to(Object.promise(ob), st, v, now))),
          Out.sends(out)},
        id, now, cfg)

# Settle a pending promise and run its chain.
def settle(+out: Out, +id: String, st: PState, v: Value, +now: Nat, +cfg: KernelCfg) -> Out:
  settle.on(Document.get(Out.doc(out), id), out, id, st, v, now, cfg)

def sweep.expired_id(b: Bool, +id: String) -> List<&2, String>:
  match b:
    case True{}:
      Con{id, Nil{}}
    case False{}:
      Nil{}

def sweep.expired_ids(os: List<&2, Object>, +now: Nat) -> List<&2, String>:
  match os:
    case Nil{}:
      Nil{}
    case Con{+o, rest}:
      List.append(&2, String,
        sweep.expired_id(Promise.is_expired(Object.promise(o), now), Object.id(o)),
        sweep.expired_ids(rest, now))

def sweep.expire.one(b: Bool, +o: Object) -> Object:
  match b:
    case False{}:
      o
    case True{}:
      Object.with_promise(o,
        Promise.settle_to(Object.promise(o),
          Promise.timeout_state(Object.promise(o)),
          Value.empty(),
          Promise.timeout_at(Object.promise(o))))

def sweep.expire(os: List<&2, Object>, +now: Nat) -> List<&2, Object>:
  match os:
    case Nil{}:
      Nil{}
    case Con{+o, rest}:
      Con{sweep.expire.one(Promise.is_expired(Object.promise(o), now), o),
        sweep.expire(rest, now)}

def sweep.chains(ids: List<&2, String>, out: Out, +now: Nat, +cfg: KernelCfg) -> Out:
  match ids:
    case Nil{}:
      out
    case Con{+id, rest}:
      sweep.chains(rest, trigger_settlement(out, id, now, cfg), now, cfg)

# Phase 1 settles every expired promise, all of them, so an awaiter that is
# itself expiring is already settled when its awaited promise fans out and is
# skipped rather than resumed. `settled_at` is the deadline, not `now`.
# Phase 2 runs the chains, in id order.
#
# Phases 3 and 4 — re-dispatch past retry_at, reclaim past lease_at — land with
# the task operations.
def sweep(+d: Document, +now: Nat, +cfg: KernelCfg) -> Out:
  sweep.chains(sweep.expired_ids(Document.objects(d), now),
    Out{Document.with_objects(d, sweep.expire(Document.objects(d), now)), Nil{}},
    now, cfg)

def linearize.arm(new: Maybe<&2, Nat>) -> List<&2, Effect>:
  match new:
    case None{}:
      Nil{}
    case Some{at}:
      Con{SetTimeout{at}, Nil{}}

def linearize.dis(old: Maybe<&2, Nat>) -> List<&2, Effect>:
  match old:
    case None{}:
      Nil{}
    case Some{at}:
      Con{DelTimeout{at}, Nil{}}

def linearize.sends(ss: List<&2, Send>) -> List<&2, Effect>:
  match ss:
    case Nil{}:
      Nil{}
    case Con{s, rest}:
      Con{Deliver{s}, linearize.sends(rest)}

def linearize.on(same: Bool, old: Maybe<&2, Nat>, +new: Maybe<&2, Nat>, +out: Out)
  -> List<&2, Effect>:
  match same:
    case True{}:
      Con{SetDocument{Document.with_timer_at(Out.doc(out), new)},
        linearize.sends(Out.sends(out))}
    case False{}:
      List.append(&2, Effect,
        linearize.arm(new),
        Con{SetDocument{Document.with_timer_at(Out.doc(out), new)},
          List.append(&2, Effect, linearize.dis(old), linearize.sends(Out.sends(out)))})

# The order the shell performs: arm the new timer, commit the document, clear
# the old timer, send.
def linearize(+old: Maybe<&2, Nat>, +out: Out) -> List<&2, Effect>:
  linearize.on(Mb.nat_is_eq(old, min_deadline(Out.doc(out))), old,
    min_deadline(Out.doc(out)), out)

def handle_internal(+d: Document, +now: Nat, +cfg: KernelCfg) -> List<&2, Effect>:
  linearize(Document.timer_at(d), sweep(d, now, cfg))

def promise_get.on(mo: Maybe<&2, Object>, out: Out, +id: String) -> Res:
  match mo:
    case None{}:
      Res{out, RErr{404n, "Promise not found"}}
    case Some{ob}:
      Res{out, RPromise{Promise.to_record(id, Object.promise(ob))}}

def promise_get(+out: Out, +id: String) -> Res:
  promise_get.on(Document.get(Out.doc(out), id), out, id)

def Addr.rest(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{+h, +t}:
      Bool.pick(String, Char.is_eq(h, ':'), t, Addr.rest(t))

def Addr.is_scheme_char(+c: Char) -> Bool:
  Bool.or(Char.is_alpha(c),
    Bool.or(Char.is_digit(c),
      Bool.or(Char.is_eq(c, '+'),
        Bool.or(Char.is_eq(c, '.'), Char.is_eq(c, '-')))))

def Addr.scheme_rest(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{+h, t}:
      Bool.and(Addr.is_scheme_char(h), Addr.scheme_rest(t))

# A scheme is one letter, then letters, digits, plus, dot or hyphen. An address
# with no colon has the whole string as its "scheme", which then has to contain
# a character that is not a scheme character, or be rejected by the authority
# check below. A bare word like "poll" passes the first test and fails nothing,
# so it is accepted here exactly as the Python kernel accepts it: the regex
# there also only anchors the scheme.
def Addr.scheme_ok(s: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{+h, t}:
      Bool.and(Char.is_alpha(h), Addr.scheme_rest(t))

def Addr.needs_authority(+s: String) -> Bool:
  Bool.or(String.eq(s, "http"),
    Bool.or(String.eq(s, "https"),
      Bool.or(String.eq(s, "ws"),
        Bool.or(String.eq(s, "wss"), String.eq(s, "ftp")))))

def Addr.has_authority.two(s: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{+h, t}:
      Bool.and(Char.is_eq(h, '/'), Bool.not(String.is_empty(t)))

def Addr.has_authority(s: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{+h, t}:
      Bool.and(Char.is_eq(h, '/'), Addr.has_authority.two(t))

# http, https, ws, wss and ftp need an authority; every other scheme is the
# transport's business.
def Addr.authority_ok(+scheme: String, rest: String) -> Bool:
  Bool.pick(Bool, Addr.needs_authority(scheme), Addr.has_authority(rest), True{})

# Any URI with a scheme. Deliberately shallow: what follows the scheme is the
# transport's business, and validation must be the same on every deployment.
# `Dewey.origin` is reused for the scheme because "everything before the first
# colon" is the same split in both places.
def Addr.is_valid(+a: String) -> Bool:
  Bool.and(Addr.scheme_ok(P.Dewey.origin(a)),
    Addr.authority_ok(P.Dewey.origin(a), Addr.rest(a)))

def pc_bad_target.valid(ok: Bool) -> Maybe<&2, Reply>:
  match ok:
    case True{}:
      None{}
    case False{}:
      Some{RErr{400n, "Invalid resonate:target address"}}

def pc_bad_target.on(a: Maybe<&2, String>) -> Maybe<&2, Reply>:
  match a:
    case None{}:
      None{}
    case Some{addr}:
      pc_bad_target.valid(Addr.is_valid(addr))

def pc_bad_target(ts: List<&2, Entry>) -> Maybe<&2, Reply>:
  pc_bad_target.on(Tags.get(ts, TAG_TARGET()))

def pc_bad_timer.on(bad: Bool) -> Maybe<&2, Reply>:
  match bad:
    case True{}:
      Some{RErr{400n, "A timer promise must not have a resonate:target tag"}}
    case False{}:
      None{}

def pc_bad_timer(+ts: List<&2, Entry>) -> Maybe<&2, Reply>:
  pc_bad_timer.on(Bool.and(Tags.is(ts, TAG_TIMER(), "true"),
    Maybe.is_some(&2, String, Tags.get(ts, TAG_TARGET()))))

def pc_delay_late(late: Bool) -> Maybe<&2, Reply>:
  match late:
    case True{}:
      Some{RErr{400n, "resonate:delay must be less than timeoutAt"}}
    case False{}:
      None{}

def pc_delay_untargeted(targeted: Bool) -> Maybe<&2, Reply>:
  match targeted:
    case True{}:
      None{}
    case False{}:
      Some{RErr{400n, "resonate:delay requires a resonate:target tag"}}

def pc_bad_delay.range(n: Maybe<&2, Nat>, +ts: List<&2, Entry>, +to: Nat) -> Maybe<&2, Reply>:
  match n:
    case None{}:
      Some{RErr{400n, "resonate:delay must be a non-negative integer"}}
    case Some{+v}:
      Maybe.or(&2, Reply,
        pc_delay_late(Nat.is_ge(v, to)),
        pc_delay_untargeted(Maybe.is_some(&2, String, Tags.get(ts, TAG_TARGET()))))

def pc_bad_delay.digits(ok: Bool, +s: String, +ts: List<&2, Entry>, +to: Nat)
  -> Maybe<&2, Reply>:
  match ok:
    case False{}:
      Some{RErr{400n, "resonate:delay must be a non-negative integer"}}
    case True{}:
      pc_bad_delay.range(Nat.read(s), ts, to)

def pc_bad_delay.on(d: Maybe<&2, String>, +ts: List<&2, Entry>, +to: Nat) -> Maybe<&2, Reply>:
  match d:
    case None{}:
      None{}
    case Some{+s}:
      pc_bad_delay.digits(P.Str.is_digits(s), s, ts, to)

def pc_bad_delay(+ts: List<&2, Entry>, +to: Nat) -> Maybe<&2, Reply>:
  pc_bad_delay.on(Tags.get(ts, TAG_DELAY()), ts, to)

def Req.id(r: Req) -> String:
  match r:
    case PromiseGet{+id}:
      id
    case PromiseCreate{+id, _, _, _}:
      id
    case PromiseSettle{+id, _, _}:
      id

def Req.tags(r: Req) -> List<&2, Entry>:
  match r:
    case PromiseCreate{_, _, _, +tg}:
      tg
    case PromiseGet{_}:
      Nil{}
    case PromiseSettle{_, _, _}:
      Nil{}

def Req.timeout_at(r: Req) -> Nat:
  match r:
    case PromiseCreate{_, +to, _, _}:
      to
    case PromiseGet{_}:
      0n
    case PromiseSettle{_, _, _}:
      0n

# Validation is a function of the request alone, so it comes out as a value
# rather than as four early returns. The first complaint wins, which is the
# order the Python kernel returns in.
def pc_reject(+r: Req) -> Maybe<&2, Reply>:
  Maybe.or(&2, Reply, pc_bad_target(Req.tags(r)),
    Maybe.or(&2, Reply, pc_bad_timer(Req.tags(r)),
      pc_bad_delay(Req.tags(r), Req.timeout_at(r))))

def Req.param(r: Req) -> Value:
  match r:
    case PromiseCreate{_, _, +p, _}:
      p
    case PromiseGet{_}:
      Value.empty()
    case PromiseSettle{_, _, _}:
      Value.empty()

def Req.settle_state(r: Req) -> SettleState:
  match r:
    case PromiseSettle{_, +s, _}:
      s
    case PromiseGet{_}:
      SResolved{}
    case PromiseCreate{_, _, _, _}:
      SResolved{}

def Req.value(r: Req) -> Value:
  match r:
    case PromiseSettle{_, _, +v}:
      v
    case PromiseGet{_}:
      Value.empty()
    case PromiseCreate{_, _, _, _}:
      Value.empty()

# The timeout verdict reads off the tags alone, so it can be taken before the
# promise it belongs to exists.
def Tags.timeout_state(ts: List<&2, Entry>) -> PState:
  Bool.pick(PState, Tags.is(ts, TAG_TIMER(), "true"), Resolved{}, RejectedTimedout{})

def insert_promise.on(late: Bool, +out: Out, +id: String, +to: Nat, param: Value,
  +tags: List<&2, Entry>) -> Out:
  match late:
    case True{}:
      Out{Document.insert(Out.doc(out),
        Ob{id, Pr{Tags.timeout_state(tags), param, Value.empty(), tags, to, to,
          Some{to}, Nil{}, Nil{}}, None{}}), Out.sends(out)}
    case False{}:
      Out{Document.insert(Out.doc(out),
        Ob{id, Pr{Pending{}, param, Value.empty(), tags, to, to, None{}, Nil{}, Nil{}},
          None{}}), Out.sends(out)}

# A promise created past its own deadline is born settled, resolved if it is a
# timer and timed out otherwise, with created_at and settled_at both stamped at
# the deadline rather than at `now`.
def insert_promise(out: Out, +id: String, +to: Nat, param: Value, +tags: List<&2, Entry>,
  +now: Nat) -> Out:
  insert_promise.on(Nat.is_ge(now, to), out, id, to, param, tags)

def Task.born_done() -> Task:
  Tk{TFulfilled{}, 0n, None{}, None{}, Nil{}, None{}, None{}}

def Task.born_pending() -> Task:
  Tk{TPending{}, 0n, None{}, None{}, Nil{}, None{}, None{}}

def promise_create.done.on(mo: Maybe<&2, Object>, out: Out, +id: String) -> Res:
  match mo:
    case None{}:
      Res{out, RErr{500n, "Promise not found after create"}}
    case Some{ob}:
      Res{out, RPromise{Promise.to_record(id, Object.promise(ob))}}

def promise_create.done(+out: Out, +id: String) -> Res:
  promise_create.done.on(Document.get(Out.doc(out), id), out, id)

def promise_create.now(+out: Out, +ob: Object, +r: Req, +cfg: KernelCfg) -> Res:
  promise_create.done(
    send_execute(
      Out{Document.put(Out.doc(out),
        Object.with_task(ob,
          Some{Task.arm_retry(Task.born_pending(),
            Nat.add(Promise.created_at(Object.promise(ob)),
              KernelCfg.retry_timeout(cfg)))})),
        Out.sends(out)},
      Req.id(r), 0n),
    Req.id(r))

def promise_create.wait(early: Bool, at: Nat, +out: Out, +ob: Object, +r: Req,
  +cfg: KernelCfg) -> Res:
  match early:
    case True{}:
      promise_create.done(
        Out{Document.put(Out.doc(out),
          Object.with_task(ob, Some{Task.arm_retry(Task.born_pending(), at)})),
          Out.sends(out)},
        Req.id(r))
    case False{}:
      promise_create.now(out, ob, r, cfg)

def promise_create.delayed(md: Maybe<&2, Nat>, +out: Out, +ob: Object, +r: Req,
  +now: Nat, +cfg: KernelCfg) -> Res:
  match md:
    case None{}:
      promise_create.now(out, ob, r, cfg)
    case Some{+at}:
      promise_create.wait(Nat.is_lt(now, at), at, out, ob, r, cfg)

# An absolute instant before which the task must not be dispatched: arm the
# retry timer there and send nothing.
def promise_create.dispatch(d: Maybe<&2, String>, +out: Out, +ob: Object, +r: Req,
  +now: Nat, +cfg: KernelCfg) -> Res:
  match d:
    case None{}:
      promise_create.now(out, ob, r, cfg)
    case Some{+s}:
      promise_create.delayed(Nat.read(s), out, ob, r, now, cfg)

# Born settled, so its task is born done.
def promise_create.live(pending: Bool, +out: Out, +ob: Object, +r: Req, +now: Nat,
  +cfg: KernelCfg) -> Res:
  match pending:
    case False{}:
      promise_create.done(
        Out{Document.put(Out.doc(out), Object.with_task(ob, Some{Task.born_done()})),
          Out.sends(out)},
        Req.id(r))
    case True{}:
      promise_create.dispatch(Tags.get(Req.tags(r), TAG_DELAY()), out, ob, r, now, cfg)

def promise_create.task(mo: Maybe<&2, Object>, +out: Out, +r: Req, +now: Nat,
  +cfg: KernelCfg) -> Res:
  match mo:
    case None{}:
      promise_create.done(out, Req.id(r))
    case Some{+ob}:
      promise_create.live(PState.is_pending(Promise.state(Object.promise(ob))),
        out, ob, r, now, cfg)

def promise_create.targeted(t: Maybe<&2, String>, +out: Out, +r: Req, +now: Nat,
  +cfg: KernelCfg) -> Res:
  match t:
    case None{}:
      promise_create.done(out, Req.id(r))
    case Some{_}:
      promise_create.task(Document.get(Out.doc(out), Req.id(r)), out, r, now, cfg)

# No target means no task and no armed deadline: such a promise only ever
# expires lazily, when someone reads it.
def promise_create.fresh(+out: Out, +r: Req, +now: Nat, +cfg: KernelCfg) -> Res:
  promise_create.targeted(Tags.get(Req.tags(r), TAG_TARGET()), out, r, now, cfg)

# Create is idempotent on id alone: the stored promise wins.
def promise_create.existing(mo: Maybe<&2, Object>, +out: Out, +r: Req, +now: Nat,
  +cfg: KernelCfg) -> Res:
  match mo:
    case Some{ob}:
      Res{out, RPromise{Promise.to_record(Req.id(r), Object.promise(ob))}}
    case None{}:
      promise_create.fresh(
        insert_promise(out, Req.id(r), Req.timeout_at(r), Req.param(r), Req.tags(r), now),
        r, now, cfg)

def promise_create.on(bad: Maybe<&2, Reply>, +out: Out, +r: Req, +now: Nat,
  +cfg: KernelCfg) -> Res:
  match bad:
    case Some{e}:
      Res{out, e}
    case None{}:
      promise_create.existing(Document.get(Out.doc(out), Req.id(r)), out, r, now, cfg)

def promise_create(+out: Out, +r: Req, +now: Nat, +cfg: KernelCfg) -> Res:
  promise_create.on(pc_reject(r), out, r, now, cfg)

def promise_settle.go(rec: PromiseRecord, +out: Out, +r: Req, +now: Nat,
  +cfg: KernelCfg) -> Res:
  Res{settle(out, Req.id(r), SettleState.to_state(Req.settle_state(r)),
    Req.value(r), now, cfg), RPromise{rec}}

def promise_settle.pending(pending: Bool, +out: Out, +ob: Object, +r: Req, +now: Nat,
  +cfg: KernelCfg) -> Res:
  match pending:
    case False{}:
      Res{out, RPromise{Promise.to_record(Req.id(r), Object.promise(ob))}}
    case True{}:
      # The record is captured before the chain runs, so the caller sees the
      # promise it settled rather than what the chain then did to the document.
      promise_settle.go(
        Promise.to_record(Req.id(r),
          Promise.settle_to(Object.promise(ob),
            SettleState.to_state(Req.settle_state(r)), Req.value(r), now)),
        out, r, now, cfg)

def promise_settle.on(mo: Maybe<&2, Object>, +out: Out, +r: Req, +now: Nat,
  +cfg: KernelCfg) -> Res:
  match mo:
    case None{}:
      Res{out, RErr{404n, "Promise not found"}}
    case Some{+ob}:
      # Settlement is terminal: a second settle reports the first one.
      promise_settle.pending(PState.is_pending(Promise.state(Object.promise(ob))),
        out, ob, r, now, cfg)

def promise_settle(+out: Out, +r: Req, +now: Nat, +cfg: KernelCfg) -> Res:
  promise_settle.on(Document.get(Out.doc(out), Req.id(r)), out, r, now, cfg)

def handle_external.dispatch(r: Req, +out: Out, +now: Nat, +cfg: KernelCfg) -> Res:
  match r:
    case PromiseGet{+id}:
      promise_get(out, id)
    case PromiseCreate{id, to, param, tg}:
      promise_create(out, PromiseCreate{id, to, param, tg}, now, cfg)
    case PromiseSettle{id, st, v}:
      promise_settle(out, PromiseSettle{id, st, v}, now, cfg)

def handle_external.finish(old: Maybe<&2, Nat>, res: Res) -> Step:
  match res:
    case Res{out, reply}:
      Step{linearize(old, out), reply}

def handle_external.on(old: Maybe<&2, Nat>, out: Out, +r: Req, +now: Nat,
  +cfg: KernelCfg) -> Step:
  handle_external.finish(old, handle_external.dispatch(r, out, now, cfg))

# Sweep, then decide one request against the swept document. `linearize` runs
# once, over the document that came in and the document that goes out, so an
# intermediate deadline the request then moved is never armed.
#
# NOT YET: the Python kernel drops a sweep dispatch the request overtook. That
# filter reads the task's state and version after the request, so it lands with
# the task operations.
def handle_external(+d: Document, +r: Req, +now: Nat, +cfg: KernelCfg) -> Step:
  handle_external.on(Document.timer_at(d), sweep(d, now, cfg), r, now, cfg)

def committed.one(e: Effect) -> Maybe<&2, Document>:
  match e:
    case SetDocument{d}:
      Some{d}
    case SetTimeout{_}:
      None{}
    case DelTimeout{_}:
      None{}
    case Deliver{_}:
      None{}

# The document a step commits. Every step emits exactly one SetDocument, so
# this is total in practice; the None case is what a law has to rule out rather
# than assume.
def committed(fx: List<&2, Effect>) -> Maybe<&2, Document>:
  match fx:
    case Nil{}:
      None{}
    case Con{e, rest}:
      Maybe.or(&2, Document, committed.one(e), committed(rest))

def PState.is_eq(a: PState, b: PState) -> Bool:
  match a b:
    case Pending{} Pending{}:
      True{}
    case Resolved{} Resolved{}:
      True{}
    case Rejected{} Rejected{}:
      True{}
    case RejectedCanceled{} RejectedCanceled{}:
      True{}
    case RejectedTimedout{} RejectedTimedout{}:
      True{}
    case _ _:
      False{}

def MbStr.is_eq(a: Maybe<&2, String>, b: Maybe<&2, String>) -> Bool:
  match a b:
    case None{} None{}:
      True{}
    case Some{x} Some{y}:
      String.eq(x, y)
    case _ _:
      False{}

def Entry.is_eq(a: Entry, b: Entry) -> Bool:
  match a b:
    case E{k1, v1} E{k2, v2}:
      Bool.and(String.eq(k1, k2), String.eq(v1, v2))

def Entries.is_eq(a: List<&2, Entry>, b: List<&2, Entry>) -> Bool:
  match a b:
    case Nil{} Nil{}:
      True{}
    case Con{x, s} Con{y, t}:
      Bool.and(Entry.is_eq(x, y), Entries.is_eq(s, t))
    case _ _:
      False{}

def Value.is_eq(a: Value, b: Value) -> Bool:
  match a b:
    case V{h1, d1} V{h2, d2}:
      Bool.and(Entries.is_eq(h1, h2), MbStr.is_eq(d1, d2))

def PromiseRecord.is_eq(a: PromiseRecord, b: PromiseRecord) -> Bool:
  match a b:
    case PRec{i1, s1, p1, v1, t1, to1, ca1, sa1} PRec{i2, s2, p2, v2, t2, to2, ca2, sa2}:
      Bool.and(String.eq(i1, i2),
        Bool.and(PState.is_eq(s1, s2),
          Bool.and(Value.is_eq(p1, p2),
            Bool.and(Value.is_eq(v1, v2),
              Bool.and(Entries.is_eq(t1, t2),
                Bool.and(Nat.is_eq(to1, to2),
                  Bool.and(Nat.is_eq(ca1, ca2), Mb.nat_is_eq(sa1, sa2))))))))

# The birth fields alone: what a create wrote and nothing after it may touch.
def PromiseRecord.born_eq(a: PromiseRecord, b: PromiseRecord) -> Bool:
  match a b:
    case PRec{_, _, p1, _, t1, to1, ca1, _} PRec{_, _, p2, _, t2, to2, ca2, _}:
      Bool.and(Value.is_eq(p1, p2),
        Bool.and(Entries.is_eq(t1, t2),
          Bool.and(Nat.is_eq(to1, to2), Nat.is_eq(ca1, ca2))))

def committed_or.on(c: Maybe<&2, Document>, d: Document) -> Document:
  match c:
    case Some{d2}:
      d2
    case None{}:
      d

# `committed` answers a Maybe because nothing in its type says a step emits a
# SetDocument. Every step does — `linearize` emits exactly one on both
# branches — but that is a fact to be proved, not assumed, and a law that has
# to discharge it before saying anything is a law about the wrong thing. So:
# fall back to the document that came in. The obligation does not disappear,
# it becomes `committed_is_some`, which is proved once and on its own.
def committed_or(d: Document, fx: List<&2, Effect>) -> Document:
  committed_or.on(committed(fx), d)

def step_doc(+d: Document, +r: Req, +now: Nat, +cfg: KernelCfg) -> Document:
  committed_or(d, Step.fx(handle_external(d, r, now, cfg)))

def record_at.on(mo: Maybe<&2, Object>, +id: String) -> Maybe<&2, PromiseRecord>:
  match mo:
    case None{}:
      None{}
    case Some{ob}:
      Some{Promise.to_record(id, Object.promise(ob))}

def record_at(d: Document, +id: String) -> Maybe<&2, PromiseRecord>:
  record_at.on(Document.get(d, id), id)

def PromiseRecord.birth(r: PromiseRecord) -> BirthFields:
  match r:
    case PRec{_, _, p, _, t, to, ca, _}:
      Birth{p, t, to, ca}

def birth_at.on(mr: Maybe<&2, PromiseRecord>) -> Maybe<&2, BirthFields>:
  match mr:
    case None{}:
      None{}
    case Some{r}:
      Some{PromiseRecord.birth(r)}

def birth_at(d: Document, +id: String) -> Maybe<&2, BirthFields>:
  birth_at.on(record_at(d, id))
