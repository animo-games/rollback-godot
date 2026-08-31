# Regression coverage for TCP/TLS-style ordered input holds.
# Run headless:
#   godot --headless --path Project -s res://addons/rollback/tests/net_sim_ordered_hold_test.gd
extends SceneTree

const RollbackNetSim := preload("res://addons/rollback/net/net_sim.gd")


func _init() -> void:
	var delivered: Array[int] = []
	var sim = RollbackNetSim.new()
	sim.dispatch = func(_is_input: bool, _net_id: int, payload: Dictionary) -> void:
		delivered.append(int(payload.get("seq", -1)))

	sim.hold_inputs_for(10_000)
	sim.queue_send(true, 2, {"seq": 1}, 0, 0, 0.0)
	sim.queue_send(true, 2, {"seq": 2}, 0, 0, 0.0)
	sim.process()
	if not delivered.is_empty():
		_fail("held packets dispatched early")
		return

	# Expire the hold, then enqueue another input before flushing. It must sit
	# behind the held prefix rather than taking the direct-send fast path.
	sim.release_ordered_input_hold()
	sim.queue_send(true, 2, {"seq": 3}, 0, 0, 0.0)
	sim.process()
	if delivered != [1, 2, 3]:
		_fail("delivery order was %s" % str(delivered))
		return
	if sim.held_inputs != 3:
		_fail("held_inputs=%d expected=3" % sim.held_inputs)
		return

	print("NET_SIM_ORDERED_HOLD_TEST: PASS")
	quit(0)


func _fail(reason: String) -> void:
	print("NET_SIM_ORDERED_HOLD_TEST: FAIL " + reason)
	quit(1)
