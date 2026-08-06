# Regression test for the publish_body_transforms opt-out audit
# (RollbackManager.collidable_pair_findings). That setting is only safe when no
# two registered bodies can contact each other, and duo asserts the precondition
# in a project.godot comment that reasons about two node types while the game
# registers seven — exactly the kind of invariant that rots silently. The symptom
# when it rots is a rare resim-only desync at grazing contact, not a crash.
#
# The rule is DIRECTIONAL and was gotten wrong twice while writing it:
#   - "layers intersect" alone flags every player-on-a-static-platform pair
#     (55 of them in one duo level).
#   - "layers intersect and at least one side is non-static" flags the same 55,
#     because the moving player is the non-static side.
# What matters is whether the body being collided INTO can hold a stale
# transform. A STATIC body is applied to the physics server immediately and
# never can. Each case below pins one of those, so a regression to either wrong
# rule fails here rather than in a live session.
#
# Run headless:
#   godot --headless --path Project -s res://addons/rollback/tests/publish_opt_out_audit_test.gd
extends SceneTree

# RollbackManager.register() enforces the _save_state/_load_state/_network_tick
# contract, so the audit can never see a bare CharacterBody2D. These are the
# minimum registrable bodies of each physics mode; state is irrelevant here
# because the audit reads layers/masks, never snapshots.
class AuditKinematic extends CharacterBody2D:
	func _save_state() -> Dictionary: return {}
	func _load_state(_s: Dictionary) -> void: pass
	func _network_tick(_t: int, _inputs: Dictionary) -> void: pass


class AuditStatic extends StaticBody2D:
	func _save_state() -> Dictionary: return {}
	func _load_state(_s: Dictionary) -> void: pass
	func _network_tick(_t: int, _inputs: Dictionary) -> void: pass


class AuditAnimatable extends AnimatableBody2D:
	func _save_state() -> Dictionary: return {}
	func _load_state(_s: Dictionary) -> void: pass
	func _network_tick(_t: int, _inputs: Dictionary) -> void: pass


class AuditArea extends Area2D:
	func _save_state() -> Dictionary: return {}
	func _load_state(_s: Dictionary) -> void: pass
	func _network_tick(_t: int, _inputs: Dictionary) -> void: pass


# Declares the physics-free opt-out. Models duo's InventoryCollectible /
# ExitInteractable: an Area2D whose layers stay populated for a wall-clock
# code path while its tick path samples RollbackOverlap instead.
class AuditPhysicsFreeArea extends Area2D:
	func _save_state() -> Dictionary: return {}
	func _load_state(_s: Dictionary) -> void: pass
	func _network_tick(_t: int, _inputs: Dictionary) -> void: pass
	func _rollback_physics_free_contact() -> bool: return true


# Same marker, returning false — the audit must read the value, not merely
# detect the method, or an opt-out could never be turned back off.
class AuditOptedInArea extends Area2D:
	func _save_state() -> Dictionary: return {}
	func _load_state(_s: Dictionary) -> void: pass
	func _network_tick(_t: int, _inputs: Dictionary) -> void: pass
	func _rollback_physics_free_contact() -> bool: return false


var _failed := false


func _check(label: String, actual: int, expected: int) -> void:
	if actual == expected:
		print("  ok: %s (%d finding(s))" % [label, actual])
		return
	_failed = true
	printerr("  FAIL: %s — got %d finding(s), expected %d" % [label, actual, expected])


func _body(kind: String, layer: int, mask: int, name: String) -> CollisionObject2D:
	var node: CollisionObject2D
	match kind:
		"kinematic":
			node = AuditKinematic.new()
		"static":
			node = AuditStatic.new()
		"animatable":
			# Extends StaticBody2D but is KINEMATIC, so a class-based static test
			# would wrongly exempt it. This is why the audit asks the server.
			node = AuditAnimatable.new()
		"area":
			node = AuditArea.new()
		"area_physics_free":
			node = AuditPhysicsFreeArea.new()
		"area_opted_in":
			node = AuditOptedInArea.new()
		_:
			push_error("unknown kind " + kind)
			return null
	node.name = name
	node.collision_layer = layer
	node.collision_mask = mask
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(16, 16)
	shape.shape = rect
	node.add_child(shape)
	return node


