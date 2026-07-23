## Phase-4 netcode: GGPO-style rollback. This drives a RollbackManager in
## externally_driven mode (advance_externally())
## using inputs gathered over a RollbackTransport's live MultiplayerAPI peer,
## but instead of stalling on missing remote input it PREDICTS (repeats the
## newest known input for that provider) and keeps simulating up to
## max_prediction ticks ahead of the last input-complete ("confirmed") tick.
## When a predicted input turns out wrong once the real one arrives, the
## session rolls back to the last snapshot before the misprediction and
## resimulates forward with corrected history (RollbackManager.resimulate()).
## A lightweight timescale nudge — built from a frame-advantage exchange
## piggybacked on every input packet — sleeps a few frames when this peer is
## running meaningfully ahead of its remote, so the two sims don't drift
## apart faster than rollback can absorb.
##
## Usage rules: this node must sit at an IDENTICAL node path on every peer
## before request_start() is called, and setup() must be called before the
## transport starts connecting — a remote hello can arrive the moment the
## engine-level connection is up, and the handler needs the transport to
## resolve the sender.
##
## Local input samplers are Callable(tick: int) -> Dictionary (input is
## always sampled input_delay ticks ahead of the tick it will apply to).
## max_prediction = 0 degenerates to input-delay lockstep (verified
## deadlock-free: the confirmed tick may run AHEAD of the sim) — the
## phase-3 RollbackLockstepSession was retired in phase 5 in its favor.
##
## Phase-5 hardening adds (a) throttle-gap detection + confirmed-input
## catch-up bursts for background-tab recovery, and (b) host-authoritative
## snapshot resync — on desync the lexicographically-smallest peer id
## broadcasts its confirmed snapshot and every peer, including the sender,
## hard-loads it (locked decision 6). Reloading the sender too keeps engine-
## internal physics history symmetric after the hard segment reset.
class_name RollbackNetSession
extends Node

## RollbackTimeSync/RollbackNetSim are internal helpers with no class_name (kept
## out of the global class namespace); preload under the same identifiers so
## every existing `RollbackTimeSync.new()` / `RollbackNetSim.new()` call site
## below keeps working unchanged.
const RollbackTimeSync := preload("time_sync.gd")
const RollbackNetSim := preload("net_sim.gd")

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

## Per-frame tick cap while the sim is strictly BEHIND the confirmed tick —
## pure authoritative replay, no prediction risk. Lets a peer that was
## frozen (background-tab throttling) or reset by a resync burst back to
## real time in a burst instead of the normal one-tick-per-frame wall-clock
## pace.
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
## Test-only: drop the first N outgoing input packets (deterministic loss).
@export var sim_drop_first_inputs := 0:
	set(v):
		sim_drop_first_inputs = v
		_net_sim.drop_first_inputs = v

var running := false

# ============================================================================
# Internal state
# ============================================================================

var _manager: RollbackManager
var _transport: RollbackTransport

var _local_providers: Array[StringName] = []
var _local_samplers: Dictionary = {}        # StringName -> Callable(tick:int) -> Dictionary
var _remote_provider_peer: Dictionary = {}  # StringName provider -> String peer_id
var _all_providers: Array[StringName] = []  # lexically sorted union of local + remote providers (wire contract: packed input indexes into this array — see _lexical_less)

## Optional per-provider input serializer. When set, input packets serialize to
## a compact PackedByteArray (via _rpc_input_packed) instead of the variant
## Dictionary (_rpc_input), and every locally-sampled input is canonicalized
## through it so the local sim matches the bytes the peer decodes. Null = legacy.
var input_codec: RollbackInputCodec = null

var _peer_net_ids: Array[int] = []  # remote peers' engine net ids, captured at _begin()
var _peer_ids: Array[String] = []   # remote peer ids, captured at _begin() alongside _peer_net_ids
var _input_buf: Dictionary = {}     # tick:int -> {StringName provider: Dictionary input} (authoritative only)
var _next_local_tick := 0

