## The L1 transport for the rollback stack: assembles a WebRTCMultiplayerPeer
## mesh from a signaling adapter, or falls back to a loopback
## WebSocketMultiplayerPeer star (one peer serves) when no concrete WebRTC
## GDExtension backend is available (editor/native dev builds without one —
## expected in this headless dev environment; web exports and native builds
## with a WebRTC GDExtension get the real mesh). Either way,
## `multiplayer.multiplayer_peer` ends up set, so the game just uses plain
## RPCs on top. `@rpc("unreliable")` rides the mesh's unreliable channel in
## WebRTC mode; on the WS fallback there is no unreliable channel, so
## everything is effectively reliable there (fine for dev/testing, not a
## perf-representative substitute for the real mesh).
##
## The game must add this node at an IDENTICAL node path on every peer before
## calling start() — its own RPCs (_identify, and RollbackNetClock's ping/pong)
## depend on that path matching. It creates a RollbackNetClock child named
## "NetClock" in _ready() and exposes it as `clock`.
##
## Usage:
##   var transport := RollbackTransport.new()
##   transport.name = "Transport"          # same path on every peer
##   add_child(transport)
##   var adapter := MySignalingAdapter.new(...)  # anything satisfying the RollbackSignalingAdapter contract (see RollbackSignalingAdapter.implements)
##   transport.peer_ready.connect(func(pid, net_id): ...)
##   transport.transport_ready.connect(func(): ...)  # all discovered peers up
##   await transport.start(adapter)
##   # ... later:
##   transport.stop()
class_name RollbackTransport
extends Node

# ============================================================================
# Signals / exports / public state
# ============================================================================

## A peer's engine-level connection came up and it identified itself.
signal peer_ready(peer_id: String, net_id: int)
## A peer's engine-level connection dropped.
signal peer_lost(peer_id: String, net_id: int)
## An established WebRTC peer dropped and a bounded connection rebuild began.
## The engine net id remains stable across the rebuild.
signal peer_recovery_started(peer_id: String, net_id: int)
## A rebuilding peer completed the identify handshake again.
signal peer_recovered(peer_id: String, net_id: int, duration_ms: int)
## Every peer known from signaling (at the time) is ready. May fire more than
## once if peers join later and all reach ready again.
signal transport_ready()
## Unrecoverable transport error (peer connect timeout, net-id collision,
## bind failure, signaling connect failure, ...).
signal transport_failed(reason: String)

## How long to wait for a discovered peer's engine-level connection to come
## up before giving up (WebRTC: restarts the handshake once first, in step
## with the peer — see MAX_GEN).
@export var connect_timeout_sec := 10.0
## Total wall-clock budget for rebuilding an established WebRTC peer before
## peer_lost is emitted. The rollback session stalls at its prediction horizon
## during this window instead of treating a transient ICE disconnect as final.
@export var recovery_timeout_sec := 15.0
## Per-connection deadline inside the total recovery budget. A timed-out rebuild
## advances the wire generation and tries a fresh RTCPeerConnection while time
## remains.
@export var recovery_retry_sec := 5.0
## Testing hook: force the WebSocket loopback fallback even if a WebRTC
## backend is available.
@export var force_ws_fallback := false

## Generation-0 ICE policy: offer only UDP-capable relays on the first
## handshake attempt, so nomination cannot land on a stream transport (a
## TCP/TLS relay is head-of-line-blocked and useless under this stack's
## unreliable channel — see ice_servers_for_generation). If that attempt times
## out, the existing restart-at-generation-1 escalation hands back the full,
## unfiltered list. Setting this false is the one-line rollback of the whole
## feature.
@export var udp_first := true
## Connect deadline while the generation-0 UDP-only policy is in force. A
## working UDP path nominates in well under a second, so paying the full
## connect_timeout_sec here would make a genuinely UDP-blocked player wait
## 10s before the generation-1 fallback even arms. This caps the cost of a
## wrong guess.
@export var udp_first_timeout_sec := 4.0

## Highest initial-handshake generation. Generation 0 is the first attempt, so
## MAX_GEN == 1 allows exactly one restart before a peer has ever connected.
## Established-peer recovery uses a wall-clock budget and may advance further.
const MAX_GEN := 1

## Cap on ICE candidates held per peer while its connection cannot accept
## them yet. A full trickle set is ~12 candidates; this only bounds a
## pathological sender.
const MAX_PENDING_ICE := 64

## How often to re-announce a restart the peer has not acknowledged. Signaling
## delivery is best-effort by contract, and a single dropped restart strands
## an answerer exactly the way the unilateral rebuild did: it cannot offer, so
## it emits nothing further to carry the new generation. Re-announcing until
## the peer answers at our generation closes that hole; the connect timeout
## bounds the repeats.
const RESTART_ANNOUNCE_INTERVAL_SEC := 1.0

## How often to retransmit a session description nothing has acknowledged yet.
## Signaling delivery is best-effort, and a peer's socket reconnect is a
## designed-in drop window: the server dedups by peer id, so a new socket
## replaces the old one and re-announces presence — but that re-announce cannot
## re-drive a handshake already in progress, because the peer is still in
## _known_peers. Nothing else recovers a dropped SDP except the connect timeout,
## which costs the whole timeout AND the entire restart budget on a fault that
## budget was never sized for.
##
## The happy path pays nothing: evidence of arrival comes back well inside one
## interval, so a retransmit only ever fires under real loss. Deliberately the
## same cadence as RESTART_ANNOUNCE_INTERVAL_SEC despite carrying a payload
## three orders of magnitude larger — the bound that matters is the connect
## timeout, which caps this at ten repeats.
const SDP_RETRANSMIT_INTERVAL_SEC := 1.0

## What to do with a handshake envelope, given its generation versus ours.
enum GenAction {
	PROCESS,     ## Same generation — the envelope belongs to our connection.
	DROP_STALE,  ## Older generation — from a connection we already discarded.
	ADOPT,       ## Newer generation — the peer restarted; follow it.
}

var local_peer_id: String = ""
var local_net_id: int = 0
## Wall-clock time-sync helper, child of this node. Populated in _ready().
var clock: RollbackNetClock

var _adapter
## Optional provider-neutral WebRTC implementation. Kept duck typed so the
## standalone rollback addon never statically depends on an SDK.
var _connection_delegate: Node
var _webrtc_mode := false
var _mesh: WebRTCMultiplayerPeer
var _ws_peer: WebSocketMultiplayerPeer
var _ws_port := 0
var _ice_servers: Array = []
## Latest adapter-supplied WebRTCPeerConnection.initialize() configuration.
## Snapshotted for each new/rebuilt peer connection; existing connections are
## intentionally left alone.
var _connection_config: Dictionary = {}
var _room_id: String = ""

## False until start() has initialized local_peer_id/_webrtc_mode (i.e. until
## connect_room() resolves and the mode is decided). Peer announces arriving
## before that are buffered in _pending_peer_ids — see _on_peer_discovered.
var _peers_ready := false
var _pending_peer_ids: Array[String] = []

## False before start() and after stop(). Signaling can deliver after teardown
## — the adapter is closed, but envelopes already queued still arrive — and
## acting on those rebuilds connections into a mesh that no longer exists.
var _active := false

## Peers that left the room. Handshake envelopes still in flight must not
## rediscover them; only a fresh peer_joined re-authorizes that. Without this
## a straggling envelope resurrects a departed peer and hands it a connect
## timeout to fail on.
var _departed: Dictionary = {}   # peer_id: String -> true

## Peers that just rejoined and owe us a generation-0 envelope. A rejoin resets
## both sides to generation 0, so an envelope from the peer's PREVIOUS
## incarnation still in flight would otherwise read as a newer generation and
## be adopted — pushing us to the terminal generation, after which the peer's
## legitimate generation-0 offer is discarded as stale and the session is dead.
## Nothing in the envelope distinguishes incarnations, so the barrier is: until
## this peer speaks at generation 0, it may not move us off it.
var _awaiting_rejoin_gen0: Dictionary = {}   # peer_id: String -> true

