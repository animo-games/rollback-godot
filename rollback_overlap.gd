## Restore-safe logical collision helpers for rollback gameplay.
##
## Shape2D queries consume transforms supplied by the caller. A restored or
## tick-moved parent can leave a CollisionShape2D child's cached global
## transform one simulation step behind until the engine's frame boundary,
## so live, predicted, and resimulated ticks must not trust those caches.
##
## Two modes:
## - Resim-safe mode (a RollbackManager is live, i.e. netplay): queries
##   recompose global transforms manually from local transforms
##   (_current_global_transform), which are always current even
##   mid-resimulation, so the stale engine caches are never read and no
##   ancestry flush is needed per query. flush_collision_shape remains for
##   external callers that read engine-cached transforms afterward (e.g.
##   hook_bullet reads _body_shape.global_transform after flushing).
## - Wall-clock mode (no RollbackManager anywhere, i.e. plain single-player
##   local play): the engine's cached global_transform is already correct
##   every frame, so the flush and recomposition are skipped and the query
##   reads the engine-cached transform directly. This avoids paying
##   interpreted-GDScript overhead per collision pair, per frame, for
##   gameplay that never resimulates.
class_name RollbackOverlap
extends RefCounted


## Number of live RollbackManagers. When zero (plain wall-clock play), the
## engine's cached global transforms are already current every frame, so the
## ancestry flush and manual recomposition below are skipped — they exist
## only for resimulated/restored ticks. Maintained by RollbackManager's
## tree notifications; never touch it from gameplay code.
static var _active_managers := 0

## Float-rounding safety margin for shape_world_bounds()/bounds_reject(): the
## broadphase reject must never discard a pair the exact test would accept.
const BOUNDS_EPSILON := 0.05


static func _resim_safe_required() -> bool:
	return _active_managers > 0


## Called by RollbackManager._enter_tree(). Never call from gameplay code.
static func notify_manager_entered_tree() -> void:
	_active_managers += 1


## Called by RollbackManager._exit_tree(). Never call from gameplay code.
static func notify_manager_exited_tree() -> void:
	if _active_managers <= 0:
		push_warning("RollbackOverlap: manager refcount underflow")
		_active_managers = 0
		return
	_active_managers -= 1


static func shapes_collide(a: CollisionShape2D, b: CollisionShape2D) -> bool:
	if not _shapes_valid(a, b):
		return false
	if not _resim_safe_required():
		return a.shape.collide(a.global_transform, b.shape, b.global_transform)
	return a.shape.collide(
		_current_global_transform(a), b.shape, _current_global_transform(b))


## Variant for sweep code whose first shape uses an explicit start transform.
static func shape_collides_at(
		a: CollisionShape2D, a_transform: Transform2D,
		b: CollisionShape2D) -> bool:
	if not _shapes_valid(a, b):
		return false
	if not _resim_safe_required():
		return a.shape.collide(a_transform, b.shape, b.global_transform)
	return a.shape.collide(
		a_transform, b.shape, _current_global_transform(b))


## Current-transform sweep used by support/contact probes. Physics bodies rest
## at their collision safe margin rather than exact shape overlap, so a tiny
## deterministic sweep represents touching without reading engine history.
static func shapes_collide_with_motion(
		a: CollisionShape2D, motion: Vector2, b: CollisionShape2D) -> bool:
	if not _shapes_valid(a, b):
		return false
	if not _resim_safe_required():
		return a.shape.collide_with_motion(
			a.global_transform, motion, b.shape, b.global_transform, Vector2.ZERO)
	return a.shape.collide_with_motion(
		_current_global_transform(a), motion,
		b.shape, _current_global_transform(b), Vector2.ZERO)


static func shape_collides_with_motion_at(
		a: CollisionShape2D, a_transform: Transform2D, motion: Vector2,
		b: CollisionShape2D) -> bool:
	if not _shapes_valid(a, b):
		return false
	if not _resim_safe_required():
		return a.shape.collide_with_motion(
			a_transform, motion, b.shape, b.global_transform, Vector2.ZERO)
	return a.shape.collide_with_motion(
		a_transform, motion, b.shape, _current_global_transform(b), Vector2.ZERO)


## Public form of _current_global_transform for callers that hoist a transform
## out of a per-candidate loop. Mirrors the two-mode contract of the query
## helpers: wall-clock mode reads the engine cache (already current every
## frame), resim-safe mode recomposes from local transforms.
static func current_global_transform(node: Node2D) -> Transform2D:
	if not _resim_safe_required():
		return node.global_transform
	return _current_global_transform(node)


## Exact test with caller-supplied transforms for BOTH shapes, so a caller that
## already computed them for a broadphase reject does not pay the recomposition
## a second time.
static func shapes_collide_between(
		a: CollisionShape2D, a_transform: Transform2D,
		b: CollisionShape2D, b_transform: Transform2D) -> bool:
	if not _shapes_valid(a, b):
		return false
	return a.shape.collide(a_transform, b.shape, b_transform)


## Conservative world-space AABB of a CollisionShape2D under an explicit
## transform, for cheap rejection before the exact test. Deliberately
## over-approximate: `Transform2D * Rect2` returns the AABB enclosing the
## transformed rect, and the result is padded so a float rounding edge can
## never reject a pair the exact test would have accepted.
##
## WorldBoundaryShape2D is infinite but reports a bogus finite get_rect(), so it
## returns a huge rect — i.e. it never rejects.
static func shape_world_bounds(cs: CollisionShape2D, xform: Transform2D) -> Rect2:
	var shape := cs.shape
	if shape == null or shape is WorldBoundaryShape2D:
		return Rect2(-1e9, -1e9, 2e9, 2e9)
	return (xform * shape.get_rect()).grow(BOUNDS_EPSILON)


## True when the two world bounds cannot possibly overlap. Borders count as an
## overlap (`intersects(..., true)`) so an exactly-touching pair is always
## handed to the exact test.
static func bounds_reject(a: Rect2, b: Rect2) -> bool:
	return not a.intersects(b, true)


static func flush_collision_shape(shape: CollisionShape2D) -> void:
	if not _resim_safe_required():
		return
	if shape == null or not is_instance_valid(shape) or not shape.is_inside_tree():
		return
	var ancestry: Array[CanvasItem] = []
	var current: Node = shape
	while current is CanvasItem:
		ancestry.push_front(current as CanvasItem)
		current = current.get_parent()
	for item in ancestry:
		item.force_update_transform()


## Build from local transforms instead of trusting CanvasItem's cached child
## global. `global_position` writes update the moved node's local transform
## immediately, including during resimulation, while descendant global caches
## can remain from a speculative pass until the engine frame boundary.
static func _current_global_transform(node: Node2D) -> Transform2D:
	var result := node.transform
	var current := node
	while not current.top_level:
		var parent := current.get_parent() as Node2D
		if parent == null:
			break
		result = parent.transform * result
		current = parent
	return result


static func _shapes_valid(a: CollisionShape2D, b: CollisionShape2D) -> bool:
	return a != null and b != null \
		and is_instance_valid(a) and is_instance_valid(b) \
		and a.is_inside_tree() and b.is_inside_tree() \
		and not a.disabled and not b.disabled \
		and a.shape != null and b.shape != null