var _last_frame_msec := -1
## Physics-frame epoch anchoring the sim to real time: the sim never
## advances past (Engine.get_physics_frames() - _tick_epoch_frames) ticks.
## -1 = unset, armed on the first running frame. Nudge sleeps shift the
## epoch forward (a deliberate, permanent slowdown to match the peer);
## throttle freezes re-anchor it entirely (a frozen span is not gameplay
## the sim owes anyone).
var _tick_epoch_frames := -1
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

# Receive-path diagnostics — debug counters, off the determinism boundary;
# they discriminate transport loss (packets_received flat) from silent
# ingest discards (a reject/skip counter climbing) during a live stall.
var _recv_unknown_sender := 0
var _recv_rejected := 0
var _recv_reject_reason := ""
var _ingest_unknown_provider := 0
var _ingest_wrong_peer := 0
var _ingest_out_of_range := 0
var _ingest_stale := 0
var _ingest_applied := 0

var _confirmed_tick := 0        # highest tick with contiguous authoritative inputs for ALL providers from tick 1 (may run AHEAD of _manager.tick — early-arrived remote inputs count)
var _checksum_done := 0         # checksums emitted for interval multiples <= this
var _used_inputs: Dictionary = {}   # tick -> {provider: Dictionary} actually fed to the sim (prediction included)
var _last_known: Dictionary = {}    # provider StringName -> {"t": int, "input": Dictionary} newest authoritative input seen (prediction source)
var _rollback_from := -1        # earliest mispredicted simulated tick pending resim; -1 = none
var _last_compose_had_prediction := false  # set by _compose_inputs_predicted(); read by the advance loop

var _time_sync := RollbackTimeSync.new()

var _net_sim := RollbackNetSim.new()

var _rollbacks := 0
var _rollback_ticks_total := 0
var _max_rollback_depth := 0
var _predicted_ticks := 0       # ticks advanced live with >=1 predicted provider
var _sleep_frames_total := 0


func _ready() -> void:
	# Just after RollbackManager's -1000000, before all gameplay nodes.
	process_physics_priority = -999999
	_net_sim.dispatch = _dispatch_packet
	_net_sim.randomize()


# ============================================================================
# Setup / API
# ============================================================================


func setup(manager: RollbackManager, transport: RollbackTransport) -> void:
	_manager = manager
	_transport = transport
	_transport.peer_lost.connect(_on_peer_lost)


## StringName's `<` compares intern-pointer addresses — process-history-
## dependent, so Array[StringName].sort() is NOT stable across peers. Every
## provider ordering that crosses the wire (or feeds a cross-peer-compared
## set) must sort lexically through this instead.
static func _lexical_less(a: StringName, b: StringName) -> bool:
	return String(a) < String(b)


## sampler is called as sampler.call(t) and must return a POD Dictionary for
## tick t.
func add_local_provider(id: StringName, sampler: Callable) -> void:
	if not _local_samplers.has(id):
		_local_providers.append(id)
		_local_providers.sort_custom(_lexical_less)
	_local_samplers[id] = sampler
	_add_provider(id)


func add_remote_provider(id: StringName, peer_id: String) -> void:
	_remote_provider_peer[id] = peer_id
	_add_provider(id)


func _add_provider(id: StringName) -> void:
	if not _all_providers.has(id):
		_all_providers.append(id)
		_all_providers.sort_custom(_lexical_less)


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
	_local_providers.sort_custom(_lexical_less)
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
		"sim_dropped": _net_sim.dropped,
		"local_adv": _time_sync.local_adv,
		"remote_adv": _time_sync.remote_adv,
		"throttle_gaps": _throttle_gaps,
		"resyncs_sent": _resyncs_sent,
		"resyncs_applied": _resyncs_applied,
		"running": running,
		"peers": _peer_net_ids.size(),
		"recv_unknown_sender": _recv_unknown_sender,
		"recv_rejected": _recv_rejected,
		"recv_reject_reason": _recv_reject_reason,
		"ingest_unknown_provider": _ingest_unknown_provider,
		"ingest_wrong_peer": _ingest_wrong_peer,
		"ingest_out_of_range": _ingest_out_of_range,
		"ingest_stale": _ingest_stale,
		"ingest_applied": _ingest_applied,
		"providers_digest": _providers_digest(),
		"remote_map_digest": _remote_map_digest(),
	}


