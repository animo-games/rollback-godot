## Signaling contract for the rollback transport. The rollback addon has no
## SDK dependency — RollbackTransport talks to whatever signaling backend the
## game hands it through this interface.
##
## The contract is duck-typed on purpose: concrete adapters need not subclass
## this class. Reason: the reference implementation for Couch Games ships in
## the couch-games-sdk addon as CouchRollbackSignalingAdapter, and that SDK
## addon is shared with games that do not install this addon — it cannot name
## a class that is not there. RollbackTransport/RollbackSessionController
## check an adapter against the contract at runtime via
## RollbackSignalingAdapter.implements() instead of relying on a static type.
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


## Duck check for the contract. Concrete adapters MAY subclass this class, but
## are not required to — see the header. RollbackTransport/RollbackSessionController
## call this instead of relying on a static type, so an adapter shipped by an
## addon that cannot depend on this one still works.
static func implements(obj) -> bool:
	if not (obj is Object):
		return false
	for m in ["connect_room", "send", "close"]:
		if not obj.has_method(m):
			return false
	for s in ["sig_received", "peer_joined", "peer_left"]:
		if not obj.has_signal(s):
			return false
	return true
