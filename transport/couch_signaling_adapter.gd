# RollbackSignalingAdapter backed by a CouchWebRTC node. The game constructs
# this with the node it gets from CouchGames.webrtc — this file never
# references the CouchGames autoload identifier directly, keeping the addon
# decoupled from SDK wiring specifics.
#
# peer_exists and peer_joined both surface as peer_joined here: the transport
# treats a peer that was already in the room and one that joins after us
# identically (build a connection either way).
class_name CouchRollbackSignalingAdapter
extends RollbackSignalingAdapter

var _webrtc: CouchWebRTC


func _init(webrtc: CouchWebRTC) -> void:
	_webrtc = webrtc
	_webrtc.signal_received.connect(_on_signal_received)
	_webrtc.peer_exists.connect(_on_peer_present)
	_webrtc.peer_joined.connect(_on_peer_present)
	_webrtc.peer_left.connect(_on_peer_left)


func connect_room() -> Dictionary:
	return await _webrtc.connect_signaling()


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