## Guards against a start() coroutine outliving the stop() (or the start) that
## superseded it: captured before connect_room()'s await and re-checked after.
var _lifecycle_seq := 0

var _known_peers: Array[String] = []  # peers currently present per signaling (joined minus left)
var _pcs: Dictionary = {}             # peer_id: String -> WebRTCPeerConnection
var _peer_to_net: Dictionary = {}     # peer_id: String -> net_id: int (learned via identify)
var _net_to_peer: Dictionary = {}     # net_id: int -> peer_id: String
var _ready_peer_set: Dictionary = {}  # peer_id: String -> true
## Established peers currently rebuilding. Entry shape:
## {net_id: int, started_msec: int, deadline_msec: int, attempt: int}.
## This is deliberately transport state rather than rollback-session state so
## the WebRTC recovery policy can move into a standalone transport addon later.
var _recovering_peers: Dictionary = {}
var _timers: Dictionary = {}          # peer_id: String -> Timer
var _gens: Dictionary = {}            # peer_id: String -> int (handshake generation, wire-visible)
var _remote_desc_set: Dictionary = {} # peer_id: String -> true (current-gen PC has a remote description)
var _pending_ice: Dictionary = {}     # peer_id: String -> Array[Dictionary] (candidates awaiting a usable connection)
var _pc_epochs: Dictionary = {}       # peer_id: String -> int (identity of the live connection; never reused)
var _restart_timers: Dictionary = {}  # peer_id: String -> Timer (re-announcing an unacknowledged restart)
## Session descriptions still lacking evidence they arrived. Entry shape:
## {gen: int, epoch: int, sdp_type: String, sdp: String, timer: Timer}. The gen
## and epoch are the ones the description was created under, so a superseded
## connection cannot put its description back on the wire — see
## _track_sdp_for_retransmit.
var _sdp_retransmits: Dictionary = {} # peer_id: String -> Dictionary

## Source of connection epochs. Unlike the generation this never resets, so a
## callback queued by a closed connection cannot be mistaken for one from its
## replacement — including across a peer leaving and rejoining, which does
## reset the generation to 0.
var _epoch_seq := 0


func _ready() -> void:
	clock = RollbackNetClock.new()
	clock.name = "NetClock"
	add_child(clock)
	multiplayer.peer_connected.connect(_on_engine_peer_connected)
	multiplayer.peer_disconnected.connect(_on_engine_peer_disconnected)


## Supply a provider-neutral WebRTC connection before start(). The connection
## runs behind this compatibility node, while this node retains the historical
## Transport RPC path and NetClock child.
func set_webrtc_connection(connection: Node) -> void:
	if _active:
		push_error("RollbackTransport: cannot replace the WebRTC connection while active")
		return
	if _connection_delegate != null and _connection_delegate.get_parent() == self:
		remove_child(_connection_delegate)
	_connection_delegate = connection
	if _connection_delegate == null:
		return
	_connection_delegate.name = "WebRTCConnection"
	if _connection_delegate.get_parent() == null:
		add_child(_connection_delegate)
	if _connection_delegate.has_method("set_rpc_host"):
		_connection_delegate.call("set_rpc_host", self)
	_connect_delegate_signals()


# ============================================================================
# Lifecycle
# ============================================================================


## Join signaling, decide WebRTC-mesh vs WS-loopback mode, and start
## connecting to peers. Async — signals report progress/failure; there is no
## synchronous "connected" return.
func start(adapter) -> void:
	if _connection_delegate != null and not force_ws_fallback and _probe_webrtc_available():
		_start_connection_delegate(adapter)
		return
	if not RollbackSignalingAdapter.implements(adapter):
		push_error("RollbackTransport: adapter does not implement the RollbackSignalingAdapter contract")
		transport_failed.emit("invalid signaling adapter")
		return
	# Capture the lifecycle this call belongs to. connect_room() suspends, and
	# a stop() (or another start()) during that suspension must invalidate
	# everything below — otherwise a late resolution reconnects a transport
	# that has already been torn down, or grafts one room's peers onto another.
	_lifecycle_seq += 1
	var token := _lifecycle_seq

	# Detach whatever the previous lifecycle was listening to, so a superseded
	# start still suspended in connect_room() cannot inject peer events into
	# this one. Same-adapter restarts keep their connections (the guards in
	# _attach_adapter_signals make reattachment a no-op).
	if _adapter != null and _adapter != adapter:
		_detach_adapter_signals(_adapter)

	_adapter = adapter
	_attach_adapter_signals(adapter)

	var res: Dictionary = await adapter.connect_room()

	if token != _lifecycle_seq:
		# Superseded while suspended. Clean up only what no one else claimed:
		# a newer start may have been handed this very adapter, and closing it
		# would strand the lifecycle that now owns it.
		if _adapter != adapter:
			_detach_adapter_signals(adapter)
			adapter.close()
		return

	if not (res.get("success", false) as bool):
		var reason := str(res.get("error", "connect_room failed"))
		push_error("RollbackTransport: signaling connect failed: %s" % reason)
		_detach_adapter_signals(adapter)
		transport_failed.emit(reason)
		return

	local_peer_id = str(res.get("peer_id", ""))
	local_net_id = derive_net_id(local_peer_id)
	_room_id = str(res.get("room_id", ""))
	var servers: Variant = res.get("ice_servers", [])
	if servers is Array:
		_ice_servers = (servers as Array).duplicate(true)
	else:
		_ice_servers = []
	_connection_config = {"iceServers": _ice_servers.duplicate(true)}
	if adapter.has_method("get_connection_config"):
		var current_config: Variant = adapter.call("get_connection_config")
		# A subclass that inherits the base class's optional no-op method returns
		# {}. Keep the connect_room() ICE result in that compatibility case.
		if current_config is Dictionary and not (current_config as Dictionary).is_empty():
			_set_connection_config(current_config as Dictionary)

	_webrtc_mode = false if force_ws_fallback else _probe_webrtc_available()

	if _webrtc_mode:
		_mesh = WebRTCMultiplayerPeer.new()
		_mesh.create_mesh(local_net_id)
		multiplayer.multiplayer_peer = _mesh
	# WS mode: role (server/client) is decided lazily per discovered peer.

	# Drain peer announces buffered during connect_room()'s await: the
	# signaling server announces already-present peers immediately on
	# (re)connect, so peer_joined can fire mid-await — and the menu flow's
	# room reconnect (connect screen first, then again here) makes that the
	# common case, not a rare race. Processing discovery before
	# local_peer_id/_webrtc_mode are set breaks both the mode choice
	# (default false -> WS fallback, impossible in a browser) and the
	# lexicographic server/offer rule ("" < pid is always true).
	_active = true
	_peers_ready = true
	var pending := _pending_peer_ids.duplicate()
	_pending_peer_ids.clear()
	for pid in pending:
		_on_peer_discovered(pid as String)


## Tear down the transport: cancel pending timers, close the multiplayer
## peer, close the signaling adapter, and clear all learned peer state.
func stop() -> void:
	if _connection_delegate != null and _webrtc_mode:
		_active = false
		_lifecycle_seq += 1
		if clock != null:
			for pid_v in _connection_delegate.call("get_ready_peers"):
				clock.untrack(int(_connection_delegate.call("get_net_id", str(pid_v))))
		_connection_delegate.call("stop")
		_adapter = null
		_webrtc_mode = false
		_peers_ready = false
		local_peer_id = ""
		local_net_id = 0
		return
	# Before anything else: stop accepting signaling. Closing the adapter does
	# not retract envelopes it has already queued, and one arriving mid-teardown
	# would rebuild a connection into a mesh this function is about to null.
	_active = false
	# Invalidate any start() still suspended in connect_room().
	_lifecycle_seq += 1
	_detach_adapter_signals(_adapter)

	for pid in _timers.keys().duplicate():
		_cancel_timer(pid as String)

	if _mesh != null:
		_mesh.close()
		_mesh = null
	if _ws_peer != null:
		_ws_peer.close()
		_ws_peer = null
	# `multiplayer` only exists inside the tree, and stop() is reachable from
	# teardown paths that run after removal.
	if is_inside_tree():
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

	if _adapter != null:
		_adapter.close()

	_pcs.clear()
	_peer_to_net.clear()
	_net_to_peer.clear()
	_ready_peer_set.clear()
	_recovering_peers.clear()
	_known_peers.clear()
	for pid in _restart_timers.keys().duplicate():
		_cancel_restart_timer(pid as String)
	for pid in _sdp_retransmits.keys().duplicate():
		_cancel_sdp_retransmit(pid as String)

	_gens.clear()
	_remote_desc_set.clear()
	_pending_ice.clear()
	_pc_epochs.clear()
	_departed.clear()
	_awaiting_rejoin_gen0.clear()
	_webrtc_mode = false
	_peers_ready = false
	_pending_peer_ids.clear()
	_connection_config.clear()
	_ice_servers.clear()