## Cross-peer comparable fingerprints: the two screens' digests must match.
func _providers_digest() -> int:
	var s := ""
	for p in _all_providers:
		s += String(p) + "|"
	return s.hash()


func _remote_map_digest() -> int:
	# Keys are StringNames; stringify BEFORE sorting so this sorts lexically
	# (plain String < IS lexical) instead of by intern-pointer address.
	var keys: Array[String] = []
	for k in _remote_provider_peer.keys():
		keys.append(String(k))
	keys.sort()
	var s := ""
	for k in keys:
		s += k + ":" + String(_remote_provider_peer[StringName(k)]) + "|"
	return s.hash()


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
		_recv_unknown_sender += 1
		return
	_packets_received += 1
	if running:
		_update_adv_estimate(int(pkt.get("t", 0)), float(pkt.get("adv", 0.0)))
	var start := int(pkt.get("start", 0))
	var frames_v: Variant = pkt.get("frames", [])
	if not (frames_v is Array):
		_recv_rejected += 1
		_recv_reject_reason = "frames_not_array"
		return
	_ingest_frames(peer_id, start, frames_v as Array)


@rpc("any_peer", "call_remote", "unreliable")
func _rpc_input_packed(buf: PackedByteArray) -> void:
	var peer_id := _transport.get_peer_id(multiplayer.get_remote_sender_id())
	if peer_id.is_empty():
		push_warning("RollbackNetSession: packed input from unknown sender")
		_recv_unknown_sender += 1
		return
	if input_codec == null:
		_recv_rejected += 1
		_recv_reject_reason = "codec_null"
		return
	_packets_received += 1
	var spb := StreamPeerBuffer.new()
	spb.data_array = buf
	spb.seek(0)
	if spb.get_available_bytes() < 4 or spb.get_u8() != 2:
		_recv_rejected += 1
		_recv_reject_reason = "bad_header"
		return
	var p_count := spb.get_u8()
	var providers: Array[StringName] = []
	for _i in p_count:
		var idx := spb.get_u8()
		if idx >= _all_providers.size():
			_recv_rejected += 1
			_recv_reject_reason = "bad_provider_idx"
			return
		providers.append(_all_providers[idx])
	var f_count := spb.get_u8()
	var start := spb.get_u32()
	var pkt_t := int(spb.get_u32())
	var pkt_adv := spb.get_float()
	if running:
		_update_adv_estimate(pkt_t, pkt_adv)
	var off := spb.get_position()
	var frames: Array = []
	for _fi in f_count:
		var frame := {}
		for pi in p_count:
			var res := input_codec.decode_input(buf, off)
			off = int(res["next"])
			frame[String(providers[pi])] = res["input"]
		frames.append(frame)
	_ingest_frames(peer_id, start, frames)


## Fetch the sender's RTT (only valid inside an input RPC) and fold this
## packet's advantage report into the RollbackTimeSync estimate.
func _update_adv_estimate(pkt_t: int, pkt_adv: float) -> void:
	var rtt_ms := _transport.clock.get_rtt_ms(multiplayer.get_remote_sender_id())
	if rtt_ms < 0.0:
		rtt_ms = 0.0
	_time_sync.record_sample(_manager.tick, pkt_t, pkt_adv, rtt_ms)


## Input-window routing shared by both input RPCs (verbatim from the old
## _rpc_input routing loop). `frames` is an Array of {provider_string: input_dict}.
func _ingest_frames(peer_id: String, start: int, frames: Array) -> void:
	for i in range(frames.size()):
		var t := start + i
		if t < 1 or t > _manager.tick + 600:
			_ingest_out_of_range += 1
			continue
		if t <= _confirmed_tick:
			_ingest_stale += 1
			continue
		var frame_v: Variant = frames[i]
		if not (frame_v is Dictionary):
			continue
		var frame := frame_v as Dictionary
		for provider_key in frame:
			var provider := StringName(String(provider_key))
			if not _remote_provider_peer.has(provider):
				_ingest_unknown_provider += 1
				continue
			if (_remote_provider_peer[provider] as String) != peer_id:
				_ingest_wrong_peer += 1
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
			_ingest_applied += 1

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
	# Must sort the same way as _expected_providers_for_peer() below — both
	# feed the equality check in _maybe_begin(), and mixing lexical with
	# pointer order there would produce false "provider map mismatch" fails.
	out.sort_custom(_lexical_less)
	return out


