## RollbackSignalingAdapter backed by a CouchWebRTC node. The game constructs
## this with the node it gets from CouchGames.webrtc — this file never
## references the CouchGames autoload identifier directly, keeping the addon
## decoupled from SDK wiring specifics.
##
## peer_exists and peer_joined both surface as peer_joined here: the transport
## treats a peer that was already in the room and one that joins after us
## identically (build a connection either way).
##
## `explicit_room_id` picks the signaling room connect_room() joins: empty =
## the platform's default lobby room (existing dev-harness/platform behavior,
## unchanged); non-empty = an explicit room (menu host/join-code flow, e.g.
## CouchWebRTC.room_id_for_code). Reconnecting to a room the peer is already
## in is safe: the signaling server dedups by peerId (a new socket with the
## same peerId replaces the old one) and re-announces peer presence.
class_name CouchRollbackSignalingAdapter
extends RollbackSignalingAdapter

var _webrtc: CouchWebRTC
var _explicit_room_id := ""


func _init(webrtc: CouchWebRTC, explicit_room_id: String = "") -> void:
	_webrtc = webrtc
	_explicit_room_id = explicit_room_id
	_webrtc.signal_received.connect(_on_signal_received)
	_webrtc.peer_exists.connect(_on_peer_present)
	_webrtc.peer_joined.connect(_on_peer_present)
	_webrtc.peer_left.connect(_on_peer_left)


func connect_room() -> Dictionary:
	return await _webrtc.connect_signaling(_explicit_room_id)


func send(target_peer_id: String, data: Variant) -> void:
	_webrtc.send_signal(target_peer_id, data)


func close() -> void:
	_webrtc.disconnect_signaling()


func _on_signal_received(sender_peer_id: String, data: Variant) -> void:
	sig_received.emit(sender_peer_id, data)


func _on_peer_present(peer_id: String) -> void:
	peer_joined.emit(peer_id)


func _on_peer_left(peer_id: String) -> void:
	peer_left.emit(peer_id)
