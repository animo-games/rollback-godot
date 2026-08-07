# Regression test for the unilateral-rebuild bug: on a connect timeout the
# transport used to close its WebRTCPeerConnection and build a fresh one
# without telling the peer. The peer kept the old connection, had already sent
# every candidate it gathered to the connection that no longer existed, and
# never re-gathered — so the rebuilt side saw an almost empty remote candidate
# set and every pair failed. It only bit when the first attempt took longer
# than connect_timeout_sec (slow links), and only when ONE side's timer fired,
# which is what made it look intermittent.
#
# The fix tags every handshake envelope with a generation. This pins the
# classification that keeps the two sides in step. Run headless:
#   godot --headless --path Project -s res://addons/rollback/tests/handshake_generation_test.gd
extends SceneTree

var _failed := false


## Minimal stand-in for the signaling adapter: records what the transport
## sends so terminal-path tests can assert it stops talking.
class StubAdapter:
	signal sig_received(sender_peer_id: String, data: Variant)
	signal peer_joined(peer_id: String)
	signal peer_left(peer_id: String)

	## Lets a test hold connect_room() suspended, which is the window every
	## start/stop cancellation bug lives in.
	signal release_connect()

	var sent: Array = []
	var closed := false
	var suspend_connect := false

	func send(target_peer_id: String, data: Variant) -> void:
		sent.append({"pid": target_peer_id, "data": data})

	func close() -> void:
		closed = true

	func connect_room() -> Dictionary:
		if suspend_connect:
			await release_connect
		return {"success": true, "peer_id": "aaa", "room_id": "room", "ice_servers": []}

	## Everything sent so far of one envelope kind, oldest first.
	## (see StubPeerConnection below for why the tests need a real backend)
	func sent_of_kind(kind: String) -> Array:
		var out: Array = []
		for entry in sent:
			var data: Variant = (entry as Dictionary)["data"]
			if data is Dictionary and str((data as Dictionary).get("kind", "")) == kind:
				out.append(data)
		return out


## A connection that accepts whatever it is handed. Without a GDExtension
## backend, WebRTCPeerConnection resolves to the abstract extension base whose
## set_remote_description REJECTS — so the paths that only run once a
## description is applied would never execute. Gating those assertions on a
## backend being present would make them vacuous, since CI is headless too;
## implementing the virtuals is what keeps them real. The transport casts
## strictly to WebRTCPeerConnection, which this satisfies by inheritance.
class StubPeerConnection extends WebRTCPeerConnectionExtension:
	func _initialize(_config: Dictionary) -> int:
		return OK

	func _set_local_description(_type: String, _sdp: String) -> int:
		return OK

	func _set_remote_description(_type: String, _sdp: String) -> int:
		return OK

	func _add_ice_candidate(_mid: String, _index: int, _name: String) -> int:
		return OK

	func _poll() -> int:
		return OK

	func _close() -> void:
		pass


func _init() -> void:
	_check_classification()
	_check_budget()
	_check_udp_first_ice_filter()
	_check_epoch_identity()
	_check_terminal_failure_stops_announcing()
	_check_departed_peer_is_not_resurrected()
	_check_rejoin_barrier()
	_check_stop_invalidates_pending_start()
	_check_overlapping_starts_keep_the_live_adapter()
	_check_offer_is_retransmitted_until_answered()
	_check_answer_is_retransmitted_until_acked()
	_check_duplicate_description_is_not_reapplied()
	_check_ack_never_adopts()
	if _failed:
		quit(1)
		return
	print("HANDSHAKE_GENERATION_TEST: PASS")
	quit(0)


