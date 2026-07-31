@tool
extends EditorPlugin

## Editor-plugin manifest hook for the rollback addon.
##
## Intentionally inert. Every class in this addon is exposed via `class_name`,
## so the nodes already appear in the Create-Node dialog and the global class
## list with no registration needed. Do NOT call add_custom_type() for them:
## Godot rejects a custom type whose name collides with an existing class_name
## (every class here has one), which fails plugin load. This plugin exists so
## the addon shows up in the Project > Plugins tab with name/version/author
## metadata and is packageable for the Asset Library — keep enter/exit no-ops.


func _enter_tree() -> void:
	# One exception to "inert": declare the addon's project settings so they are
	# visible and editable in Project > Project Settings instead of being a
	# magic string a consuming game has to know about. Only ever adds a missing
	# key — never overwrites a value the game has already chosen.
	_declare_setting(RollbackManager.PUBLISH_SETTING, true,
		"Republish each registered body's transform to the physics server after"
		+ " it ticks. Required for determinism when two registered bodies can"
		+ " collide with each other; safe to disable when every registered body"
		+ " collides with static world geometry only.")


func _declare_setting(key: String, default_value: Variant, hint: String) -> void:
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, default_value)
	ProjectSettings.set_initial_value(key, default_value)
	ProjectSettings.add_property_info({
		"name": key,
		"type": typeof(default_value),
		"hint": PROPERTY_HINT_NONE,
		"hint_string": hint,
	})
	ProjectSettings.set_as_basic(key, true)


func _exit_tree() -> void:
	pass
