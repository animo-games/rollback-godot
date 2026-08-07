# Regression coverage for the wall-clock prediction-pressure governor.
# Run headless:
#   godot --headless --path Project -s res://addons/rollback/tests/prediction_pressure_test.gd
extends SceneTree

const RollbackTimeSync := preload("res://addons/rollback/net/time_sync.gd")


func _init() -> void:
	var sync = RollbackTimeSync.new()

	# max_prediction=12 has a six-tick reserve, so depth <= 6 is free.
	for _i in 20:
		if sync.should_sleep_for_prediction_pressure(6, 12):
			_fail("slept below the soft boundary")
			return

	# Inside the pressure band, eight due frames spend exactly four frames.
	var sleeps := 0
	for _i in 8:
		if sync.should_sleep_for_prediction_pressure(9, 12):
			sleeps += 1
	if sleeps != 4:
		_fail("depth 9 spent %d frames, expected 4" % sleeps)
		return

	# The explicit session stall branch owns the hard cap.
	for _i in 8:
		if sync.should_sleep_for_prediction_pressure(12, 12):
			_fail("pressure governor hid the hard cap")
			return

	# Recovery clears fractional credit; one depth-7 call alone cannot sleep.
	sync.should_sleep_for_prediction_pressure(6, 12)
	if sync.should_sleep_for_prediction_pressure(7, 12):
		_fail("stale pressure credit survived recovery")
		return

	print("PREDICTION_PRESSURE_TEST: PASS")
	quit(0)


func _fail(reason: String) -> void:
	print("PREDICTION_PRESSURE_TEST: FAIL " + reason)
	quit(1)
