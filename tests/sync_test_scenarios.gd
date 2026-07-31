extends SceneTree

# Rollback addon self-test. Headless, no editor needed:
#   godot --headless --path . --script addons/rollback/tests/sync_test_scenarios.gd
#
# Scenario 1 (logic): pure-GDScript pawns, forced rollback depth 8 every
#   tick for 600 ticks -> expect zero desyncs.
# Scenario 2 (canary): a pawn with deliberately unregistered mutable state
#   -> expect the sync test to CATCH the desync (harness works).
# Scenario 3 (physics): CharacterBody2D pawns via move_and_slide against
#   static geometry + a tick-pure moving platform, forced rollback depth 8
#   every tick for 900 ticks -> expect zero desyncs. This is the phase-1
#   probe of GodotPhysics2D kinematic determinism under restore + resim.

const RBManager := preload("res://addons/rollback/rollback_manager.gd")
const TPMover := preload("res://addons/rollback/tick_pure_mover.gd")

var _failed := false


class LogicPawn extends Node:
	var provider: StringName
	var pos := Vector2.ZERO
	var vel := Vector2.ZERO
	var energy := 100.0
	var counter := 0

	func _save_state() -> Dictionary:
		return {"pos": pos, "vel": vel, "energy": energy, "counter": counter}

	func _load_state(s: Dictionary) -> void:
		pos = s["pos"]
		vel = s["vel"]
		energy = s["energy"]
		counter = s["counter"]

	func _network_tick(_t: int, inputs: Dictionary) -> void:
		var inp: Dictionary = inputs.get(provider, {})
		var mv: Vector2 = inp.get("move", Vector2.ZERO)
		vel = vel * 0.9 + mv * 25.0
		pos += vel * (1.0 / 60.0)
		energy += sin(pos.x * 0.01) * 0.5 - 0.1
		if bool(inp.get("jump", false)):
			counter += 1
			vel.y -= 100.0


class CanaryPawn extends Node:
	var pos := Vector2.ZERO
	var hidden := 0  # deliberately NOT in _save_state — must be caught

	func _save_state() -> Dictionary:
		return {"pos": pos}

	func _load_state(s: Dictionary) -> void:
		pos = s["pos"]

	func _network_tick(_t: int, _inputs: Dictionary) -> void:
		hidden += 1
		pos = Vector2(float(hidden), 0.0)


class PhysicsPawn extends CharacterBody2D:
	const GRAVITY := 1200.0
	const SPEED := 140.0
	const JUMP_VELOCITY := -420.0
	const Motion := preload("res://addons/rollback/rollback_motion.gd")
	var provider: StringName
	## false: engine move_and_slide (known hidden state); true: RollbackMotion.
	var use_helper := false
	var grounded := false

	func _init() -> void:
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(24, 32)
		shape.shape = rect
		add_child(shape)

	func _save_state() -> Dictionary:
		return {"pos": global_position, "vel": velocity, "grounded": grounded}

	func _load_state(s: Dictionary) -> void:
		global_position = s["pos"]
		velocity = s["vel"]
		grounded = s["grounded"]

	func _network_tick(_t: int, inputs: Dictionary) -> void:
		var inp: Dictionary = inputs.get(provider, {})
		var mv: Vector2 = inp.get("move", Vector2.ZERO)
		velocity.x = mv.x * SPEED
		velocity.y += GRAVITY * RollbackManager.TICK_DELTA
		if bool(inp.get("jump", false)) and Motion.grounded(self):
			velocity.y = JUMP_VELOCITY
		if use_helper:
			var result := Motion.move(self, velocity, RollbackManager.TICK_DELTA)
			velocity = result["velocity"]
			grounded = result["on_floor"]
		else:
			move_and_slide()
			grounded = is_on_floor()


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	# Speed up wall time: fixed 1/60 physics delta is unchanged, the engine
	# just runs more steps per render frame.
	Engine.max_fps = 0
	Engine.time_scale = 4.0
	await _scenario_logic()
	await _scenario_canary()
	# Informational probes of engine move_and_slide under resim (hidden
	# internal state — expected to desync; do not gate the suite):
	await _scenario_physics("physics/slide+platform", false, true, 600, false)
	await _scenario_physics("physics/slide-noplatform", false, false, 600, false)
	# The supported pattern — this one gates the suite. Run it at more than one
	# sim rate: the physics-server transform staleness this scenario exercises
	# only surfaces once the per-tick step is large enough for the two pawns to
	# reach a grazing contact, so a 60 Hz-only suite passed while the very same
	# scenario had 54 desyncs at 30 Hz.
	for rate in [60, 30]:
		RBManager.set_tick_rate(rate)
		await _scenario_physics(
			"physics/helper+platform@%dHz" % rate, true, true, 900, true)
	RBManager.set_tick_rate(60)
	print("ROLLBACK TEST: " + ("FAIL" if _failed else "PASS"))
	quit(1 if _failed else 0)


