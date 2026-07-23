# rollback

Game-agnostic GGPO-style rollback netcode core for Godot 4 (web-focused).
Fixed-tick simulation, per-tick state snapshots + content hashing, a
sync-test determinism harness, and a full networked session — input delay,
prediction, rollback/resimulation, checksums, and host resync — on top of a
WebRTC (or WebSocket-fallback) transport.

## Install

This addon lives at `github.com/animo-games/rollback-godot` (private) and is
consumed as a git submodule at `addons/rollback` in your project. All public
types are exposed via `class_name` (`RollbackManager`, `RollbackMotion`,
`RollbackOverlap`, `RollbackSpawnPool`, `TickPureMover`, `RollbackTransport`,
`RollbackNetClock`, `RollbackNetSession`, `RollbackSignalingAdapter`,
`RollbackInputCodec`, ...) — nothing needs to be autoloaded, and everything
works whether or not the plugin is enabled. Enabling "Rollback" under
Project > Plugins is optional; the plugin entry is just metadata (it doesn't
register an autoload or change runtime behavior).

## Quickstart (offline / sync-test)

```gdscript
var rb := RollbackManager.new()
add_child(rb)
rb.add_input_provider(&"p1", _sample_p1_input)  # -> Dictionary, POD values
rb.register(player)           # implements the registered-node contract
rb.register_tick_pure(mover)  # implements _tick_pure_update(tick)
rb.max_rollback_ticks = 8
rb.sync_test_mode = true      # forced rollback + diff every tick (debug)
rb.sync_test_depth = 8
rb.desync_detected.connect(func(report): print(report))
rb.start()
```

