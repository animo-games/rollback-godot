## Encapsulates the determinism-order-sensitive standup of a networked rollback
## session. It owns a persistent duck-typed connection and the per-segment
## RollbackNetSession, and drives the exact ordering the stack requires: the
## session node exists at its path before the world is built (so a peer's hello
## RPC can't miss it); the transport is started once, after the first segment's
## build (build-before-start is load-bearing for web WebRTC readiness); setup +
## signal wiring happen before transport.start(); providers are registered only
## after the peer resolves; then request_start() + await session_started.
##
## The GAME still owns building the world (manager + actors + registration) and
## deciding when to transition between segments — pass the world build as a
## callback to run_segment(), and run your own transition loop between segments.
##
## Add this node at an IDENTICAL node path on every peer: it names its transport
## child "Transport" and its session children "Session<N>", and those paths must
## match across peers for the RPCs to route.
class_name RollbackSessionController
extends Node

## Ticks of input delay; applied to each segment's session. Must match on every peer.
@export var input_delay: int = 1
## Prediction window; must be <= manager.max_rollback_ticks and equal on every peer.
@export var max_prediction: int = 8
## Ticks between checksum exchanges. Must match on every peer.
@export var checksum_interval: int = 20
## Seconds to wait for transport_ready / session_started before failing a segment.
@export var handshake_timeout_sec: float = 60.0

## The persistent connection, supplied to begin() or created as the legacy
## RollbackTransport compatibility path. Survives across segments.
var transport
## Rollback-specific wall clock attached below Transport to preserve the
## historical Transport/NetClock RPC path without making SDK connections own it.
var clock: RollbackNetClock
## Optional compact input codec applied to every segment's session. Must be
## stateless (encode/decode/canonicalize are pure). Null = the default
## variant-Dictionary wire path.
var input_codec: RollbackInputCodec

signal peer_ready(peer_id: String)
signal segment_started(seg_index: int, session: RollbackNetSession)
signal segment_failed(reason: String)
## Re-emitted from the active session so the game can handle desyncs in one place.
signal desync_detected(report: Dictionary)

var _start_source
var _transport_started: bool = false
var _transport_ready: bool = false
var _ready_peers: Array[String] = []
var _local_specs: Array = []   # [{ "id": StringName, "sampler": Callable }], applied to every segment
var _remote_specs: Array = []  # [{ "id": StringName, "peer_id": String }] or [{ "id":, "auto": true }]
## The currently running segment's session, if any. Tracked so shutdown() can
## stop it without the game having to keep its own handle around.
var _active_session: RollbackNetSession = null


## Install a persistent connection at child path "Transport". A supplied
## connection is duck typed and may live in any addon. Passing a signaling
## adapter retains the legacy behavior by constructing RollbackTransport.
## `signaling_source` is optional for configured façades whose start() takes no
## arguments.
func begin(connection_or_signaling, signaling_source = null) -> void:
	if _implements_connection(connection_or_signaling):
		transport = connection_or_signaling
		_start_source = signaling_source
	else:
		transport = RollbackTransport.new()
		_start_source = connection_or_signaling
	transport.name = "Transport"
	var failure_signal := &"connection_failed" \
		if transport.has_signal("connection_failed") else &"transport_failed"
	transport.connect(failure_signal, func(reason: String) -> void:
		segment_failed.emit("transport_failed: " + reason))
	add_child(transport)
	if transport is RollbackTransport:
		clock = (transport as RollbackTransport).clock
	else:
		clock = RollbackNetClock.new()
		clock.name = "NetClock"
		transport.add_child(clock)


## Register a local input provider. Applied to every segment's session; call
## before run_segment(). sampler is Callable(tick: int) -> Dictionary.
func add_local_provider(id: StringName, sampler: Callable) -> void:
	_local_specs.append({"id": id, "sampler": sampler})


## Register a remote input provider — input this peer expects from `peer_id`.
func add_remote_provider(id: StringName, peer_id: String) -> void:
	_remote_specs.append({"id": id, "peer_id": peer_id})


## Register a remote provider mapped to the single ready peer (2-player
## convenience): the peer is resolved inside run_segment once the transport is
## up. Fails the segment if there isn't exactly one ready peer.
func add_auto_remote_provider(id: StringName) -> void:
	_remote_specs.append({"id": id, "auto": true})


