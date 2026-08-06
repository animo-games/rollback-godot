## Deterministic fixed-tick driver with save/load/resimulate support — the
## core of a GGPO-style rollback stack. Phase 1 scope: offline tick loop,
## state registration, per-tick snapshots + hashing, and a sync-test mode that
## forces a rollback + resimulation every tick and diffs the result. This
## proves the registered state set is complete and the sim is deterministic
## before any networking exists.
##
## Registered-node contract (duck-typed, checked at register()):
##   _save_state() -> Dictionary
##       Every mutable gameplay variable, POD values only (numbers, bools,
##       strings, Vector2/3, arrays/dictionaries of those). Key order does not
##       matter — the snapshot hash canonicalizes dictionary keys — but Array
##       element order IS significant (it's part of the state).
##   _load_state(state: Dictionary) -> void
##       Restore exactly what _save_state saved. After this returns, a
##       _network_tick must behave as if the intervening ticks never happened.
##       CharacterBody2D caveat: is_on_floor()/get_last_motion() are hidden
##       engine state that load cannot restore — gameplay reads inside
##       _network_tick must use explicit queries (e.g. test_move) instead.
##   _network_tick(tick: int, inputs: Dictionary) -> void
##       Advance one fixed tick. `inputs` is {provider_id: Dictionary} for
##       that tick. ALL gameplay mutation happens here or in helpers it calls
##       — never in _process/_physics_process, and never from wall-clock time.
##
## Tick-pure nodes (moving platforms, rotating hazards) instead implement:
##   _tick_pure_update(tick: int) -> void   # state = f(tick); no snapshot
## and are updated by the manager before registered nodes each tick, and
## after every restore — their colliders must match the tick being simulated.
##
## Registered nodes MAY also implement:
##   _pre_network_tick() -> void
##       Called on every registered node at the top of each simulated tick,
##       before tick-pure updates and any _network_tick. Use it to emulate
##       engine frame-boundary work the tick loop bypasses — canonically,
##       force_update_transform() on child collision bodies so queries from
##       other nodes see start-of-tick transforms in live and resim alike.
##   _post_network_tick() -> void
##       Called on every registered node that has it, after all nodes'
##       _network_tick for the simulated tick (live and resim alike). Use it
##       for cross-node coupling that must observe every node's post-tick
##       position (e.g. rider velocity-add).
##   _set_rollback_manager(manager: RollbackManager) -> void
##       Called once at register(). Store the reference to gate cosmetic
##       side effects (see fire_once) — e.g. suppress particle/SFX one-shots
##       while manager.is_resimulating.
##
## Node paths are snapshot keys and define tick order: registered nodes are
## iterated sorted by path, so paths must be stable (and, once networked,
## identical across peers).
class_name RollbackManager
extends Node

## Fixed simulation timestep — the single source of truth for the tick rate.
## Every registered node advances its gameplay by exactly this many seconds per
## tick. Game code should reference `RollbackManager.TICK_DELTA` rather than
## re-declaring `1.0 / 60.0` locally. Tracks Engine.physics_ticks_per_second
## and is changed only via `set_tick_rate()`.
static var TICK_DELTA := 1.0 / 60.0

static func _static_init() -> void:
	TICK_DELTA = 1.0 / float(Engine.physics_ticks_per_second)


## Single entry point for switching the sim rate (perf A/B: 60 vs 30 Hz).
## Keeps Engine.physics_ticks_per_second and TICK_DELTA in lockstep so
## start()'s validation still holds. Do NOT call while an online session
## is running — peers would desync; tick-count timers computed at event
## time adapt on their next computation, values computed once at _ready
## (e.g. bot activation delays) keep their old tick counts.
static func set_tick_rate(ticks_per_second: int) -> void:
	Engine.physics_ticks_per_second = ticks_per_second
	TICK_DELTA = 1.0 / float(ticks_per_second)

## Emitted at the top of every simulated tick (including resimulated ones —
## check is_resimulating to suppress cosmetic side effects).
signal before_tick(tick: int)
signal after_tick(tick: int)
## Sync-test found a divergence. See _diff_snapshots for the report shape.
signal desync_detected(report: Dictionary)