func _check_classification() -> void:
	# Same generation: the envelope belongs to the connection we are holding.
	_expect(RollbackTransport.classify_generation(0, 0), RollbackTransport.GenAction.PROCESS,
		"same generation must be processed")
	_expect(RollbackTransport.classify_generation(1, 1), RollbackTransport.GenAction.PROCESS,
		"same non-zero generation must be processed")

	# Older: from a connection we already tore down. Applying it would graft a
	# dead handshake's ufrag onto the live one.
	_expect(RollbackTransport.classify_generation(1, 0), RollbackTransport.GenAction.DROP_STALE,
		"envelope from a superseded generation must be dropped")

	# Newer: the peer restarted. Following it is the whole fix — staying put is
	# exactly the stranded state the bug produced.
	_expect(RollbackTransport.classify_generation(0, 1), RollbackTransport.GenAction.ADOPT,
		"envelope from a newer generation must be adopted")

	# An absent "gen" field reads as 0, so a peer that never restarts is
	# classified identically to one that has not restarted yet.
	_expect(RollbackTransport.classify_generation(0, int({}.get("gen", 0))),
		RollbackTransport.GenAction.PROCESS,
		"missing gen must default to generation 0")


func _check_budget() -> void:
	# One restart, matching the retry budget the generation counter replaced.
	# Both sides derive the budget from the same number, so neither can burn a
	# restart the other does not know about.
	_expect(RollbackTransport.MAX_GEN, 1, "MAX_GEN must allow exactly one restart")

	# A generation past the budget is refused rather than adopted — otherwise a
	# peer looping on restarts would drag us along indefinitely.
	_expect(RollbackTransport.classify_generation(1, 2), RollbackTransport.GenAction.ADOPT,
		"past-budget generation still classifies as newer (the caller enforces MAX_GEN)")


