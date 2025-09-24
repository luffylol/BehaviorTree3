--[[
  Behavior Trees V5 — Reverse-Preorder Abort Lists (Simple & Explicit)

	Originally by iniich_n and tyridge77: https://devforum.roblox.com/t/behaviortree2-create-complex-behaviors-with-ease/451047
	Working off of Forked and improved version by defaultio

  What my fork adds:
    * After flattening, we do a tiny pass that builds two sets per node:
        node.on_success_abort = { [leafIndex]=true, ... }  -- all leaves skipped if THIS node succeeds
        node.on_fail_abort    = { [leafIndex]=true, ... }  -- all leaves skipped if THIS node fails
      A "leaf" is a task or a child tree.
      Skipped = the strict interval (i+1 .. jump-1) in the pre-order array.

    * At runtime, when a node returns SUCCESS/FAIL:
        if prevRunningLeafIndex is in node.on_success_abort / node.on_fail_abort → finish-only cancel it.

	* IMPORTANT: Execution from the tree starts from the root every time you have a call to :run()
				 This differs from previous implemention 

  Notes:
    * Decorators (Invert/Succeed/Fail) already rewired jumps during build, so this automatically
      respects their behavior. No special-casing needed.
    * We never reset indices on abort; we only call finish on the currently running leaf.

  Future:
  	* Going to add more types of nodes:
  		- Parralel composite nodes
  		- Priority composite nodes
  		- Expect composite (like parallel, but waits for all children to succeed before succeeding itself)
  		- Timeout nodes
  		- Revert nodes (revert to previous state)
		- More decorators for ease of use

  Status enums:
    SUCCESS = 1, FAIL = 2, RUNNING = 3, ABORT = 4
]]

local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local IsStudio = RunService:IsRunning() and RunService:IsStudio()

local BehaviorTree = {}
local SUCCESS, FAIL, RUNNING, ABORT = 1, 2, 3, 4

-- Debug support for studio plugin (optional)
local RunningTreesFolder
if IsStudio then
	local cam = Instance.new("Camera", script)
	cam.Name = "NonReplicated"
	RunningTreesFolder = Instance.new("Folder", cam)
	RunningTreesFolder.Name = "RunningTrees(debug)"
	CollectionService:AddTag(RunningTreesFolder, "_btRunningTrees")
end

-------- Blackboards --------

BehaviorTree.SharedBlackboards = {} -- name -> table

local BLACKBOARD_QUERY_TYPE_TRUE, BLACKBOARD_QUERY_TYPE_FALSE, BLACKBOARD_QUERY_TYPE_NIL, BLACKBOARD_QUERY_TYPE_NOTNIL =
	1, 2, 3, 4

-------- Build helpers --------