func _start_connection_delegate(adapter) -> void:
	_adapter = adapter
	_active = true
	_webrtc_mode = true
	_peers_ready = true
	_connect_delegate_signals()
	if _connection_delegate.has_method("set_rpc_host"):
		_connection_delegate.call("set_rpc_host", self)
	_connection_delegate.call("start", adapter, multiplayer)


func _connect_delegate_signals() -> void:
	if _connection_delegate == null:
		return
	_connect_delegate_signal(&"peer_ready", _on_delegate_peer_ready)
	_connect_delegate_signal(&"peer_lost", _on_delegate_peer_lost)
	_connect_delegate_signal(&"peer_recovery_started", _on_delegate_recovery_started)
	_connect_delegate_signal(&"peer_recovered", _on_delegate_recovered)
	_connect_delegate_signal(&"connection_ready", _on_delegate_connection_ready)
	_connect_delegate_signal(&"connection_failed", _on_delegate_connection_failed)


func _connect_delegate_signal(signal_name: StringName, callable: Callable) -> void:
	if _connection_delegate.has_signal(signal_name) \
			and not _connection_delegate.is_connected(signal_name, callable):
		_connection_delegate.connect(signal_name, callable)


func _sync_delegate_identity() -> void:
	local_peer_id = str(_connection_delegate.get("local_peer_id"))
	local_net_id = int(_connection_delegate.get("local_net_id"))


func _on_delegate_peer_ready(peer_id: String, net_id: int) -> void:
	_sync_delegate_identity()
	if clock != null:
		clock.track(net_id)
	peer_ready.emit(peer_id, net_id)


func _on_delegate_peer_lost(peer_id: String, net_id: int) -> void:
	if clock != null:
		clock.untrack(net_id)
	peer_lost.emit(peer_id, net_id)


func _on_delegate_recovery_started(peer_id: String, net_id: int) -> void:
	if clock != null:
		clock.untrack(net_id)
	peer_recovery_started.emit(peer_id, net_id)


func _on_delegate_recovered(peer_id: String, net_id: int, duration_ms: int) -> void:
	if clock != null:
		clock.track(net_id)
	peer_recovered.emit(peer_id, net_id, duration_ms)


func _on_delegate_connection_ready() -> void:
	_sync_delegate_identity()
	transport_ready.emit()


func _on_delegate_connection_failed(reason: String) -> void:
	transport_failed.emit(reason)


# ============================================================================
# Discovery (WebRTC mesh + WS loopback)
# ============================================================================


## Adapter-authorized discovery: a peer_joined announcement, which is the only
## thing that may resurrect a departed peer id.
func _on_peer_discovered(pid: String) -> void:
	if _departed.has(pid):
		# A rejoin. Until this peer speaks at generation 0 we cannot tell its
		# envelopes from its previous incarnation's, so it may not move us off
		# generation 0 in the meantime.
		_awaiting_rejoin_gen0[pid] = true
	_departed.erase(pid)
	_discover_peer(pid)


func _discover_peer(pid: String) -> void:
	if not _peers_ready:
		# start() hasn't finished initializing (connect_room's await is still
		# in flight) — buffer the announce; start() drains the queue once
		# local_peer_id/_webrtc_mode are set. See the drain site for the race.
		if not pid.is_empty() and not _pending_peer_ids.has(pid) and not _pcs.has(pid):
			_pending_peer_ids.append(pid)
		return

	if pid.is_empty() or pid == local_peer_id or _known_peers.has(pid):
		return

	var candidate_id := derive_net_id(pid)
	if candidate_id == local_net_id:
		push_error("RollbackTransport: net id collision between local peer and %s" % pid)
		transport_failed.emit("net id collision with %s" % pid)
		return
	for known in _known_peers:
		if derive_net_id(known as String) == candidate_id:
			push_error("RollbackTransport: net id collision between %s and %s" % [known, pid])
			transport_failed.emit("net id collision between %s and %s" % [known, pid])
			return

	_known_peers.append(pid)

	if _webrtc_mode:
		_create_peer_connection(pid, 0)
	else:
		_ws_discover_peer(pid)


func _create_peer_connection(pid: String, gen: int) -> bool:
	if _mesh == null:
		# No mesh to attach to — the transport was torn down, or was never
		# started. Building a connection here would crash on add_peer and
		# repopulate state that stop() has just cleared.
		push_error("RollbackTransport: refusing to build a connection for %s with no mesh" % pid)
		return false

	var pc := WebRTCPeerConnection.new()
	# _ice_servers itself stays the unfiltered truth from start() — only the
	# per-connection view is narrowed, and only at generation 0.
	var init_cfg := _connection_config.duplicate(true)
	var servers := ice_servers_for_generation(_ice_servers, gen, udp_first)
	if servers.is_empty():
		init_cfg.erase("iceServers")
	else:
		init_cfg["iceServers"] = servers
	var err := pc.initialize(init_cfg)
	if err != OK:
		push_error("RollbackTransport: WebRTCPeerConnection.initialize failed for %s (err=%d)" % [pid, err])
		if _recovering_peers.has(pid):
			_fail_recovery(pid, "peer connection init failed")
		else:
			transport_failed.emit("peer connection init failed for %s" % pid)
		return false

	# One line per connection, so a browser capture says which ICE-server arm
	# was actually live: "full" when the policy isn't filtering, "udp-only"
	# when it removed something, and "udp-only(no-op)" when the policy was on
	# but nothing changed (including the bail-out) — the capture needs to be
	# able to tell "filtered" apart from "nothing to filter / refused to
	# filter".
	var policy: String
	if not udp_first or gen != 0:
		policy = "full"
	elif servers != _ice_servers:
		policy = "udp-only"
	else:
		policy = "udp-only(no-op)"
	print("RollbackTransport: %s gen=%d ice=%s (%d/%d servers)" % [
		pid, gen, policy, servers.size(), _ice_servers.size()])

	# The epoch is bound into the handlers rather than read at emit time: a
	# closed connection can still deliver queued signals, and those must not be
	# published as if they belonged to its replacement.
	var epoch := _next_epoch()
	pc.session_description_created.connect(_on_session_description_created.bind(pid, gen, epoch))
	pc.ice_candidate_created.connect(_on_ice_candidate_created.bind(pid, gen, epoch))
	_gens[pid] = gen
	_pc_epochs[pid] = epoch
	_pcs[pid] = pc
	var mesh_err := _mesh.add_peer(pc, derive_net_id(pid))
	if mesh_err != OK:
		push_error("RollbackTransport: WebRTCMultiplayerPeer.add_peer failed for %s (err=%d)" % [pid, mesh_err])
		pc.close()
		_pcs.erase(pid)
		if _recovering_peers.has(pid):
			_fail_recovery(pid, "mesh add_peer failed")
		else:
			transport_failed.emit("mesh add_peer failed for %s" % pid)
		return false

	# Locked offer rule: the lexicographically smaller peer id offers.
	if local_peer_id < pid:
		pc.create_offer()

	_start_connect_timeout(pid)
	return true


