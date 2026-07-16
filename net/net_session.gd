# Phase-4 netcode: GGPO-style rollback. This drives a RollbackManager in
# externally_driven mode (advance_externally())
# using inputs gathered over a RollbackTransport's live MultiplayerAPI peer,
# but instead of stalling on missing remote input it PREDICTS (repeats the
# newest known input for that provider) and keeps simulating up to
# max_prediction ticks ahead of the last input-complete ("confirmed") tick.
# When a predicted input turns out wrong once the real one arrives, the
# session rolls back to the last snapshot before the misprediction and
# resimulates forward with corrected history (RollbackManager.resimulate()).
# A lightweight timescale nudge — built from a frame-advantage exchange
# piggybacked on every input packet — sleeps a few frames when this peer is
# running meaningfully ahead of its remote, so the two sims don't drift
# apart faster than rollback can absorb.
#
# Usage rules: this node must sit at an IDENTICAL node path on every peer
# before request_start() is called, and setup() must be called before the
# transport starts connecting — a remote hello can arrive the moment the
# engine-level connection is up, and the handler needs the transport to
# resolve the sender.
#
# Local input samplers are Callable(tick: int) -> Dictionary (input is
# always sampled input_delay ticks ahead of the tick it will apply to).
# max_prediction = 0 degenerates to input-delay lockstep (verified
# deadlock-free: the confirmed tick may run AHEAD of the sim) — the
# phase-3 RollbackLockstepSession was retired in phase 5 in its favor.
#
# Phase-5 hardening adds (a) throttle-gap detection + confirmed-input
# catch-up bursts for background-tab recovery, and (b) host-authoritative
# snapshot resync — on desync the lexicographically-smallest peer id
# broadcasts its confirmed snapshot and every peer, including the sender,
# hard-loads it (locked decision 6). Reloading the sender too keeps engine-
# internal physics history symmetric after the hard segment reset.
class_name RollbackNetSession
extends Node

# ============================================================================
# Signals / exports / public state
# ============================================================================

signal session_started()
signal session_failed(reason: String)
## Checksum exchange found a mismatch. {"tick": int, "local_hash": int,
## "remote_hash": int, "peer_id": String}.
signal desync_detected(report: Dictionary)
## A wall-clock gap >= throttle_gap_ms was detected between physics frames.
signal throttle_gap_detected(gap_ms: int)
## This peer (resync host) sent an authoritative snapshot for `tick`.
signal resync_sent(tick: int)
## This peer hard-loaded an authoritative snapshot for `tick` from the host.
signal resync_applied(tick: int)

## Ticks of input delay: local input sampled "for" tick T is applied at tick
## T. Must match on every peer.
@export var input_delay := 2
## How often (in ticks) to exchange a state checksum for desync detection.
@export var checksum_interval := 20
## Catch-up cap: how many ticks may be advanced in a single physics frame.
@export var max_ticks_per_frame := 4
## While stalled (prediction cap reached with nothing left to predict),
## resend our input window every N physics frames.
@export var stall_resend_frames := 12
## Each outgoing input packet carries up to this many of the most recent
## ticks, for resilience against a dropped unreliable packet.
@export var redundancy := 10
## Ticks the sim may run past the last confirmed tick before it must wait.
## Bounds how deep a rollback can ever need to go, so it must be <=
## manager.max_rollback_ticks — and must be equal on every peer.
@export var max_prediction := 8
## Frame-advantage difference (in ticks) that triggers a slowdown sleep.
@export var nudge_threshold := 1.5
## Physics frames to wait after a nudge before considering another one.
@export var nudge_cooldown_frames := 60
## Max frames slept per nudge.
@export var nudge_max_sleep := 8

## Per-frame tick cap while the sim is strictly BEHIND the confirmed tick —
## pure authoritative replay, no prediction risk. Lets a peer that was
## frozen (background-tab throttling) or reset by a resync burst back to
## real time instead of crawling at max_ticks_per_frame.
@export var catchup_ticks_per_frame := 12
## Wall-clock gap between physics frames (ms) treated as a throttle event
## (backgrounded tab / suspended process). On detection stale
## frame-advantage samples are dropped and the input window is resent.
@export var throttle_gap_ms := 500
## When true, the resync host (lexicographically smallest peer id — same
## rule as the transport's offer rule) answers a detected desync by sending
## its full snapshot; the other peer hard-loads it and continues.
@export var resync_enabled := true
## Minimum ticks between two resync sends (guards against re-sending for
## every mismatched checksum of one desync episode).
@export var resync_cooldown_ticks := 120

