# Phase-3 netcode: strict lockstep with input delay, no rollback. Drives a
# RollbackManager in externally_driven mode (advance_externally()) using
# inputs gathered over a RollbackTransport's live MultiplayerAPI peer.
#
# Each local input is sampled `input_delay` ticks ahead of when it applies
# (sampled "for" tick T, applied at tick T) and broadcast to every remote
# peer; the local sim stalls (skips advancing) whenever any provider's input
# for the next tick hasn't arrived yet — there is no rollback/resimulation
# here, so correctness depends entirely on inputs showing up before their
# tick is due. A per-`checksum_interval` state-checksum exchange (built on
# RollbackManager's per-tick snapshot hash) catches desyncs after the fact
# even though nothing here can correct them.
#
# This node must sit at an IDENTICAL node path on every peer before
# request_start() is called — its RPCs depend on that path matching, same
# rule as RollbackTransport/RollbackNetClock. Call setup() before the
# transport starts connecting: a remote peer's hello can arrive the moment
# the engine-level connection is up, and the handler needs the transport to
# resolve the sender (an early hello is stashed by raw net id and resolved
# later, but only setup() makes that resolution possible). Hellos are
# re-sent periodically until the session begins, so a hello that raced
# ahead of the receiver's request_start() (or vice versa) is not fatal.
#
# Local input samplers differ from RollbackManager's: RollbackManager calls
# `sampler.call()` (no args — "now" is implicit); here samplers are called as
# `sampler.call(tick)` because input is always sampled input_delay ticks
# ahead of the tick it will apply on, so the sampler must know which future
# tick it's producing input for.
class_name RollbackLockstepSession
extends Node

# ============================================================================
# Signals / exports / public state
# ============================================================================

signal session_started()
signal session_failed(reason: String)
## Checksum exchange found a mismatch. {"tick": int, "local_hash": int,
## "remote_hash": int, "peer_id": String}.
signal desync_detected(report: Dictionary)

## Ticks of input delay: local input sampled "for" tick T is applied at tick
## T (i.e. it's sampled input_delay ticks before T, at the time T - input_delay
## is the newest tick being consumed). Must match on every peer.
@export var input_delay := 2
## How often (in ticks) to exchange a state checksum for desync detection.
@export var checksum_interval := 20
## Catch-up cap: how many ticks may be advanced in a single physics frame
## once buffered input allows it (e.g. after a stall clears).
@export var max_ticks_per_frame := 4
## While stalled (missing input for the next tick), resend our input window
## every N physics frames.
@export var stall_resend_frames := 12
## Each outgoing input packet carries up to this many of the most recent
## ticks, for resilience against a dropped unreliable packet.
@export var redundancy := 10

var running := false

# ============================================================================
# Internal state
# ============================================================================

var _manager: RollbackManager
var _transport: RollbackTransport

var _local_providers: Array[StringName] = []
var _local_samplers: Dictionary = {}        # StringName -> Callable(tick:int) -> Dictionary
var _remote_provider_peer: Dictionary = {}  # StringName provider -> String peer_id
var _all_providers: Array[StringName] = []  # sorted union of local + remote providers

var _peer_net_ids: Array[int] = []  # remote peers' engine net ids, captured at _begin()
var _input_buf: Dictionary = {}     # tick:int -> {StringName provider: Dictionary input}
var _next_local_tick := 0

var _requested := false
var _hellos: Dictionary = {}  # peer_id:String -> Dictionary hello payload
var _pending_hellos: Dictionary = {}  # net_id:int -> Dictionary payload (arrived before setup())
var _hello_resend_frames := 0

var _local_hashes: Dictionary = {}   # tick:int -> int hash (ours, awaiting a remote match)
var _remote_hashes: Dictionary = {}  # tick:int -> {"hash": int, "peer": String} (remote's, awaiting ours)