const _CONTRACT: Array[StringName] = [&"_save_state", &"_load_state", &"_network_tick"]

## Increments once per simulated tick advance (live and resimulated alike).
## A cache-invalidation token for game code that wants to compute something
## once per advance and share it across nodes. Deliberately NOT simulation
## state: peers perform different numbers of rollbacks, so this value differs
## between them and must never be snapshotted or branched on for gameplay.
var advance_generation: int = 0

## How many ticks of history to keep restorable. Networked rollback depth is
## bounded by this; sync_test_depth must not exceed it.
@export var max_rollback_ticks: int = 8
## When true, every tick is followed by a forced rollback of sync_test_depth
## ticks and a resimulation, hash-diffed against the original snapshots.
@export var sync_test_mode: bool = false
## Republish every registered body's transform to the physics server after it
## ticks, and after every restore.
##
## Godot latches node transforms into the server once per real physics step,
## not when global_position is written. A live tick therefore queries the
## server one step stale — consistently, so it is at least deterministic — but
## a resimulated tick queries it stale by however far the live sim had run when
## the rollback fired, which is wall-clock frame timing rather than simulated
## tick. Any motion query whose result depends on ANOTHER registered body's
## position then resolves differently in resim than it did live.
##
## Only matters when two registered bodies can actually collide (their
## layer/mask intersect). Games where every registered body collides with
## static world geometry only — no body-vs-body contact — can set this false
## and save the per-body republish; static geometry and tick-pure movers are
## StaticBody2D, which the server applies immediately, so they are unaffected
## either way. Measured at roughly +20% resim cost in the addon's two-pawn
## physics scenario.
##
## A consuming game normally sets this once for the whole project through the
## `rollback/physics/publish_body_transforms` project setting rather than
## touching every manager — see PUBLISH_SETTING below.
@export var publish_body_transforms: bool = true
## Depth (in ticks) of the forced rollback+resim performed each tick in
## sync-test mode. Must not exceed max_rollback_ticks.
@export var sync_test_depth: int = 2

## Current simulated tick. Tick 0 is the pre-start state; the first simulated
## tick is 1.
var tick: int = 0
## Highest tick for which an attached session has contiguous authoritative
## input from every provider. It can run ahead of tick; zero means no
## confirmation has been published yet. This is coordination/presentation
## metadata, never captured in snapshots and never suitable for branching
## registered gameplay logic.
var confirmed_tick: int = 0
var running := false
## When true, an external session (lockstep/rollback netcode) drives ticks
## via advance_externally() and _physics_process is inert.
var externally_driven := false
## True while inside a rollback resimulation (sync-test or, later, netcode).
var is_resimulating := false

var _registered: Array[Node] = []
var _pre_tickers: Array[Node] = []
## Registered nodes with an optional _post_network_tick() hook.
var _post_tickers: Array[Node] = []
var _tick_pure: Array[Node] = []
var _providers: Array[StringName] = []
var _samplers: Dictionary = {}       # StringName -> Callable() -> Dictionary
var _snapshots: Dictionary = {}      # tick -> {"states": {String: Dictionary}} (+ lazily added "hash": int)
var _input_history: Dictionary = {}  # tick -> {StringName: Dictionary}
var _desync_count := 0
var _resim_ticks := 0
var _resim_usec_total := 0
var _resim_usec_max := 0
var _sim_tick := 0            # tick currently being advanced; differs from `tick` during resimulate
var _fired_events: Dictionary = {}  # tick:int -> {String key: true}
var _paths: Dictionary = {}         # Node -> String cached get_path(), see _path_of()


func _enter_tree() -> void:
	# Activates RollbackOverlap's resim-safe path for the lifetime of this
	# manager (netplay segment); see rollback_overlap.gd.
	RollbackOverlap.notify_manager_entered_tree()


func _exit_tree() -> void:
	# Releases RollbackOverlap's resim-safe path; refcount returns to 0 once
	# the last manager tears down, restoring the wall-clock fast path.
	RollbackOverlap.notify_manager_exited_tree()