## Discard this peer's connection and build a fresh one at `gen`. Callers are
## responsible for keeping the peer in step — either by announcing the new
## generation (see _on_connect_timeout) or by adopting the peer's (see
## _on_sig_received). A one-sided rebuild strands the handshake: the peer keeps
## a connection whose candidates can no longer reach anything.
func _rebuild_peer_connection(pid: String, gen: int) -> bool:
	var net_id := derive_net_id(pid)
	if _mesh != null and _mesh.has_peer(net_id):
		_mesh.remove_peer(net_id)
	var old_pc: Variant = _pcs.get(pid)
	if old_pc is WebRTCPeerConnection:
		(old_pc as WebRTCPeerConnection).close()
	_pcs.erase(pid)
	_remote_desc_set.erase(pid)
	_pending_ice.erase(pid)
	_cancel_restart_timer(pid)
	# The description belonged to the connection being discarded; repeating it
	# under the new generation would hand the peer a dead ufrag.
	_cancel_sdp_retransmit(pid)
	return _create_peer_connection(pid, gen)


func _ws_discover_peer(pid: String) -> void:
	if _ws_peer != null:
		push_warning("RollbackTransport: WS fallback is 2-peer only; ignoring extra peer %s" % pid)
		return
	# Locked rule (mirrors the WebRTC offer rule): the lexicographically
	# smaller peer id hosts the loopback WS server.
	if local_peer_id < pid:
		_ws_become_server(pid)
	# else: wait for the ws_listen envelope from pid (client role).


func _ws_become_server(pid: String) -> void:
	var base_port := 9100 + (derive_net_id(_room_id) % 400)
	var bound := false
	for i in range(10):
		var try_port := base_port + i
		var peer := WebSocketMultiplayerPeer.new()
		var err := peer.create_server(try_port, "127.0.0.1")
		if err == OK:
			_ws_peer = peer
			_ws_port = try_port
			bound = true
			break
	if not bound:
		push_error("RollbackTransport: failed to bind WS fallback server (tried ports %d..%d)" % [base_port, base_port + 9])
		transport_failed.emit("ws server bind failed")
		return

	multiplayer.multiplayer_peer = _ws_peer
	_adapter.send(pid, {"v": 1, "kind": "ws_listen", "port": _ws_port})
	_start_connect_timeout(pid)


# ============================================================================
# Envelope routing (signaling -> WebRTC handshake / WS role assignment)
# ============================================================================


func _on_sig_received(sender_peer_id: String, data: Variant) -> void:
	if not _active:
		return
	if not (data is Dictionary):
		push_warning("RollbackTransport: dropping non-Dictionary signal from %s" % sender_peer_id)
		return
	var env := data as Dictionary
	if int(env.get("v", 0)) != 1:
		push_warning("RollbackTransport: dropping signal with unexpected version from %s" % sender_peer_id)
		return

	var kind := str(env.get("kind", ""))
	if kind == "ws_listen":
		_handle_ws_listen(sender_peer_id, env)
		return
	if kind != "sdp" and kind != "ice" and kind != "restart" and kind != "sdp_ack":
		push_warning("RollbackTransport: unknown signal kind '%s' from %s" % [kind, sender_peer_id])
		return
	if not _webrtc_mode:
		return

	# Discover on any handshake envelope, not just "sdp": a peer whose announce
	# we have not processed yet is still a peer whose candidates we must keep.
	# A peer that has *left*, though, stays gone until it rejoins for real.
	if not _known_peers.has(sender_peer_id):
		if _departed.has(sender_peer_id):
			return
		_discover_peer(sender_peer_id)

	var incoming_gen := int(env.get("gen", 0))

	if _awaiting_rejoin_gen0.has(sender_peer_id):
		if incoming_gen != 0:
			# Cannot be from the incarnation that just rejoined — that one is
			# still at generation 0. Adopting it would strand the real peer.
			return
		_awaiting_rejoin_gen0.erase(sender_peer_id)

	if incoming_gen >= int(_gens.get(sender_peer_id, 0)):
		# The peer is at or past our generation, so it has clearly heard about
		# any restart we announced. Stop re-announcing.
		_cancel_restart_timer(sender_peer_id)

	if kind == "sdp_ack":
		# Deliberately never routed through classify_generation. An ack
		# acknowledges a description WE sent, so one from a generation above
		# ours cannot legitimately exist — and letting it reach ADOPT would let
		# a peer tear down a live connection with a receipt for a description
		# that was never issued.
		_handle_sdp_ack(sender_peer_id, env, incoming_gen)
		return

	match classify_generation(int(_gens.get(sender_peer_id, 0)), incoming_gen):
		GenAction.DROP_STALE:
			# From a connection we have already torn down. Applying it would
			# graft a dead handshake's ufrag onto the live one.
			return
		GenAction.ADOPT:
			# MAX_GEN bounds only the initial connection. Once a peer has been
			# established, every outage needs a fresh generation because candidates
			# from a closed RTCPeerConnection cannot be reused. Recovery itself is
			# bounded by recovery_timeout_sec instead.
			var established := _ready_peer_set.has(sender_peer_id) \
				or _recovering_peers.has(sender_peer_id)
			if incoming_gen > MAX_GEN and not established:
				push_warning("RollbackTransport: %s restarted past the generation budget (gen=%d)" % [
					sender_peer_id, incoming_gen])
				return
			if _ready_peer_set.has(sender_peer_id):
				_mark_peer_recovering(sender_peer_id, get_net_id(sender_peer_id))
			if not _rebuild_peer_connection(sender_peer_id, incoming_gen):
				return
		GenAction.PROCESS:
			pass

	match kind:
		"sdp":
			_handle_sdp(sender_peer_id, env)
		"ice":
			_handle_ice(sender_peer_id, env)
		"restart":
			# The generation bump is the entire payload; adopting it above was
			# the whole point. The peer sends its offer separately.
			pass


## Next connection epoch. Strictly increasing for the lifetime of this node
## and never reset by peer churn — that is the whole point, see _pc_epochs.
func _next_epoch() -> int:
	_epoch_seq += 1
	return _epoch_seq


## Decide what to do with an envelope tagged `incoming_gen` when our own
## connection for that peer sits at `local_gen`.
static func classify_generation(local_gen: int, incoming_gen: int) -> GenAction:
	if incoming_gen < local_gen:
		return GenAction.DROP_STALE
	if incoming_gen > local_gen:
		return GenAction.ADOPT
	return GenAction.PROCESS


func _handle_sdp(pid: String, env: Dictionary) -> void:
	var pc := _pcs.get(pid) as WebRTCPeerConnection
	if pc == null:
		push_warning("RollbackTransport: sdp from unknown peer connection %s" % pid)
		return
	var sdp_type := str(env.get("sdp_type", ""))
	var sdp := str(env.get("sdp", ""))

	if _remote_desc_set.has(pid):
		# A retransmit: this generation's description is already applied.
		# Applying it again would renegotiate a connection that is still
		# mid-handshake, which is exactly what made retransmission look
		# expensive to add — ignoring the duplicate is what makes it cheap.
		# Re-ack instead: the only reason a peer is still repeating is that the
		# receipt was the thing that got lost.
		_ack_sdp(pid, sdp_type)
		return

	var err := pc.set_remote_description(sdp_type, sdp)
	if err != OK:
		# Held candidates stay held rather than being applied to a connection
		# that never took the description — they would only error individually.
		# No ack either: nothing landed, and the peer's retransmit is now the
		# only thing that will retry it.
		push_error("RollbackTransport: set_remote_description failed for %s (err=%d)" % [pid, err])
		return
	_remote_desc_set[pid] = true
	if sdp_type == "answer":
		# Our offer has demonstrably arrived — an answer cannot exist without
		# it. That is why offers need no ack of their own.
		_cancel_sdp_retransmit(pid)
	_ack_sdp(pid, sdp_type)
	_flush_pending_ice(pid)