var _stall_frames_streak := 0
var _stall_frames_total := 0
var _max_stall_streak := 0
var _checksums_ok := 0
var _checksum_mismatches := 0
var _packets_sent := 0
var _packets_received := 0


func _ready() -> void:
	# Just after RollbackManager's -1000000, before all gameplay nodes.
	process_physics_priority = -999999


# ============================================================================
# Setup / API
# ============================================================================


func setup(manager: RollbackManager, transport: RollbackTransport) -> void:
	_manager = manager
	_transport = transport
	_transport.peer_lost.connect(_on_peer_lost)


## sampler is called as sampler.call(t) and must return a POD Dictionary for
## tick t.
func add_local_provider(id: StringName, sampler: Callable) -> void:
	if not _local_samplers.has(id):
		_local_providers.append(id)
		_local_providers.sort()
	_local_samplers[id] = sampler
	_add_provider(id)


func add_remote_provider(id: StringName, peer_id: String) -> void:
	_remote_provider_peer[id] = peer_id
	_add_provider(id)


func _add_provider(id: StringName) -> void:
	if not _all_providers.has(id):
		_all_providers.append(id)
		_all_providers.sort()


func request_start() -> void:
	if input_delay < 1:
		_fail("input_delay must be >= 1")
		return
	_local_providers.sort()
	_requested = true
	_send_hello()
	_maybe_begin()


func _hello_payload() -> Dictionary:
	return {
		"v": 1,
		"input_delay": input_delay,
		"checksum_interval": checksum_interval,
		"providers": _local_provider_strings(),
	}


func _send_hello() -> void:
	var payload := _hello_payload()
	for peer_id in _transport.get_ready_peers():
		var net_id := _transport.get_net_id(peer_id)
		_rpc_hello.rpc_id(net_id, payload)


func stop() -> void:
	running = false
	_requested = false
	if _manager:
		_manager.stop()
		_manager.externally_driven = false


func get_stats() -> Dictionary:
	return {
		"tick": _manager.tick if _manager else 0,
		"stall_frames": _stall_frames_total,
		"max_stall_streak": _max_stall_streak,
		"checksums_ok": _checksums_ok,
		"checksum_mismatches": _checksum_mismatches,
		"packets_sent": _packets_sent,
		"packets_received": _packets_received,
	}


func _local_provider_strings() -> Array:
	var out: Array = []
	for provider in _local_providers:
		out.append(String(provider))
	return out


func _on_peer_lost(peer_id: String, _net_id: int) -> void:
	if running or _requested:
		_fail("peer lost: " + peer_id)


# ============================================================================
# RPCs
# ============================================================================


@rpc("any_peer", "call_remote", "reliable")
func _rpc_hello(payload: Dictionary) -> void:
	if _transport == null:
		# Raced ahead of setup(); stash by raw net id, resolved in
		# _maybe_begin() once the transport exists.
		_pending_hellos[multiplayer.get_remote_sender_id()] = payload
		return
	var peer_id := _transport.get_peer_id(multiplayer.get_remote_sender_id())
	if peer_id.is_empty():
		push_warning("RollbackLockstepSession: hello from unknown sender")
		return
	_hellos[peer_id] = payload
	_maybe_begin()


@rpc("any_peer", "call_remote", "unreliable")
func _rpc_input(pkt: Dictionary) -> void:
	var peer_id := _transport.get_peer_id(multiplayer.get_remote_sender_id())
	if peer_id.is_empty():
		push_warning("RollbackLockstepSession: input packet from unknown sender")
		return
	_packets_received += 1

	var start := int(pkt.get("start", 0))
	var frames_v: Variant = pkt.get("frames", [])
	if not (frames_v is Array):
		return
	var frames := frames_v as Array

	for i in range(frames.size()):
		var t := start + i
		if t <= _manager.tick:
			continue
		var frame_v: Variant = frames[i]
		if not (frame_v is Dictionary):
			continue
		var frame := frame_v as Dictionary
		for provider_key in frame:
			var provider := StringName(String(provider_key))
			if not _remote_provider_peer.has(provider):
				continue
			if (_remote_provider_peer[provider] as String) != peer_id:
				continue
			if not _input_buf.has(t):
				_input_buf[t] = {}
			var tick_buf: Dictionary = _input_buf[t]
			if tick_buf.has(provider):
				continue
			var input_v: Variant = frame[provider_key]
			tick_buf[provider] = input_v if input_v is Dictionary else {}


