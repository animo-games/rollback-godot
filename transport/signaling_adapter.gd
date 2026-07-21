## Abstract signaling contract for the rollback transport. The rollback addon
## has no SDK dependency — RollbackTransport talks to whatever signaling
## backend the game hands it through this interface. The game is responsible
## for wiring a concrete adapter (e.g. a `CouchWebRTC`-backed subclass) to the
## platform's actual signaling channel.
##
## Contract notes:
##   - Delivery of send() is best-effort. Unknown/disconnected targets are
##     dropped silently by most backends — drive retries off connection state,
##     not the signaling channel.
##   - Data blobs typically make a JSON round-trip: ints arrive as floats on
##     the other side. Always cast with int() before using a numeric field.
##   - peer_id is an opaque string identifying a signaling-room participant.
class_name RollbackSignalingAdapter
extends RefCounted

## A handshake blob from another peer.
signal sig_received(peer_id: String, data: Variant)
## A peer is present in the signaling room (already there or just joined —
## callers treat both the same way).
signal peer_joined(peer_id: String)
## A peer left the signaling room.
signal peer_left(peer_id: String)


## Join the signaling room. Async — await the result.
## Returns {success: bool, error?: String, peer_id?: String, room_id?: String,
## ice_servers?: Array}.
func connect_room() -> Dictionary:
	push_error("RollbackSignalingAdapter.connect_room not implemented")
	return {"success": false, "error": "not implemented"}


## Relay an opaque JSON-serializable blob to one peer. Best-effort delivery.
func send(_target_peer_id: String, _data: Variant) -> void:
	push_error("RollbackSignalingAdapter.send not implemented")


## Leave the signaling room. Existing peer connections (if any) are unaffected.
func close() -> void:
	push_error("RollbackSignalingAdapter.close not implemented")
