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
	pass


func _exit_tree() -> void:
	pass