## Project setting mirroring `publish_body_transforms`, so a consuming game can
## opt out once in project.godot instead of at every construction site:
##
##     [rollback]
##     physics/publish_body_transforms=false
##
## Applied in _init(), so anything the caller assigns after `.new()` — or that
## the scene loader restores for a manager saved into a .tscn — still wins.
const PUBLISH_SETTING := "rollback/physics/publish_body_transforms"


func _init() -> void:
	if ProjectSettings.has_setting(PUBLISH_SETTING):
		publish_body_transforms = bool(ProjectSettings.get_setting(PUBLISH_SETTING))


func _ready() -> void:
	# Tick before every gameplay node's own _physics_process.
	process_physics_priority = -1000000


## Nodes must be registered (and providers added) before start(); the
## registered set is assumed fixed for the run. Spawn/despawn inside the
## rollback window is a later-phase problem.
func register(node: Node) -> void:
	if node in _registered:
		return
	for m in _CONTRACT:
		if not node.has_method(m):
			push_error("RollbackManager: %s missing %s" % [node.get_path(), m])
			return
	if running:
		push_warning("RollbackManager: registering %s while running" % node.get_path())
	_registered.append(node)
	_registered.sort_custom(_path_less)
	# One method connect, not two bound built-ins: `_registered.erase.bind(n)`
	# and `_pre_tickers.erase.bind(n)` compare EQUAL as Callables (same
	# built-in Array method + same bound arg), so the second connect would be
	# rejected and _pre_tickers would never get its exit cleanup.
	node.tree_exiting.connect(_on_registered_exiting.bind(node))
	if node.has_method(&"_pre_network_tick"):
		_pre_tickers.append(node)
		_pre_tickers.sort_custom(_path_less)
	if node.has_method(&"_post_network_tick"):
		_post_tickers.append(node)
		_post_tickers.sort_custom(_path_less)
	if node.has_method(&"_set_rollback_manager"):
		node.call(&"_set_rollback_manager", self)


func _on_registered_exiting(node: Node) -> void:
	_registered.erase(node)
	_pre_tickers.erase(node)
	_post_tickers.erase(node)
	_paths.erase(node)


## Registers a tick-pure node: state is a pure function of the tick, so it is
## re-applied on every restore (and before registered nodes each tick) rather
## than snapshotted. See the class doc for the _tick_pure_update contract.
func register_tick_pure(node: Node) -> void:
	if node in _tick_pure:
		return
	if not node.has_method(&"_tick_pure_update"):
		push_error("RollbackManager: %s missing _tick_pure_update" % node.get_path())
		return
	_tick_pure.append(node)
	_tick_pure.sort_custom(_path_less)
	node.tree_exiting.connect(_tick_pure.erase.bind(node))


## Registers every node in `root`'s subtree (and `root` itself) that implements
## a rollback contract: nodes with the full registered-node contract go through
## register(); nodes with only _tick_pure_update() go through
## register_tick_pure(). Registration order is irrelevant (the manager
## path-sorts its sets), and a node already registered is skipped — so this
## composes with manual register() calls for nodes the game registers
## explicitly. Gameplay-agnostic: the game chooses which subtree to hand in;
## the manager only checks for the contract methods.
func register_tree(root: Node, recursive: bool = true) -> void:
	var nodes: Array[Node] = root.find_children("*", "", recursive, false)
	nodes.push_front(root)
	for n in nodes:
		if _has_contract(n):
			register(n)
		elif n.has_method(&"_tick_pure_update"):
			register_tick_pure(n)


## sampler is called once per tick and must return a Dictionary of POD values.
func add_input_provider(id: StringName, sampler: Callable) -> void:
	if not _samplers.has(id):
		_providers.append(id)
		_providers.sort()
	_samplers[id] = sampler


## Resets tick/history and captures the tick-0 snapshot, then starts the tick
## loop. The registered set is assumed fixed after this call.
func start() -> void:
	var expected_tps := roundi(1.0 / TICK_DELTA)
	if Engine.physics_ticks_per_second != expected_tps:
		push_error("RollbackManager.start(): Engine.physics_ticks_per_second is %d but the rollback sim assumes %d (TICK_DELTA = 1/%d). Set physics/common/physics_ticks_per_second to %d in the consumer project. Refusing to start." % [Engine.physics_ticks_per_second, expected_tps, expected_tps, expected_tps])
		return
	_audit_collidable_pairs()
	tick = 0
	confirmed_tick = 0
	_snapshots.clear()
	_input_history.clear()
	_fired_events.clear()
	_desync_count = 0
	_resim_ticks = 0
	_resim_usec_total = 0
	_resim_usec_max = 0
	_apply_tick_pure(0)
	_snapshots[0] = _capture()
	running = true