`sync_test_mode` forces a rollback + resimulation every tick and diffs the
result against the live pass — it's the tool that proves your game's
registered state is complete and its simulation deterministic *before* any
netcode depends on it. See [Self-test](#self-test) for the standalone
scenario runner.

## The three-category state contract

Everything that exists on a gameplay collision layer (or feeds gameplay
reads) must be exactly one of:

1. **Registered** — real mutable gameplay state (players, crates, switches).
   Implements `_save_state() -> Dictionary` / `_load_state(state)` /
   `_network_tick(tick, inputs)` and is passed to `register()`.
2. **Tick-pure** — state is a pure function of the tick number (moving
   platforms, rotating hazards). Implements `_tick_pure_update(tick)`
   (`TickPureMover` is the ready-made helper) and is passed to
   `register_tick_pure()`. No snapshot; the manager re-applies it on every
   restore and resimulated tick so colliders match the tick being simulated.
3. **Cosmetic** — particles, sprites, audio, tweens. Must never feed back
   into gameplay reads. Suppress side effects during resim by checking
   `manager.is_resimulating`.

## Rules that keep the sim deterministic

- All gameplay mutation happens in `_network_tick` (or helpers it calls) —
  never in `_process`/`_physics_process`, never from wall-clock time, timers,
  or tweens. Use tick counts (`ticks = seconds * 60`).
- `_save_state` returns POD values only. Dictionary key order is irrelevant to
  the snapshot hash (the manager canonicalizes keys before hashing), but Array
  element order IS significant — it's part of the state.
- RNG must be a seeded, tick-keyed service (never bare `randi()`).
- Node paths are snapshot keys and define tick order — keep them stable
  (and identical across peers once networked).
- The consumer project's physics tick rate must be 60
  (`physics/common/physics_ticks_per_second`) — `RollbackManager.TICK_DELTA`
  hardcodes `1.0 / 60.0`, and `start()` fails fast (refuses to start, no state
  mutated) if the engine setting doesn't match.
- `CharacterBody2D.is_on_floor()` / `get_last_motion()` are hidden engine
  state left over from the previous `move_and_slide` — a restore cannot fix
  them. Grounded checks inside `_network_tick` must use explicit synchronous
  queries instead, e.g. `test_move(global_transform, Vector2(0, 0.1))`.
- `RollbackMotion.move()` quantizes the body's final position to a 1/64 px
  grid: the physics server's depenetration at rest is float32-ulp noisy and
  depends on engine-internal broadphase state snapshots can't capture, so
  without snapping, live and resimulated passes settle on different
  ulp-neighbors. Sub-0.01 px per-axis displacements additionally snap back
  to the pre-move coordinate (rest jitter suppression), so a resting pose
  stays a fixed point even when it sits on a grid-cell midpoint.
- Child collision bodies (a `StaticBody2D`/`Area2D` under a registered body)
  only push transforms to the physics server on the engine's per-frame flush,
  which resimulation bypasses — queries from other nodes see them where the
  live frame left them, up to a full rollback window stale. A registered node
  that owns queryable children implements the optional `_pre_network_tick()`
  (called on every registered node at the top of each simulated tick, live
  and resim) and calls `force_update_transform()` on them there, pinning the
  observable transform to start-of-tick in both passes.
- A registered node may also implement the optional `_post_network_tick()`
  (called on registered nodes that have it, in path-sorted order, after every
  node's `_network_tick` within the same simulated tick, live and resim
  alike). Use it for cross-node coupling that must read another node's
  finished position for the tick — e.g. rideable → rider velocity transfer,
  where the rider needs the host's post-tick position, not its start-of-tick
  one.

## Registering a whole level subtree

`RollbackManager.register_tree(root: Node, recursive := true) -> void` walks
`root`'s subtree (including `root` itself) and registers every node that
implements a rollback contract: nodes with the full registered-node contract
go through `register()`, nodes that only implement `_tick_pure_update()` go
through `register_tick_pure()`. It's order-independent — the manager
path-sorts internally — and nodes already registered are skipped, so it
composes cleanly with manual `register()` calls made before or after it.
`register()` and `register_tick_pure()` are themselves idempotent, so
re-registering the same node anywhere (manually or via a second
`register_tree` pass) is a no-op rather than an error.

```gdscript
rb.register(player)          # register the parts you need explicit handles to
rb.register_tree(level_root) # then sweep the rest of the level in one call
```

### RollbackBinder (editor-droppable)

`RollbackBinder` is a `Node` you can drop into a level scene in the editor and
wire without bootstrap code. Set its `root_path` export (empty = the binder's
parent) and `recursive`, then call `bind(manager)` once from your segment-build
code — after the subtree's nodes are in the tree and **before** `manager.start()`.
It calls `register_tree()` on the configured root. It deliberately does **not**
auto-register in `_ready()`: that would race the manager's freeze/register/
unfreeze start() sequencing that determinism depends on, so registration stays an
explicit call you make at the right moment.

## Fixed dynamic-entity pools

`RollbackSpawnPool` supports bounded entities such as projectiles without
changing the manager's registered set during a segment. It instantiates a
fixed number of stable-path slots before `RollbackManager.start()`, advances
only active slots from the owner's `_network_tick`, and folds allocation plus
slot state into the owning registered node's snapshot. Restoring before a
spawn deactivates that slot; resimulating the spawn deterministically reuses
it. Pool exhaustion must be handled deterministically by the game (normally by
rejecting the spawn). This is preferred to registering/freeing nodes inside a
rollback window.

`get_stats()` reports tick count, desyncs, and resim cost (avg/max usec per
forced rollback) — the target budget is rollback depth ≤ ~8 ticks
resimulating comfortably inside a 60Hz frame in WASM.

## Logical collision queries

`RollbackOverlap` provides restore-safe overlap/swept-overlap queries for
gameplay code that needs to ask "what's here" without trusting the engine's
per-frame-cached child transforms, which resimulation and mid-tick restores
can leave stale. When a `RollbackManager` is live it recomposes transforms
manually from local transforms instead of reading engine caches, so queries
are correct even mid-resimulation; when no manager is live (plain
single-player, no netplay) it takes a wall-clock fast path and reads the
engine-cached transform directly, avoiding interpreted-GDScript overhead for
gameplay that never resimulates.

## Transport

`RollbackTransport` turns a signaling adapter into a live `MultiplayerAPI`:
it assembles a `WebRTCMultiplayerPeer` mesh when a concrete WebRTC
GDExtension backend is available, or falls back to a loopback
`WebSocketMultiplayerPeer` star (smaller peer id serves) when one isn't —
e.g. editor/native dev builds without the extension. Either way
`multiplayer.multiplayer_peer` ends up set, so the game drives everything
with plain RPCs on top. `@rpc("unreliable")` rides the mesh's unreliable
channel in WebRTC mode; the WS fallback has no unreliable channel, so
everything is effectively reliable there — fine for dev/testing, not a
perf-representative substitute for the real mesh.

The addon itself has no SDK dependency: it talks to signaling only through
`RollbackSignalingAdapter` (`sig_received`/`peer_joined`/`peer_left` signals,
`connect_room()`/`send()`/`close()`), so plugging in a new signaling backend
means implementing that adapter interface rather than touching the
transport. The concrete adapter lives in your game, not this addon — e.g. a
`CouchWebRTC`-backed subclass that wraps the node the game hands it and treats
already-present peers (`peer_exists`) the same as newly-joined ones
(`peer_joined`). Delivery over signaling is best-effort and blobs make a JSON
round-trip — ints arrive as floats, cast with `int()`.

The game must add the transport at an **identical node path on every peer**
before calling `start()` — its own RPCs (identify handshake, `NetClock`
ping/pong) depend on that path matching across peers.

Peer ids (signaling room / lobby userIds, strings) are mapped to engine
multiplayer ids via a deterministic FNV-1a hash,
`RollbackTransport.derive_net_id(peer_id) -> int`, folded into `[2, 2^30+1]`.
In WebRTC mesh mode this **is** the real engine id (`create_mesh`/`add_peer`
are seeded with it), so all peers agree on it before any handshake completes.
The WS fallback can't force custom ids (`WebSocketMultiplayerPeer` assigns
its own), so there `get_net_id()`/`get_peer_id()` fall back to the learned
id from the identify handshake once a peer is connected. The offer/host role
is decided the same way in both modes: the lexicographically smaller peer id
creates the WebRTC offer, or hosts the WS loopback server.