## Registers the given bodies with a fresh manager and returns the finding count.
func _findings_for(bodies: Array) -> int:
	var stage := Node2D.new()
	root.add_child(stage)
	var rb := RollbackManager.new()
	rb.publish_body_transforms = false
	stage.add_child(rb)
	for body: CollisionObject2D in bodies:
		stage.add_child(body)
		rb.register(body)
	# The audit asks PhysicsServer2D for each body's mode, which requires the
	# bodies to be in the tree — they are, but the server needs a step to have
	# seen them.
	await physics_frame
	var count := rb.collidable_pair_findings().size()
	stage.queue_free()
	await process_frame
	return count


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	print("PUBLISH_OPT_OUT_AUDIT_TEST")

	# Two mutually-colliding movers: the case the setting exists for, and the
	# one that actually desyncs in sync_test_scenarios.
	_check("two kinematic bodies that mask each other", await _findings_for([
		_body("kinematic", 1, 1, "PawnA"),
		_body("kinematic", 1, 1, "PawnB"),
	]), 1)

	# duo's real shape: a player masks a timed platform's layer, the platform
	# masks nothing back and is StaticBody2D. Safe — the platform is never stale.
	# A "layers intersect" or "at least one non-static" rule reports this.
	_check("kinematic body onto a static platform it masks", await _findings_for([
		_body("kinematic", 1, 8, "Player"),
		_body("static", 8, 0, "PlatformOnOff"),
	]), 0)

	# Same shape but the platform is AnimatableBody2D — kinematic despite
	# extending StaticBody2D, so it CAN be stale and this one is a real hit.
	_check("kinematic body onto an animatable platform it masks", await _findings_for([
		_body("kinematic", 1, 8, "Player"),
		_body("animatable", 8, 0, "MovingPlatform"),
	]), 1)

	# Disjoint layers: duo's players vs crates. Never a hit.
	_check("disjoint layers and masks", await _findings_for([
		_body("kinematic", 1, 12, "Player"),
		_body("kinematic", 128, 12, "Crate"),
	]), 0)

	# Areas are republished by _sync_one_transform too, so a stale area changes
	# overlap results under resim just as a stale body changes contact.
	_check("area overlapping a mover", await _findings_for([
		_body("kinematic", 1, 1, "Player"),
		_body("area", 1, 1, "Trigger"),
	]), 1)

	# duo's real false positive, and the reason the physics-free marker exists:
	# a pickup area that masks the player's layer but resolves collection from
	# RollbackOverlap on the tick. Paired first WITHOUT the marker so the finding
	# is shown to be real under the old rule, then with it.
	_check("querying area, no marker (baseline)", await _findings_for([
		_body("kinematic", 1, 8, "Player"),
		_body("area", 0, 1, "Collectible"),
	]), 1)
	_check("querying area declares physics-free contact", await _findings_for([
		_body("kinematic", 1, 8, "Player"),
		_body("area_physics_free", 0, 1, "Collectible"),
	]), 0)

	# The marker suppresses only the direction the declarer QUERIES in. Here the
	# player masks the area's layer, so the player is the querier and the
	# physics-free area is the stale side — still a real hit. A marker
	# implemented as a blanket per-node exemption reports 0 and fails here.
	_check("physics-free area is still audited as the stale side", await _findings_for([
		_body("kinematic", 1, 2, "Player"),
		_body("area_physics_free", 2, 0, "Trigger"),
	]), 1)

	# Read the value, not the method's presence: an opt-out that cannot be
	# switched back off is a trapdoor.
	_check("marker returning false does not opt out", await _findings_for([
		_body("kinematic", 1, 8, "Player"),
		_body("area_opted_in", 0, 1, "Collectible"),
	]), 1)

	# The opt-out is what arms the audit; with the republish on there is nothing
	# to warn about, however the layers are set.
	var stage := Node2D.new()
	root.add_child(stage)
	var rb := RollbackManager.new()
	rb.publish_body_transforms = true
	stage.add_child(rb)
	for body: CollisionObject2D in [
		_body("kinematic", 1, 1, "PawnA"), _body("kinematic", 1, 1, "PawnB"),
	]:
		stage.add_child(body)
		rb.register(body)
	await physics_frame
	# The rule itself still sees the pair — it is _audit_collidable_pairs() that
	# returns early — so assert on the guard, not on the rule going quiet.
	_check("publish on: rule still sees the pair", rb.collidable_pair_findings().size(), 1)
	stage.queue_free()
	await process_frame

	print("PUBLISH_OPT_OUT_AUDIT_TEST: " + ("FAIL" if _failed else "PASS"))
	quit(1 if _failed else 0)