## Stand up segment `seg_index`. `build` is Callable(seg_index: int,
## session: RollbackNetSession) -> Dictionary and must build the world and return
## a dict containing "manager": RollbackManager (plus whatever the game needs at
## teardown). The session node already exists at its path when build runs.
## Input routing comes from the providers registered up front via
## add_local_provider / add_remote_provider / add_auto_remote_provider (they
## persist across segments). Returns build's dict + {"session": session,
## "ok": true}, or {"ok": false} on failure (segment_failed is emitted first).
func run_segment(seg_index: int, build: Callable) -> Dictionary:
	if transport == null:
		segment_failed.emit("run_segment called before begin()")
		return {"ok": false}

	var session := RollbackNetSession.new()
	session.name = "Session%d" % seg_index
	session.input_codec = input_codec
	session.input_delay = input_delay
	session.max_prediction = max_prediction
	session.checksum_interval = checksum_interval
	add_child(session)

	var built_v: Variant = await build.call(seg_index, session)
	if not (built_v is Dictionary) or not ((built_v as Dictionary).get("ok", true) as bool):
		segment_failed.emit("segment %d build failed" % seg_index)
		session.queue_free()
		return {"ok": false}
	var built := built_v as Dictionary
	var manager := built.get("manager") as RollbackManager
	if manager == null:
		segment_failed.emit("segment %d build returned no manager" % seg_index)
		session.queue_free()
		return {"ok": false}

	session.setup(manager, transport, clock)
	session.session_failed.connect(func(reason: String) -> void:
		segment_failed.emit("session_failed: " + reason))
	session.desync_detected.connect(func(report: Dictionary) -> void:
		desync_detected.emit(report))
	var started := [false]
	session.session_started.connect(func() -> void: started[0] = true, CONNECT_ONE_SHOT)

	if not _transport_started:
		_transport_started = true
		var ready_signal := &"connection_ready" \
			if transport.has_signal("connection_ready") else &"transport_ready"
		transport.connect(ready_signal, func() -> void: _transport_ready = true, CONNECT_ONE_SHOT)
		if _start_source == null:
			transport.call("start")
		else:
			transport.call("start", _start_source)
		if not await _await_flag(func() -> bool: return _transport_ready, "transport_ready"):
			session.queue_free()
			return {"ok": false}
		_ready_peers = transport.get_ready_peers()
		for pid in _ready_peers:
			peer_ready.emit(pid)
	else:
		# A peer may have dropped and rejoined between segments; without this
		# refresh add_auto_remote_provider would map to a stale peer id from
		# the first segment's roster.
		_ready_peers = transport.get_ready_peers()

	if not _register_providers(session):
		session.queue_free()
		return {"ok": false}

	session.request_start()
	if not await _await_flag(func() -> bool: return started[0], "session_started (seg %d)" % seg_index):
		session.queue_free()
		return {"ok": false}

	var out := built.duplicate()
	out["session"] = session
	out["ok"] = true
	_active_session = session
	segment_started.emit(seg_index, session)
	return out


## Stop and free a segment's session. Calls session.stop() FIRST (freezes the sim
## and suppresses the peer_lost failure path) before you free the rest of the
## world; then queue_frees the session node.
func stop_segment(session: RollbackNetSession) -> void:
	if session == null:
		return
	session.stop()
	session.queue_free()
	if session == _active_session:
		_active_session = null


## Full teardown for a quit/disconnect: stops the active session first (a
## stopped session ignores peer_lost, so teardown can't fire a spurious
## session_failed), then closes the transport's multiplayer peer NOW — without
## this the remote peer's inbound RPCs keep routing to freed session nodes and
## its engine never fires peer_disconnected, leaving it stuck in-game — then
## closes the signaling adapter and frees the transport. Safe to call twice.
func shutdown() -> void:
	if _active_session != null and is_instance_valid(_active_session):
		_active_session.stop()
		_active_session.queue_free()
	_active_session = null
	if transport != null and is_instance_valid(transport):
		transport.stop()
	if _start_source != null and _start_source.has_method("close"):
		_start_source.close()
	_start_source = null
	if transport != null and is_instance_valid(transport):
		transport.queue_free()
	transport = null


func _register_providers(session: RollbackNetSession) -> bool:
	for spec_v in _local_specs:
		var spec := spec_v as Dictionary
		session.add_local_provider(spec["id"] as StringName, spec["sampler"] as Callable)
	for spec_v in _remote_specs:
		var spec := spec_v as Dictionary
		if spec.get("auto", false) as bool:
			if _ready_peers.size() != 1:
				segment_failed.emit("add_auto_remote_provider needs exactly one ready peer, got %d" % _ready_peers.size())
				return false
			session.add_remote_provider(spec["id"] as StringName, _ready_peers[0])
		else:
			session.add_remote_provider(spec["id"] as StringName, spec["peer_id"] as String)
	return true


func _await_flag(cond: Callable, what: String) -> bool:
	var deadline := Time.get_ticks_msec() + int(handshake_timeout_sec * 1000.0)
	while not (cond.call() as bool):
		await get_tree().process_frame
		if Time.get_ticks_msec() >= deadline:
			segment_failed.emit("timeout waiting for " + what)
			return false
	return true


static func _implements_connection(candidate) -> bool:
	if not (candidate is Node):
		return false
	for signal_name in [
		&"peer_ready", &"peer_lost", &"peer_recovered",
	]:
		if not candidate.has_signal(signal_name):
			return false
	if not candidate.has_signal("connection_ready") \
			and not candidate.has_signal("transport_ready"):
		return false
	if not candidate.has_signal("connection_failed") \
			and not candidate.has_signal("transport_failed"):
		return false
	for method_name in [
		&"start", &"stop", &"get_ready_peers", &"get_net_id", &"get_peer_id",
		&"is_recovering", &"request_recovery",
	]:
		if not candidate.has_method(method_name):
			return false
	return true