`RollbackNetClock` (a child of the transport named `NetClock`) measures
per-peer latency/clock offset over the live `MultiplayerAPI`: `track(net_id)`
/ `untrack(net_id)`, `get_rtt_ms(net_id)`, `get_offset_ms(net_id)`
(`remote_clock ≈ local_clock + offset`), `get_synchronized_time_ms(net_id)`,
and a `peer_clock_updated` signal — all values are the median of the last 8
ping/pong samples. This node is wall-clock territory (transport, not
simulation), unlike the tick loop the rest of this addon runs on.

## Networked session (input delay, prediction, checksums, resync)

`RollbackNetSession` is the full GGPO-style networked session. It drives a
`RollbackManager` in `externally_driven` mode — calling
`advance_externally(inputs)` itself instead of letting the manager
sample/advance on its own `_physics_process` — using inputs gathered over a
`RollbackTransport`'s live peer. Wire encoding of input packets is pluggable
via `RollbackInputCodec`: subclass it to pack your game's input dictionary
into a compact wire format instead of relying on the default.

- **Input delay.** Local input intended for tick `T` is sampled and sent
  `input_delay` ticks early, so it's expected to have arrived over the
  network by the time tick `T` needs to be simulated. Both peers must agree
  on `input_delay` (and `checksum_interval`) — this is checked in the hello
  handshake and a mismatch fails the session.