local function addNode(nodes, nodeType)
	local n = { type = nodeType }
	-- preemption sets (built later)
	n.on_success_abort = nil
	n.on_fail_abort = nil
	nodes[#nodes + 1] = n
	return n, #nodes
end

local function ProcessNode(node, nodes)
	------------------------------
	----------- LEAVES -----------
	if node.type == "task" then
		assert(node.params.run, "Task leaf node has no run func")
		local t = addNode(nodes, "task")
		t.start = node.params.start
		t.run = node.params.run
		t.finish = node.params.finish
		t.onsuccess = true
		t.onfail = false
		t.nodefolder = node.params.nodefolder
		return
	elseif node.type == "blackboard" then
		local b = addNode(nodes, "blackboard")
		b.onsuccess = true
		b.onfail = false
		b.key = node.params.key
		b.board = node.params.board
		local v = node.params.value:lower()
		local comparestring = false
		if v == "true" then
			b.returntype = BLACKBOARD_QUERY_TYPE_TRUE
		elseif v == "false" then
			b.returntype = BLACKBOARD_QUERY_TYPE_FALSE
		elseif v == "unset" or v == "nil" then
			b.returntype = BLACKBOARD_QUERY_TYPE_NIL
		elseif v == "set" then
			b.returntype = BLACKBOARD_QUERY_TYPE_NOTNIL
		else
			comparestring = true
			b.returntype = node.params.value
		end
		b.comparestring = comparestring
		return
	elseif node.type == "tree" then
		assert(node.params.tree, "Tree leaf node has no linked tree object")
		local tr = addNode(nodes, "tree")
		tr.tree = node.params.tree
		tr.onsuccess = true
		tr.onfail = false
		tr.nodefolder = node.params.nodefolder
		return
	end

	-----------------------------------
	----------- DECORATORS ------------
	if node.type == "always_succeed" then
		assert(#node.params.nodes <= 1, "succeed decorator with multiple children")
		if node.params.nodes[1] then
			local before = #nodes + 1
			ProcessNode(node.params.nodes[1], nodes)
			for i = before, #nodes do
				local n = nodes[i]
				if n.onsuccess == false then
					n.onsuccess = true
				end
				if n.onfail == false then
					n.onfail = true
				end
			end
		else
			local s = addNode(nodes, "succeed")
			s.onsuccess = true
		end
		return
	elseif node.type == "always_fail" then
		assert(#node.params.nodes <= 1, "fail decorator with multiple children")
		if node.params.nodes[1] then
			local before = #nodes + 1
			ProcessNode(node.params.nodes[1], nodes)
			for i = before, #nodes do
				local n = nodes[i]
				if n.onsuccess == true then
					n.onsuccess = false
				end
				if n.onfail == true then
					n.onfail = false
				end
			end
		else
			local f = addNode(nodes, "fail")
			f.onfail = false
		end
		return
	elseif node.type == "invert" then
		assert(#node.params.nodes == 1, "invert decorator needs exactly 1 child")
		local before = #nodes + 1
		ProcessNode(node.params.nodes[1], nodes)
		for i = before, #nodes do
			local n = nodes[i]
			if n.onsuccess == true then
				n.onsuccess = false
			elseif n.onsuccess == false then
				n.onsuccess = true
			end
			if n.onfail == false then
				n.onfail = true
			elseif n.onfail == true then
				n.onfail = false
			end
		end
		return
	elseif node.type == "repeat" then
		assert(#node.params.nodes == 1, "repeat decorator needs exactly 1 child")
		local repeatStartIndex = #nodes + 1
		local repeatCount = node.params.count and node.params.count > 0 and node.params.count or nil
		if repeatCount and repeatCount > 0 then
			addNode(nodes, "repeat-start")
			local rep = addNode(nodes, "repeat")
			rep.repeatGoal = repeatCount
			rep.repeatCount = 0
			rep.onsuccess = true
			rep.onfail = false
			repeatStartIndex = #nodes
		end
		local childBefore = #nodes + 1
		ProcessNode(node.params.nodes[1], nodes)
		local breakOnFail = node.params.breakonfail
		for i = childBefore, #nodes do
			local n = nodes[i]
			if (n.onsuccess == true) or (n.onsuccess == false and not breakOnFail) then
				n.onsuccess = repeatStartIndex
			end
			if (n.onfail == false and not breakOnFail) or (n.onfail == true) then
				n.onfail = repeatStartIndex
			end
		end
		return
	end

	-----------------------------------
	------------ COMPOSITES -----------
	if node.type == "while" then
		assert(#node.params.nodes == 2, "while needs 2 children")
		local cond = node.params.nodes[1]
		local act = node.params.nodes[2]
		local repeatStartIndex = #nodes + 1
		local repeatCount = node.params.count and node.params.count > 0 and node.params.count or nil
		if repeatCount and repeatCount > 0 then
			addNode(nodes, "repeat-start")
			local rep = addNode(nodes, "repeat")
			rep.repeatGoal = repeatCount
			rep.repeatCount = 0
			rep.onsuccess = false
			rep.onfail = false
			repeatStartIndex = #nodes
		end
		local condS = #nodes + 1
		ProcessNode(cond, nodes)
		local actS = #nodes + 1
		ProcessNode(act, nodes)
		for i = condS, actS - 1 do
			local n = nodes[i]
			if n.onsuccess == true then
				n.onsuccess = actS
			end
			if n.onfail == true then
				n.onfail = actS
			end
		end
		for i = actS, #nodes do
			local n = nodes[i]
			if n.onsuccess == false then
				n.onsuccess = repeatStartIndex
			end
			if n.onfail == false then
				n.onfail = repeatStartIndex
			end
		end
		return
	elseif node.type == "sequence" then
		assert(#node.params.nodes >= 1, "sequence has no children")
		local ranges = {}
		for i, child in ipairs(node.params.nodes) do
			local s = #nodes + 1
			ProcessNode(child, nodes)
			local e = #nodes
			ranges[i] = { s = s, e = e }
		end
		for i, r in ipairs(ranges) do
			local nextStart = (i < #ranges) and ranges[i + 1].s or nil
			for idx = r.s, r.e do
				local n = nodes[idx]
				if n.onsuccess == true then
					n.onsuccess = nextStart or true
				end
				if n.onfail == true then
					n.onfail = nextStart or true
				end
			end
		end
		return
	elseif node.type == "selector" then
		assert(#node.params.nodes >= 1, "selector has no children")
		local ranges = {}
		for i, child in ipairs(node.params.nodes) do
			local s = #nodes + 1
			ProcessNode(child, nodes)
			local e = #nodes
			ranges[i] = { s = s, e = e }
		end
		for i, r in ipairs(ranges) do
			local nextStart = (i < #ranges) and ranges[i + 1].s or nil
			for idx = r.s, r.e do
				local n = nodes[idx]
				if n.onsuccess == false then
					n.onsuccess = nextStart or false
				end
				if n.onfail == false then
					n.onfail = nextStart or false
				end
			end
		end
		return
	elseif node.type == "random" then
		assert(#node.params.nodes >= 1, "random has no children")
		local rnd = addNode(nodes, "random")
		rnd.indices = {}
		for _, child in ipairs(node.params.nodes) do
			local index = #nodes + 1
			if child.weight then
				local base = #rnd.indices
				for i = 1, child.weight do
					rnd.indices[base + i] = index
				end
			else
				rnd.indices[#rnd.indices + 1] = index
			end
			ProcessNode(child, nodes)
		end
		return
	end

	-----------------------------
	------------- ROOT ----------
	if node.type == "root" then
		assert(#nodes == 0, "root at nonroot location")
		ProcessNode(node.tree, nodes)
		-- convert booleans to terminal indices
		for i = 1, #nodes do
			local n = nodes[i]
			if n.onsuccess == true then
				n.onsuccess = #nodes + 1
			elseif n.onsuccess == false then
				n.onsuccess = #nodes + 2
			end
			if n.onfail == true then
				n.onfail = #nodes + 1
			elseif n.onfail == false then
				n.onfail = #nodes + 2
			end
		end
		return
	end

	error("ProcessNode: bad node.type " .. tostring(node.type))
end

-------- Build abort lists (reverse-preorder intervals) --------

local function isLeaf(n)
	return n.type == "task" or n.type == "tree"
end

local function buildAbortLists(nodes)
	local N = #nodes
	for i = 1, N do
		local ni = nodes[i]

		-- SUCCESS: nodes strictly between i and onsuccess are skipped
		do
			local jump = ni.onsuccess
			-- Treat terminals as end of array (no interval beyond)
			if jump == N + 1 or jump == N + 2 then
				jump = N + 1
			end
			if type(jump) == "number" and jump > i + 1 then
				local set = nil
				for j = i + 1, jump - 1 do
					if isLeaf(nodes[j]) then
						set = set or {}
						set[j] = true
					end
				end
				if set then
					ni.on_success_abort = set
				end
			end
		end

		-- FAIL: nodes strictly between i and onfail are skipped
		do
			local jump = ni.onfail
			if jump == N + 1 or jump == N + 2 then
				jump = N + 1
			end
			if type(jump) == "number" and jump > i + 1 then
				local set = nil
				for j = i + 1, jump - 1 do
					if isLeaf(nodes[j]) then
						set = set or {}
						set[j] = true
					end
				end
				if set then
					ni.on_fail_abort = set
				end
			end
		end
	end
end

-------- Runtime proto --------

local TreeProto = {}

-- finish-only cancel; do NOT reset indices/cursors
function TreeProto:_cancelRunning(obj, status, index, ...)
	local data = self.DataLookup[obj]
	if not data then
		return
	end
	local idx = index or data.index
	if not idx then
		return
	end
	local node = self.nodes[idx]
	if not node then
		return
	end
	if node.type == "task" then
		if node.finish then
			node.finish(obj, status or FAIL, ...)
		end
	elseif node.type == "tree" then
		node.tree:_cancelRunning(obj, status or ABORT, nil, ...)
	end
end

function TreeProto:abort(obj, index, status, ...)
	self:_cancelRunning(obj, status or ABORT, index, ...)
end

local function set_contains(set, idx)
	return set and set[idx] == true
end

function TreeProto:run(obj, ...)
	assert(typeof(obj) == "table", "The first argument of a behavior tree's run method must be a table!")

	-- Debug hookup
	local DebugEntityNode
	if IsStudio and self.folder then
		local treeName = self.folder.Name
		local objName = tostring(obj)
		local entities = RunningTreesFolder:FindFirstChild(treeName)
		if not entities then
			entities = Instance.new("Folder")
			entities.Name = treeName
			entities.Parent = RunningTreesFolder
		end
		local entity = entities:FindFirstChild(objName)
		if not entity then
			entity = Instance.new("Folder")
			entity.Name = objName

			local nodefolder = Instance.new("ObjectValue", entity)
			nodefolder.Name = "Node"
			local treefolder = Instance.new("ObjectValue", entity)
			treefolder.Name = "TreeFolder"
			treefolder.Value = self.folder

			local displayName = obj.name or obj.Name
			if displayName and typeof(displayName) ~= "string" then
				displayName = nil
			end
			if not displayName then
				for _, v in pairs(obj) do
					if typeof(v) == "Instance" then
						displayName = v.Name
					end
				end
			end
			if displayName then
				local name = Instance.new("StringValue", entity)
				name.Name = "Name"
				name.Value = displayName
			end
			entity.Parent = entities
		end
		DebugEntityNode = entity.Node
	end

	local nodes = self.nodes

	-- Per-entity state
	local data = self.DataLookup[obj]
	if not data then
		data = { index = 1, paused = false, running = false }
		self.DataLookup[obj] = data
	end

	-- Blackboards
	local blackboard = obj.Blackboard
	if not blackboard then
		blackboard = {}
		obj.Blackboard = blackboard
	end
	if not obj.SharedBlackboards then
		obj.SharedBlackboards = BehaviorTree.SharedBlackboards
	end

	local N = #nodes
	local isResume = data.paused
	data.paused = false
	data.running = true

	local prevRunningIndex = isResume and data.index or nil
	data.index = 1

	while data.index <= N do
		local node = nodes[data.index]
		if IsStudio then
			DebugEntityNode.Value = node.nodefolder
		end

		if node.type == "task" then
			if not isResume and node.start then
				node.start(obj, ...)
			end

			local status = node.run(obj, ...)
			if status == nil then
				warn("node.run did not return a status; treating as FAIL")
				status = FAIL
			end

			if status == RUNNING then
				data.paused = true
				break
			else
				-- Reverse-preorder abort check using fixed sets
				if prevRunningIndex then
					if status == SUCCESS then
						if set_contains(node.on_success_abort, prevRunningIndex) then
							self:_cancelRunning(obj, FAIL, prevRunningIndex, "preempt")
						end
					else -- FAIL
						if set_contains(node.on_fail_abort, prevRunningIndex) then
							self:_cancelRunning(obj, FAIL, prevRunningIndex, "preempt")
						end
					end
				end

				if node.finish then
					node.finish(obj, status, ...)
				end
				data.index = (status == SUCCESS) and node.onsuccess or node.onfail
			end
		elseif node.type == "blackboard" then
			local result = false
			local board = (node.board == "Entity") and blackboard or BehaviorTree.SharedBlackboards[node.board]
			if board then
				local val = board[node.key]
				if node.comparestring then
					result = (tostring(val) ~= nil and tostring(val) == node.returntype)
				else
					if node.returntype == BLACKBOARD_QUERY_TYPE_TRUE then
						result = (val == true)
					elseif node.returntype == BLACKBOARD_QUERY_TYPE_FALSE then
						result = (val == false)
					elseif node.returntype == BLACKBOARD_QUERY_TYPE_NIL then
						result = (val == nil)
					elseif node.returntype == BLACKBOARD_QUERY_TYPE_NOTNIL then
						result = (val ~= nil)
					end
				end
			end
			data.index = result and node.onsuccess or node.onfail
		elseif node.type == "tree" then
			local result = node.tree:run(obj, ...)
			if result == RUNNING then
				data.paused = true
				break
			else
				if prevRunningIndex then
					if result == SUCCESS then
						if set_contains(node.on_success_abort, prevRunningIndex) then
							self:_cancelRunning(obj, FAIL, prevRunningIndex, "preempt")
						end
					else -- FAIL
						if set_contains(node.on_fail_abort, prevRunningIndex) then
							self:_cancelRunning(obj, FAIL, prevRunningIndex, "preempt")
						end
					end
				end
				data.index = (result == SUCCESS) and node.onsuccess or node.onfail
			end
		elseif node.type == "random" then
			data.index = node.indices[math.random(1, #node.indices)]
		elseif node.type == "repeat-start" then
			data.index = data.index + 1
			local rep = nodes[data.index]
			rep.repeatCount = 0
		elseif node.type == "repeat" then
			node.repeatCount = node.repeatCount + 1
			if node.repeatCount > node.repeatGoal then
				data.index = node.onsuccess
			else
				data.index = data.index + 1
			end
		elseif node.type == "succeed" then
			data.index = node.onsuccess
		elseif node.type == "fail" then
			data.index = node.onfail
		else
			error("bad node.type")
		end
	end

	local outcome
	if data.index == N + 1 then
		outcome = SUCCESS
	elseif data.index == N + 2 then
		outcome = FAIL
	else
		outcome = RUNNING
	end

	if data.index > N then
		data.index = 1
	end
	data.running = false
	return outcome
end

TreeProto.Run = TreeProto.run
TreeProto.Abort = TreeProto.abort

-------- Constructor --------

function BehaviorTree:new(params)
	local nodes = {}
	local DataLookup = {}
	ProcessNode({ type = "root", tree = params.tree, params = {} }, nodes)
	-- Build reverse-preorder abort lists (after booleans -> terminals)
	buildAbortLists(nodes)
	return setmetatable({
		nodes = nodes,
		DataLookup = DataLookup,
		folder = params.treeFolder,
	}, { __index = TreeProto })
end

-------- Node ctors --------

-- Composites
BehaviorTree.Sequence = function(p)
	return { type = "sequence", params = p }
end
BehaviorTree.Selector = function(p)
	return { type = "selector", params = p }
end
BehaviorTree.Random = function(p)
	return { type = "random", params = p }
end
BehaviorTree.While = function(p)
	return { type = "while", params = p }
end

-- Decorators
BehaviorTree.Succeed = function(p)
	return { type = "always_succeed", params = p }
end
BehaviorTree.Fail = function(p)
	return { type = "always_fail", params = p }
end
BehaviorTree.Invert = function(p)
	return { type = "invert", params = p }
end
BehaviorTree.Repeat = function(p)
	return { type = "repeat", params = p }
end

-- Leafs
BehaviorTree.Task = function(p)
	return { type = "task", params = p }
end
BehaviorTree["External Task"] = function(p)
	return { type = "task", params = p }
end
BehaviorTree.Tree = function(p)
	return { type = "tree", params = p }
end
BehaviorTree["Blackboard Query"] = function(p)
	return { type = "blackboard", params = p }
end

return BehaviorTree
