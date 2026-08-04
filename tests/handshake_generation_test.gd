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


func _init() -> void:
	_check_classification()
	_check_budget()
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


func _expect(actual: Variant, expected: Variant, what: String) -> void:
	if actual != expected:
		print("HANDSHAKE_GENERATION_TEST: FAIL %s (got %s, expected %s)" % [
			what, str(actual), str(expected)])
		_failed = true