- **Neutral-input prefill.** Ticks `1..input_delay` have no "real" local
  input to send (there's nothing to delay them from), so every peer prefills
  `_input_buf` for those ticks with `{}` for every provider, local and
  remote, identically. This is a convention, not something negotiated over
  the wire — it only works because every peer computes the same prefill
  independently.
- **Samplers take the tick.** Unlike `RollbackManager.add_input_provider`,
  whose sampler is a zero-arg `Callable() -> Dictionary` (samples "now"),
  `RollbackNetSession.add_local_provider`'s sampler is
  `Callable(tick: int) -> Dictionary` — it's always being asked for input
  `input_delay` ticks in the future, so it needs to know which tick that is.
- **Identical node path.** Like `RollbackTransport`/`RollbackNetClock`, this
  node must exist at the same path on every peer before `request_start()` is
  called — its RPCs assume that.
- **Provider → peer mapping.** Each side registers `add_local_provider` for
  the input it supplies and `add_remote_provider(id, peer_id)` for input it
  expects from someone else. The hello handshake exchanges each peer's local
  provider list and cross-checks it against what the receiving side expects
  from that `peer_id` via `add_remote_provider` — a mismatch (wrong
  providers claimed by the wrong peer) fails the session instead of silently
  trusting whoever sends packets. `_rpc_input` also re-checks this per
  packet: a peer can only supply input for providers mapped to it.
- **Checksums.** Every `checksum_interval` ticks, each peer hashes its
  `RollbackManager` snapshot for that tick (`get_tick_hash`) and exchanges it
  with every remote peer. A match just increments a counter; a mismatch
  means the sims have diverged — `desync_detected` fires with `{tick,
  local_hash, remote_hash, peer_id}`, and when `resync_enabled` is on the
  host resync path (below) recovers automatically.
- **Stall and resend.** While waiting on missing input, the session
  resends its current input window every `stall_resend_frames` physics
  frames (covers a dropped unreliable packet) and tracks stall stats
  (`stall_frames`, `max_stall_streak` in `get_stats()`). Once the missing
  input shows up, the sim is behind its wall-clock schedule, so it catches
  up by advancing up to `catchup_ticks_per_frame` ticks per physics frame
  (bounded by the prediction window) instead of the steady-state pace of
  about one tick per frame.
- **Teardown.** A peer disconnecting mid-session fails the session
  (`session_failed`); a deliberate `stop()` suppresses that path, so an
  expected disconnect afterwards (the other side quitting once a match
  ends) doesn't fire a spurious failure.
- **Prediction and rollback.** Instead of stalling on missing remote input,
  the session **predicts** (repeats the newest known input for that
  provider) and keeps the sim advancing up to `max_prediction` ticks ahead of
  the last input-complete tick. When a prediction turns out wrong once the
  real input arrives, it rolls back to the last snapshot before the
  misprediction and resimulates forward with corrected history via
  `RollbackManager.resimulate()`. A frame-advantage exchange piggybacked on
  every input packet drives a small timescale nudge: when this peer is
  running meaningfully ahead of its remote, it bleeds off the lead smoothly
  by occasionally sleeping a single frame — a mild slow-mo capped so the
  leader never freezes — rather than sleeping several frames at once, so the
  two sims don't outrun each other faster than rollback can absorb.
- **`max_prediction` must be `<= manager.max_rollback_ticks`** — it bounds
  how far the sim can run ahead of confirmed input, which bounds how deep a
  rollback can ever need to reach, which is exactly what
  `max_rollback_ticks` caps. `request_start()` fails fast if this doesn't
  hold, and it's checked in the hello handshake (must be equal on every
  peer) same as `input_delay`/`checksum_interval`.
- **Confirmed-tick semantics.** `get_confirmed_tick()` is the highest tick
  with contiguous authoritative (non-predicted) input for every provider
  from tick 1 — it can run *ahead* of the simulated tick when a remote
  packet arrives early. Checksums are only ever exchanged for ticks that are
  both confirmed and already simulated, so a checksum can't be computed
  against a snapshot that's still liable to be rewritten by a rollback.
  `RollbackManager.confirmed_tick` mirrors that session value for registered
  presentation consumers, resets to `0` in `start()`, and can likewise lead
  the manager's simulated `tick`. It is non-snapshot coordination/presentation
  metadata only and must never drive registered gameplay logic.
- **`max_prediction = 0` is strict lockstep**: the sim can never run ahead
  of the confirmed tick, so there's nothing to predict and nothing to roll
  back — it just stalls on missing input. This mode is verified
  deadlock-free and lockstep-equivalent, so it's a legitimate way to run the
  same session code with rollback disabled entirely.
- **Debug net-condition simulation.** `sim_latency_ms`, `sim_jitter_ms`, and
  `sim_drop_percent` perturb *outgoing* session packets for local
  harnesses/dev testing (`sim_drop_percent` only affects the unreliable
  input stream, not checksums). All zero by default (disabled). This sits
  off the determinism boundary — it's transport-timing noise, not sim
  state — so ordinary wall-clock randomness here is fine even though it
  would never be inside `_network_tick`.
- **`RollbackManager.resimulate(base, inputs_by_tick)`** is the primitive
  all of the above sits on: restore the snapshot at tick `base`, then replay
  `base+1..tick` with `inputs_by_tick` overriding recorded input history for
  any tick it covers (other ticks replay what was already recorded),
  recapturing snapshots as it goes. It's the netcode analog of the sync-test
  forced-rollback path described in Quickstart, just driven by real
  mispredictions instead of a debug timer.
