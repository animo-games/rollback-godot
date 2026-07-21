## Editor-droppable subtree registrar for RollbackManager.
##
## Add this node anywhere in a level subtree and call bind(manager) once — after
## the target nodes are in the tree and BEFORE manager.start() — from your own
## segment-build code, in the freeze/register/unfreeze ordering the rollback loop
## needs. It is deliberately NOT auto-firing in _ready(): auto registration would
## race the manager's start() sequencing (freeze, settle, register, unfreeze) that
## determinism depends on. It is a thin, editor-visible wrapper over
## RollbackManager.register_tree().
class_name RollbackBinder
extends Node

## Subtree root to register. Empty -> this node's parent. The root itself is
## included if it implements a rollback contract.
@export_node_path("Node") var root_path: NodePath

## Recurse into the whole subtree (vs. the direct children of the root only).
@export var recursive: bool = true

## Emitted after bind() has registered the subtree.
signal bound


## Registers root_path's subtree (or this node's parent when root_path is empty)
## with `manager` via RollbackManager.register_tree(). Call after the nodes are in
## the tree and before manager.start().
func bind(manager: RollbackManager) -> void:
	if manager == null:
		push_error("RollbackBinder: bind() called with a null manager")
		return
	var root: Node = get_node_or_null(root_path) if not root_path.is_empty() else get_parent()
	if root == null:
		push_error("RollbackBinder: no root to bind (root_path=%s)" % str(root_path))
		return
	manager.register_tree(root, recursive)
	bound.emit()
