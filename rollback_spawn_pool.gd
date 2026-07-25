class_name RollbackSpawnPool
extends RefCounted
## Fixed-capacity deterministic entity pool for rollback simulations.
##
## Slots are instantiated before RollbackManager.start() and keep stable node
## paths for the whole segment. The owning registered node folds save_state()
## into its own snapshot and calls tick() from _network_tick. Pooled scenes
## implement the small `_rollback_*` contract used below.
##
## Inactive slots are not serialised: save_state() stores `null` for any slot
## that isn't active, and load_state() hands that slot back an empty
## Dictionary rather than replaying old field data. This is safe because an
## inactive slot's per-field state never influences the simulation before it
## is re-activated, and `_rollback_activate()` is responsible for fully
## initialising the slot on the way back in (for example bullet's
## `_rollback_activate` calls `shoot()`, which sets position/direction, and
## `reset_physics_interpolation()` to kill the teleport smear). Because of
## this, `_rollback_load_state({})` must restore the slot to its canonical
## inactive state: every field must be read with `.get(key, default)`, and
## the defaults must together describe an unspawned slot. Both current
## implementers (`bullet.gd`, `sticky_wall.gd`) already satisfy this; a new
## pooled type that reads `state["key"]` directly, or whose defaults describe
## anything other than an unspawned entity, will break restore.

var _slots: Array[Node] = []
var _next_slot := 0


func setup(parent: Node, scene: PackedScene, capacity: int) -> void:
	_slots.clear()
	_next_slot = 0
	for i in maxi(1, capacity):
		var slot := scene.instantiate() as Node
		slot.name = "RollbackSlot%02d" % i
		parent.add_child(slot)
		if slot.has_method(&"_rollback_deactivate"):
			slot.call(&"_rollback_deactivate")
		_slots.append(slot)


func acquire() -> Node:
	if _slots.is_empty():
		return null
	for offset in _slots.size():
		var index := (_next_slot + offset) % _slots.size()
		var slot := _slots[index]
		if not (slot.call(&"_rollback_is_active") as bool):
			_next_slot = (index + 1) % _slots.size()
			return slot
	return null


## Deterministic full-pool policy for entities whose gameplay semantics replace
## the oldest slot (for example one StickyWall per player). Normal projectile
## pools continue to use acquire() and reject shots while exhausted.
func acquire_recycling() -> Node:
	var free_slot := acquire()
	if free_slot != null:
		return free_slot
	if _slots.is_empty():
		return null
	var index := _next_slot % _slots.size()
	var slot := _slots[index]
	if slot.has_method(&"_rollback_deactivate"):
		slot.call(&"_rollback_deactivate")
	_next_slot = (index + 1) % _slots.size()
	return slot


## Deactivate every currently-active slot. Used by entities that must clear their
## whole live set on a triggering event (for example the sticky launcher dropping
## its old wall when a new goo bullet is fired).
func deactivate_all() -> void:
	for slot in _slots:
		if (slot.call(&"_rollback_is_active") as bool) and slot.has_method(&"_rollback_deactivate"):
			slot.call(&"_rollback_deactivate")


func tick(delta: float) -> void:
	for slot in _slots:
		if slot.call(&"_rollback_is_active") as bool:
			slot.call(&"_rollback_tick", delta)


func bind_owner(owner: Node) -> void:
	for slot in _slots:
		if slot.has_method(&"_rollback_bind_owner"):
			slot.call(&"_rollback_bind_owner", owner)


func save_state() -> Dictionary:
	var states: Array = []
	for slot in _slots:
		if slot.call(&"_rollback_is_active") as bool:
			states.append(slot.call(&"_rollback_save_state"))
		else:
			states.append(null)
	return {"next": _next_slot, "slots": states}


func load_state(state: Dictionary) -> void:
	_next_slot = state.get("next", 0) as int
	var states_v: Variant = state.get("slots", [])
	if not (states_v is Array):
		return
	var states := states_v as Array
	for i in mini(states.size(), _slots.size()):
		var slot_state: Variant = states[i]
		# A non-Dictionary entry (namely `null`, stored above for inactive slots)
		# coerces to `{}` here, which every `_rollback_load_state` implementation
		# must treat as "restore to canonical inactive state" — see the class
		# doc comment for the contract this depends on.
		_slots[i].call(&"_rollback_load_state", slot_state as Dictionary if slot_state is Dictionary else {})


func active_count() -> int:
	var count := 0
	for slot in _slots:
		if slot.call(&"_rollback_is_active") as bool:
			count += 1
	return count


func first_active() -> Node:
	for slot in _slots:
		if slot.call(&"_rollback_is_active") as bool:
			return slot
	return null