## Debug net-condition simulation, applied to OUTGOING session packets only.
## For harnesses/dev use; zero = disabled. This sits off the determinism
## boundary (it perturbs transport timing, not sim state), so wall-clock
## randomness here is fine.
@export var sim_latency_ms := 0
@export var sim_jitter_ms := 0
## Drop applies to unreliable input packets only (checksums stay reliable).
@export var sim_drop_percent := 0.0

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
var _peer_ids: Array[String] = []   # remote peer ids, captured at _begin() alongside _peer_net_ids
var _input_buf: Dictionary = {}     # tick:int -> {StringName provider: Dictionary input} (authoritative only)
var _next_local_tick := 0

var _last_frame_msec := -1
var _throttle_gaps := 0
var _resync_send_pending := false
var _last_resync_sent_tick := -1
var _resyncs_sent := 0
var _resyncs_applied := 0
var _authoritative_floor := 0   # ticks <= this are authoritative-by-resync: never roll back into them

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

var _confirmed_tick := 0        # highest tick with contiguous authoritative inputs for ALL providers from tick 1 (may run AHEAD of _manager.tick — early-arrived remote inputs count)
var _checksum_done := 0         # checksums emitted for interval multiples <= this
var _used_inputs: Dictionary = {}   # tick -> {provider: Dictionary} actually fed to the sim (prediction included)
var _last_known: Dictionary = {}    # provider StringName -> {"t": int, "input": Dictionary} newest authoritative input seen (prediction source)
var _rollback_from := -1        # earliest mispredicted simulated tick pending resim; -1 = none
var _last_compose_had_prediction := false  # set by _compose_inputs_predicted(); read by the advance loop

var _remote_adv := 0.0
var _adv_samples: Array = []    # rolling local frame-advantage samples, cap 16
var _local_adv := 0.0
var _sleep_frames := 0
var _nudge_cooldown := 0

var _sim_queue: Array = []      # pending delayed sends: {"due": int, "is_input": bool, "net_id": int, "pkt"/"t"/"h": ...}
var _sim_rng := RandomNumberGenerator.new()

var _rollbacks := 0
var _rollback_ticks_total := 0
var _max_rollback_depth := 0
var _predicted_ticks := 0       # ticks advanced live with >=1 predicted provider
var _sleep_frames_total := 0
var _sim_dropped := 0


func _ready() -> void:
	# Just after RollbackManager's -1000000, before all gameplay nodes.
	process_physics_priority = -999999
	_sim_rng.randomize()


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
	if max_prediction < 0:
		_fail("max_prediction must be >= 0")
		return
	if _manager != null and max_prediction > _manager.max_rollback_ticks:
		_fail("max_prediction exceeds manager.max_rollback_ticks")
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
		"max_prediction": max_prediction,
	}


func _send_hello() -> void:
	# Hellos are never queued through the sim-latency path — they're
	# handshake plumbing, not simulation traffic.
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


## Highest tick with contiguous authoritative input from every provider.
func get_confirmed_tick() -> int:
	return _confirmed_tick


