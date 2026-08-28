extends SceneTree

var _failed := false


class StubConnection extends Node:
	signal peer_ready(peer_id: String, net_id: int)
	signal peer_lost(peer_id: String, net_id: int)
	signal peer_recovered(peer_id: String, net_id: int, duration_ms: int)
	signal connection_ready()
	signal connection_failed(reason: String)

	var stopped := false

	func start(_source = null) -> void:
		pass

	func stop() -> void:
		stopped = true

	func get_ready_peers() -> Array[String]:
		return []

	func get_net_id(_peer_id: String) -> int:
		return 0

	func get_peer_id(_net_id: int) -> String:
		return ""

	func is_recovering(_peer_id: String = "") -> bool:
		return false

	func request_recovery(_peer_id: String) -> bool:
		return false


class StubSource:
	extends RefCounted

	signal sig_received(peer_id: String, data: Variant)
	signal peer_joined(peer_id: String)
	signal peer_left(peer_id: String)

	var closed := false

	func connect_room() -> Dictionary:
		return {"success": false, "error": "not started"}

	func send(_peer_id: String, _data: Variant) -> void:
		pass

	func close() -> void:
		closed = true


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var controller := RollbackSessionController.new()
	controller.name = "Controller"
	root.add_child(controller)
	var supplied := StubConnection.new()
	controller.begin(supplied)
	_expect(controller.transport == supplied, true, "controller must retain the supplied connection")
	_expect(supplied.name, "Transport", "supplied connection must own the stable RPC path")
	_expect(supplied.get_node_or_null("NetClock") == controller.clock, true,
		"rollback NetClock must be attached below the supplied Transport")
	controller.shutdown()
	_expect(supplied.stopped, true, "shutdown must stop the supplied connection")
	controller.queue_free()
	await process_frame

	var legacy_controller := RollbackSessionController.new()
	root.add_child(legacy_controller)
	var source := StubSource.new()
	legacy_controller.begin(source)
	_expect(legacy_controller.transport is RollbackTransport, true,
		"a signaling source must retain the legacy RollbackTransport path")
	_expect(legacy_controller.clock == (legacy_controller.transport as RollbackTransport).clock, true,
		"legacy transport must retain its own NetClock")
	legacy_controller.shutdown()
	_expect(source.closed, true, "legacy shutdown must close the signaling source")
	legacy_controller.queue_free()
	await process_frame

	if _failed:
		quit(1)
		return
	print("CONNECTION_INJECTION_TEST: PASS")
	quit(0)


func _expect(actual: Variant, expected: Variant, label: String) -> void:
	if actual == expected:
		return
	_failed = true
	printerr("CONNECTION_INJECTION_TEST: FAIL %s (expected=%s actual=%s)" % [
		label, str(expected), str(actual),
	])