func _scripted_input(t: int, salt: int) -> Dictionary:
	var h := hash(str(t * 2654435761 + salt))
	return {
		"move": Vector2(float(h % 3 - 1), 0.0),
		"jump": (h >> 4) % 7 == 0,
	}


func _make_manager(stage: Node, depth: int) -> RBManager:
	var rb: RBManager = RBManager.new()
	rb.name = "Rollback"
	rb.max_rollback_ticks = depth
	rb.sync_test_depth = depth
	rb.sync_test_mode = true
	stage.add_child(rb)
	rb.add_input_provider(&"p1", func() -> Dictionary: return _scripted_input(rb.tick, 11))
	rb.add_input_provider(&"p2", func() -> Dictionary: return _scripted_input(rb.tick, 77))
	return rb


func _run_ticks(rb: RBManager, ticks: int) -> Array:
	var desyncs: Array = []
	rb.desync_detected.connect(func(r: Dictionary) -> void: desyncs.append(r))
	rb.start()
	while rb.tick < ticks:
		await physics_frame
	rb.stop()
	return desyncs


func _finish_scenario(label: String, rb: RBManager, desyncs: Array, expect_desync: bool) -> void:
	print("%s stats: %s" % [label, str(rb.get_stats())])
	var bad := (not desyncs.is_empty()) if not expect_desync else desyncs.is_empty()
	if bad:
		_failed = true
		if expect_desync:
			printerr("%s FAILED: harness did not catch the planted desync" % label)
		else:
			printerr("%s FAILED, first desync: %s" % [label, str(desyncs[0])])
	else:
		print("%s: ok (%d desyncs, expected %s)" % [label, desyncs.size(),
				"some" if expect_desync else "none"])


func _scenario_logic() -> void:
	var stage := Node2D.new()
	stage.name = "LogicStage"
	root.add_child(stage)
	var rb := _make_manager(stage, 8)
	for cfg in [["PawnA", &"p1"], ["PawnB", &"p2"], ["PawnC", &"p1"]]:
		var pawn := LogicPawn.new()
		pawn.name = cfg[0]
		pawn.provider = cfg[1]
		stage.add_child(pawn)
		rb.register(pawn)
	var desyncs := await _run_ticks(rb, 600)
	_finish_scenario("logic", rb, desyncs, false)
	stage.queue_free()
	await process_frame


func _scenario_canary() -> void:
	var stage := Node2D.new()
	stage.name = "CanaryStage"
	root.add_child(stage)
	var rb := _make_manager(stage, 4)
	var pawn := CanaryPawn.new()
	pawn.name = "Canary"
	stage.add_child(pawn)
	rb.register(pawn)
	var desyncs := await _run_ticks(rb, 30)
	_finish_scenario("canary", rb, desyncs, true)
	stage.queue_free()
	await process_frame


func _scenario_physics(label: String, use_helper: bool, with_platform: bool,
		ticks: int, strict: bool) -> void:
	var stage := Node2D.new()
	stage.name = "PhysicsStage"
	root.add_child(stage)

	for cfg in [
		["Floor", Vector2(2000, 40), Vector2(0, 300)],
		["WallL", Vector2(40, 800), Vector2(-400, 0)],
		["WallR", Vector2(40, 800), Vector2(400, 0)],
	]:
		stage.add_child(_static_box(cfg[0], cfg[1], cfg[2]))

	var rb := _make_manager(stage, 8)
	if with_platform:
		var platform := _static_box("Platform", Vector2(200, 20), Vector2(0, 150))
		stage.add_child(platform)
		var mover: TPMover = TPMover.new()
		mover.name = "Mover"
		mover.offset_a = Vector2(-140, 0)
		mover.offset_b = Vector2(140, 0)
		mover.period_ticks = 180
		platform.add_child(mover)
		rb.register_tick_pure(mover)

	for cfg in [["PawnA", &"p1", Vector2(-60, 260)], ["PawnB", &"p2", Vector2(60, 260)]]:
		var pawn := PhysicsPawn.new()
		pawn.name = cfg[0]
		pawn.provider = cfg[1]
		pawn.use_helper = use_helper
		stage.add_child(pawn)
		pawn.global_position = cfg[2]
		rb.register(pawn)

	var desyncs := await _run_ticks(rb, ticks)
	if strict:
		_finish_scenario(label, rb, desyncs, false)
	else:
		print("%s (informational): %d desyncs over %d ticks, stats: %s" % [
				label, desyncs.size(), ticks, str(rb.get_stats())])
		if not desyncs.is_empty():
			print("%s first desync: %s" % [label, str(desyncs[0])])
	stage.queue_free()
	await process_frame


func _static_box(box_name: String, size: Vector2, pos: Vector2) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.name = box_name
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = size
	shape.shape = rect
	body.add_child(shape)
	body.position = pos
	return body