func get_stats() -> Dictionary:
	return {
		"tick": _manager.tick if _manager else 0,
		"stall_frames": _stall_frames_total,
		"max_stall_streak": _max_stall_streak,
		"checksums_ok": _checksums_ok,
		"checksum_mismatches": _checksum_mismatches,
		"packets_sent": _packets_sent,
		"packets_received": _packets_received,
		"confirmed": _confirmed_tick,
		"rollbacks": _rollbacks,
		"rollback_ticks": _rollback_ticks_total,
		"max_rollback_depth": _max_rollback_depth,
		"predicted_ticks": _predicted_ticks,
		"sleep_frames": _sleep_frames_total,
		"sim_dropped": _sim_dropped,
		"local_adv": _local_adv,
		"remote_adv": _remote_adv,
		"throttle_gaps": _throttle_gaps,
		"resyncs_sent": _resyncs_sent,
		"resyncs_applied": _resyncs_applied,
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
		push_warning("RollbackNetSession: hello from unknown sender")
		return
	_hellos[peer_id] = payload
	_maybe_begin()


@rpc("any_peer", "call_remote", "unreliable")
func _rpc_input(pkt: Dictionary) -> void:
	var peer_id := _transport.get_peer_id(multiplayer.get_remote_sender_id())
	if peer_id.is_empty():
		push_warning("RollbackNetSession: input packet from unknown sender")
		return
	_packets_received += 1

	if running:
		var pkt_t := int(pkt.get("t", 0))
		var pkt_adv := float(pkt.get("adv", 0.0))
		_remote_adv = pkt_adv
		var rtt_ms := _transport.clock.get_rtt_ms(multiplayer.get_remote_sender_id())
		if rtt_ms < 0.0:
			rtt_ms = 0.0
		var rtt_ticks := rtt_ms * 60.0 / 1000.0
		var sample := float(_manager.tick) - (float(pkt_t) + rtt_ticks * 0.5)
		_adv_samples.append(sample)
		if _adv_samples.size() > 16:
			_adv_samples.pop_front()
		var sum := 0.0
		for s in _adv_samples:
			sum += s as float
		_local_adv = sum / _adv_samples.size()

	var start := int(pkt.get("start", 0))
	var frames_v: Variant = pkt.get("frames", [])
	if not (frames_v is Array):
		return
	var frames := frames_v as Array

	for i in range(frames.size()):
		var t := start + i
		if t < 1 or t > _manager.tick + 600:
			continue
		if t <= _confirmed_tick:
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
				# First write wins — sender never rewrites a tick.
				continue
			var input_v: Variant = frame[provider_key]
			var input: Dictionary = input_v if input_v is Dictionary else {}
			tick_buf[provider] = input

			var lk_is_newer := true
			if _last_known.has(provider):
				var lk: Dictionary = _last_known[provider]
				var lk_t := int(lk.get("t", -1))
				lk_is_newer = t > lk_t
			if lk_is_newer:
				_last_known[provider] = {"t": t, "input": input}

			# Unlike lockstep, do NOT skip already-simulated ticks: check
			# whether this authoritative input contradicts what we already
			# fed the sim (a prediction) and flag it for rollback.
			if t <= _manager.tick and t > _authoritative_floor:
				var used_tick: Dictionary = {}
				if _used_inputs.has(t):
					used_tick = _used_inputs[t]
				var used_v: Variant = used_tick.get(provider)
				if not (used_v is Dictionary) or (used_v as Dictionary) != input:
					_rollback_from = t if _rollback_from < 0 else mini(_rollback_from, t)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_checksum(t: int, h: int) -> void:
	var peer_id := _transport.get_peer_id(multiplayer.get_remote_sender_id())
	if peer_id.is_empty():
		push_warning("RollbackNetSession: checksum from unknown sender")
		return
	if _local_hashes.has(t):
		var local_h: int = _local_hashes[t]
		if local_h == h:
			_checksums_ok += 1
		else:
			_checksum_mismatches += 1
			desync_detected.emit({"tick": t, "local_hash": local_h, "remote_hash": h, "peer_id": peer_id})
			if resync_enabled and _is_resync_host():
				_resync_send_pending = true
		_local_hashes.erase(t)
	else:
		_remote_hashes[t] = {"hash": h, "peer": peer_id}


@rpc("any_peer", "call_remote", "reliable")
func _rpc_resync(t: int, states: Dictionary, h: int) -> void:
	if not running:
		return
	var peer_id := _transport.get_peer_id(multiplayer.get_remote_sender_id())
	if peer_id.is_empty():
		push_warning("RollbackNetSession: resync from unknown sender")
		return
	if _is_resync_host():
		push_warning("RollbackNetSession: ignoring resync — this peer is the resync host")
		return
	if t <= _authoritative_floor:
		return  # stale duplicate of an already-applied resync
	if not _apply_authoritative_snapshot(t, states, h):
		return
	_resyncs_applied += 1
	resync_applied.emit(t)


## Apply one hard-resync snapshot and discard all timeline bookkeeping that
## referred to the pre-resync history. Used by both receiver and sender: the
## sender must traverse the same load boundary so PhysicsServer caches and
## restore hooks cannot remain asymmetric after an otherwise-identical reset.
func _apply_authoritative_snapshot(t: int, states: Dictionary, h: int) -> bool:
	if not _manager.load_authoritative_snapshot(t, states):
		_fail("resync load failed at tick %d" % t)
		return false
	if _manager.get_tick_hash(t) != h:
		_fail("resync state did not round-trip (save/load asymmetry) at tick %d" % t)
		return false
	_authoritative_floor = t
	_rollback_from = -1
	_used_inputs.clear()
	_local_hashes.clear()
	_remote_hashes.clear()
	_checksum_done = t
	return true


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
		if int(hello.get("max_prediction", -1)) != max_prediction:
			_fail("max_prediction mismatch with %s" % peer_id)
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
	_peer_ids.clear()
	for peer_id in _transport.get_ready_peers():
		_peer_net_ids.append(_transport.get_net_id(peer_id))
		_peer_ids.append(peer_id)

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


## The resync host is the peer whose id sorts lexicographically first —
## the same deterministic rule the transport uses for the WebRTC offer.
func _is_resync_host() -> bool:
	for peer_id in _peer_ids:
		if peer_id < _transport.local_peer_id:
			return false
	return true


func _fail(reason: String) -> void:
	push_error("RollbackNetSession: " + reason)
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

	var now_msec := Time.get_ticks_msec()
	if _last_frame_msec >= 0 and now_msec - _last_frame_msec >= throttle_gap_ms:
		_throttle_gaps += 1
		# Frame-advantage samples from before the freeze are meaningless.
		_adv_samples.clear()
		_sleep_frames = 0
		_send_input_packet()
		throttle_gap_detected.emit(int(now_msec - _last_frame_msec))
	_last_frame_msec = now_msec

	_apply_pending_rollback()
	if not running:
		return  # a failed resimulate _fail()s and stops the session mid-frame
	_update_confirmed()  # must run AFTER rollback so checksum hashes reflect corrections
	if _resync_send_pending:
		_resync_send_pending = false
		_maybe_send_resync()

	if _nudge_cooldown > 0:
		_nudge_cooldown -= 1
	if _sleep_frames > 0:
		# Voluntary slowdown to let a fast-running peer's remote catch up —
		# not a stall (nothing is missing, we're choosing to wait).
		_sleep_frames -= 1
		_sleep_frames_total += 1
		return
	elif _adv_samples.size() >= 8 and _nudge_cooldown == 0:
		var nudge := (_local_adv - _remote_adv) * 0.5
		if nudge >= nudge_threshold:
			_sleep_frames = mini(int(ceil(nudge)), nudge_max_sleep)
			_nudge_cooldown = nudge_cooldown_frames

	var frame_cap := max_ticks_per_frame
	if _manager.tick < _confirmed_tick:
		# Strictly behind authoritative input: pure replay, safe to burst.
		frame_cap = maxi(frame_cap, catchup_ticks_per_frame)
	var advanced := 0
	while advanced < frame_cap:
		var target := _manager.tick + 1
		if target > _confirmed_tick + max_prediction:
			break  # prediction cap: bounds rollback depth to the snapshot window
		_sample_and_send(target)
		var inputs := _compose_inputs_predicted(target)
		_used_inputs[target] = inputs
		if _last_compose_had_prediction:
			_predicted_ticks += 1
		_manager.advance_externally(inputs)
		_after_advance(target)
		advanced += 1
		_update_confirmed()  # a local sample may complete future ticks; cheap
	if advanced > 0:
		_stall_frames_streak = 0
	else:
		_stall_frames_streak += 1
		_stall_frames_total += 1
		_max_stall_streak = maxi(_max_stall_streak, _stall_frames_streak)
		if _stall_frames_streak == 30:
			# Peer likely frozen (throttled tab): our advantage samples are stale.
			_adv_samples.clear()
		if _stall_frames_streak % stall_resend_frames == 0:
			_send_input_packet()


func _sample_and_send(target: int) -> void:
	# Sample exactly up to target + input_delay. After a resync rewinds the
	# sim, target regresses below already-sampled ticks — the guard stops
	# local input from being re-sampled (which would permanently inflate
	# effective input latency).
	while _next_local_tick <= target + input_delay:
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

	var pkt := {"v": 1, "start": t0, "frames": frames, "t": _manager.tick, "adv": _local_adv}
	for net_id in _peer_net_ids:
		_queue_send(true, net_id, {"pkt": pkt})
	_packets_sent += 1


func _after_advance(t: int) -> void:
	# Checksums are exchanged from _update_confirmed() (once a tick is
	# confirmed, not merely simulated), so this is trimming only.
	var trim_before := t - (redundancy + input_delay + max_prediction + 2)
	for key in _input_buf.keys():
		if key < trim_before:
			_input_buf.erase(key)
	for key in _used_inputs.keys():
		if key < trim_before:
			_used_inputs.erase(key)

	var hash_trim_before := t - 600
	for key in _local_hashes.keys():
		if key < hash_trim_before:
			_local_hashes.erase(key)
	for key in _remote_hashes.keys():
		if key < hash_trim_before:
			_remote_hashes.erase(key)


# ============================================================================
# Prediction / rollback
# ============================================================================


## Composes the inputs for tick t: authoritative where we have it, else the
## newest known input for that provider (prediction), else neutral {}.
## Also sets _last_compose_had_prediction so callers can track how much of
## the sim is currently running on guesses.
func _compose_inputs_predicted(t: int) -> Dictionary:
	_last_compose_had_prediction = false
	var out := {}
	var tick_buf: Dictionary = {}
	if _input_buf.has(t):
		tick_buf = _input_buf[t]
	for provider in _all_providers:
		if tick_buf.has(provider):
			out[provider] = tick_buf[provider]
		elif _last_known.has(provider):
			var lk: Dictionary = _last_known[provider]
			out[provider] = lk["input"]
			_last_compose_had_prediction = true
		else:
			out[provider] = {}
			_last_compose_had_prediction = true
	return out


func _apply_pending_rollback() -> void:
	if _rollback_from < 0:
		return
	if _rollback_from <= _authoritative_floor:
		_rollback_from = _authoritative_floor + 1
		if _rollback_from > _manager.tick:
			_rollback_from = -1
			return
	var base := _rollback_from - 1
	if base >= _manager.tick:
		# Nothing simulated past it — shouldn't happen, but nothing to do.
		_rollback_from = -1
		return
	var inputs_by_tick := {}
	for t in range(base + 1, _manager.tick + 1):
		var inputs := _compose_inputs_predicted(t)
		inputs_by_tick[t] = inputs
		# Resim's predictions are the new comparison baseline.
		_used_inputs[t] = inputs
	var depth := _manager.tick - base
	if not _manager.resimulate(base, inputs_by_tick):
		_fail("rollback resimulate failed at base %d" % base)
		return
	_rollbacks += 1
	_rollback_ticks_total += depth
	_max_rollback_depth = maxi(_max_rollback_depth, depth)
	_rollback_from = -1


# ============================================================================
# Confirmed tick / checksums
# ============================================================================


func _update_confirmed() -> void:
	var t := _confirmed_tick + 1
	while _input_buf.has(t):
		var tick_buf: Dictionary = _input_buf[t]
		var complete := true
		for provider in _all_providers:
			if not tick_buf.has(provider):
				complete = false
				break
		if not complete:
			break
		_confirmed_tick = t
		t += 1

	var limit := mini(_confirmed_tick, _manager.tick)
	for t2 in range(_checksum_done + 1, limit + 1):
		if t2 % checksum_interval == 0:
			_exchange_checksum(t2)
	_checksum_done = limit


func _exchange_checksum(t: int) -> void:
	var h := _manager.get_tick_hash(t)
	if h == -1:
		push_warning("RollbackNetSession: no snapshot hash for tick %d" % t)
		return
	if _remote_hashes.has(t):
		var remote: Dictionary = _remote_hashes[t]
		var remote_h: int = remote["hash"]
		var remote_peer: String = remote["peer"]
		if remote_h == h:
			_checksums_ok += 1
		else:
			_checksum_mismatches += 1
			desync_detected.emit({"tick": t, "local_hash": h, "remote_hash": remote_h, "peer_id": remote_peer})
			if resync_enabled and _is_resync_host():
				_resync_send_pending = true
		_remote_hashes.erase(t)
	else:
		_local_hashes[t] = h
	for net_id in _peer_net_ids:
		_queue_send(false, net_id, {"t": t, "h": h})


## Host answer to a desync: broadcast the authoritative snapshot at the
## newest tick that is both simulated and confirmed — that state is fully
## post-correction (no predictions baked in) and its snapshot is guaranteed
## still retained (tick - confirmed <= max_prediction <= max_rollback_ticks).
## Bypasses the debug sim-latency queue: resync is control-plane, like hello.
func _maybe_send_resync() -> void:
	var t := mini(_confirmed_tick, _manager.tick)
	if t < 1:
		return
	if _last_resync_sent_tick >= 0 and t - _last_resync_sent_tick < resync_cooldown_ticks:
		return
	var states := _manager.get_snapshot_states(t)
	if states.is_empty():
		push_warning("RollbackNetSession: no snapshot to resync at tick %d" % t)
		return
	var h := _manager.get_tick_hash(t)
	for net_id in _peer_net_ids:
		_rpc_resync.rpc_id(net_id, t, states, h)
	# Reset the authoritative sender through the same load path as receivers.
	# Without this, only the receiver flushes restore hooks/physics transforms,
	# so a rotated kinematic actor can diverge later despite matching snapshots.
	if not _apply_authoritative_snapshot(t, states, h):
		return
	_last_resync_sent_tick = t
	_resyncs_sent += 1
	resync_sent.emit(t)


# ============================================================================
# Sim-queue (debug net-condition simulation)
# ============================================================================


func _process(_delta: float) -> void:
	if _sim_queue.is_empty():
		return
	var now := Time.get_ticks_msec()
	var remaining: Array = []
	for entry_v in _sim_queue:
		var entry := entry_v as Dictionary
		var due := int(entry.get("due", 0))
		if due > now:
			remaining.append(entry)
			continue
		var net_id := int(entry.get("net_id", 0))
		var is_input := entry.get("is_input", false) as bool
		if is_input:
			var pkt: Dictionary = entry.get("pkt", {})
			_rpc_input.rpc_id(net_id, pkt)
		else:
			_rpc_checksum.rpc_id(net_id, int(entry.get("t", 0)), int(entry.get("h", 0)))
	_sim_queue = remaining


## Routes an outgoing session packet either straight out (all sim knobs
## zero/off) or through _sim_queue with simulated latency/jitter/drop.
## Jitter reordering the reliable checksum stream is harmless — _rpc_checksum
## is tick-keyed, not order-dependent.
func _queue_send(is_input: bool, net_id: int, payload: Dictionary) -> void:
	if sim_latency_ms == 0 and sim_jitter_ms == 0 and sim_drop_percent <= 0.0:
		if is_input:
			var pkt: Dictionary = payload.get("pkt", {})
			_rpc_input.rpc_id(net_id, pkt)
		else:
			_rpc_checksum.rpc_id(net_id, int(payload.get("t", 0)), int(payload.get("h", 0)))
		return

	if is_input and sim_drop_percent > 0.0 and _sim_rng.randf() * 100.0 < sim_drop_percent:
		_sim_dropped += 1
		return

	var now := Time.get_ticks_msec()
	var jitter := int(_sim_rng.randf_range(-float(sim_jitter_ms), float(sim_jitter_ms)))
	var due := maxi(now, now + sim_latency_ms + jitter)
	var entry := payload.duplicate()
	entry["due"] = due
	entry["is_input"] = is_input
	entry["net_id"] = net_id
	_sim_queue.append(entry)