## Verifies the `publish_body_transforms == false` opt-out is actually safe for
## this registered set, at `start()`, when the set is final.
##
## The opt-out exists because the per-body republish is pure cost for a game
## whose registered bodies never touch each other (see `publish_body_transforms`
## and the README). That precondition is a property of every registered node's
## collision layers/masks — easy to state in a comment, easy to invalidate later
## by registering one more node type, and silent when it breaks: the symptom is
## a rare resim-only desync at grazing contact, not a crash.
##
## Nodes that resolve contact without the physics server suppress their own
## direction — see `_is_physics_free_contact`.
##
## Two bodies can touch when either one's mask selects the other's layer, so the
## test is symmetric. Reported per pair, with the layer/mask values, because the
## fix is usually to narrow one mask rather than to turn the setting back on.
##
## Diagnostic only — it never refuses to start. A false positive here (bodies
## that share layers but are kept apart by level geometry) must not brick a
## shipping game, and a true positive is a determinism bug that wants a loud log,
## not a hard stop.
func _audit_collidable_pairs() -> void:
	if publish_body_transforms:
		return
	var findings := collidable_pair_findings()
	if findings.is_empty():
		return
	push_error(
		("RollbackManager: publish_body_transforms is FALSE, but %d registered " +
		"collider pair(s) can touch. That setting is only safe when no two " +
		"registered bodies can contact each other; with it off, their transforms " +
		"go stale during resimulation by however far the live sim had run, so " +
		"contact resolves differently on the resim pass and desyncs at grazing " +
		"contact. Either narrow the layers/masks below or set " +
		"rollback/physics/publish_body_transforms=true.\n%s")
		% [findings.size(), "\n".join(findings)]
	)


## The audit's rule, separated from its reporting so it can be tested directly.
## Returns one human-readable line per registered collider pair that can touch.
## Public for tests; `_audit_collidable_pairs()` is the caller that matters.
func collidable_pair_findings() -> PackedStringArray:
	# Scope is exactly `_sync_one_transform`'s domain: the registered node itself
	# when it is a PhysicsBody2D or Area2D. Collider CHILDREN are deliberately
	# out of scope — the republish never touches them, so flagging them here
	# would blame this setting for the separate `_pre_network_tick()` /
	# `force_update_transform()` contract and bury the real hits. (Auditing
	# subtrees instead produced 301 findings on duo, essentially all noise.)
	var bodies: Array[CollisionObject2D] = []
	for node in _registered:
		if node is PhysicsBody2D or node is Area2D:
			bodies.append(node as CollisionObject2D)

	var findings: PackedStringArray = []
	for i in bodies.size():
		for j in range(i + 1, bodies.size()):
			var a := bodies[i]
			var b := bodies[j]
			# The hazard is DIRECTIONAL, and getting this wrong is the difference
			# between a usable check and a wall of noise. When A collides into B,
			# what can desync the result is B sitting at a stale position while A
			# queries — so it matters whether B is stale-able, not whether either
			# of them is. A STATIC body is applied to the server immediately and
			# is therefore never stale.
			#
			# Concretely: duo's players mask the timed platforms' layer, but those
			# platforms are StaticBody2D and mask nothing back, so all 55 such
			# pairs are safe. Testing "layers intersect AND at least one side is
			# non-static" reported every one of them.
			#
			# The opt-out is applied to the QUERIER for the same reason: what the
			# republish fixes is a physics-server query reading a stale transform,
			# so a node that resolves its own contact from node transforms
			# (RollbackOverlap and friends) has nothing to be wrong about in that
			# direction. It still counts as the stale side when something else
			# queries it — declaring yourself physics-free says what you read, not
			# what others read of you.
			var a_into_b := (a.collision_mask & b.collision_layer) != 0 \
					and not _is_static_body(b) and not _is_physics_free_contact(a)
			var b_into_a := (b.collision_mask & a.collision_layer) != 0 \
					and not _is_static_body(a) and not _is_physics_free_contact(b)
			if not a_into_b and not b_into_a:
				continue
			findings.append("  %s (layer=%d mask=%d) <-> %s (layer=%d mask=%d)" % [
				String(a.get_path()), a.collision_layer, a.collision_mask,
				String(b.get_path()), b.collision_layer, b.collision_mask,
			])

	return findings


