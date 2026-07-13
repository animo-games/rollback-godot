# Deterministic replacement for CharacterBody2D.move_and_slide, for use
# inside _network_tick. move_and_slide keeps hidden internal state across
# calls (previous floor contact for snapping, platform-follow tracking) that
# a rollback restore cannot reset, so it diverges under resimulation. This
# helper is a pure function of the body's current transform, the velocity you
# pass, and the physics space: a bounded slide loop over move_and_collide.
#
# Floor contact is returned to the caller — save it in _save_state if
# gameplay reads it (coyote time, jump checks), and it rolls back with
# everything else.
class_name RollbackMotion
extends RefCounted

const MAX_SLIDES := 4
## cos(floor max angle): normals with dot(up) above this count as floor.
const FLOOR_DOT := 0.7071  # 45 degrees


## Slide `body` along `velocity * delta`. Returns
## {"velocity": Vector2, "on_floor": bool, "on_wall": bool, "on_ceiling": bool}
## where velocity has floor/wall/ceiling components removed by the slides.
static func move(body: PhysicsBody2D, velocity: Vector2, delta: float,
		up: Vector2 = Vector2.UP) -> Dictionary:
	var vel := velocity
	var motion := vel * delta
	var on_floor := false
	var on_wall := false
	var on_ceiling := false
	for _i in MAX_SLIDES:
		var col := body.move_and_collide(motion)
		if col == null:
			break
		var normal := col.get_normal()
		var d := normal.dot(up)
		if d > FLOOR_DOT:
			on_floor = true
		elif d < -FLOOR_DOT:
			on_ceiling = true
		else:
			on_wall = true
		motion = col.get_remainder().slide(normal)
		vel = vel.slide(normal)
		if motion.length_squared() < 0.00000001:
			break
	return {"velocity": vel, "on_floor": on_floor, "on_wall": on_wall, "on_ceiling": on_ceiling}


## Synchronous grounded probe — a pure query of the current world state,
## unlike CharacterBody2D.is_on_floor() which reports the last
## move_and_slide's cached result.
static func grounded(body: PhysicsBody2D, distance: float = 1.0,
		up: Vector2 = Vector2.UP) -> bool:
	return body.test_move(body.global_transform, -up * distance)
