## Self-contained OFFLINE rollback demo — no networking, no input devices. Builds
## a RollbackManager, two boxes on a floor, and a TickPureMover platform,
## registers them with a RollbackBinder (which calls RollbackManager.register_tree
## under the hood), turns on sync_test_mode so every tick is force-rolled-back +
## resimulated + hash-diffed, and drives the sim from a fixed scripted input
## pattern. A complete registered state + a deterministic sim => zero desyncs.
## Run headless:
##   godot --headless --path . addons/rollback/examples/box_arena/box_arena.tscn
extends Node2D

const RollbackBox := preload("res://addons/rollback/examples/box_arena/rollback_box.gd")
const FLOOR_Y := 400.0

@export var run_ticks: int = 120

var _rb: RollbackManager
var _arena: Node2D
var _boxes: Array = []
var _desynced := false
var _done := false


func _ready() -> void:
	_arena = Node2D.new()
	_arena.name = "Arena"
	add_child(_arena)

	_build_floor()
	_boxes.append(_build_box("Box0", &"p0", Vector2(360, 200)))
	_boxes.append(_build_box("Box1", &"p1", Vector2(440, 200)))
	_build_platform()

	_rb = RollbackManager.new()
	_rb.name = "Rollback"
	_rb.sync_test_mode = true
	_rb.sync_test_depth = 8
	_rb.max_rollback_ticks = 16
	_rb.desync_detected.connect(_on_desync)
	add_child(_rb)

	# Scripted deterministic input — sampled fresh each tick by the manager. The
	# boxes walk APART (p0 left, p1 right) and p0 jumps every 45 ticks, so each
	# box only ever contacts the static floor. Dynamic-body-vs-dynamic-body
	# contact is deliberately avoided here: two moving bodies colliding needs the
	# _pre_network_tick / force_update_transform machinery (see the README's
	# determinism rules) to stay resim-stable — out of scope for a first example.
	_rb.add_input_provider(&"p0", func() -> Dictionary:
		return {"mx": -1.0, "my": 0.0, "b": 1 if (_rb.tick % 45) == 0 else 0})
	_rb.add_input_provider(&"p1", func() -> Dictionary:
		return {"mx": 1.0, "my": 0.0, "b": 0})

	# One call registers the whole arena subtree: the boxes (registered-node
	# contract) and the platform's TickPureMover (tick-pure). A RollbackBinder
	# dropped into a scene in the editor does the same thing.
	var binder := RollbackBinder.new()
	binder.name = "Binder"
	_arena.add_child(binder)
	binder.bind(_rb)

	_rb.after_tick.connect(_on_after_tick)
	_rb.start()
	print("box_arena: running %d ticks with sync_test_mode on..." % run_ticks)


func _build_floor() -> void:
	var body := StaticBody2D.new()
	body.name = "Floor"
	body.position = Vector2(400, FLOOR_Y)
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(1200, 40)
	shape.shape = rect
	body.add_child(shape)
	_arena.add_child(body)


func _build_box(box_name: String, provider: StringName, pos: Vector2) -> Node:
	var box := RollbackBox.new()
	box.name = box_name
	box.provider_id = provider
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(32, 32)
	shape.shape = rect
	box.add_child(shape)
	_arena.add_child(box)
	box.global_position = pos
	return box


func _build_platform() -> void:
	var platform := Node2D.new()
	platform.name = "Platform"
	platform.position = Vector2(400, 320)
	var mover := TickPureMover.new()
	mover.name = "Mover"
	mover.pattern = TickPureMover.Pattern.PING_PONG
	mover.offset_a = Vector2(-100, 0)
	mover.offset_b = Vector2(100, 0)
	mover.period_ticks = 120
	platform.add_child(mover)
	_arena.add_child(platform)


func _on_desync(report: Dictionary) -> void:
	_desynced = true
	push_error("box_arena: DESYNC %s" % str(report))


func _on_after_tick(t: int) -> void:
	if t >= run_ticks and not _done:
		_done = true
		# Stop now so no further tick runs, but defer the report: this fires
		# mid-tick, before the manager captures this tick's snapshot, so the
		# hash isn't available until _step returns.
		_rb.stop()
		_finish.call_deferred()


func _finish() -> void:
	_done = true
	_rb.stop()
	print("box_arena: done tick=%d hash=%d" % [_rb.tick, _rb.get_tick_hash(_rb.tick)])
	for b in _boxes:
		print("  %s -> %s" % [(b as Node).name, str((b as Node2D).global_position)])
	if _desynced:
		print("box_arena: FAIL — sync-test found a desync")
		get_tree().quit(1)
	else:
		print("box_arena: PASS — deterministic")
		get_tree().quit(0)
