local TreeCreator = require(script:WaitForChild("TreeCreator"))
local BehaviorTree3 = require(script:WaitForChild("BehaviorTree5"))

export type object = { [any]: any, Blackboard: {} }

export type BehaviorTree = {
	Run: (self: BehaviorTree, obj: object, ...any) -> number,
	Abort: (self: BehaviorTree, obj: {}, index: number?, status: number?, ...any) -> (),
}

export type TreeCreator = {
	Create: (self: TreeCreator, treeFolder: Instance) -> BehaviorTree?,
	RegisterSharedBlackboard: (self: TreeCreator, index: string, tab: { [any]: any }) -> (),
}

return {
	TreeCreator = TreeCreator,
	BehaviorTree = BehaviorTree3,
}