- **Throttle recovery.** A backgrounded tab (or a suspended process) can
  starve `_physics_process` for seconds at a time. `RollbackNetSession`
  measures the wall-clock gap between physics frames; a gap
  `>= throttle_gap_ms` (default 500ms) is treated as a throttle event:
  rolling frame-advantage samples are dropped (they're stale — computed
  against a delta that no longer means anything), the nudge accumulator is
  reset, the local input window is resent, and
  `throttle_gap_detected(gap_ms)` fires so the game can log/flag it. Recovery
  itself is the `catchup_ticks_per_frame` export (default 12): while this
  peer's simulated tick is strictly *behind* `get_confirmed_tick()`, replay
  is pure authoritative catch-up with zero prediction risk, so it's safe to
  burst through more ticks per frame than the normal live-simulation pace of
  about one tick per frame allows. A parallel guard on the stall counter
  (`_stall_frames_streak == 30`) also clears stale advantage samples if the
  *remote* peer is the one that froze, even though this peer never stalled
  itself. Worth naming explicitly: `max_prediction` bounds how far a peer can
  run ahead of confirmed input, so once the frozen peer's remote runs out of
  room to predict, a 2-player match effectively **pauses** — both sims sit
  still until the frozen peer's tab resumes. The catch-up burst is what makes
  that pause a short stutter that snaps back to real time, rather than a slow
  one-tick-per-frame crawl back to sync.
- **Host resync.** Checksums only ever *detect* divergence; they don't correct
  it on their own. On a checksum mismatch, one specific peer — the **resync
  host**, defined as whichever peer id sorts lexicographically first (the
  same deterministic rule `RollbackTransport` uses to decide who creates the
  WebRTC offer) — broadcasts its full simulation state, and every other peer
  discards its own history and hard-loads it.
  - `resync_enabled` (default `true`) gates whether the host branch fires;
    `resync_cooldown_ticks` (default 120) rate-limits repeat sends so one
    desync episode's run of mismatched checksums doesn't trigger a resync per
    checksum.
  - The host sends at `min(get_confirmed_tick(), tick)` — the newest tick
    that is both simulated and fully confirmed, so it carries no baked-in
    predictions, and is guaranteed to still have a retained snapshot
    (`tick - confirmed <= max_prediction <= max_rollback_ticks`).
  - `resync_sent(tick)` fires on the host after it sends; `resync_applied(tick)`
    fires on a guest after it successfully hard-loads.
  - The primitives underneath: `RollbackManager.get_snapshot_states(t)`
    returns a deep-duplicated `{path: Dictionary}` of a retained snapshot (or
    `{}` if it's gone), and `RollbackManager.load_authoritative_snapshot(t,
    states)` hard-loads it — `_load_state` on every registered node, then
    `_apply_tick_pure`, discarding **all** local snapshot/input history so the
    manager ends up at tick `t` with exactly one snapshot. The guest verifies
    the load round-tripped by comparing `get_tick_hash(t)` against the hash
    the host sent alongside the states; a mismatch fails the session rather
    than silently continuing on unverified state.
  - Applying a resync sets `_authoritative_floor = t`: an invariant that
    ticks `<= t` are now authoritative-by-definition and must never be rolled
    back into again, even if a late/stale packet from before the resync still
    claims to contradict them. Both the misprediction-flagging check in
    `_rpc_input` and `_apply_pending_rollback`'s rollback target respect the
    floor.
  - Like checksums, resync assumes the registered node set and paths are
    identical on every peer — `states` is keyed by node path, and
    `load_authoritative_snapshot` fails closed (returns `false`, no partial
    load) if any registered node's path is missing from the incoming
    dictionary.
- **`RollbackManager.fire_once(key)`.** A resimulation replays
  `_network_tick` for ticks that already ran once live — fine for gameplay
  state (it's overwritten deterministically), but wrong for a one-shot
  cosmetic side effect (a hit sound, a VFX spawn) that would otherwise fire
  again on every resim of the same tick. `fire_once(key)` returns `true` the
  first time it's called for the *currently simulating* tick with that key,
  and `false` on every subsequent call for that same tick (including from a
  later resimulation) — so gate the side effect on it instead of on
  `is_resimulating` when the effect should fire exactly once even though the
  tick itself gets resimulated. Note the corollary: if a correction means a
  resimulated tick no longer reaches the `fire_once` call site at all, the
  earlier firing cannot be un-fired — acceptable for cosmetics, which is the
  only thing this is for.

  ```gdscript
  func _network_tick(tick: int, inputs: Dictionary) -> void:
      if hit_this_tick():
          if rollback_manager.fire_once("hit_%d" % tick):
              spawn_hit_vfx()  # runs once even across N resimulations of this tick
      # ... gameplay mutation, unaffected by fire_once either way ...
  ```

  Reaching `fire_once` from cosmetic call sites (SFX, particles) requires a
  reference to the manager itself, which those call sites otherwise have no
  way to obtain — `register()` calls the optional
  `_set_rollback_manager(manager)` hook on any registered node that
  implements it, so the node can stash the reference and hand out its own
  gated helper (e.g. a `Player.fire_cosmetic(key)` wrapper that stores the
  manager from `_set_rollback_manager`, then calls `fire_once` keyed on
  `"%s:%s" % [get_path(), key]` so state code just calls
  `player.fire_cosmetic("jump_sfx")` without touching the manager directly,
  and behaves as always-true outside rollback play).

```gdscript
var manager := RollbackManager.new()
add_child(manager)
manager.max_rollback_ticks = 8

