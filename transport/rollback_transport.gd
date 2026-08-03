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
## up before giving up (WebRTC: retries once with a fresh connection first).
@export var connect_timeout_sec := 10.0
## Testing hook: force the WebSocket loopback fallback even if a WebRTC
## backend is available.
@export var force_ws_fallback := false

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

var _known_peers: Array[String] = []  # peers currently present per signaling (joined minus left)
var _pcs: Dictionary = {}             # peer_id: String -> WebRTCPeerConnection
var _peer_to_net: Dictionary = {}     # peer_id: String -> net_id: int (learned via identify)
var _net_to_peer: Dictionary = {}     # net_id: int -> peer_id: String
var _ready_peer_set: Dictionary = {}  # peer_id: String -> true
var _timers: Dictionary = {}          # peer_id: String -> Timer
var _retry_counts: Dictionary = {}    # peer_id: String -> int


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
	_adapter = adapter
	_adapter.sig_received.connect(_on_sig_received)
	_adapter.peer_joined.connect(_on_peer_discovered)
	_adapter.peer_left.connect(_on_adapter_peer_left)

	var res: Dictionary = await _adapter.connect_room()
	if not (res.get("success", false) as bool):
		var reason := str(res.get("error", "connect_room failed"))
		push_error("RollbackTransport: signaling connect failed: %s" % reason)
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
	_peers_ready = true
	var pending := _pending_peer_ids.duplicate()
	_pending_peer_ids.clear()
	for pid in pending:
		_on_peer_discovered(pid as String)


## Tear down the transport: cancel pending timers, close the multiplayer
## peer, close the signaling adapter, and clear all learned peer state.
func stop() -> void:
	for pid in _timers.keys().duplicate():
		_cancel_timer(pid as String)

	if _mesh != null:
		_mesh.close()
		_mesh = null
	if _ws_peer != null:
		_ws_peer.close()
		_ws_peer = null
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

	if _adapter != null:
		_adapter.close()

	_pcs.clear()
	_peer_to_net.clear()
	_net_to_peer.clear()
	_ready_peer_set.clear()
	_known_peers.clear()
	_retry_counts.clear()
	_peers_ready = false
	_pending_peer_ids.clear()


# ============================================================================
# Discovery (WebRTC mesh + WS loopback)
# ============================================================================


func _on_peer_discovered(pid: String) -> void:
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
		_create_peer_connection(pid)
	else:
		_ws_discover_peer(pid)


func _create_peer_connection(pid: String) -> void:
	var pc := WebRTCPeerConnection.new()
	var init_cfg: Dictionary = {"iceServers": _ice_servers} if not _ice_servers.is_empty() else {}
	var err := pc.initialize(init_cfg)
	if err != OK:
		push_error("RollbackTransport: WebRTCPeerConnection.initialize failed for %s (err=%d)" % [pid, err])
		transport_failed.emit("peer connection init failed for %s" % pid)
		return

	pc.session_description_created.connect(_on_session_description_created.bind(pid))
	pc.ice_candidate_created.connect(_on_ice_candidate_created.bind(pid))
	_pcs[pid] = pc
	_mesh.add_peer(pc, derive_net_id(pid))

	# Locked offer rule: the lexicographically smaller peer id offers.
	if local_peer_id < pid:
		pc.create_offer()

	_start_connect_timeout(pid)


func _rebuild_peer_connection(pid: String) -> void:
	var net_id := derive_net_id(pid)
	if _mesh != null and _mesh.has_peer(net_id):
		_mesh.remove_peer(net_id)
	var old_pc: Variant = _pcs.get(pid)
	if old_pc is WebRTCPeerConnection:
		(old_pc as WebRTCPeerConnection).close()
	_pcs.erase(pid)
	_create_peer_connection(pid)


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
	if not (data is Dictionary):
		push_warning("RollbackTransport: dropping non-Dictionary signal from %s" % sender_peer_id)
		return
	var env := data as Dictionary
	if int(env.get("v", 0)) != 1:
		push_warning("RollbackTransport: dropping signal with unexpected version from %s" % sender_peer_id)
		return

	var kind := str(env.get("kind", ""))
	match kind:
		"sdp":
			if not _known_peers.has(sender_peer_id):
				_on_peer_discovered(sender_peer_id)
			_handle_sdp(sender_peer_id, env)
		"ice":
			_handle_ice(sender_peer_id, env)
		"ws_listen":
			_handle_ws_listen(sender_peer_id, env)
		_:
			push_warning("RollbackTransport: unknown signal kind '%s' from %s" % [kind, sender_peer_id])


func _handle_sdp(pid: String, env: Dictionary) -> void:
	if not _webrtc_mode:
		return
	var pc := _pcs.get(pid) as WebRTCPeerConnection
	if pc == null:
		push_warning("RollbackTransport: sdp from unknown peer connection %s" % pid)
		return
	var sdp_type := str(env.get("sdp_type", ""))
	var sdp := str(env.get("sdp", ""))
	pc.set_remote_description(sdp_type, sdp)


func _handle_ice(pid: String, env: Dictionary) -> void:
	if not _webrtc_mode:
		return
	var pc := _pcs.get(pid) as WebRTCPeerConnection
	if pc == null:
		push_warning("RollbackTransport: ice from unknown peer connection %s" % pid)
		return
	var mid := str(env.get("mid", ""))
	var index := int(env.get("index", 0))
	var candidate := str(env.get("candidate", ""))
	pc.add_ice_candidate(mid, index, candidate)


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


func _on_session_description_created(sdp_type: String, sdp: String, pid: String) -> void:
	var pc := _pcs.get(pid) as WebRTCPeerConnection
	if pc == null:
		return
	pc.set_local_description(sdp_type, sdp)
	_adapter.send(pid, {"v": 1, "kind": "sdp", "sdp_type": sdp_type, "sdp": sdp})


func _on_ice_candidate_created(mid_name: String, index_name: int, sdp_name: String, pid: String) -> void:
	_adapter.send(pid, {"v": 1, "kind": "ice", "mid": mid_name, "index": index_name, "candidate": sdp_name})


func _on_adapter_peer_left(pid: String) -> void:
	if _ready_peer_set.has(pid):
		# Already connected at the engine level; signaling leaving doesn't
		# affect an established connection.
		return
	_cancel_timer(pid)
	_retry_counts.erase(pid)
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
	_retry_counts.erase(peer_str)
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
		push_error("RollbackTransport: peer %s connect timeout" % pid)
		transport_failed.emit("peer %s connect timeout" % pid)
		return

	var retries := _retry_counts.get(pid, 0) as int
	if retries == 0:
		_retry_counts[pid] = 1
		push_warning("RollbackTransport: connect timeout for %s, retrying once" % pid)
		_rebuild_peer_connection(pid)
	else:
		push_error("RollbackTransport: peer %s connect timeout" % pid)
		transport_failed.emit("peer %s connect timeout" % pid)


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