func _check_udp_first_ice_filter() -> void:
	# Browser bug this pins: ICE nomination landed on a TCP/TLS relay path
	# while the UDP relay pairs were cancelled unchecked — never actually
	# tried. A stream transport under this stack's unreliable channel is
	# head-of-line-blocked and useless, so generation 0 must only ever be
	# offered relays that can yield a UDP candidate pair. Escalation back to
	# the full list is a side effect of the generation bumping (already
	# covered by _check_classification/_check_budget) — this only pins the
	# filtering rule itself, which is a pure function of (servers, gen,
	# udp_first_enabled).
	var cloudflare_shaped: Array = [
		{"urls": "stun:stun.cloudflare.com:3478"},
		{"urls": "stun:stun.cloudflare.com:53"},
		{"urls": "turn:turn.cloudflare.com:3478?transport=udp", "username": "u1", "credential": "c1"},
		{"urls": "turn:turn.cloudflare.com:53?transport=udp", "username": "u1", "credential": "c1"},
		{"urls": "turn:turn.cloudflare.com:80?transport=tcp", "username": "u1", "credential": "c1"},
		{"urls": "turn:turn.cloudflare.com:80?transport=tcp", "username": "u2", "credential": "c2"},
		{"urls": "turns:turn.cloudflare.com:5349?transport=tcp", "username": "u1", "credential": "c1"},
		{"urls": "turns:turn.cloudflare.com:443?transport=tcp", "username": "u1", "credential": "c1"},
	]

	# 1. Generation 0, policy on: only the stun + turn-udp entries survive.
	var filtered: Array = RollbackTransport.ice_servers_for_generation(cloudflare_shaped, 0, true)
	_expect(filtered.size(), 4, "udp-first gen 0 must keep exactly the stun + turn-udp entries")
	for entry in filtered:
		var url := str((entry as Dictionary).get("urls", ""))
		if url.to_lower().contains("transport=tcp"):
			print("HANDSHAKE_GENERATION_TEST: FAIL a transport=tcp url survived udp-first filtering: %s" % url)
			_failed = true
		if url.to_lower().begins_with("turns:"):
			print("HANDSHAKE_GENERATION_TEST: FAIL a turns: url survived udp-first filtering: %s" % url)
			_failed = true

	# 2. Generation 1: the escalation. Same list, byte-identical.
	var gen1: Array = RollbackTransport.ice_servers_for_generation(cloudflare_shaped, 1, true)
	if gen1 != cloudflare_shaped:
		print("HANDSHAKE_GENERATION_TEST: FAIL generation 1 did not escalate back to the full list")
		_failed = true

	# 3. The rollback switch: policy disabled, generation 0 stays unfiltered.
	var disabled: Array = RollbackTransport.ice_servers_for_generation(cloudflare_shaped, 0, false)
	if disabled != cloudflare_shaped:
		print("HANDSHAKE_GENERATION_TEST: FAIL udp_first_enabled=false must leave generation 0 unfiltered")
		_failed = true

	# 4. Array-valued "urls" (Cloudflare returns both shapes across entries in
	# one list): filter WITHIN the array rather than dropping the whole entry,
	# and keep the entry's other keys by duplicating it.
	var array_urls_entry := {
		"urls": ["turn:x:3478?transport=udp", "turn:x:80?transport=tcp"],
		"username": "u", "credential": "c",
	}
	var array_filtered: Array = RollbackTransport._udp_only_ice_servers([array_urls_entry])
	if array_filtered.size() != 1:
		print("HANDSHAKE_GENERATION_TEST: FAIL array-urls entry with a surviving url must not be dropped (got %d entries)" % array_filtered.size())
		_failed = true
	else:
		var d := array_filtered[0] as Dictionary
		var urls: Array = d.get("urls", [])
		_expect(urls.size(), 1, "only the udp url should survive within the array")
		if urls.size() == 1:
			_expect(str(urls[0]), "turn:x:3478?transport=udp", "the surviving url must be the udp one")
		_expect(str(d.get("username", "")), "u", "username must survive the filter")
		_expect(str(d.get("credential", "")), "c", "credential must survive the filter")

	# 5. An entry whose entire "urls" array is TCP-only is dropped as an
	# entry — asserted in a list that still has another surviving relay, so
	# the bail-out cannot be the reason it disappeared.
	var tcp_only_entry := {"urls": ["turn:y:80?transport=tcp"]}
	var udp_entry := {"urls": "turn:z:3478?transport=udp"}
	var mixed_filtered: Array = RollbackTransport._udp_only_ice_servers([udp_entry, tcp_only_entry])
	_expect(mixed_filtered.size(), 1, "a tcp-only array-urls entry must be dropped entirely, not just thinned")

	# 6. A transport-less turn: URL survives — UDP is the RFC 5928 default.
	var bare_turn := {"urls": "turn:host:3478"}
	var bare_udp_entry := {"urls": "turn:other:3478?transport=udp"}
	var bare_filtered: Array = RollbackTransport._udp_only_ice_servers([bare_udp_entry, bare_turn])
	_expect(bare_filtered.size(), 2, "a turn: url with no transport parameter must survive")

	# 7. Bail-out: a deployment that only offers TCP/TLS relays must not be
	# handed a config that provably cannot connect, so the ORIGINAL list comes
	# back unchanged rather than a stun-only remnant.
	var tcp_only_deployment: Array = [
		{"urls": "stun:s:3478"},
		{"urls": "turn:t:80?transport=tcp"},
		{"urls": "turns:t:443?transport=tcp"},
	]
	var bailed: Array = RollbackTransport._udp_only_ice_servers(tcp_only_deployment)
	if bailed != tcp_only_deployment:
		print("HANDSHAKE_GENERATION_TEST: FAIL an all-relays-are-tcp/tls list must bail out to the original, unfiltered list")
		_failed = true

	# 8. An empty list returns empty, and a non-Dictionary entry passes
	# through rather than being dropped — we do not understand it, and
	# dropping config we cannot read is worse than keeping it.
	_expect(RollbackTransport._udp_only_ice_servers([]).size(), 0, "an empty list must return empty")
	var with_garbage: Array = RollbackTransport._udp_only_ice_servers(["garbage"])
	_expect(with_garbage.size(), 1, "a non-Dictionary entry must pass through")
	if with_garbage.size() == 1 and str(with_garbage[0]) != "garbage":
		print("HANDSHAKE_GENERATION_TEST: FAIL non-Dictionary entry was altered: %s" % str(with_garbage[0]))
		_failed = true