var transport := RollbackTransport.new()
transport.name = "Transport"  # identical path on every peer
add_child(transport)

var session := RollbackNetSession.new()
session.name = "Session"  # identical path on every peer
add_child(session)
session.max_prediction = 0  # strict lockstep; leave at 8 for rollback proper
session.setup(manager, transport)  # before transport.start(): hellos can arrive as soon as a peer connects
session.add_local_provider(&"p1", _sample_p1_input)       # Callable(tick) -> Dictionary
session.add_remote_provider(&"p2", remote_peer_id)
session.session_started.connect(func(): print("session running"))
session.desync_detected.connect(func(report): print(report))

await transport.start(adapter)
await transport.transport_ready
session.request_start()
```

## Standing up a session: RollbackSessionController

`RollbackNetSession` is powerful but the *standup ordering* around it is subtle
and determinism-sensitive. `RollbackSessionController` (a `Node`) encapsulates
that ordering so a new game doesn't have to re-derive it: the session node exists
at its path before the world is built (so a peer's hello RPC can't miss it); the
transport is started once, after the first segment's build (build-before-start is
load-bearing for web WebRTC readiness); `setup()` + signal wiring happen before
`transport.start()`; providers are registered only after the peer resolves; then
`request_start()` and await `session_started`.

It owns the persistent `RollbackTransport` and the per-segment
`RollbackNetSession`. The **game still owns** building the world (manager +
actors + registration) and deciding when to transition between segments — you
pass the world build in as a callback and run your own transition loop. Add the
controller at an **identical node path on every peer** (it names its transport
child `Transport` and session children `Session<N>`).

```gdscript
var controller := RollbackSessionController.new()
controller.name = "SessionController"   # identical path on every peer
controller.input_delay = 2
controller.max_prediction = 8
controller.input_codec = MyInputCodec.new()   # optional; stateless
controller.desync_detected.connect(func(r): push_warning("desync %s" % r))
add_child(controller)
controller.begin(adapter)                       # create transport (not started yet)

# Register input providers up front (they persist across segments):
controller.add_local_provider(&"p0", func(t): return sample_input(t))
controller.add_auto_remote_provider(&"p1")      # map the lone remote to the single ready peer

var seg := await controller.run_segment(0,
    func(seg_index, session):                   # BUILD: you create the world
        var rb := RollbackManager.new()
        rb.name = "Rollback"
        add_child(rb)
        # ... spawn actors, rb.register(...) / rb.register_tree(level_root) ...
        return {"manager": rb, "ok": true})
if seg.get("ok", false):
    # ... run until your transition condition, then:
    controller.stop_segment(seg["session"])     # stop() first, then frees the session
