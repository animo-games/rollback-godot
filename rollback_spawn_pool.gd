class_name RollbackSpawnPool
extends RefCounted
## Fixed-capacity deterministic entity pool for rollback simulations.
##
## Slots are instantiated before RollbackManager.start() and keep stable node
## paths for the whole segment. The owning registered node folds save_state()
## into its own snapshot and calls tick() from _network_tick. Pooled scenes
## implement the small `_rollback_*` contract used below.

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
		states.append(slot.call(&"_rollback_save_state"))
	return {"next": _next_slot, "slots": states}


func load_state(state: Dictionary) -> void:
	_next_slot = state.get("next", 0) as int
	var states_v: Variant = state.get("slots", [])
	if not (states_v is Array):
		return
	var states := states_v as Array
	for i in mini(states.size(), _slots.size()):
		var slot_state: Variant = states[i]
		_slots[i].call(&"_rollback_load_state", slot_state as Dictionary if slot_state is Dictionary else {})


func active_count() -> int:
	var count := 0
	for slot in _slots:
		if slot.call(&"_rollback_is_active") as bool:
			count += 1
	return count