func _check_epoch_identity() -> void:
	# The generation is not a safe identity for a connection: a peer that
	# leaves and rejoins restarts at generation 0, so a callback queued by the
	# departed connection would pass a generation-equality guard and be applied
	# to its replacement. Epochs are drawn from a counter that never resets,
	# which is the property that makes them usable as identity.
	var t := RollbackTransport.new()
	var first := t._next_epoch()
	var second := t._next_epoch()
	if second <= first:
		print("HANDSHAKE_GENERATION_TEST: FAIL epochs must increase (got %d then %d)" % [first, second])
		_failed = true

	# Surviving a peer-left/rejoin cycle is the case that matters: generation
	# resets, epoch must not.
	t._on_adapter_peer_left("peerX")
	var third := t._next_epoch()
	if third <= second:
		print("HANDSHAKE_GENERATION_TEST: FAIL epoch reused after peer left (got %d, previous %d)" % [
			third, second])
		_failed = true
	t.free()


func _check_terminal_failure_stops_announcing() -> void:
	# The restart announce repeats on its own schedule and does not consult the
	# retry budget. A terminal timeout that only emitted transport_failed left
	# it announcing once a second forever, against an adapter the game is about
	# to close — so exhausting the budget must take every timer with it.
	var t := RollbackTransport.new()
	var adapter := StubAdapter.new()
	t._adapter = adapter
	t._active = true
	t._webrtc_mode = true
	t.local_peer_id = "aaa"

	# Sitting at the last generation with an announce in flight, and a
	# description still being repeated — the SDP retransmit has the same
	# property that made this test necessary: its own schedule, no knowledge of
	# the retry budget.
	t._gens["zzz"] = RollbackTransport.MAX_GEN
	t._announce_restart("zzz", RollbackTransport.MAX_GEN)
	t._track_sdp_for_retransmit("zzz", RollbackTransport.MAX_GEN, 1, "offer", "SDP-OFFER")
	t._start_connect_timeout("zzz")
	if not t._restart_timers.has("zzz"):
		print("HANDSHAKE_GENERATION_TEST: FAIL announce timer was not created")
		_failed = true

	t._on_connect_timeout("zzz")

	if t._restart_timers.has("zzz"):
		print("HANDSHAKE_GENERATION_TEST: FAIL restart timer survived terminal failure")
		_failed = true
	if t._sdp_retransmits.has("zzz"):
		print("HANDSHAKE_GENERATION_TEST: FAIL sdp retransmit survived terminal failure")
		_failed = true
	if t._timers.has("zzz"):
		print("HANDSHAKE_GENERATION_TEST: FAIL connect timer survived terminal failure")
		_failed = true
	t.free()


func _check_departed_peer_is_not_resurrected() -> void:
	# Handshake envelopes still in flight when a peer leaves must not rebuild
	# it. Re-announced restarts make such stragglers common, and a resurrected
	# peer only exists to fail its own connect timeout.
	var t := RollbackTransport.new()
	var adapter := StubAdapter.new()
	t._adapter = adapter
	t._active = true
	t._webrtc_mode = true
	t._peers_ready = true
	t.local_peer_id = "aaa"

	t._on_adapter_peer_left("zzz")
	t._on_sig_received("zzz", {"v": 1, "gen": 1, "kind": "restart"})

	if t._known_peers.has("zzz"):
		print("HANDSHAKE_GENERATION_TEST: FAIL departed peer was rediscovered by a late envelope")
		_failed = true
	if t._pcs.has("zzz"):
		print("HANDSHAKE_GENERATION_TEST: FAIL departed peer got a new connection")
		_failed = true

	# A genuine rejoin is the one thing that clears the tombstone.
	t._on_peer_discovered("zzz")
	if t._departed.has("zzz"):
		print("HANDSHAKE_GENERATION_TEST: FAIL peer_joined did not clear the tombstone")
		_failed = true

	# And nothing is accepted at all once the transport is stopped.
	t._active = false
	t._known_peers.clear()
	t._on_sig_received("qqq", {"v": 1, "gen": 1, "kind": "restart"})
	if t._known_peers.has("qqq"):
		print("HANDSHAKE_GENERATION_TEST: FAIL envelope was processed after stop")
		_failed = true
	t.free()