```

Input routing is registered up front with `add_local_provider(id, sampler)`
(`sampler` is `Callable(tick) -> Dictionary`), `add_remote_provider(id, peer_id)`,
and `add_auto_remote_provider(id)` — which maps a single remote provider to the
single ready peer (the 2-player convenience). Providers persist across segments,
so register them once before the first `run_segment`. `run_segment(seg_index,
build)` returns your build dict plus `{"session": ..., "ok": true}`, or `{"ok":
false}` on failure (with a `segment_failed` signal). This is session **standup
only** — it does not own the segment loop or transition policy (exits, playlists,
tutorial jumps are too game-specific to lift).

## What belongs in this addon vs your game

The dividing line: does the code need to know what a specific gameplay
entity *is*? If no, it belongs in this addon. If yes, it belongs in your
game.

The addon owns gameplay-agnostic machinery: `RollbackManager`,
`RollbackMotion`, `TickPureMover`, `RollbackOverlap`, `RollbackSpawnPool`,
the transport (`RollbackTransport`, `RollbackNetClock`,
`RollbackSignalingAdapter`), and the session
(`RollbackNetSession`, `RollbackInputCodec`) — plus `register_tree()` for
sweeping a subtree. None of it needs to know whether a node is a player, a
crate, or a moving platform; it only cares which contract the node
implements.

Things that enumerate concrete game types stay in your game — for example: a
level binder with an explicit `is Crate or is FlyBot or ...` allowlist, a
segment/level-transition builder that references your specific `Player`/level
scene classes, or an input codec that knows the shape of your input
dictionary. Subclass `RollbackInputCodec` for your input format, and call
`register()` / `register_tree()` from your own level-load code rather than
pushing game-specific knowledge into the addon.

## Segment transitions & the collider-reap settle

Rollback cannot cross a hard level transition — the registered set and its
history are only valid within one segment. A transition therefore tears down
one segment (manager, level, actors) and builds the next while the transport
(and, in a networked game, the session) persists across the boundary.

If the level being freed and the level being built land static colliders at
the **same world coordinates** (a common case: segments share a footprint or
tile grid), you must let at least one physics frame settle between
`queue_free()`-ing the old level and instantiating the new one, so the freed
level's colliders are reaped from the 2D physics space before the new
colliders are added at the same coordinates. Skipping that settle frame lets
the physics server hand back stale or duplicate collision state at those
coordinates, which is silently different per peer and causes a desync.

This is a physics-server body-reap race, not a stale-state leak — clearing
autoloads or resetting game state does not fix it, because the problem lives
entirely in engine-side physics bookkeeping outside anything the rollback
snapshot system touches. Anyone building level/segment transitions on top of
this addon needs to budget for that settle frame explicitly.

## Examples

`examples/box_arena/` is a self-contained reference:

- **`box_arena.tscn` / `box_arena.gd`** — a runnable OFFLINE demo (no networking,
  no input devices). It builds a `RollbackManager`, two `RollbackMotion`-driven
  boxes on a floor, and a `TickPureMover` platform, registers them via a
  `RollbackBinder`, turns on `sync_test_mode`, and drives a scripted input
  pattern — proving the state contract and determinism live. Run it headless:

  ```
  godot --headless --path . addons/rollback/examples/box_arena/box_arena.tscn
  ```

  It prints `box_arena: PASS — deterministic` and exits 0 when no desync is found.

- **`rollback_box.gd`** — the actor: a minimal registered-node contract
  (`_save_state` / `_load_state` / `_network_tick`) over `RollbackMotion`.
- **`box_input_codec.gd`** — an example `RollbackInputCodec` subclass for a
  `{mx, my, b}` input, showing the compact-wire path.
- **`online_template.gd`** — a copy-paste reference for the two-peer
  `RollbackSessionController` wiring. Not standalone-runnable: online play needs a
  signaling adapter you supply. The example scripts intentionally have no
  `class_name` so they don't enter your game's global class list.

## Self-test

```
godot --headless --path . --script addons/rollback/tests/sync_test_scenarios.gd
```

Scenarios: pure-logic determinism (must be clean), a planted
incomplete-registration canary (must be caught), engine `move_and_slide`
probes (informational — they desync, which is why `RollbackMotion` exists),
and `RollbackMotion` + tick-pure moving platform (must be clean; gates the
suite).

### Running standalone (addon repo, no consumer project)

The commands above assume a consumer project root at `res://addons/rollback`.
To gate the addon repo itself (CI or local, with no consumer project checked
out), `test_project/` is a minimal project shim that mounts the repo at that
same path via a runtime symlink (never committed — see `.gitignore`):

```
mkdir -p test_project/addons
ln -sfn "$(pwd)" test_project/addons/rollback
godot --headless --path test_project --import
godot --headless --path test_project --script res://addons/rollback/tests/sync_test_scenarios.gd
godot --headless --path test_project -s res://addons/rollback/tests/provider_order_test.gd
godot --headless --path test_project -s res://addons/rollback/tests/confirmed_tick_mirror_test.gd
godot --headless --path test_project res://addons/rollback/examples/box_arena/box_arena.tscn
```

`.github/workflows/tests.yml` runs exactly this on push/PR.