## Acknowledge a description that landed. Only answers are acknowledged: an
## offer already gets a stronger receipt in the answer it produces, whereas an
## answerer emits nothing at all afterwards — the same silence that forces a
## restart to be re-announced — so an explicit receipt is the only thing that
## can ever stop it repeating.
func _ack_sdp(pid: String, sdp_type: String) -> void:
	if sdp_type != "answer":
		return
	_adapter.send(pid, {
		"v": 1, "gen": int(_gens.get(pid, 0)), "kind": "sdp_ack", "sdp_type": sdp_type,
	})


## Stop retransmitting the description this receipt covers. Written against what
## we are actually holding rather than against a role, so an ack for a
## generation or a description we are not repeating is simply ignored.
func _handle_sdp_ack(pid: String, env: Dictionary, incoming_gen: int) -> void:
	var entry: Variant = _sdp_retransmits.get(pid)
	if not (entry is Dictionary):
		return
	var e := entry as Dictionary
	if incoming_gen != int(e["gen"]):
		return
	if str(env.get("sdp_type", "")) != str(e["sdp_type"]):
		return
	_cancel_sdp_retransmit(pid)


func _handle_ice(pid: String, env: Dictionary) -> void:
	var mid := str(env.get("mid", ""))
	var index := int(env.get("index", 0))
	var candidate := str(env.get("candidate", ""))
	var pc := _pcs.get(pid) as WebRTCPeerConnection
	if pc == null or not _remote_desc_set.has(pid):
		# Candidates that arrive before the connection can take them — ahead of
		# the peer announce, or ahead of their own session description. Dropping
		# them cost the entire trickle set on links slow enough to reorder the
		# handshake against discovery; hold them instead.
		_buffer_pending_ice(pid, mid, index, candidate)
		return
	_apply_ice_candidate(pid, pc, mid, index, candidate)


func _buffer_pending_ice(pid: String, mid: String, index: int, candidate: String) -> void:
	var queued: Array = _pending_ice.get(pid, [])
	if queued.size() >= MAX_PENDING_ICE:
		push_warning("RollbackTransport: pending ICE buffer full for %s, dropping candidate" % pid)
		return
	queued.append({"mid": mid, "index": index, "candidate": candidate})
	_pending_ice[pid] = queued


## Apply everything held for `pid`, in arrival order. Called once the peer's
## remote description lands, which is what makes the connection able to accept
## candidates at all.
func _flush_pending_ice(pid: String) -> void:
	var queued: Array = _pending_ice.get(pid, [])
	if queued.is_empty():
		return
	_pending_ice.erase(pid)
	var pc := _pcs.get(pid) as WebRTCPeerConnection
	if pc == null:
		return
	for entry in queued:
		var e := entry as Dictionary
		_apply_ice_candidate(pid, pc, str(e["mid"]), int(e["index"]), str(e["candidate"]))


## Hand one candidate to the connection, reporting rejection rather than
## swallowing it. A candidate lost without a trace is what made the original
## bug expensive to find; if the discarded one is the only viable relay, the
## handshake just times out with nothing to explain why.
func _apply_ice_candidate(pid: String, pc: WebRTCPeerConnection, mid: String, index: int, candidate: String) -> void:
	var err := pc.add_ice_candidate(mid, index, candidate)
	if err != OK:
		push_warning("RollbackTransport: add_ice_candidate rejected for %s (gen=%d err=%d): %s" % [
			pid, int(_gens.get(pid, 0)), err, candidate])


func _handle_ws_listen(pid: String, env: Dictionary) -> void:
	if _webrtc_mode:
		push_warning("RollbackTransport: got ws_listen while in WebRTC mode, ignoring")
		return
	if _ws_peer != null:
		return
	var port := int(env.get("port", 0))
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client("ws://127.0.0.1:%d" % port)
	if err != OK:
		push_error("RollbackTransport: WS client connect failed to port %d (err=%d)" % [port, err])
		transport_failed.emit("ws client connect failed")
		return
	_ws_peer = peer
	_ws_port = port
	multiplayer.multiplayer_peer = _ws_peer
	if not _known_peers.has(pid):
		_known_peers.append(pid)
	_start_connect_timeout(pid)


func _on_session_description_created(sdp_type: String, sdp: String, pid: String, gen: int, epoch: int) -> void:
	if int(_pc_epochs.get(pid, -1)) != epoch:
		return
	var pc := _pcs.get(pid) as WebRTCPeerConnection
	if pc == null:
		return
	pc.set_local_description(sdp_type, sdp)
	_adapter.send(pid, {"v": 1, "gen": gen, "kind": "sdp", "sdp_type": sdp_type, "sdp": sdp})
	_track_sdp_for_retransmit(pid, gen, epoch, sdp_type, sdp)


func _on_ice_candidate_created(mid_name: String, index_name: int, sdp_name: String, pid: String, gen: int, epoch: int) -> void:
	if int(_pc_epochs.get(pid, -1)) != epoch:
		# A superseded connection still draining candidates. Sending them under
		# the live generation would hand the peer a stale ufrag to discard.
		return
	_adapter.send(pid, {"v": 1, "gen": gen, "kind": "ice", "mid": mid_name, "index": index_name, "candidate": sdp_name})


func _on_adapter_peer_left(pid: String) -> void:
	if _ready_peer_set.has(pid) or _recovering_peers.has(pid):
		# Already connected at the engine level; signaling leaving doesn't
		# affect an established connection. During recovery the SDK may be
		# replacing its signaling socket, so peer_left is not proof that the
		# gameplay peer is gone; the bounded recovery deadline owns that decision.
		return
	_cancel_timer(pid)
	_cancel_restart_timer(pid)
	_cancel_sdp_retransmit(pid)
	_departed[pid] = true
	_awaiting_rejoin_gen0.erase(pid)
	_gens.erase(pid)
	_remote_desc_set.erase(pid)
	_pending_ice.erase(pid)
	# _pc_epochs is deliberately NOT erased: a rejoin resets the generation to
	# 0, so the epoch is the only thing left that can tell a queued callback
	# from the departed connection apart from one belonging to its successor.
	_known_peers.erase(pid)
	var pc: Variant = _pcs.get(pid)
	if pc is WebRTCPeerConnection:
		(pc as WebRTCPeerConnection).close()
	_pcs.erase(pid)


# ============================================================================
# Identify handshake / ready tracking
# ============================================================================


func _on_engine_peer_connected(id: int) -> void:
	if _connection_delegate != null and _webrtc_mode:
		return
	_identify.rpc_id(id, local_peer_id)


func _on_engine_peer_disconnected(id: int) -> void:
	if _connection_delegate != null and _webrtc_mode:
		return
	var mapped: Variant = _net_to_peer.get(id)
	if mapped == null:
		return
	var peer_str := mapped as String

	if _recovering_peers.has(peer_str):
		# An intentional rebuild removes the old peer from the mesh and can emit
		# this signal synchronously. Recovery was marked first, so do not recurse
		# or publish a terminal loss for that expected removal.
		if clock != null:
			clock.untrack(id)
		_ready_peer_set.erase(peer_str)
		return

	if _active and _webrtc_mode and _known_peers.has(peer_str):
		push_warning("RollbackTransport: established peer %s disconnected; rebuilding at generation %d" % [
			peer_str, int(_gens.get(peer_str, 0)) + 1])
		if request_recovery(peer_str):
			return

	if clock != null:
		clock.untrack(id)
	_ready_peer_set.erase(peer_str)
	_finalize_peer_loss(peer_str, id)


@rpc("any_peer", "call_remote", "reliable")
func _identify(peer_str: String) -> void:
	if _connection_delegate != null and _webrtc_mode:
		_connection_delegate.call("receive_identify", peer_str, multiplayer.get_remote_sender_id())
		return
	_accept_identify(peer_str, multiplayer.get_remote_sender_id())


