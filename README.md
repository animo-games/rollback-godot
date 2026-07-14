# rollback

Game-agnostic GGPO-style rollback netcode core for Godot 4 (web-focused).
Developed in-tree for duo; will split to its own repo once stable.

**Phase 1 scope (current):** no networking. Fixed-tick driver, state
registration, per-tick snapshots + content hashing, and a sync-test mode
that forces a rollback + resimulation every tick and diffs the result
against the live pass. This is the tool that proves a game's registered
state is complete and its simulation deterministic *before* any netcode
depends on it.

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
- `_save_state` returns POD values only and builds its dictionary in a fixed
  key order (hashes depend on insertion order).
- RNG must be a seeded, tick-keyed service (never bare `randi()`).
- Node paths are snapshot keys and define tick order — keep them stable
  (and identical across peers once networked).
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

## Usage

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

`get_stats()` reports tick count, desyncs, and resim cost (avg/max usec per
forced rollback) — the phase-1 budget gate is rollback depth ≤ ~8 ticks
resimulating comfortably inside a 60Hz frame in WASM.

## Self-test

```
godot --headless --path . --script addons/rollback/tests/sync_test_scenarios.gd
```

Scenarios: pure-logic determinism (must be clean), a planted
incomplete-registration canary (must be caught), engine `move_and_slide`
probes (informational — they desync, which is why `RollbackMotion` exists),
and `RollbackMotion` + tick-pure moving platform (must be clean; gates the
suite).

## Transport (L1)

`RollbackTransport` (`addons/rollback/transport/rollback_transport.gd`) turns
signaling into a live `MultiplayerAPI`: it assembles a `WebRTCMultiplayerPeer`
mesh when a concrete WebRTC GDExtension backend is available, or falls back
to a loopback `WebSocketMultiplayerPeer` star (smaller peer id serves) when
one isn't — e.g. editor/native dev builds without the extension. Either way
`multiplayer.multiplayer_peer` ends up set, so the game drives everything
with plain RPCs on top. `@rpc("unreliable")` rides the mesh's unreliable
channel in WebRTC mode; the WS fallback has no unreliable channel, so
everything is effectively reliable there — fine for dev/testing, not a
perf-representative substitute for the real mesh.

The addon itself has no SDK dependency: it talks to signaling only through
`RollbackSignalingAdapter` (`sig_received`/`peer_joined`/`peer_left` signals,
`connect_room()`/`send()`/`close()`). `CouchRollbackSignalingAdapter` wraps a
`CouchWebRTC` node the game hands it (`CouchGames.webrtc`) and treats
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

`RollbackNetClock` (`transport/net_clock.gd`, a child of the transport named
`NetClock`) measures per-peer latency/clock offset over the live
`MultiplayerAPI`: `track(net_id)` / `untrack(net_id)`, `get_rtt_ms(net_id)`,
`get_offset_ms(net_id)` (`remote_clock ≈ local_clock + offset`),
`get_synchronized_time_ms(net_id)`, and a `peer_clock_updated` signal — all
values are the median of the last 8 ping/pong samples. This node is
wall-clock territory (transport, not simulation), unlike the tick loop above.
