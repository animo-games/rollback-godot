# Regression test for the rollback tick rate in the hello handshake. Peers
# running different physics rates would otherwise start successfully and then
# advance the same deterministic simulation at different wall-clock speeds.
# Run headless:
#   godot --headless --path Project -s res://addons/rollback/tests/tick_rate_handshake_test.gd
extends SceneTree


func _init() -> void:
	var expected_delta := 1.0 / float(Engine.physics_ticks_per_second)
	if not is_equal_approx(RollbackManager.TICK_DELTA, expected_delta):
		print("TICK_RATE_HANDSHAKE_TEST: FAIL tick_delta=%f expected=%f" % [
			RollbackManager.TICK_DELTA, expected_delta])
		quit(1)
		return

	var session := RollbackNetSession.new()
	var hello := session._hello_payload()
	if int(hello.get("ticks_per_second", -1)) != Engine.physics_ticks_per_second:
		print("TICK_RATE_HANDSHAKE_TEST: FAIL hello=%s engine_tps=%d" % [
			str(hello), Engine.physics_ticks_per_second])
		quit(1)
		return

	var manager := RollbackManager.new()
	var transport := RollbackTransport.new()
	transport._ready_peer_set["peer"] = true
	session.setup(manager, transport)
	session._requested = true

	var failure_reasons: Array[String] = []
	session.session_failed.connect(
		func(reason: String) -> void: failure_reasons.append(reason)
	)
	hello["ticks_per_second"] = Engine.physics_ticks_per_second + 1
	session._hellos["peer"] = hello
	session._maybe_begin()

	var expected := "ticks_per_second mismatch with peer"
	if failure_reasons != [expected] or session.running:
		print("TICK_RATE_HANDSHAKE_TEST: FAIL reasons=%s running=%s expected=%s" % [
			str(failure_reasons), str(session.running), expected])
		quit(1)
		return

	session.free()
	transport.free()
	manager.free()
	print("TICK_RATE_HANDSHAKE_TEST: PASS")
	quit(0)