func _check_rejoin_barrier() -> void:
	# A rejoin resets both sides to generation 0, so an envelope still in flight
	# from the peer's PREVIOUS incarnation reads as a newer generation. Adopting
	# it pushes us to the terminal generation, after which the rejoined peer's
	# legitimate generation-0 offer is discarded as stale and the session is
	# dead. On main a stale candidate was merely ignored by the browser, so this
	# would be a regression rather than an inherited weakness.
	var t := RollbackTransport.new()
	t._adapter = StubAdapter.new()
	t._active = true
	t._webrtc_mode = true
	t.local_peer_id = "aaa"

	# Leave, then rejoin. Discovery is left buffered (_peers_ready false) so the
	# barrier can be observed without needing a real mesh.
	t._on_adapter_peer_left("zzz")
	t._on_peer_discovered("zzz")
	if not t._awaiting_rejoin_gen0.has("zzz"):
		print("HANDSHAKE_GENERATION_TEST: FAIL rejoin did not raise the generation barrier")
		_failed = true

	# The straggler from the previous incarnation must not move us.
	t._peers_ready = true
	t._known_peers.append("zzz")
	t._gens["zzz"] = 0
	t._on_sig_received("zzz", {"v": 1, "gen": 1, "kind": "ice", "mid": "0", "index": 0, "candidate": "x"})
	if int(t._gens.get("zzz", -1)) != 0:
		print("HANDSHAKE_GENERATION_TEST: FAIL stale pre-leave envelope was adopted (gen=%s)" % [
			str(t._gens.get("zzz"))])
		_failed = true

	# The rejoined peer speaking at generation 0 lowers the barrier.
	t._on_sig_received("zzz", {"v": 1, "gen": 0, "kind": "ice", "mid": "0", "index": 0, "candidate": "x"})
	if t._awaiting_rejoin_gen0.has("zzz"):
		print("HANDSHAKE_GENERATION_TEST: FAIL generation-0 envelope did not lower the barrier")
		_failed = true
	t.free()


func _check_stop_invalidates_pending_start() -> void:
	# start() suspends in connect_room(). A stop() during that suspension must
	# invalidate the resumption, or a late resolution reconnects a transport
	# that has already been torn down.
	# Deliberately outside the tree: stop() must survive teardown ordering where
	# the node has already been removed.
	var t := RollbackTransport.new()
	t._adapter = StubAdapter.new()
	var token := t._lifecycle_seq
	t.stop()
	if t._lifecycle_seq == token:
		print("HANDSHAKE_GENERATION_TEST: FAIL stop() did not invalidate a pending start")
		_failed = true
	if t._active:
		print("HANDSHAKE_GENERATION_TEST: FAIL stop() left the transport active")
		_failed = true
	t.free()


func _check_overlapping_starts_keep_the_live_adapter() -> void:
	# Two starts with the SAME adapter, the first still suspended in
	# connect_room(). Cleanup that fires on the superseded resumption must not
	# close or detach the adapter the newer lifecycle is now using — doing so
	# leaves _adapter pointing at a dead object and silently loses signaling.
	var t := RollbackTransport.new()
	# WS mode so the completing start never reaches `multiplayer`, which does
	# not exist outside the tree. The cancellation path under test is the same.
	t.force_ws_fallback = true
	var adapter := StubAdapter.new()
	adapter.suspend_connect = true

	t.start(adapter)   # suspends inside connect_room()
	t.start(adapter)   # supersedes the first, same adapter
	adapter.release_connect.emit()

	if adapter.closed:
		print("HANDSHAKE_GENERATION_TEST: FAIL superseded start closed the live adapter")
		_failed = true
	if not adapter.sig_received.is_connected(t._on_sig_received):
		print("HANDSHAKE_GENERATION_TEST: FAIL superseded start detached the live adapter's signals")
		_failed = true
	if t._adapter != adapter:
		print("HANDSHAKE_GENERATION_TEST: FAIL _adapter no longer points at the live adapter")
		_failed = true
	t.free()