## True for a body the physics server applies immediately, i.e. one that cannot
## hold a stale transform across a resimulated tick. Asks the server for the
## mode rather than testing the class, because `AnimatableBody2D` extends
## `StaticBody2D` yet is KINEMATIC — the very case that goes stale.
func _is_static_body(node: CollisionObject2D) -> bool:
	if not (node is PhysicsBody2D):
		return false
	return PhysicsServer2D.body_get_mode((node as PhysicsBody2D).get_rid()) \
		== PhysicsServer2D.BODY_MODE_STATIC


## Opt-out marker for the audit above: true when `node` declares that it resolves
## contact on the tick without asking the physics server — typically by sampling
## RollbackOverlap at explicit node transforms, which recomposes globals from
## local transforms and never reads PhysicsServer2D, so `publish_body_transforms`
## cannot affect its result either way.
##
## This exists because the audit's only evidence is collision_layer/mask, and
## those stay populated on a node whose tick path has stopped consulting them —
## an Area2D that keeps `monitoring` on for a wall-clock/offline code path reads
## to the audit exactly like one that queries every tick. Without a way to say
## otherwise, such a node produces a permanent finding, and a permanent finding
## is one nobody reads the day a real one appears.
##
## Declaring it is a claim about THIS node's own contact tests. It is not a
## blanket exemption: motion queries this node makes through move_and_slide(),
## and other nodes' queries against it, are unaffected and still audited.
##
##     func _rollback_physics_free_contact() -> bool: return true
func _is_physics_free_contact(node: CollisionObject2D) -> bool:
	if not node.has_method(&"_rollback_physics_free_contact"):
		return false
	return bool(node.call(&"_rollback_physics_free_contact"))


## Halts the physics-driven tick loop. Safe to call when not running.
func stop() -> void:
	running = false


## Snapshot hash for tick t, or -1 if that snapshot is gone/never existed.
## Computed on first request and cached; see _snapshot_hash().
func get_tick_hash(t: int) -> int:
	var snapshot: Variant = _snapshots.get(t)
	if not (snapshot is Dictionary):
		return -1
	return _snapshot_hash(snapshot as Dictionary)


## Deep duplicate of the stored per-node states for tick t, or {} if that
## snapshot is gone/never existed.
func get_snapshot_states(t: int) -> Dictionary:
	var snapshot: Variant = _snapshots.get(t)
	if not (snapshot is Dictionary):
		return {}
	var states: Variant = (snapshot as Dictionary).get("states")
	if not (states is Dictionary):
		return {}
	return (states as Dictionary).duplicate(true)


## Hard-loads a full authoritative snapshot received from a remote peer (host
## resync). Discards ALL local history — after this call the manager is at
## tick t with exactly one snapshot. Returns false (with a push_error) if
## states is missing an entry for a registered node; the caller compares
## get_tick_hash(t) against the sender's hash to verify the state round-tripped.
func load_authoritative_snapshot(t: int, states: Dictionary) -> bool:
	for node in _registered:
		var path := _path_of(node)
		if not states.has(path):
			push_error("RollbackManager: resync snapshot missing state for %s" % path)
			return false
	is_resimulating = true
	for node in _registered:
		var path := _path_of(node)
		var s: Variant = states[path]
		node.call(&"_load_state", s if s is Dictionary else {})
	_apply_tick_pure(t)
	is_resimulating = false
	tick = t
	_snapshots.clear()
	_input_history.clear()
	_snapshots[t] = _capture()
	return true


