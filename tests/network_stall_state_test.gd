# Regression coverage for player-visible hard-stall notice/recovery hysteresis.
# Run headless:
#   godot --headless --path Project -s res://addons/rollback/tests/network_stall_state_test.gd
extends SceneTree


func _init() -> void:
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

	print("NETWORK_STALL_STATE_TEST: PASS")
	quit(0)


func _fail(reason: String) -> void:
	print("NETWORK_STALL_STATE_TEST: FAIL " + reason)
	quit(1)