@rpc("any_peer", "call_remote", "reliable")
func _rpc_checksum(t: int, h: int) -> void:
	var peer_id := _transport.get_peer_id(multiplayer.get_remote_sender_id())
	if peer_id.is_empty():
		push_warning("RollbackLockstepSession: checksum from unknown sender")
		return
	if _local_hashes.has(t):
		var local_h: int = _local_hashes[t]
		if local_h == h:
			_checksums_ok += 1
		else:
			_checksum_mismatches += 1
			desync_detected.emit({"tick": t, "local_hash": local_h, "remote_hash": h, "peer_id": peer_id})
		_local_hashes.erase(t)
	else:
		_remote_hashes[t] = {"hash": h, "peer": peer_id}


# ============================================================================
# Begin logic
# ============================================================================


func _maybe_begin() -> void:
	if _transport != null and not _pending_hellos.is_empty():
		# Hellos that arrived before setup(): resolve now that we can.
		for net_id in _pending_hellos.keys():
			var peer_id := _transport.get_peer_id(net_id as int)
			if peer_id.is_empty():
				continue  # leave stashed for a later attempt
			_hellos[peer_id] = _pending_hellos[net_id] as Dictionary
			_pending_hellos.erase(net_id)
	if running or not _requested:
		return
	if _manager == null or _transport == null:
		return
	var ready_peers := _transport.get_ready_peers()
	if ready_peers.is_empty():
		return
	for peer_id in ready_peers:
		if not _hellos.has(peer_id):
			return

	for peer_id in ready_peers:
		var hello: Dictionary = _hellos[peer_id]
		if int(hello.get("input_delay", -1)) != input_delay:
			_fail("input_delay mismatch with %s" % peer_id)
			return
		if int(hello.get("checksum_interval", -1)) != checksum_interval:
			_fail("checksum_interval mismatch with %s" % peer_id)
			return
		var hello_providers := _hello_provider_set(hello)
		var expected_providers := _expected_providers_for_peer(peer_id)
		if hello_providers != expected_providers:
			_fail("provider map mismatch with %s" % peer_id)
			return

	_begin()


func _hello_provider_set(hello: Dictionary) -> Array[StringName]:
	var raw: Variant = hello.get("providers", [])
	var out: Array[StringName] = []
	if raw is Array:
		for p in (raw as Array):
			out.append(StringName(String(p)))
	out.sort()
	return out


func _expected_providers_for_peer(peer_id: String) -> Array[StringName]:
	var out: Array[StringName] = []
	for provider in _remote_provider_peer:
		if (_remote_provider_peer[provider] as String) == peer_id:
			out.append(provider as StringName)
	out.sort()
	return out


func _begin() -> void:
	_peer_net_ids.clear()
	for peer_id in _transport.get_ready_peers():
		_peer_net_ids.append(_transport.get_net_id(peer_id))

	_manager.externally_driven = true
	_manager.start()

	for t in range(1, input_delay + 1):
		var neutral := {}
		for provider in _all_providers:
			neutral[provider] = {}
		_input_buf[t] = neutral
	_next_local_tick = input_delay + 1

	running = true
	session_started.emit()


func _fail(reason: String) -> void:
	push_error("RollbackLockstepSession: " + reason)
	stop()
	session_failed.emit(reason)


# ============================================================================
# Tick loop
# ============================================================================


