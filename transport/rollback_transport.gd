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
## Testing hook: force the WebSocket loopback fallback even if a WebRTC
## backend is available.
@export var force_ws_fallback := false

## Highest handshake generation. Generation 0 is the first attempt, so
## MAX_GEN == 1 allows exactly one restart — matching the previous
## "retry once" budget, but now spent in step with the peer.
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
var _webrtc_mode := false
var _mesh: WebRTCMultiplayerPeer
var _ws_peer: WebSocketMultiplayerPeer
var _ws_port := 0
var _ice_servers: Array = []
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
var _timers: Dictionary = {}          # peer_id: String -> Timer
var _gens: Dictionary = {}            # peer_id: String -> int (handshake generation, wire-visible)
var _remote_desc_set: Dictionary = {} # peer_id: String -> true (current-gen PC has a remote description)
var _pending_ice: Dictionary = {}     # peer_id: String -> Array[Dictionary] (candidates awaiting a usable connection)
var _pc_epochs: Dictionary = {}       # peer_id: String -> int (identity of the live connection; never reused)
var _restart_timers: Dictionary = {}  # peer_id: String -> Timer (re-announcing an unacknowledged restart)

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


# ============================================================================
# Lifecycle
# ============================================================================


## Join signaling, decide WebRTC-mesh vs WS-loopback mode, and start
## connecting to peers. Async — signals report progress/failure; there is no
## synchronous "connected" return.
func start(adapter) -> void:
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

	_adapter = adapter
	_attach_adapter_signals(adapter)

	var res: Dictionary = await adapter.connect_room()

	if token != _lifecycle_seq:
		# Superseded while suspended. This adapter belongs to nobody now.
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
	_known_peers.clear()
	for pid in _restart_timers.keys().duplicate():
		_cancel_restart_timer(pid as String)

	_gens.clear()
	_remote_desc_set.clear()
	_pending_ice.clear()
	_pc_epochs.clear()
	_departed.clear()
	_awaiting_rejoin_gen0.clear()
	_webrtc_mode = false
	_peers_ready = false
	_pending_peer_ids.clear()


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


func _create_peer_connection(pid: String, gen: int) -> void:
	if _mesh == null:
		# No mesh to attach to — the transport was torn down, or was never
		# started. Building a connection here would crash on add_peer and
		# repopulate state that stop() has just cleared.
		push_error("RollbackTransport: refusing to build a connection for %s with no mesh" % pid)
		return

	var pc := WebRTCPeerConnection.new()
	var init_cfg: Dictionary = {"iceServers": _ice_servers} if not _ice_servers.is_empty() else {}
	var err := pc.initialize(init_cfg)
	if err != OK:
		push_error("RollbackTransport: WebRTCPeerConnection.initialize failed for %s (err=%d)" % [pid, err])
		transport_failed.emit("peer connection init failed for %s" % pid)
		return

	# The epoch is bound into the handlers rather than read at emit time: a
	# closed connection can still deliver queued signals, and those must not be
	# published as if they belonged to its replacement.
	var epoch := _next_epoch()
	pc.session_description_created.connect(_on_session_description_created.bind(pid, gen, epoch))
	pc.ice_candidate_created.connect(_on_ice_candidate_created.bind(pid, gen, epoch))
	_gens[pid] = gen
	_pc_epochs[pid] = epoch
	_pcs[pid] = pc
	_mesh.add_peer(pc, derive_net_id(pid))

	# Locked offer rule: the lexicographically smaller peer id offers.
	if local_peer_id < pid:
		pc.create_offer()

	_start_connect_timeout(pid)


## Discard this peer's connection and build a fresh one at `gen`. Callers are
## responsible for keeping the peer in step — either by announcing the new
## generation (see _on_connect_timeout) or by adopting the peer's (see
## _on_sig_received). A one-sided rebuild strands the handshake: the peer keeps
## a connection whose candidates can no longer reach anything.
func _rebuild_peer_connection(pid: String, gen: int) -> void:
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
	_create_peer_connection(pid, gen)


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
	if kind != "sdp" and kind != "ice" and kind != "restart":
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

	match classify_generation(int(_gens.get(sender_peer_id, 0)), incoming_gen):
		GenAction.DROP_STALE:
			# From a connection we have already torn down. Applying it would
			# graft a dead handshake's ufrag onto the live one.
			return
		GenAction.ADOPT:
			if incoming_gen > MAX_GEN:
				push_warning("RollbackTransport: %s restarted past the generation budget (gen=%d)" % [
					sender_peer_id, incoming_gen])
				return
			_rebuild_peer_connection(sender_peer_id, incoming_gen)
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
	var err := pc.set_remote_description(sdp_type, sdp)
	if err != OK:
		# Held candidates stay held rather than being applied to a connection
		# that never took the description — they would only error individually.
		push_error("RollbackTransport: set_remote_description failed for %s (err=%d)" % [pid, err])
		return
	_remote_desc_set[pid] = true
	_flush_pending_ice(pid)


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


