## Positions its Node2D parent as a pure function of the rollback tick — the
## easy path for moving platforms and rotating hazards ("tick-pure" category:
## no snapshot needed, always consistent after a rollback because the manager
## re-applies it for whatever tick is being simulated).
##
## Add as a child, register with RollbackManager.register_tick_pure(), and
## stop moving the parent from anywhere else (no Tweens, no _physics_process).
class_name TickPureMover
extends Node

enum Pattern { PING_PONG, LOOP, SINE }

## Motion pattern: PING_PONG (a→b→a), LOOP (a→b, jump back), or SINE (eased a→b→a).
@export var pattern: Pattern = Pattern.PING_PONG
## Offsets from the parent's starting position.
@export var offset_a: Vector2 = Vector2.ZERO
@export var offset_b: Vector2 = Vector2.ZERO
## Ticks for a full cycle (a -> b -> a for PING_PONG/SINE, a -> b for LOOP).
@export var period_ticks: int = 120

var _target: Node2D
var _base_position: Vector2


func _ready() -> void:
	_target = get_parent() as Node2D
	if _target == null:
		push_error("TickPureMover: parent must be a Node2D")
		return
	_base_position = _target.position


func _tick_pure_update(t: int) -> void:
	if _target == null or period_ticks <= 0:
		return
	var cycle := float(posmod(t, period_ticks)) / float(period_ticks)
	var phase: float
	match pattern:
		Pattern.LOOP:
			phase = cycle
		Pattern.SINE:
			phase = 0.5 - 0.5 * cos(cycle * TAU)
		_:  # PING_PONG
			phase = 2.0 * cycle if cycle < 0.5 else 2.0 - 2.0 * cycle
	_target.position = _base_position + offset_a.lerp(offset_b, phase)
