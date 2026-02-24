--[[
	run-in-roblox 테스트 엔트리 모듈입니다.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local tiniest = require(ReplicatedStorage.roblox_packages.tiniest)

local testsRoot = ReplicatedStorage:WaitForChild("tests")
local specsRoot = testsRoot:WaitForChild("specs")

local tiny = tiniest.for_runtime.configure({
	pretty = {
		disable_emoji = true,
	},
})

local tests = tiny.collect_tests_from_hierarchy(specsRoot, {
	file_name_pattern = "%.spec$",
})
local result = tiny.run_tests(tests, {})

local passedCount = result.status_tally.pass
local failedCount = result.status_tally.fail
print(("[TEST] total=%d passed=%d failed=%d"):format(#result.tests, passedCount, failedCount))

if failedCount > 0 then
	error("[TEST] tiniest tests failed")
end

print("[TEST] tiniest tests passed")
return true
