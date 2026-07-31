## Deterministic replacement for CharacterBody2D.move_and_slide, for use
## inside _network_tick. move_and_slide keeps hidden internal state across
## calls (previous floor contact for snapping, platform-follow tracking) that
## a rollback restore cannot reset, so it diverges under resimulation. This
## helper is a pure function of the body's current transform, the velocity you
## pass, and the physics space: a bounded slide loop over move_and_collide.
##
## Floor contact is returned to the caller — save it in _save_state if
## gameplay reads it (coyote time, jump checks), and it rolls back with
## everything else.
class_name RollbackMotion
extends RefCounted

const MAX_SLIDES := 4
## cos(floor max angle): normals with dot(up) above this count as floor.
const FLOOR_DOT := 0.7071  # 45 degrees
## Post-move positions snap to a 1/64 px grid. The physics server's
## depenetration at rest is noisy at the float32-ulp level (~2^-12 px at
## world scale ~1000) and the noise depends on engine-internal broadphase
## state that rollback snapshots cannot capture, so live and resimulated
## passes settle on different ulp-neighbors. Snapping to a grid ~20x coarser
## than the noise (and far below anything visible) makes the resting pose a
## single stable fixed point in both passes. 64 is a power of two, so the
## quantization is exact in float and idempotent.
const POSITION_QUANT := 64.0
## Per-axis displacement below this after a move() is treated as rest-contact
## depenetration noise and snapped back to the pre-move coordinate. Real
## gameplay motion is orders of magnitude larger per tick; recovery noise at
## rest is ~0.001 px. Without this, a resting pose whose recovery output sits
## near a POSITION_QUANT cell midpoint can round to adjacent grid points in
## live vs resimulated passes.
const MICRO_MOTION_EPS := 0.01


## Slide `body` along `velocity * delta`. Returns
## {"velocity": Vector2, "on_floor": bool, "on_wall": bool, "on_ceiling": bool,
## "collisions": Array[KinematicCollision2D]}
## where velocity has floor/wall/ceiling components removed by the slides.
## `collisions` is transient per-tick data for contact-driven gameplay
## (bounce pads, wall pops) — consume it this tick, never snapshot it.
## `max_slides` may be set to 1 for move-and-stop/bounce actors whose gameplay
## consumes only the first contact; the default preserves the slide behavior.
static func move(body: PhysicsBody2D, velocity: Vector2, delta: float,
		up: Vector2 = Vector2.UP, max_slides: int = MAX_SLIDES,
		stop_on_slope: bool = false) -> Dictionary:
	var start := body.global_position
	var vel := velocity
	var motion := vel * delta
	var on_floor := false
	var on_wall := false
	var on_ceiling := false
	var hit_world_flat_floor := false
	var collisions: Array[KinematicCollision2D] = []
	# Preserve an already-grounded idle pose exactly. Running a downward
	# recovery move at a TileMap seam can select either adjacent polygon and
	# lift/slide the body by a visible amount depending on broadphase order.
	# Re-probe support so a removed platform still releases the body.
	if stop_on_slope and grounded(body):
		return {
			"velocity": Vector2.ZERO,
			"on_floor": true,
			"on_wall": false,
			"on_ceiling": false,
			"collisions": collisions,
		}
	for _i in maxi(1, max_slides):
		var col := body.move_and_collide(motion)
		if col == null:
			break
		collisions.append(col)
		var normal := col.get_normal()
		var d := normal.dot(up)
		if normal.y < -FLOOR_DOT and absf(normal.x) < 0.01:
			hit_world_flat_floor = true
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
	var pos := body.global_position
	# CharacterBody2D's platformer default stops a resting body on slopes. A
	# raw move_and_collide loop otherwise lets gravity pick either polygon at
	# a tile seam and inject horizontal slide, with collision-order-dependent
	# results across rollback resimulation. Callers opt in only when they were
	# already grounded and had no horizontal motion at the start of the tick.
	if stop_on_slope:
		pos.x = start.x
		vel.x = 0.0
	if absf(pos.x - start.x) < MICRO_MOTION_EPS:
		pos.x = start.x
	if absf(pos.y - start.y) < MICRO_MOTION_EPS:
		pos.y = start.y
	# Equivalent flat-floor polygons can return recovery travel on opposite
	# sides of a quantization midpoint. Canonicalize toward the floor (+Y)
	# before the general round so both collision results choose the same cell.
	if hit_world_flat_floor:
		pos.y = ceilf(pos.y * POSITION_QUANT) / POSITION_QUANT
	body.global_position = (pos * POSITION_QUANT).round() / POSITION_QUANT
	return {
		"velocity": vel,
		"on_floor": on_floor,
		"on_wall": on_wall,
		"on_ceiling": on_ceiling,
		"collisions": collisions,
	}


## Synchronous grounded probe — a pure query of the current world state,
## unlike CharacterBody2D.is_on_floor() which reports the last
## move_and_slide's cached result.
static func grounded(body: PhysicsBody2D, distance: float = 1.0,
		up: Vector2 = Vector2.UP) -> bool:
	return body.test_move(body.global_transform, -up * distance)