## Cosmetic side-effect dedup across rollback resimulation. Call from inside
## a _network_tick (or a helper it calls); returns true exactly once per
## (current simulated tick, key) — a resimulation of the same tick returns
## false, so one-shot audio/VFX don't double-fire. Note: a corrected resim
## that no longer reaches the call site cannot "unfire" the effect —
## acceptable for cosmetics by definition.
func fire_once(key: String) -> bool:
	var tick_map: Dictionary
	if _fired_events.has(_sim_tick):
		tick_map = _fired_events[_sim_tick] as Dictionary
	else:
		tick_map = {}
		_fired_events[_sim_tick] = tick_map
	if tick_map.has(key):
		return false
	tick_map[key] = true
	return true


## Returns tick count, desync count, and resim cost avg/max usec.
func get_stats() -> Dictionary:
	return {
		"tick": tick,
		"desyncs": _desync_count,
		"resim_ticks": _resim_ticks,
		"resim_usec_avg": 0.0 if _resim_ticks == 0 else float(_resim_usec_total) / _resim_ticks,
		"resim_usec_max": _resim_usec_max,
	}


func _physics_process(_delta: float) -> void:
	if not running or externally_driven:
		return
	_step(_sample_inputs())


## Advance exactly one tick with externally supplied inputs
## ({provider StringName: Dictionary}). Used by network session drivers;
## requires running and externally_driven.
func advance_externally(inputs: Dictionary) -> void:
	_step(inputs)


## Netcode rollback: restore the snapshot at tick `base`, then resimulate
## ticks base+1..tick. inputs_by_tick ({t:int -> {provider StringName ->
## Dictionary}}) REPLACES the recorded input history for any tick it has an
## entry for; other ticks replay their recorded inputs. Snapshots for the
## resimulated range are recaptured (they are the corrected authoritative
## history). Returns false (with a push_error) if the base snapshot is gone.
func resimulate(base: int, inputs_by_tick: Dictionary) -> bool:
	if base >= tick:
		return true
	if not _snapshots.has(base):
		push_error("RollbackManager: no snapshot for tick %d, cannot resimulate" % base)
		return false
	var t0 := Time.get_ticks_usec()
	is_resimulating = true
	_restore(base)
	for t in range(base + 1, tick + 1):
		if inputs_by_tick.has(t):
			_input_history[t] = inputs_by_tick[t] as Dictionary
		_advance(t, _input_history[t])
		_snapshots[t] = _capture()
	is_resimulating = false
	var usec := int(Time.get_ticks_usec() - t0)
	_resim_ticks += tick - base
	_resim_usec_total += usec
	_resim_usec_max = maxi(_resim_usec_max, usec)
	return true


func _step(inputs: Dictionary) -> void:
	tick += 1
	_input_history[tick] = inputs
	_advance(tick, inputs)
	_snapshots[tick] = _capture()
	if sync_test_mode:
		_run_sync_test()
	_trim(tick - (max_rollback_ticks + 2))


func _advance(t: int, inputs: Dictionary) -> void:
	advance_generation += 1
	_sim_tick = t
	before_tick.emit(t)
	for node in _pre_tickers:
		node.call(&"_pre_network_tick")
	_apply_tick_pure(t)
	for node in _registered:
		node.call(&"_network_tick", t, inputs)
		if publish_body_transforms:
			_sync_one_transform(node)
	for node in _post_tickers:
		node.call(&"_post_network_tick")
	after_tick.emit(t)


func _apply_tick_pure(t: int) -> void:
	for node in _tick_pure:
		node.call(&"_tick_pure_update", t)


func _sample_inputs() -> Dictionary:
	var out := {}
	for id in _providers:
		var sample: Variant = (_samplers[id] as Callable).call()
		out[id] = sample if sample is Dictionary else {}
	return out


## Stores per-node state only. The snapshot hash is deliberately NOT computed
## here — see _snapshot_hash().
func _capture() -> Dictionary:
	var states := {}
	for node in _registered:
		var s: Variant = node.call(&"_save_state")
		if not (s is Dictionary):
			push_error("RollbackManager: %s._save_state returned non-Dictionary" % node.get_path())
			s = {}
		states[_path_of(node)] = s
	return {"states": states}


