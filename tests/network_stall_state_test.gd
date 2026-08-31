# Regression coverage for player-visible hard-stall notice/recovery hysteresis.
# Run headless:
#   godot --headless --path Project -s res://addons/rollback/tests/network_stall_state_test.gd
extends SceneTree


class RecoveryRequestTransport extends RollbackTransport:
	var requested_peers: Array[String] = []

	func request_recovery(peer_id: String = "") -> bool:
		requested_peers.append(peer_id)
		_recovering_peers[peer_id] = {}
		return true


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var session := RollbackNetSession.new()
	session.hard_stall_notice_ms = 250
	session.hard_stall_timeout_ms = 0
	var started: Array[int] = []
	var recovered: Array[int] = []
	session.network_stall_started.connect(func(ms: int) -> void: started.append(ms))
	session.network_stall_recovered.connect(func(ms: int) -> void: recovered.append(ms))

	session._confirmed_tick = 10
	session._update_hard_stall_state(true, 1000)
	session._update_hard_stall_state(true, 1249)
	if not started.is_empty():
		_fail("notice fired before 250ms")
		return
	session._update_hard_stall_state(true, 1250)
	if started != [250] or not session._hard_stall_notice_active:
		_fail("notice did not fire at threshold: %s" % str(started))
		return

	# One confirmed tick is not enough to hide the banner.
	session._confirmed_tick = 11
	session._update_hard_stall_state(false, 1300)
	if not recovered.is_empty() or not session._hard_stall_notice_active:
		_fail("notice cleared without a stable recovery window")
		return

	# Three confirmed ticks beyond recovery entry clear it exactly once.
	session._confirmed_tick = 14
	session._update_hard_stall_state(false, 1400)
	if recovered != [400] or session._hard_stall_notice_active:
		_fail("recovery did not clear notice: %s" % str(recovered))
		return

	# The player-visible stall still starts during a WebRTC rebuild, but its
	# generic input timeout must not race the transport's bounded recovery. Once
	# identify succeeds, a short grace lets the first unreliable input arrive.
	var recovery_session := RollbackNetSession.new()
	var transport := RollbackTransport.new()
	recovery_session._transport = transport
	recovery_session.running = true
	recovery_session.hard_stall_notice_ms = 0
	recovery_session.hard_stall_timeout_ms = 100
	recovery_session._hard_stall_since_msec = 1000
	transport._recovering_peers["peer"] = {}
	recovery_session._update_hard_stall_state(true, 1100)
	if not recovery_session.running:
		_fail("input timeout fired while transport recovery was active")
		return
	transport._recovering_peers.clear()
	recovery_session._recovery_grace_until_msec = 1200
	recovery_session._update_hard_stall_state(true, 1199)
	if not recovery_session.running:
		_fail("input timeout fired before post-recovery input grace elapsed")
		return
	var failed: Array[String] = []
	recovery_session.session_failed.connect(func(reason: String) -> void: failed.append(reason))
	recovery_session._update_hard_stall_state(true, 1200)
	if recovery_session.running or failed != ["Timed out waiting for the other player's input"]:
		_fail("input timeout did not resume after recovery grace: %s" % str(failed))
		return

	# If engine-level disconnect lags behind the application stall, the timeout
	# requests exactly one rebuild rather than quitting first.
	var proactive_session := RollbackNetSession.new()
	var proactive_transport := RecoveryRequestTransport.new()
	proactive_session._transport = proactive_transport
	proactive_session._peer_ids = ["peer"]
	proactive_session.running = true
	proactive_session.hard_stall_notice_ms = 0
	proactive_session.hard_stall_timeout_ms = 100
	proactive_session._hard_stall_since_msec = 1000
	proactive_session._update_hard_stall_state(true, 1100)
	proactive_session._update_hard_stall_state(true, 1200)
	if not proactive_session.running or proactive_transport.requested_peers != ["peer"]:
		_fail("hard stall did not target exactly one transport peer: %s" % str(
			proactive_transport.requested_peers))
		return

	# RollbackNetSession is deliberately a two-player policy layer for now. The
	# generic transport supports explicit recovery in a larger mesh, but session
	# startup must fail clearly instead of beginning with ambiguous stall policy.
	var multi_session := RollbackNetSession.new()
	var multi_transport := RollbackTransport.new()
	var multi_manager := RollbackManager.new()
	multi_transport._ready_peer_set["peer-a"] = true
	multi_transport._ready_peer_set["peer-b"] = true
	multi_session._transport = multi_transport
	multi_session._manager = multi_manager
	multi_session._requested = true
	var multi_failures: Array[String] = []
	multi_session.session_failed.connect(func(reason: String) -> void: multi_failures.append(reason))
	multi_session._maybe_begin()
	if multi_failures != ["rollback sessions require exactly one remote peer (got 2)"]:
		_fail("multi-peer rollback session did not fail explicitly: %s" % str(multi_failures))
		return
	multi_session.free()
	multi_transport.free()
	multi_manager.free()
	session.free()
	recovery_session.free()
	transport.free()
	proactive_session.free()
	proactive_transport.free()
	await process_frame

	print("NETWORK_STALL_STATE_TEST: PASS")
	quit(0)


func _fail(reason: String) -> void:
	print("NETWORK_STALL_STATE_TEST: FAIL " + reason)
	quit(1)