## A transport mid-handshake with one peer, wired far enough to exercise the
## envelope paths without a real WebRTC backend — see StubPeerConnection.
func _mid_handshake(adapter: StubAdapter, epoch: int) -> RollbackTransport:
	var t := RollbackTransport.new()
	t._adapter = adapter
	t._active = true
	t._webrtc_mode = true
	t._peers_ready = true
	t.local_peer_id = "aaa"          # "aaa" < "zzz", so this side offers
	t._known_peers.append("zzz")
	t._gens["zzz"] = 0
	t._pc_epochs["zzz"] = epoch
	t._pcs["zzz"] = StubPeerConnection.new()
	return t


func _check_offer_is_retransmitted_until_answered() -> void:
	# A description is sent exactly once, and every drop point on the way to the
	# peer is silent — the sender's signaling socket may not be open, and the
	# server drops an envelope whose target socket it cannot resolve, which a
	# peer's ordinary socket reconnect guarantees a window of. Nothing noticed
	# until the connect timeout, whose rebuild then spends the single restart
	# both sides agree on. Repeating the offer is what keeps that budget for
	# the unilateral-timeout case it was actually sized for.
	var adapter := StubAdapter.new()
	var t := _mid_handshake(adapter, 7)

	t._on_session_description_created("offer", "SDP-OFFER", "zzz", 0, 7)
	if not t._sdp_retransmits.has("zzz"):
		print("HANDSHAKE_GENERATION_TEST: FAIL offer was sent without arming a retransmit")
		_failed = true

	# The drop is invisible, so the only thing that can repeat the offer is the
	# timer firing again.
	t._on_sdp_retransmit_tick("zzz")
	var offers := adapter.sent_of_kind("sdp")
	_expect(offers.size(), 2, "a dropped offer must be retransmitted")
	if offers.size() == 2 and offers[1] != offers[0]:
		print("HANDSHAKE_GENERATION_TEST: FAIL retransmitted offer differs from the original")
		_failed = true

	# The answer is a stronger receipt than any ack: it cannot exist unless the
	# offer arrived. That is why offers are never acknowledged explicitly.
	t._on_sig_received("zzz", {
		"v": 1, "gen": 0, "kind": "sdp", "sdp_type": "answer", "sdp": "SDP-ANSWER"})
	if t._sdp_retransmits.has("zzz"):
		print("HANDSHAKE_GENERATION_TEST: FAIL an answer did not stop the offer retransmit")
		_failed = true
	_expect(adapter.sent_of_kind("sdp_ack").size(), 1, "an applied answer must be acknowledged")

	# And a superseded connection must never put its description back on the
	# wire under the live generation — the same guard every handshake callback
	# carries.
	t._track_sdp_for_retransmit("zzz", 0, 7, "offer", "SDP-OFFER")
	t._pc_epochs["zzz"] = 8
	var before := adapter.sent_of_kind("sdp").size()
	t._on_sdp_retransmit_tick("zzz")
	_expect(adapter.sent_of_kind("sdp").size(), before,
		"a retransmit from a superseded epoch must not be sent")
	if t._sdp_retransmits.has("zzz"):
		print("HANDSHAKE_GENERATION_TEST: FAIL superseded retransmit was not cancelled")
		_failed = true
	t.free()