func _accept_identify(peer_str: String, sender: int) -> void:
	var validation_error := _validate_identify(peer_str, sender)
	if not validation_error.is_empty():
		_reject_identify(peer_str, sender, validation_error)
		return

	var recovery: Variant = _recovering_peers.get(peer_str)
	_peer_to_net[peer_str] = sender
	_net_to_peer[sender] = peer_str

	_cancel_timer(peer_str)
	_cancel_restart_timer(peer_str)
	_cancel_sdp_retransmit(peer_str)
	# _gens is deliberately kept: the connection is up, and holding its
	# generation is what keeps late envelopes from a superseded handshake
	# classified as stale rather than replayed onto the live connection.
	_ready_peer_set[peer_str] = true
	if clock != null:
		clock.track(sender)
	peer_ready.emit(peer_str, sender)
	if recovery is Dictionary:
		_recovering_peers.erase(peer_str)
		var started_msec := int((recovery as Dictionary).get("started_msec", Time.get_ticks_msec()))
		peer_recovered.emit(peer_str, sender, maxi(0, Time.get_ticks_msec() - started_msec))
	_maybe_emit_transport_ready()


func _validate_identify(peer_str: String, sender: int) -> String:
	if peer_str.is_empty():
		return "empty peer id"
	if sender <= 0:
		return "invalid sender net id %d" % sender
	if not _known_peers.has(peer_str):
		return "peer was not authorized by signaling"
	if _webrtc_mode:
		var expected := derive_net_id(peer_str)
		if sender != expected:
			return "net id mismatch (sender=%d expected=%d)" % [sender, expected]
	var mapped_peer: Variant = _net_to_peer.get(sender)
	if mapped_peer != null and str(mapped_peer) != peer_str:
		return "sender net id is already mapped to %s" % str(mapped_peer)
	var mapped_net: Variant = _peer_to_net.get(peer_str)
	if mapped_net != null and int(mapped_net) != sender:
		return "peer id is already mapped to net id %d" % int(mapped_net)
	var recovery: Variant = _recovering_peers.get(peer_str)
	if recovery is Dictionary and int((recovery as Dictionary).get("net_id", -1)) != sender:
		return "recovery net id changed"
	return ""


func _reject_identify(peer_str: String, sender: int, reason: String) -> void:
	var message := "identify rejected for %s from sender %d: %s" % [peer_str, sender, reason]
	var recovering_pid := _recovery_peer_for_identify(peer_str, sender)
	if not recovering_pid.is_empty():
		_fail_recovery(recovering_pid, message)
		return
	push_error("RollbackTransport: " + message)

	# Initial identification is part of transport establishment. Tear down only
	# the connection attributable to this sender/claim, then surface the existing
	# terminal setup error. Do not mutate either id map before validation passes.
	var cleanup_pid := _peer_for_sender(sender)
	if cleanup_pid.is_empty() and _known_peers.has(peer_str) \
			and not _ready_peer_set.has(peer_str):
		cleanup_pid = peer_str
	_cleanup_unidentified_peer(cleanup_pid)
	transport_failed.emit(message)


func _recovery_peer_for_identify(peer_str: String, sender: int) -> String:
	if _recovering_peers.has(peer_str):
		return peer_str
	for pid_v in _recovering_peers.keys():
		var pid := str(pid_v)
		var recovery := _recovering_peers[pid] as Dictionary
		if int(recovery.get("net_id", -1)) == sender:
			return pid
	return ""


func _peer_for_sender(sender: int) -> String:
	var mapped: Variant = _net_to_peer.get(sender)
	if mapped != null:
		return str(mapped)
	if _webrtc_mode:
		for pid_v in _known_peers:
			var pid := str(pid_v)
			if derive_net_id(pid) == sender:
				return pid
	return ""


func _cleanup_unidentified_peer(pid: String) -> void:
	if pid.is_empty() or _ready_peer_set.has(pid):
		return
	_cancel_timer(pid)
	_cancel_restart_timer(pid)
	_cancel_sdp_retransmit(pid)
	_gens.erase(pid)
	_remote_desc_set.erase(pid)
	_pending_ice.erase(pid)
	_known_peers.erase(pid)
	var net_id := derive_net_id(pid)
	if _webrtc_mode and _mesh != null and _mesh.has_peer(net_id):
		_mesh.remove_peer(net_id)
	var pc: Variant = _pcs.get(pid)
	if pc is WebRTCPeerConnection:
		(pc as WebRTCPeerConnection).close()
	_pcs.erase(pid)


func _maybe_emit_transport_ready() -> void:
	if _known_peers.is_empty():
		return
	for pid in _known_peers:
		if not _ready_peer_set.has(pid as String):
			return
	transport_ready.emit()


# ============================================================================
# Helpers
# ============================================================================


## Deterministic string -> int id (FNV-1a 32-bit over UTF-8), folded into
## [2, 2^30+1] so it avoids the reserved 0/1 ids and stays positive.
static func derive_net_id(peer_id: String) -> int:
	var h := 2166136261
	for b in peer_id.to_utf8_buffer():
		h = ((h ^ b) * 16777619) & 0xFFFFFFFF
	return (h & 0x3FFFFFFF) + 2


## The ICE server list to hand a connection at `gen`. Unfiltered at every
## generation except the very first: generation 0 is the one attempt where
## offering a stream-transport relay can get it nominated, because nothing
## has proven yet that a UDP path is unreachable. Once a generation-0 attempt
## times out, the restart already in place bumps the generation in step on
## both peers (see _announce_restart) — so this being a pure function of the
## generation is what makes "both peers escalate together" free: no wire
## field, nothing to version-negotiate.
static func ice_servers_for_generation(servers: Array, gen: int, udp_first_enabled: bool) -> Array:
	if udp_first_enabled and gen == 0:
		return _udp_only_ice_servers(servers)
	return servers


## Drop relay entries that can only yield a stream-transport candidate pair.
## STUN is always kept (it only ever produces srflx candidates, never a
## relay). TURN is kept unless it is TLS (turns:, inherently a stream
## transport) or explicitly transport=tcp; a bare turn: URL or one with
## transport=udp is kept, since UDP is the RFC 5928 default. Anything else
## (a scheme we don't understand, or a Dictionary with no "urls" at all)
## passes through untouched — dropping config we cannot read is worse than
## keeping it.
static func _udp_only_ice_servers(servers: Array) -> Array:
	var had_relay := false
	var out: Array = []
	for entry in servers:
		if not (entry is Dictionary):
			out.append(entry)
			continue
		var d := entry as Dictionary
		if not d.has("urls"):
			out.append(entry)
			continue

		var urls: Variant = d["urls"]
		var url_list: Array = urls if urls is Array else [urls]
		var kept: Array = []
		for u in url_list:
			var url := str(u)
			var lower := url.to_lower()
			if lower.begins_with("turn:") or lower.begins_with("turns:"):
				had_relay = true
			if lower.begins_with("turns:"):
				continue
			if lower.begins_with("turn:") and lower.contains("transport=tcp"):
				continue
			kept.append(url)

		if kept.is_empty():
			continue
		if urls is Array:
			var d2 := d.duplicate()
			d2["urls"] = kept
			out.append(d2)
		else:
			# Single-URL shape: kept has exactly one entry, or this entry
			# would have been dropped above.
			out.append(entry)

	if had_relay and not _has_relay(out):
		# A deployment that only offers TCP/TLS relays must not be handed a
		# config that provably cannot connect — the original, unfiltered list
		# is the only one with any chance.
		return servers
	return out


## Whether any entry in `servers` still offers a turn:/turns: URL.
static func _has_relay(servers: Array) -> bool:
	for entry in servers:
		if not (entry is Dictionary):
			continue
		var urls: Variant = (entry as Dictionary).get("urls")
		var url_list: Array = urls if urls is Array else [urls]
		for u in url_list:
			var lower := str(u).to_lower()
			if lower.begins_with("turn:") or lower.begins_with("turns:"):
				return true
	return false


