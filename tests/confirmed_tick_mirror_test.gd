# Regression test for the RollbackNetSession confirmed-tick mirror exposed
# through RollbackManager: registered presentation consumers need the same
# contiguous-authoritative-input horizon without reaching into the session.
# Run headless:
#   godot --headless --path Project -s res://addons/rollback/tests/confirmed_tick_mirror_test.gd
extends SceneTree


func _init() -> void:
	var manager := RollbackManager.new()
	manager.confirmed_tick = 17
	manager.start()
	if manager.confirmed_tick != 0 or manager.tick != 0:
		print("CONFIRMED_TICK_MIRROR_TEST: FAIL reset confirmed=%d tick=%d expected_confirmed=0 expected_tick=0" % [
			manager.confirmed_tick, manager.tick])
		quit(1)
		return

	var session := RollbackNetSession.new()
	session._manager = manager
	var provider: StringName = &"local"
	session.add_local_provider(provider, func(_tick: int) -> Dictionary: return {})

	var tick_1: Dictionary = {provider: {}}
	var tick_2: Dictionary = {provider: {}}
	session._input_buf[1] = tick_1
	session._input_buf[2] = tick_2
	session._update_confirmed()
	if session.get_confirmed_tick() != 2 or manager.confirmed_tick != 2:
		print("CONFIRMED_TICK_MIRROR_TEST: FAIL contiguous session=%d manager=%d expected=2" % [
			session.get_confirmed_tick(), manager.confirmed_tick])
		quit(1)
		return

	var tick_3: Dictionary = {}
	session._input_buf[3] = tick_3
	session._update_confirmed()
	if session.get_confirmed_tick() != 2 or manager.confirmed_tick != 2:
		print("CONFIRMED_TICK_MIRROR_TEST: FAIL gap session=%d manager=%d expected=2" % [
			session.get_confirmed_tick(), manager.confirmed_tick])
		quit(1)
		return

	tick_3[provider] = {}
	session._update_confirmed()
	if session.get_confirmed_tick() != 3 or manager.confirmed_tick != 3:
		print("CONFIRMED_TICK_MIRROR_TEST: FAIL filled_gap session=%d manager=%d expected=3" % [
			session.get_confirmed_tick(), manager.confirmed_tick])
		quit(1)
		return

	print("CONFIRMED_TICK_MIRROR_TEST: PASS")
	quit(0)
