local TreeCreatorModule = require(script:WaitForChild("TreeCreator"))
local BehaviorTreeModule = require(script:WaitForChild("BehaviorTree5"))

-- ---------- Public types (what consumers can import) ----------
export type Object = { [any]: any, Blackboard: {} }

export type BehaviorTree = {
	Run: (self: BehaviorTree, obj: Object, ...any) -> number,
	Abort: (self: BehaviorTree, obj: Object, index: number?, status: number?, ...any) -> (),
}

export type TreeCreator = {
	Create: (self: TreeCreator, treeFolder: Instance) -> BehaviorTree?,
	RegisterSharedBlackboard: (self: TreeCreator, index: string, tab: { [any]: any }) -> (),
}

-- If the implementation modules already carry precise types,
-- you can expose them with typeof instead:
-- export type BehaviorTree = typeof(BehaviorTreeModule)
-- export type TreeCreator  = typeof(TreeCreatorModule)

-- ---------- Runtime export (values) ----------
local exports: { TreeCreator: TreeCreator, BehaviorTree: BehaviorTree } = {
	-- cast to the public interfaces; keeps callers type-safe
	TreeCreator = TreeCreatorModule :: any,
	BehaviorTree = BehaviorTreeModule :: any,
}

return exports
