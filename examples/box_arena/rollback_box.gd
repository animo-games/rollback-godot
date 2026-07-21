## Minimal example of a RollbackManager-registered actor: a box you push around
## with RollbackMotion. Implements the full registered-node contract
## (_save_state / _load_state / _network_tick). Nothing here knows about any
## specific game — it just reads {mx, my, b} from its per-tick input and moves.
## No class_name on purpose: examples stay out of a consuming game's global
## class list; the demo preloads this script instead.
extends CharacterBody2D

const SPEED := 240.0
const GRAVITY := 900.0
const JUMP_VELOCITY := -360.0

## Which input provider in the tick's inputs dict drives this box.
@export var provider_id: StringName = &"p0"

var _vel := Vector2.ZERO
var _on_floor := false


func _network_tick(_tick: int, inputs: Dictionary) -> void:
	var in_v: Variant = inputs.get(provider_id, {})
	var input: Dictionary = in_v if in_v is Dictionary else {}
	var mx := float(input.get("mx", 0.0))
	var jump := (int(input.get("b", 0)) & 1) != 0

	_vel.x = mx * SPEED
	_vel.y += GRAVITY * RollbackManager.TICK_DELTA
	if jump and _on_floor:
		_vel.y = JUMP_VELOCITY

	var res := RollbackMotion.move(self, _vel, RollbackManager.TICK_DELTA)
	_vel = res["velocity"] as Vector2
	_on_floor = res["on_floor"] as bool


func _save_state() -> Dictionary:
	# Fixed key order — snapshot hashes depend on it.
	return {
		"px": global_position.x, "py": global_position.y,
		"vx": _vel.x, "vy": _vel.y, "f": _on_floor,
	}


func _load_state(state: Dictionary) -> void:
	global_position = Vector2(state["px"], state["py"])
	_vel = Vector2(state["vx"], state["vy"])
	_on_floor = state["f"]