func _physics_process(_delta: float) -> void:
	if not running:
		if _requested:
			# Re-send our hello until the session begins — covers hello
			# delivery racing ahead of the receiver's setup()/request_start()
			# in either direction (hellos are idempotent on the receiver).
			_hello_resend_frames += 1
			if _hello_resend_frames % 60 == 0:
				_send_hello()
		return
	var advanced := 0
	while advanced < max_ticks_per_frame:
		var target := _manager.tick + 1
		if not _have_all_inputs(target):
			break
		_sample_and_send()
		_manager.advance_externally(_compose_inputs(target))
		_after_advance(target)
		advanced += 1
	if advanced > 0:
		_stall_frames_streak = 0
	else:
		_stall_frames_streak += 1
		_stall_frames_total += 1
		_max_stall_streak = maxi(_max_stall_streak, _stall_frames_streak)
		if _stall_frames_streak % stall_resend_frames == 0:
			_send_input_packet()


func _have_all_inputs(t: int) -> bool:
	if not _input_buf.has(t):
		return false
	var tick_buf: Dictionary = _input_buf[t]
	for provider in _all_providers:
		if not tick_buf.has(provider):
			return false
	return true


func _sample_and_send() -> void:
	if not _input_buf.has(_next_local_tick):
		_input_buf[_next_local_tick] = {}
	var tick_buf: Dictionary = _input_buf[_next_local_tick]
	for provider in _local_providers:
		var sampler := _local_samplers[provider] as Callable
		var sample: Variant = sampler.call(_next_local_tick)
		tick_buf[provider] = sample if sample is Dictionary else {}
	_next_local_tick += 1
	_send_input_packet()


func _send_input_packet() -> void:
	if _peer_net_ids.is_empty() or _next_local_tick <= input_delay + 1:
		return
	var t0 := maxi(input_delay + 1, _next_local_tick - redundancy)
	var last := _next_local_tick - 1
	# Shrink the window start past any leading ticks already trimmed from the
	# buffer (defensive; the local write path keeps this contiguous).
	while t0 <= last and not _input_buf.has(t0):
		t0 += 1

	var frames: Array = []
	for t in range(t0, last + 1):
		if not _input_buf.has(t):
			break
		var tick_buf: Dictionary = _input_buf[t]
		var frame := {}
		for provider in _local_providers:
			if tick_buf.has(provider):
				frame[String(provider)] = tick_buf[provider]
		frames.append(frame)
	if frames.is_empty():
		return

	var pkt := {"v": 1, "start": t0, "frames": frames}
	for net_id in _peer_net_ids:
		_rpc_input.rpc_id(net_id, pkt)
	_packets_sent += 1


func _compose_inputs(t: int) -> Dictionary:
	var tick_buf: Dictionary = _input_buf[t]
	var out := {}
	for provider in _all_providers:
		out[provider] = tick_buf[provider] as Dictionary
	return out


func _after_advance(t: int) -> void:
	var trim_before := t - (redundancy + input_delay)
	for key in _input_buf.keys():
		if key < trim_before:
			_input_buf.erase(key)

	if t % checksum_interval == 0:
		var h := _manager.get_tick_hash(t)
		if _remote_hashes.has(t):
			var remote: Dictionary = _remote_hashes[t]
			var remote_h: int = remote["hash"]
			var remote_peer: String = remote["peer"]
			if remote_h == h:
				_checksums_ok += 1
			else:
				_checksum_mismatches += 1
				desync_detected.emit({"tick": t, "local_hash": h, "remote_hash": remote_h, "peer_id": remote_peer})
			_remote_hashes.erase(t)
		else:
			_local_hashes[t] = h
		for net_id in _peer_net_ids:
			_rpc_checksum.rpc_id(net_id, t, h)

	var hash_trim_before := t - 600
	for key in _local_hashes.keys():
		if key < hash_trim_before:
			_local_hashes.erase(key)
	for key in _remote_hashes.keys():
		if key < hash_trim_before:
			_remote_hashes.erase(key)