func _expected_providers_for_peer(peer_id: String) -> Array[StringName]:
	var out: Array[StringName] = []
	for provider in _remote_provider_peer:
		if (_remote_provider_peer[provider] as String) == peer_id:
			out.append(provider as StringName)
	# See _hello_provider_set() — must sort lexically to compare equal.
	out.sort_custom(_lexical_less)
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

	if _tick_epoch_frames < 0:
		_tick_epoch_frames = int(Engine.get_physics_frames()) - _manager.tick

	var now_msec := Time.get_ticks_msec()
	if _last_frame_msec >= 0 and now_msec - _last_frame_msec >= throttle_gap_ms:
		_throttle_gaps += 1
		# Frame-advantage samples from before the freeze are meaningless.
		_time_sync.reset()
		_tick_epoch_frames = int(Engine.get_physics_frames()) - _manager.tick
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

	# Proportional-drip time-sync: bleed off this peer's lead over the shared
	# midpoint smoothly (a mild slow-mo) instead of a visible multi-frame freeze.
	# gap = how far ahead of the midpoint we are, in ticks. Sleeping one frame
	# shifts the epoch (a permanent slowdown); as we slow, gap -> 0 and the drip
	# self-limits. NUDGE_MAX_RATE caps sleep frequency so the leader never freezes.
	if _time_sync.should_sleep_frame(nudge_threshold):
		_sleep_frames_total += 1
		_tick_epoch_frames += 1
		return

	# Real-time anchor: the sim may never outrun the physics-frame schedule
	# (one tick per 60Hz physics frame since the session epoch). Without an
	# absolute clock, any advance policy keyed only on the prediction window
	# or the confirmed tick lets two peers pace each other instead of the
	# wall — measured in practice as sustained ~1.3-3x fast-forward on
	# low-latency links. Behind schedule (post-stall / post-throttle /
	# post-resync) the sim bursts back at up to catchup_ticks_per_frame,
	# still bounded by the prediction window below.
	var wall_target := int(Engine.get_physics_frames()) - _tick_epoch_frames
	var frame_cap := clampi(wall_target - _manager.tick, 0, catchup_ticks_per_frame)
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
	elif frame_cap > 0:
		# frame_cap == 0 means we're at/ahead of schedule on purpose — not a
		# stall (nothing was supposed to advance this frame).
		# Latency stalls owe the wall clock nothing: re-anchor the epoch here
		# so the stall accrues no wall-clock debt, which would otherwise be
		# paid off later as a fast-forward burst that fights the nudge and
		# re-opens the peer gap.
		_tick_epoch_frames = int(Engine.get_physics_frames()) - _manager.tick
		_stall_frames_streak += 1
		_stall_frames_total += 1
		_max_stall_streak = maxi(_max_stall_streak, _stall_frames_streak)
		if _stall_frames_streak == 30:
			# Peer likely frozen (throttled tab): our advantage samples are stale.
			_time_sync.clear_samples()
		if _stall_frames_streak % stall_resend_frames == 0:
			# Full window, not the normal redundancy-sized one: a peer that ran
			# ahead of us has already confirmed past our recent ticks, so its
			# resend window sits beyond the hole it's missing — only ticks
			# older than the normal window can still reach it.
			_send_input_packet(true)


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
			var sample_dict: Dictionary = sample if sample is Dictionary else {}
			# Canonicalize through the codec so the local sim uses the exact value
			# the peer will decode from the wire (quantization must not diverge).
			if input_codec != null and not sample_dict.is_empty():
				sample_dict = input_codec.canonicalize(sample_dict)
			tick_buf[provider] = sample_dict
		_next_local_tick += 1
		_send_input_packet()


