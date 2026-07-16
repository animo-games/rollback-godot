## Restore-safe logical collision helpers for rollback gameplay.
##
## Shape2D queries consume transforms supplied by the caller. A restored or
## tick-moved parent can leave a CollisionShape2D child's cached global
## transform one simulation step behind until the engine's frame boundary.
## Flush every CanvasItem in the ancestry before reading node transforms so
## live, predicted, and resimulated ticks query the same geometry.
class_name RollbackOverlap
extends RefCounted


static func shapes_collide(a: CollisionShape2D, b: CollisionShape2D) -> bool:
	if not _shapes_valid(a, b):
		return false
	flush_collision_shape(a)
	flush_collision_shape(b)
	return a.shape.collide(
		_current_global_transform(a), b.shape, _current_global_transform(b))


## Variant for sweep code whose first shape uses an explicit start transform.
static func shape_collides_at(
		a: CollisionShape2D, a_transform: Transform2D,
		b: CollisionShape2D) -> bool:
	if not _shapes_valid(a, b):
		return false
	flush_collision_shape(a)
	flush_collision_shape(b)
	return a.shape.collide(
		a_transform, b.shape, _current_global_transform(b))


## Current-transform sweep used by support/contact probes. Physics bodies rest
## at their collision safe margin rather than exact shape overlap, so a tiny
## deterministic sweep represents touching without reading engine history.
static func shapes_collide_with_motion(
		a: CollisionShape2D, motion: Vector2, b: CollisionShape2D) -> bool:
	if not _shapes_valid(a, b):
		return false
	flush_collision_shape(a)
	flush_collision_shape(b)
	return a.shape.collide_with_motion(
		_current_global_transform(a), motion,
		b.shape, _current_global_transform(b), Vector2.ZERO)


static func shape_collides_with_motion_at(
		a: CollisionShape2D, a_transform: Transform2D, motion: Vector2,
		b: CollisionShape2D) -> bool:
	if not _shapes_valid(a, b):
		return false
	flush_collision_shape(a)
	flush_collision_shape(b)
	return a.shape.collide_with_motion(
		a_transform, motion, b.shape, _current_global_transform(b), Vector2.ZERO)


static func flush_collision_shape(shape: CollisionShape2D) -> void:
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