func _restore(t: int) -> bool:
	var snapshot: Variant = _snapshots.get(t)
	if snapshot == null:
		push_error("RollbackManager: no snapshot for tick %d" % t)
		return false
	var states: Dictionary = (snapshot as Dictionary)["states"]
	for node in _registered:
		node.call(&"_load_state", states[_path_of(node)])
	_apply_tick_pure(t)
	_sync_physics_transforms()
	return true


## Godot delivers Node2D transform changes to the physics server on a deferred
## notification pass, so a transform written by _load_state is not yet visible
## to move_and_collide/test_move queries issued later in the same frame. A live
## tick never notices — the previous frame flushed everything — but a restore
## followed immediately by resimulated ticks queries a space that still holds
## pre-restore transforms. Two registered bodies that touch then resolve their
## contact differently in resim than they did live: the moving body's own
## transform is correct, the other body's is stale, and the contact is silently
## missed. Push every restored transform straight into the server instead.
func _sync_physics_transforms() -> void:
	for node in _registered:
		_sync_one_transform(node)
	for node in _tick_pure:
		_sync_one_transform(node)


## A KINEMATIC body treats BODY_STATE_TRANSFORM as a *target* consumed at the
## next physics step, so writing it does not move the collider now. STATIC
## bodies take the immediate path, so flip the mode across the write and put it
## back. Mode is read rather than assumed, both so a registered RigidBody2D is
## restored to its own mode and so this stays correct if a body's mode changes
## at runtime.
## Note: CanvasItem.force_update_transform() is NOT enough here, even though it
## is the right tool for the child-body case in the README. It flushes the node
## transform, but a KINEMATIC body's server-side collider still does not move
## until the step consumes the target. Measured: still 54 desyncs at 30 Hz.
## Flipping to BODY_MODE_STATIC across the write takes the immediate path.
func _sync_one_transform(node: Node) -> void:
	if node is PhysicsBody2D:
		var rid := (node as PhysicsBody2D).get_rid()
		var xform := (node as PhysicsBody2D).global_transform
		var mode := PhysicsServer2D.body_get_mode(rid)
		if mode == PhysicsServer2D.BODY_MODE_STATIC:
			PhysicsServer2D.body_set_state(rid,
				PhysicsServer2D.BODY_STATE_TRANSFORM, xform)
			return
		PhysicsServer2D.body_set_mode(rid, PhysicsServer2D.BODY_MODE_STATIC)
		PhysicsServer2D.body_set_state(rid,
			PhysicsServer2D.BODY_STATE_TRANSFORM, xform)
		PhysicsServer2D.body_set_mode(rid, mode)
	elif node is Area2D:
		var area := node as Area2D
		PhysicsServer2D.area_set_transform(area.get_rid(), area.global_transform)


## Forced rollback + resim of the last sync_test_depth ticks, then a diff
## against the snapshots the live pass produced. Restores the authoritative
## snapshot afterwards either way, so a desync is reported once per cause
## rather than compounding.
func _run_sync_test() -> void:
	var depth: int = mini(sync_test_depth, tick)
	var base := tick - depth
	if not _snapshots.has(base):
		return
	var t0 := Time.get_ticks_usec()
	is_resimulating = true
	_restore(base)
	var regenerated := {}
	for t in range(base + 1, tick + 1):
		_advance(t, _input_history[t])
		regenerated[t] = _capture()
	is_resimulating = false
	var usec := int(Time.get_ticks_usec() - t0)
	_resim_ticks += depth
	_resim_usec_total += usec
	_resim_usec_max = maxi(_resim_usec_max, usec)

	for t in range(base + 1, tick + 1):
		var expected: Dictionary = _snapshots[t]
		var actual: Dictionary = regenerated[t]
		if _snapshot_hash(expected) != _snapshot_hash(actual):
			_desync_count += 1
			desync_detected.emit(_diff_snapshots(t, depth, expected, actual))
			break
	_restore(tick)