## Send the local input window to all peers. Normal sends (full_window=false)
## cover the last `redundancy` ticks, resent every tick to survive isolated
## packet loss. `full_window` (stall resends) instead covers everything still
## in `_input_buf`: a peer that ran ahead confirms through our last sampled
## tick and parks its own resend window permanently past a hole in ours (the
## normal redundancy window on either side never reaches back far enough to
## cover it again) — the startup-loss deadlock this recovers from.
func _send_input_packet(full_window := false) -> void:
	if _peer_net_ids.is_empty() or _next_local_tick <= input_delay + 1:
		return
	var t0 := input_delay + 1 if full_window else maxi(input_delay + 1, _next_local_tick - redundancy)
	var last := _next_local_tick - 1
	t0 = maxi(t0, last - 254)  # packed wire format: u8 frame count
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

	if input_codec != null:
		# frames may be shorter than [t0, last] if the collection loop above
		# broke on a buffer hole; encode only the contiguous run it gathered
		# so the encoder never indexes a tick that isn't actually buffered.
		var buf := _encode_packed_input(t0, t0 + frames.size() - 1)
		if buf.is_empty():
			return
		for net_id in _peer_net_ids:
			_net_sim.queue_send(true, net_id, {"buf": buf}, sim_latency_ms, sim_jitter_ms, sim_drop_percent)
		_packets_sent += 1
		return

	var pkt := {"v": 1, "start": t0, "frames": frames, "t": _manager.tick, "adv": _time_sync.local_adv}
	for net_id in _peer_net_ids:
		_net_sim.queue_send(true, net_id, {"pkt": pkt}, sim_latency_ms, sim_jitter_ms, sim_drop_percent)
	_packets_sent += 1


## Compact wire form of the input window [t0, last] for all local providers.
## Layout (StreamPeerBuffer, little-endian): u8 version=2, u8 provider_count P,
## P × u8 provider index into _all_providers, u8 frame_count F, u32 start,
## u32 t, f32 adv, then F frames × P providers × codec bytes (providers in
## _local_providers sorted order; the index list lets the peer map them back).
func _encode_packed_input(t0: int, last: int) -> PackedByteArray:
	var spb := StreamPeerBuffer.new()
	spb.put_u8(2)
	var providers := _local_providers
	spb.put_u8(providers.size())
	for provider in providers:
		spb.put_u8(_all_providers.find(provider))
	spb.put_u8(last - t0 + 1)
	spb.put_u32(t0)
	spb.put_u32(_manager.tick)
	spb.put_float(_time_sync.local_adv)
	for t in range(t0, last + 1):
		var tick_buf: Dictionary = _input_buf[t]
		for provider in providers:
			var input: Dictionary = tick_buf[provider] if tick_buf.has(provider) else {}
			spb.put_data(input_codec.encode_input(input))
	return spb.data_array


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

	# Publish the manager mirror only after pending rollback has already
	# corrected simulated history (the tick loop calls this function after
	# rollback). This is non-snapshot metadata for registered presentation consumers.
	_manager.confirmed_tick = _confirmed_tick
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
		_net_sim.queue_send(false, net_id, {"t": t, "h": h}, sim_latency_ms, sim_jitter_ms, sim_drop_percent)


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
# Outgoing-packet dispatch (+ debug net-condition simulation via RollbackNetSim)
# ============================================================================


func _process(_delta: float) -> void:
	_net_sim.process()


## The real outgoing dispatch: performs the actual @rpc call. RollbackNetSim
## calls this for packets that survive its latency/jitter/drop simulation, and
## immediately (from queue_send) when all sim knobs are off. The @rpc methods
## must live on this Node, which is why dispatch routes back here rather than
## living in the helper.
func _dispatch_packet(is_input: bool, net_id: int, payload: Dictionary) -> void:
	if is_input:
		if payload.has("buf"):
			_rpc_input_packed.rpc_id(net_id, payload["buf"] as PackedByteArray)
		else:
			_rpc_input.rpc_id(net_id, payload.get("pkt", {}))
	else:
		_rpc_checksum.rpc_id(net_id, int(payload.get("t", 0)), int(payload.get("h", 0)))