func _check_answer_is_retransmitted_until_acked() -> void:
	# The answerer is the side that cannot recover on its own: having no offer
	# to make it emits nothing after its answer, so no later envelope of its own
	# can carry the fact that the answer was lost — exactly the silence that
	# forces a restart to be re-announced. An explicit receipt is the only thing
	# that can stop it repeating.
	var adapter := StubAdapter.new()
	var t := _mid_handshake(adapter, 7)

	t._on_session_description_created("answer", "SDP-ANSWER", "zzz", 0, 7)
	t._on_sdp_retransmit_tick("zzz")
	_expect(adapter.sent_of_kind("sdp").size(), 2, "a dropped answer must be retransmitted")

	# A receipt for a generation we are not repeating proves nothing.
	t._on_sig_received("zzz", {"v": 1, "gen": 1, "kind": "sdp_ack", "sdp_type": "answer"})
	if not t._sdp_retransmits.has("zzz"):
		print("HANDSHAKE_GENERATION_TEST: FAIL an ack from another generation stopped the retransmit")
		_failed = true

	# Nor does one for a description we are not repeating.
	t._on_sig_received("zzz", {"v": 1, "gen": 0, "kind": "sdp_ack", "sdp_type": "offer"})
	if not t._sdp_retransmits.has("zzz"):
		print("HANDSHAKE_GENERATION_TEST: FAIL an ack for another description stopped the retransmit")
		_failed = true

	t._on_sig_received("zzz", {"v": 1, "gen": 0, "kind": "sdp_ack", "sdp_type": "answer"})
	if t._sdp_retransmits.has("zzz"):
		print("HANDSHAKE_GENERATION_TEST: FAIL a matching ack did not stop the retransmit")
		_failed = true
	t.free()


func _check_duplicate_description_is_not_reapplied() -> void:
	# What made retransmission look expensive to add: re-applying a description
	# mid-handshake renegotiates a connection that is still coming up. It is
	# avoidable — the receiver already knows it has taken this generation's
	# description, so the duplicate can simply be dropped. The ack is re-sent
	# instead, because a peer still repeating has lost its receipt, not its
	# description.
	var adapter := StubAdapter.new()
	var t := _mid_handshake(adapter, 7)
	t._remote_desc_set["zzz"] = true
	# Proxy for "the apply path did not run": applying a description flushes
	# held candidates, so a surviving buffer means it was skipped.
	t._pending_ice["zzz"] = [{"mid": "0", "index": 0, "candidate": "x"}]

	t._on_sig_received("zzz", {
		"v": 1, "gen": 0, "kind": "sdp", "sdp_type": "answer", "sdp": "SDP-ANSWER"})

	if not t._pending_ice.has("zzz"):
		print("HANDSHAKE_GENERATION_TEST: FAIL a duplicate description was re-applied")
		_failed = true
	_expect(adapter.sent_of_kind("sdp_ack").size(), 1,
		"a duplicate description must re-send the lost receipt")
	t.free()


func _check_ack_never_adopts() -> void:
	# An ack acknowledges a description WE sent, so one above our generation
	# cannot legitimately exist. Routing it through classify_generation anyway
	# would let a peer tear down a live connection with a receipt for a
	# description that was never issued.
	var adapter := StubAdapter.new()
	var t := _mid_handshake(adapter, 7)
	var pc: Variant = t._pcs.get("zzz")
	t._remote_desc_set["zzz"] = true

	t._on_sig_received("zzz", {
		"v": 1, "gen": RollbackTransport.MAX_GEN, "kind": "sdp_ack", "sdp_type": "answer"})

	# Asserted against the connection itself rather than _gens/_pc_epochs: with
	# no mesh to attach to, an adopted rebuild discards the old connection and
	# then refuses to build the replacement, so the generation never moves and
	# watching it would pass either way. What the rebuild unmistakably does do
	# is throw away the live connection and everything learned on it.
	if t._pcs.get("zzz") != pc:
		print("HANDSHAKE_GENERATION_TEST: FAIL an ack tore down the live connection")
		_failed = true
	if not t._remote_desc_set.has("zzz"):
		print("HANDSHAKE_GENERATION_TEST: FAIL an ack discarded the applied description")
		_failed = true
	t.free()


func _expect(actual: Variant, expected: Variant, what: String) -> void:
	if actual != expected:
		print("HANDSHAKE_GENERATION_TEST: FAIL %s (got %s, expected %s)" % [
			what, str(actual), str(expected)])
		_failed = true
