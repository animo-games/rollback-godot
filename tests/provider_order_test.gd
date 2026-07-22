# Regression test for the StringName.sort() intern-pointer-order bug: two
# peers interning the same provider names in different runtime order used to
# get different _all_providers orderings (pointer order, not text order),
# which corrupted the packed-input wire index and silently stalled online
# sessions. Run headless:
#   godot --headless --path Project -s res://addons/rollback/tests/provider_order_test.gd
extends SceneTree


func _init() -> void:
	# Concatenation defeats literal-compile-time interning, and interning b
	# before a (anti-lexical order) means a pointer-order sort would put b
	# first — the opposite of the required lexical order [a, b].
	var b := StringName("zz_prov_" + "b")
	var a := StringName("zz_prov_" + "a")

	var session := RollbackNetSession.new()
	session.add_local_provider(b, func(_t: int) -> Dictionary: return {})
	session.add_remote_provider(a, "peerX")

	var expected_providers: Array[StringName] = [a, b]
	var expected_digest: int = ("zz_prov_a|zz_prov_b|").hash()
	var actual_digest: int = session.get_stats()["providers_digest"]

	if session._all_providers != expected_providers:
		print("PROVIDER_ORDER_TEST: FAIL _all_providers=%s expected=%s" % [
			str(session._all_providers), str(expected_providers)])
		quit(1)
		return
	if actual_digest != expected_digest:
		print("PROVIDER_ORDER_TEST: FAIL providers_digest=%d expected=%d" % [
			actual_digest, expected_digest])
		quit(1)
		return

	print("PROVIDER_ORDER_TEST: PASS")
	quit(0)