## The engine-level multiplayer id for a peer. Returns the id learned via the
## identify handshake once connected; otherwise falls back to the
## deterministic derivation (which IS the eventual id in WebRTC mesh mode,
## since add_peer()/create_mesh() are seeded with derive_net_id — but is only
## a placeholder prediction in WS fallback mode, where WebSocketMultiplayerPeer
## assigns its own random ids that this function cannot know in advance).
func get_net_id(peer_id: String) -> int:
	if _connection_delegate != null and _webrtc_mode:
		return int(_connection_delegate.call("get_net_id", peer_id))
	if _peer_to_net.has(peer_id):
		return _peer_to_net[peer_id] as int
	return derive_net_id(peer_id)


## The peer id for an engine-level net id, from the learned map. "" if unknown.
func get_peer_id(net_id: int) -> String:
	if _connection_delegate != null and _webrtc_mode:
		return str(_connection_delegate.call("get_peer_id", net_id))
	var v: Variant = _net_to_peer.get(net_id)
	return v as String if v is String else ""


## The handshake generation currently in force for `peer_id` (0 = first attempt).
## Exposed for diagnostics: a capture cannot otherwise tell a generation-0
## UDP-only session from a generation-1 full-list fallback.
func get_generation(peer_id: String) -> int:
	if _connection_delegate != null and _webrtc_mode:
		return int(_connection_delegate.call("get_generation", peer_id))
	return int(_gens.get(peer_id, 0))


## Peer ids that have completed the identify handshake.
func get_ready_peers() -> Array[String]:
	if _connection_delegate != null and _webrtc_mode:
		var delegated: Array[String] = []
		for pid_v in _connection_delegate.call("get_ready_peers"):
			delegated.append(str(pid_v))
		return delegated
	var out: Array[String] = []
	for pid in _ready_peer_set.keys():
		out.append(pid as String)
	return out


## Whether one established peer (or any peer when peer_id is empty) is inside
## its bounded WebRTC rebuild window.
func is_recovering(peer_id: String = "") -> bool:
	if _connection_delegate != null and _webrtc_mode:
		return bool(_connection_delegate.call("is_recovering", peer_id))
	if peer_id.is_empty():
		return not _recovering_peers.is_empty()
	return _recovering_peers.has(peer_id)


## Rebuild one established WebRTC peer without ending the gameplay session.
## Callers may use this when application-level liveness (for example, a
## sustained input stall) fails before the engine publishes peer_disconnected.
## Returns false when recovery is unavailable or already in progress.
func request_recovery(peer_id: String = "") -> bool:
	if _connection_delegate != null and _webrtc_mode:
		if peer_id.is_empty():
			var peers := get_ready_peers()
			if peers.size() != 1:
				return false
			peer_id = peers[0]
		return bool(_connection_delegate.call("request_recovery", peer_id))
	if not _active or not _webrtc_mode:
		return false
	if (peer_id.is_empty() and not _recovering_peers.is_empty()) \
			or _recovering_peers.has(peer_id):
		return false
	var pid := peer_id
	if pid.is_empty():
		if _ready_peer_set.size() != 1:
			return false
		pid = str(_ready_peer_set.keys()[0])
	if not _known_peers.has(pid) or not _ready_peer_set.has(pid):
		return false
	var net_id := get_net_id(pid)
	_mark_peer_recovering(pid, net_id)
	var next_gen := int(_gens.get(pid, 0)) + 1
	if _rebuild_peer_connection(pid, next_gen):
		_announce_restart(pid, next_gen)
	# The request was accepted even if connection construction failed
	# synchronously; that path has already emitted the terminal peer_lost.
	return true


func is_webrtc_mode() -> bool:
	return _webrtc_mode


func get_multiplayer_peer() -> MultiplayerPeer:
	if _connection_delegate != null and _webrtc_mode:
		return _connection_delegate.call("get_multiplayer_peer") as MultiplayerPeer
	if _mesh != null:
		return _mesh
	return _ws_peer


func _cancel_timer(pid: String) -> void:
	if _timers.has(pid):
		var t := _timers[pid] as Timer
		t.stop()
		t.queue_free()
		_timers.erase(pid)


## Generation 0 under the UDP-only policy gets a shorter deadline: a working
## UDP path nominates in well under a second, so the full connect_timeout_sec
## would make a genuinely UDP-blocked player wait 10s before the generation-1
## fallback even arms — this caps the cost of a wrong guess. The
## _webrtc_mode guard is load-bearing: _start_connect_timeout is also called
## from _ws_become_server and _handle_ws_listen, where there is no generation
## and no ICE at all, and the WS loopback must keep the full deadline. The
## minf keeps a caller that deliberately shortened connect_timeout_sec from
## being lengthened by this path. This reads _gens[pid], which
## _create_peer_connection sets before calling _start_connect_timeout — that
## ordering is what makes it correct.
func _connect_timeout_for(pid: String) -> float:
	var recovery: Variant = _recovering_peers.get(pid)
	if recovery is Dictionary:
		var remaining_msec := int((recovery as Dictionary).get("deadline_msec", 0)) \
			- Time.get_ticks_msec()
		return maxf(0.05, minf(recovery_retry_sec, float(remaining_msec) / 1000.0))
	if _webrtc_mode and udp_first and int(_gens.get(pid, 0)) == 0:
		return minf(udp_first_timeout_sec, connect_timeout_sec)
	return connect_timeout_sec


func _start_connect_timeout(pid: String) -> void:
	_cancel_timer(pid)
	var t := Timer.new()
	t.wait_time = _connect_timeout_for(pid)
	t.one_shot = true
	t.timeout.connect(_on_connect_timeout.bind(pid))
	add_child(t)
	t.start()
	_timers[pid] = t


func _on_connect_timeout(pid: String) -> void:
	if _ready_peer_set.has(pid):
		return
	if _recovering_peers.has(pid):
		_on_recovery_timeout(pid)
		return
	if not _webrtc_mode:
		# WS fallback has no per-connection rebuild path — a bound
		# server/client either connects or it doesn't.
		_fail_peer(pid)
		return

	var gen := int(_gens.get(pid, 0))
	if gen >= MAX_GEN:
		_fail_peer(pid)
		return

	var next_gen := gen + 1
	push_warning("RollbackTransport: connect timeout for %s, restarting handshake at generation %d" % [pid, next_gen])
	# The peer must discard the connection we are closing: everything it has
	# already gathered was sent to that connection and can never reach the
	# replacement, so a peer left on the old generation contributes no
	# candidates to the new one at all. Verified in-browser — without this
	# announcement the answering side's session dies outright.
	if _rebuild_peer_connection(pid, next_gen):
		_announce_restart(pid, next_gen)


func _mark_peer_recovering(pid: String, net_id: int) -> void:
	if _recovering_peers.has(pid):
		return
	var now_msec := Time.get_ticks_msec()
	_recovering_peers[pid] = {
		"net_id": net_id,
		"started_msec": now_msec,
		"deadline_msec": now_msec + maxi(1, roundi(recovery_timeout_sec * 1000.0)),
		"attempt": 1,
	}
	if clock != null:
		clock.untrack(net_id)
	_ready_peer_set.erase(pid)
	# Keep both id maps during recovery. WebRTC mesh ids are deterministic, and
	# retaining the identity lets packets arriving immediately after reconnection
	# be authenticated even if they race ahead of the identify RPC.
	peer_recovery_started.emit(pid, net_id)


func _on_recovery_timeout(pid: String) -> void:
	var recovery: Variant = _recovering_peers.get(pid)
	if not (recovery is Dictionary):
		return
	var entry := recovery as Dictionary
	if Time.get_ticks_msec() >= int(entry.get("deadline_msec", 0)):
		_fail_recovery(pid, "recovery timeout")
		return

	entry["attempt"] = int(entry.get("attempt", 1)) + 1
	_recovering_peers[pid] = entry
	var next_gen := int(_gens.get(pid, 0)) + 1
	push_warning("RollbackTransport: recovery retry %d for %s at generation %d" % [
		int(entry["attempt"]), pid, next_gen])
	if _rebuild_peer_connection(pid, next_gen):
		_announce_restart(pid, next_gen)