func _on_ice_candidate_created(mid_name: String, index_name: int, sdp_name: String, pid: String, gen: int, epoch: int) -> void:
	if int(_pc_epochs.get(pid, -1)) != epoch:
		# A superseded connection still draining candidates. Sending them under
		# the live generation would hand the peer a stale ufrag to discard.
		return
	_adapter.send(pid, {"v": 1, "gen": gen, "kind": "ice", "mid": mid_name, "index": index_name, "candidate": sdp_name})


func _on_adapter_peer_left(pid: String) -> void:
	if _ready_peer_set.has(pid):
		# Already connected at the engine level; signaling leaving doesn't
		# affect an established connection.
		return
	_cancel_timer(pid)
	_cancel_restart_timer(pid)
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
	_identify.rpc_id(id, local_peer_id)


func _on_engine_peer_disconnected(id: int) -> void:
	var mapped: Variant = _net_to_peer.get(id)
	if mapped == null:
		return
	var peer_str := mapped as String
	clock.untrack(id)
	_ready_peer_set.erase(peer_str)
	_peer_to_net.erase(peer_str)
	_net_to_peer.erase(id)
	if _webrtc_mode and _mesh != null and _mesh.has_peer(id):
		_mesh.remove_peer(id)
	peer_lost.emit(peer_str, id)


@rpc("any_peer", "call_remote", "reliable")
func _identify(peer_str: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	_peer_to_net[peer_str] = sender
	_net_to_peer[sender] = peer_str

	if _webrtc_mode:
		var expected := derive_net_id(peer_str)
		if sender != expected:
			push_error("RollbackTransport: net id mismatch for %s (sender=%d expected=%d)" % [peer_str, sender, expected])

	_cancel_timer(peer_str)
	_cancel_restart_timer(peer_str)
	# _gens is deliberately kept: the connection is up, and holding its
	# generation is what keeps late envelopes from a superseded handshake
	# classified as stale rather than replayed onto the live connection.
	_ready_peer_set[peer_str] = true
	clock.track(sender)
	peer_ready.emit(peer_str, sender)
	_maybe_emit_transport_ready()


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


## The engine-level multiplayer id for a peer. Returns the id learned via the
## identify handshake once connected; otherwise falls back to the
## deterministic derivation (which IS the eventual id in WebRTC mesh mode,
## since add_peer()/create_mesh() are seeded with derive_net_id — but is only
## a placeholder prediction in WS fallback mode, where WebSocketMultiplayerPeer
## assigns its own random ids that this function cannot know in advance).
func get_net_id(peer_id: String) -> int:
	if _peer_to_net.has(peer_id):
		return _peer_to_net[peer_id] as int
	return derive_net_id(peer_id)


## The peer id for an engine-level net id, from the learned map. "" if unknown.
func get_peer_id(net_id: int) -> String:
	var v: Variant = _net_to_peer.get(net_id)
	return v as String if v is String else ""


## Peer ids that have completed the identify handshake.
func get_ready_peers() -> Array[String]:
	var out: Array[String] = []
	for pid in _ready_peer_set.keys():
		out.append(pid as String)
	return out


func is_webrtc_mode() -> bool:
	return _webrtc_mode


func _cancel_timer(pid: String) -> void:
	if _timers.has(pid):
		var t := _timers[pid] as Timer
		t.stop()
		t.queue_free()
		_timers.erase(pid)


func _start_connect_timeout(pid: String) -> void:
	_cancel_timer(pid)
	var t := Timer.new()
	t.wait_time = connect_timeout_sec
	t.one_shot = true
	t.timeout.connect(_on_connect_timeout.bind(pid))
	add_child(t)
	t.start()
	_timers[pid] = t


func _on_connect_timeout(pid: String) -> void:
	if _ready_peer_set.has(pid):
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
	# Announce before rebuilding. The peer must discard the connection we are
	# about to close: everything it has already gathered was sent to that
	# connection and can never reach the replacement, so a peer left on the old
	# generation contributes no candidates to the new one at all.
	_rebuild_peer_connection(pid, next_gen)
	_announce_restart(pid, next_gen)


func _attach_adapter_signals(a) -> void:
	if a == null:
		return
	if not a.sig_received.is_connected(_on_sig_received):
		a.sig_received.connect(_on_sig_received)
	if not a.peer_joined.is_connected(_on_peer_discovered):
		a.peer_joined.connect(_on_peer_discovered)
	if not a.peer_left.is_connected(_on_adapter_peer_left):
		a.peer_left.connect(_on_adapter_peer_left)


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


## Give up on a peer. Every timer for it must go first: the restart announce
## repeats on its own schedule and does not consult the retry budget, so a
## terminal failure that only emits would leave it announcing once a second
## forever, against an adapter the game is probably about to close.
func _fail_peer(pid: String) -> void:
	_cancel_timer(pid)
	_cancel_restart_timer(pid)
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
