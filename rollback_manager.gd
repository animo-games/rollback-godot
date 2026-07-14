# Deterministic fixed-tick driver with save/load/resimulate support — the
# core of a GGPO-style rollback stack. Phase 1 scope: offline tick loop,
# state registration, per-tick snapshots + hashing, and a sync-test mode that
# forces a rollback + resimulation every tick and diffs the result. This
# proves the registered state set is complete and the sim is deterministic
# before any networking exists.
#
# Registered-node contract (duck-typed, checked at register()):
#   _save_state() -> Dictionary
#       Every mutable gameplay variable, POD values only (numbers, bools,
#       strings, Vector2/3, arrays/dictionaries of those). Build the
#       dictionary in a fixed key order — snapshot hashes depend on it.
#   _load_state(state: Dictionary) -> void
#       Restore exactly what _save_state saved. After this returns, a
#       _network_tick must behave as if the intervening ticks never happened.
#       CharacterBody2D caveat: is_on_floor()/get_last_motion() are hidden
#       engine state that load cannot restore — gameplay reads inside
#       _network_tick must use explicit queries (e.g. test_move) instead.
#   _network_tick(tick: int, inputs: Dictionary) -> void
#       Advance one fixed tick. `inputs` is {provider_id: Dictionary} for
#       that tick. ALL gameplay mutation happens here or in helpers it calls
#       — never in _process/_physics_process, and never from wall-clock time.
#
# Tick-pure nodes (moving platforms, rotating hazards) instead implement:
#   _tick_pure_update(tick: int) -> void   # state = f(tick); no snapshot
# and are updated by the manager before registered nodes each tick, and
# after every restore — their colliders must match the tick being simulated.
#
# Registered nodes MAY also implement:
#   _pre_network_tick() -> void
#       Called on every registered node at the top of each simulated tick,
#       before tick-pure updates and any _network_tick. Use it to emulate
#       engine frame-boundary work the tick loop bypasses — canonically,
#       force_update_transform() on child collision bodies so queries from
#       other nodes see start-of-tick transforms in live and resim alike.
#
# Node paths are snapshot keys and define tick order: registered nodes are
# iterated sorted by path, so paths must be stable (and, once networked,
# identical across peers).
class_name RollbackManager
extends Node

## Emitted at the top of every simulated tick (including resimulated ones —
## check is_resimulating to suppress cosmetic side effects).
signal before_tick(tick: int)
signal after_tick(tick: int)
## Sync-test found a divergence. See _diff_snapshots for the report shape.
signal desync_detected(report: Dictionary)

const _CONTRACT: Array[StringName] = [&"_save_state", &"_load_state", &"_network_tick"]

## How many ticks of history to keep restorable. Networked rollback depth is
## bounded by this; sync_test_depth must not exceed it.
@export var max_rollback_ticks: int = 8
## When true, every tick is followed by a forced rollback of sync_test_depth
## ticks and a resimulation, hash-diffed against the original snapshots.
@export var sync_test_mode: bool = false
@export var sync_test_depth: int = 2

## Current simulated tick. Tick 0 is the pre-start state; the first simulated
## tick is 1.
var tick: int = 0
var running := false
## When true, an external session (lockstep/rollback netcode) drives ticks
## via advance_externally() and _physics_process is inert.
var externally_driven := false
## True while inside a rollback resimulation (sync-test or, later, netcode).
var is_resimulating := false

var _registered: Array[Node] = []
var _pre_tickers: Array[Node] = []
var _tick_pure: Array[Node] = []
var _providers: Array[StringName] = []
var _samplers: Dictionary = {}       # StringName -> Callable() -> Dictionary
var _snapshots: Dictionary = {}      # tick -> {"states": {String: Dictionary}, "hash": int}
var _input_history: Dictionary = {}  # tick -> {StringName: Dictionary}
var _desync_count := 0
var _resim_ticks := 0
var _resim_usec_total := 0
var _resim_usec_max := 0


func _ready() -> void:
	# Tick before every gameplay node's own _physics_process.
	process_physics_priority = -1000000


## Nodes must be registered (and providers added) before start(); the
## registered set is assumed fixed for the run. Spawn/despawn inside the
## rollback window is a later-phase problem.
func register(node: Node) -> void:
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


func _on_registered_exiting(node: Node) -> void:
	_registered.erase(node)
	_pre_tickers.erase(node)


func register_tick_pure(node: Node) -> void:
	if not node.has_method(&"_tick_pure_update"):
		push_error("RollbackManager: %s missing _tick_pure_update" % node.get_path())
		return
	_tick_pure.append(node)
	_tick_pure.sort_custom(_path_less)
	node.tree_exiting.connect(_tick_pure.erase.bind(node))


## sampler is called once per tick and must return a Dictionary of POD values.
func add_input_provider(id: StringName, sampler: Callable) -> void:
	if not _samplers.has(id):
		_providers.append(id)
		_providers.sort()
	_samplers[id] = sampler


func start() -> void:
	tick = 0
	_snapshots.clear()
	_input_history.clear()
	_desync_count = 0
	_resim_ticks = 0
	_resim_usec_total = 0
	_resim_usec_max = 0
	_apply_tick_pure(0)
	_snapshots[0] = _capture()
	running = true


func stop() -> void:
	running = false


## Snapshot hash for tick t, or -1 if that snapshot is gone/never existed.
func get_tick_hash(t: int) -> int:
	var snapshot: Variant = _snapshots.get(t)
	if not (snapshot is Dictionary):
		return -1
	var h: Variant = (snapshot as Dictionary).get("hash")
	return h as int if h is int else -1


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
	before_tick.emit(t)
	for node in _pre_tickers:
		node.call(&"_pre_network_tick")
	_apply_tick_pure(t)
	for node in _registered:
		node.call(&"_network_tick", t, inputs)
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


func _capture() -> Dictionary:
	var states := {}
	var accum := []
	for node in _registered:
		var s: Variant = node.call(&"_save_state")
		if not (s is Dictionary):
			push_error("RollbackManager: %s._save_state returned non-Dictionary" % node.get_path())
			s = {}
		var path := String(node.get_path())
		states[path] = s
		accum.append([path, s])
	return {"states": states, "hash": accum.hash()}


func _restore(t: int) -> bool:
	var snapshot: Variant = _snapshots.get(t)
	if snapshot == null:
		push_error("RollbackManager: no snapshot for tick %d" % t)
		return false
	var states: Dictionary = (snapshot as Dictionary)["states"]
	for node in _registered:
		node.call(&"_load_state", states[String(node.get_path())])
	_apply_tick_pure(t)
	return true


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
		if expected["hash"] != actual["hash"]:
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


static func _path_less(a: Node, b: Node) -> bool:
	return String(a.get_path()) < String(b.get_path())