func _diff_snapshots(t: int, depth: int, expected: Dictionary, actual: Dictionary) -> Dictionary:
	var nodes := {}
	var exp_states: Dictionary = expected["states"]
	var act_states: Dictionary = actual["states"]
	for path in exp_states:
		if not act_states.has(path):
			nodes[path] = {"missing": true}
			continue
		var exp_state: Dictionary = exp_states[path]
		var act_state: Dictionary = act_states[path]
		var keys := {}
		for key in exp_state:
			if not act_state.has(key) or exp_state[key] != act_state[key]:
				keys[key] = {"expected": exp_state[key], "actual": act_state.get(key)}
		for key in act_state:
			if not exp_state.has(key):
				keys[key] = {"expected": null, "actual": act_state[key]}
		if not keys.is_empty():
			nodes[path] = keys
	for path in act_states:
		if not exp_states.has(path):
			nodes[path] = {"extra": true}
	return {"tick": t, "depth": depth, "nodes": nodes}


func _trim(before: int) -> void:
	if before <= 0:
		return
	for t in _snapshots.keys():
		if t < before:
			_snapshots.erase(t)
	for t in _input_history.keys():
		if t < before:
			_input_history.erase(t)
	for t in _fired_events.keys():
		if t < before:
			_fired_events.erase(t)


## Cached String(node.get_path()) for a registered node. The registered set
## and node paths are fixed for a run, but get_path() allocates and walks
## the tree — it ran once per node per capture AND per restore. Only cached
## once the node is in the tree, so a node registered before add_child()
## still resolves correctly later.
func _path_of(node: Node) -> String:
	var cached: Variant = _paths.get(node)
	if cached is String:
		return cached as String
	var p := String(node.get_path())
	if node.is_inside_tree():
		_paths[node] = p
	return p


func _has_contract(node: Node) -> bool:
	for m in _CONTRACT:
		if not node.has_method(m):
			return false
	return true


## Snapshot hash, computed on first request and cached into the snapshot dict.
## Deferred because _capture() runs on every live AND resimulated tick while
## the hash is consumed only every checksum_interval ticks (plus resync and
## the determinism gates) — canonicalizing eagerly was the single most
## expensive thing in the online tick and ~95% of it was discarded.
##
## Hashes a key-order-independent canonicalization of each state: Godot's
## Dictionary.hash() is insertion-order-dependent, so without this two peers
## building the same dict in different key order would checksum differently.
## states[] keeps the raw dict for load/restore/diff. Iterating `states`
## walks its keys in insertion order, which is the path-sorted _registered
## order _capture() wrote them in — so this hashes exactly the same array the
## eager version did.
static func _snapshot_hash(snapshot: Dictionary) -> int:
	var cached: Variant = snapshot.get("hash")
	if cached is int:
		return cached as int
	var accum := []
	var states: Variant = snapshot.get("states")
	if states is Dictionary:
		for path in (states as Dictionary):
			accum.append([path, _canonicalize((states as Dictionary)[path])])
	var h := accum.hash()
	snapshot["hash"] = h
	return h


## Recursively rewrites a state value into a key-order-independent form for
## hashing: a Dictionary becomes an Array of [key, canonical_value] pairs
## sorted by key (so insertion order can't change the hash); an Array keeps its
## order (element order IS determinism-significant); PODs pass through. Used
## only for the snapshot hash — the raw state is stored unchanged for
## load/restore/diff.
static func _canonicalize(v: Variant) -> Variant:
	if v is Dictionary:
		var d := v as Dictionary
		var keys := d.keys()
		# Sort by stringified key, not keys.sort(): a _save_state() Dictionary
		# may use StringName keys, and StringName's `<` compares
		# intern-pointer addresses (process-history-dependent), which would
		# make this checksum diverge across peers despite identical state.
		keys.sort_custom(_canon_key_less)
		var out := []
		for k in keys:
			out.append([k, _canonicalize(d[k])])
		return out
	if v is Array:
		var out_arr := []
		for e in (v as Array):
			out_arr.append(_canonicalize(e))
		return out_arr
	return v


static func _canon_key_less(a: Variant, b: Variant) -> bool:
	# str(), not String(): keys are arbitrary Variants (int slot keys etc.)
	# and the String() constructor rejects non-string types at runtime.
	return str(a) < str(b)


static func _path_less(a: Node, b: Node) -> bool:
	return String(a.get_path()) < String(b.get_path())
