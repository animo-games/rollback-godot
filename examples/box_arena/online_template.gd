## REFERENCE (not standalone-runnable): two-peer wiring with
## RollbackSessionController. Online play needs a signaling adapter you provide
## (a RollbackSignalingAdapter subclass) and your own world-build; this shows the
## control flow only. See a full production bootstrap for a complete example.
## No class_name (example hygiene); preloads the example codec.
extends Node

const BoxInputCodec := preload("res://addons/rollback/examples/box_arena/box_input_codec.gd")

var _controller: RollbackSessionController


## Call with your signaling adapter and this peer's player index (0 or 1).
func run(adapter: RollbackSignalingAdapter, local_idx: int) -> void:
	_controller = RollbackSessionController.new()
	_controller.name = "SessionController"  # identical path on every peer
	_controller.input_delay = 2
	_controller.max_prediction = 8
	_controller.input_codec = BoxInputCodec.new()
	_controller.desync_detected.connect(func(r: Dictionary) -> void:
		push_warning("desync: %s" % str(r)))
	add_child(_controller)
	_controller.begin(adapter)

	var remote_idx := 1 - local_idx
	var seg: Dictionary = await _controller.run_segment(0,
		_build_segment,
		{
			"local": [{
				"id": StringName("p%d" % local_idx),
				"sampler": func(_t: int) -> Dictionary: return _sample_input(),
			}],
			"remote": [{"id": StringName("p%d" % remote_idx)}],
			"auto_remote_peer": true,  # map the lone remote to the single ready peer
		})
	if not (seg.get("ok", false) as bool):
		return
	# ... run your game until a transition/quit condition, then:
	# _controller.stop_segment(seg["session"] as RollbackNetSession)


## BUILD callback: create the manager + world + registration and return it. The
## session already exists at its path when this runs (so a peer hello can't miss
## it). Return {"manager": RollbackManager, ...anything your teardown needs...}.
## Both peers must build an IDENTICAL registered set at identical node paths.
func _build_segment(_seg_index: int, _session: RollbackNetSession) -> Dictionary:
	var rb := RollbackManager.new()
	rb.name = "Rollback"
	rb.max_rollback_ticks = 16
	add_child(rb)
	# Spawn your actors here, then register them, e.g.:
	#   rb.register(some_actor)
	#   rb.register_tree(level_root)
	return {"manager": rb, "ok": true}


func _sample_input() -> Dictionary:
	# Replace with your real device/input sampling.
	return {"mx": 0.0, "my": 0.0, "b": 0}