func _fail_recovery(pid: String, reason: String) -> void:
	var recovery: Variant = _recovering_peers.get(pid)
	if not (recovery is Dictionary):
		return
	var net_id := int((recovery as Dictionary).get("net_id", derive_net_id(pid)))
	_recovering_peers.erase(pid)
	_cancel_timer(pid)
	_cancel_restart_timer(pid)
	_cancel_sdp_retransmit(pid)
	_ready_peer_set.erase(pid)
	_peer_to_net.erase(pid)
	_net_to_peer.erase(net_id)
	if _mesh != null and _mesh.has_peer(net_id):
		_mesh.remove_peer(net_id)
	var pc: Variant = _pcs.get(pid)
	if pc is WebRTCPeerConnection:
		(pc as WebRTCPeerConnection).close()
	_pcs.erase(pid)
	push_error("RollbackTransport: peer %s %s" % [pid, reason])
	peer_lost.emit(pid, net_id)


func _finalize_peer_loss(pid: String, net_id: int) -> void:
	_recovering_peers.erase(pid)
	_peer_to_net.erase(pid)
	_net_to_peer.erase(net_id)
	if _webrtc_mode and _mesh != null and _mesh.has_peer(net_id):
		_mesh.remove_peer(net_id)
	peer_lost.emit(pid, net_id)


func _attach_adapter_signals(a) -> void:
	if a == null:
		return
	if not a.sig_received.is_connected(_on_sig_received):
		a.sig_received.connect(_on_sig_received)
	if not a.peer_joined.is_connected(_on_peer_discovered):
		a.peer_joined.connect(_on_peer_discovered)
	if not a.peer_left.is_connected(_on_adapter_peer_left):
		a.peer_left.connect(_on_adapter_peer_left)
	if a.has_signal("connection_config_updated") \
			and not a.connection_config_updated.is_connected(_on_connection_config_updated):
		a.connection_config_updated.connect(_on_connection_config_updated)


## Takes the adapter explicitly rather than reading `_adapter`: a superseded
## start() must detach the adapter IT opened, which by then is no longer the
## one the field points at.
func _detach_adapter_signals(a) -> void:
	if a == null:
		return
	if a.sig_received.is_connected(_on_sig_received):
		a.sig_received.disconnect(_on_sig_received)
	if a.peer_joined.is_connected(_on_peer_discovered):
		a.peer_joined.disconnect(_on_peer_discovered)
	if a.peer_left.is_connected(_on_adapter_peer_left):
		a.peer_left.disconnect(_on_adapter_peer_left)
	if a.has_signal("connection_config_updated") \
			and a.connection_config_updated.is_connected(_on_connection_config_updated):
		a.connection_config_updated.disconnect(_on_connection_config_updated)


func _on_connection_config_updated(config: Dictionary) -> void:
	_set_connection_config(config)


func _set_connection_config(config: Dictionary) -> void:
	_connection_config = config.duplicate(true)
	var servers: Variant = _connection_config.get("iceServers", [])
	_ice_servers = (servers as Array).duplicate(true) if servers is Array else []


## Give up on a peer. Every timer for it must go first: the restart announce and
## the SDP retransmit both repeat on their own schedules and neither consults
## the retry budget, so a terminal failure that only emits would leave them
## talking once a second forever, against an adapter the game is probably about
## to close.
func _fail_peer(pid: String) -> void:
	_cancel_timer(pid)
	_cancel_restart_timer(pid)
	_cancel_sdp_retransmit(pid)
	push_error("RollbackTransport: peer %s connect timeout" % pid)
	transport_failed.emit("peer %s connect timeout" % pid)


## Tell `pid` we have moved to `gen`, and keep telling it until it answers at
## that generation or later. One-shot delivery is not enough: the adapter
## contract is explicitly best-effort, and the one envelope that matters is
## the one an answerer sends — having no offer to make, it produces nothing
## else that could carry the new generation, so a single drop strands it.
func _announce_restart(pid: String, gen: int) -> void:
	# We have moved off generation 0 ourselves, so the barrier has nothing left
	# to protect — and keeping it would discard the peer's replies to this very
	# announcement, which are necessarily above generation 0.
	_awaiting_rejoin_gen0.erase(pid)
	_cancel_restart_timer(pid)
	_adapter.send(pid, {"v": 1, "gen": gen, "kind": "restart"})

	var t := Timer.new()
	t.wait_time = RESTART_ANNOUNCE_INTERVAL_SEC
	t.one_shot = false
	t.timeout.connect(_on_restart_announce_tick.bind(pid, gen))
	add_child(t)
	t.start()
	_restart_timers[pid] = t


func _on_restart_announce_tick(pid: String, gen: int) -> void:
	if int(_gens.get(pid, 0)) != gen or _ready_peer_set.has(pid):
		# Superseded or connected — either way the announce is moot.
		_cancel_restart_timer(pid)
		return
	_adapter.send(pid, {"v": 1, "gen": gen, "kind": "restart"})


## Keep re-sending `pid`'s session description until something proves it
## arrived. One-shot delivery is not enough for the same reason a one-shot
## restart announcement was not: the adapter contract is explicitly best-effort,
## and a dropped description is invisible to both sides — an answerer that never
## receives an offer has no local description, so it gathers no candidates and
## emits absolutely nothing. The fault therefore surfaces only when the connect
## timeout fires, and the rebuild that follows spends the one restart the peer
## and we agree on, leaving nothing for the unilateral-timeout case MAX_GEN
## actually exists for.
##
## Evidence of arrival differs by role — see _ack_sdp for why offers need no
## receipt of their own.
func _track_sdp_for_retransmit(pid: String, gen: int, epoch: int, sdp_type: String, sdp: String) -> void:
	_cancel_sdp_retransmit(pid)
	var t := Timer.new()
	t.wait_time = SDP_RETRANSMIT_INTERVAL_SEC
	t.one_shot = false
	t.timeout.connect(_on_sdp_retransmit_tick.bind(pid))
	add_child(t)
	t.start()
	_sdp_retransmits[pid] = {
		"gen": gen, "epoch": epoch, "sdp_type": sdp_type, "sdp": sdp, "timer": t,
	}


func _on_sdp_retransmit_tick(pid: String) -> void:
	var entry: Variant = _sdp_retransmits.get(pid)
	if not (entry is Dictionary):
		return
	var e := entry as Dictionary
	# The same two guards every handshake callback carries, for the same
	# reasons: a superseded connection must not put its description back on the
	# wire under the live generation, and a peer that is already up has nothing
	# left to negotiate.
	if int(_pc_epochs.get(pid, -1)) != int(e["epoch"]) \
			or int(_gens.get(pid, 0)) != int(e["gen"]) \
			or _ready_peer_set.has(pid):
		_cancel_sdp_retransmit(pid)
		return
	_adapter.send(pid, {
		"v": 1, "gen": int(e["gen"]), "kind": "sdp",
		"sdp_type": str(e["sdp_type"]), "sdp": str(e["sdp"]),
	})


func _cancel_sdp_retransmit(pid: String) -> void:
	var entry: Variant = _sdp_retransmits.get(pid)
	if not (entry is Dictionary):
		return
	var t := (entry as Dictionary).get("timer") as Timer
	if t != null:
		t.stop()
		t.queue_free()
	_sdp_retransmits.erase(pid)


func _cancel_restart_timer(pid: String) -> void:
	if _restart_timers.has(pid):
		var t := _restart_timers[pid] as Timer
		t.stop()
		t.queue_free()
		_restart_timers.erase(pid)


## Detect whether a concrete WebRTC backend is registered. WebRTCPeerConnection
## silently falls back to the abstract WebRTCPeerConnectionExtension base when
## no GDExtension backend is configured (e.g. native headless dev builds
## without one) — and that stub's initialize() still returns OK because the
## unoverridden virtual defaults to 0/OK, so the return code alone can't be
## trusted. get_class() reveals the stub reliably.
static func _probe_webrtc_available() -> bool:
	var pc := WebRTCPeerConnection.new()
	if pc.get_class() == "WebRTCPeerConnectionExtension":
		return false
	var err := pc.initialize({})
	return err == OK
