--[[
	CSV 기반 LocalizationTable을 사용하여 ExtendedTranslator를 검증하는 스펙입니다.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ExtendedTranslator = require(ReplicatedStorage.src)

local localizationTables = ReplicatedStorage:WaitForChild("LocalizationTables")
local baseLocalizationTable = localizationTables:WaitForChild("Base")
local overrideLocalizationTable = localizationTables:WaitForChild("Override")

local function withTranslator(params, callback: (translator: any) -> ())
	local translator = ExtendedTranslator.new(params)
	local ok, err = pcall(callback, translator)
	translator:Destroy()

	if not ok then
		error(err, 0)
	end
end

local function withTemporaryGlobalLocalePriority(
	localeIdsByPriority: { [string]: number },
	callback: () -> ()
)
	local previousGlobalLocaleIdsByPriority = ExtendedTranslator.GetGlobalLocaleIdsByPriority()
	ExtendedTranslator.SetGlobalLocaleIdsByPriority(localeIdsByPriority)
	local ok, err = pcall(callback)
	ExtendedTranslator.SetGlobalLocaleIdsByPriority(previousGlobalLocaleIdsByPriority)

	if not ok then
		error(err, 0)
	end
end

return function(tiny)
	local describe = tiny.describe
	local expect = tiny.expect
	local test = tiny.test

	describe("ExtendedTranslator", function()
		test("uses higher locale priority first", function()
			withTranslator({
				LocalizationTables = { baseLocalizationTable },
				LocaleIdsByPriority = {
					["ja-jp"] = 20,
					["en-us"] = 10,
				},
			}, function(translator)
				expect(translator:FormatByKey("GREETING")).is("こんにちは（基本）")
			end)
		end)

		test("falls back to lower-priority locale when key is missing", function()
			withTranslator({
				LocalizationTables = { baseLocalizationTable },
				LocaleIdsByPriority = {
					["ja-jp"] = 20,
					["en-us"] = 10,
				},
			}, function(translator)
				expect(translator:FormatByKey("ONLY_ENGLISH")).is("English only value")
			end)
		end)

		test("falls back to source locale when translated value is missing", function()
			withTranslator({
				LocalizationTables = { baseLocalizationTable },
				LocaleIdsByPriority = {
					["en-us"] = 10,
				},
			}, function(translator)
				expect(translator:FormatByKey("SOURCE_ONLY")).is("원문 전용")
			end)
		end)

		test("applies localization table priority across multiple tables", function()
			withTranslator({
				LocalizationTables = { baseLocalizationTable, overrideLocalizationTable },
				LocaleIdsByPriority = {
					["en-us"] = 10,
				},
			}, function(translator)
				translator:AddLocalizationTable(baseLocalizationTable, 0)
				translator:AddLocalizationTable(overrideLocalizationTable, 50)

				expect(translator:FormatByKey("GREETING")).is("Hello from override")
				expect(translator:FormatByKey("OVERRIDE_ONLY")).is("Override only value")
				expect(translator:FormatByKey("SHARED_KEY")).is("Override value")
			end)
		end)

		test("returns to lower-priority table after removing a higher-priority table", function()
			withTranslator({
				LocalizationTables = { baseLocalizationTable, overrideLocalizationTable },
				LocaleIdsByPriority = {
					["en-us"] = 10,
				},
			}, function(translator)
				translator:AddLocalizationTable(baseLocalizationTable, 0)
				translator:AddLocalizationTable(overrideLocalizationTable, 50)
				translator:RemoveLocalizationTable(overrideLocalizationTable)

				expect(translator:FormatByKey("GREETING")).is("Hello from base")
				expect(translator:FormatByKey("SHARED_KEY")).is("Base value")
			end)
		end)

		test("formats placeholders with args", function()
			withTranslator({
				LocalizationTables = { baseLocalizationTable },
				LocaleIdsByPriority = {
					["en-us"] = 10,
				},
			}, function(translator)
				expect(translator:FormatByKey("COUNT_FORMAT", {
					count = 3,
				})).is("3.00 items")
			end)
		end)

		test("returns key itself when translation is missing everywhere", function()
			withTranslator({
				LocalizationTables = { baseLocalizationTable },
				LocaleIdsByPriority = {
					["en-us"] = 10,
				},
			}, function(translator)
				expect(translator:FormatByKey("DOES_NOT_EXIST")).is("DOES_NOT_EXIST")
			end)
		end)

		test("reflects global locale priority updates for global mode instances", function()
			withTemporaryGlobalLocalePriority({
				["en-us"] = 0,
			}, function()
				withTranslator({
					LocalizationTables = { baseLocalizationTable },
					UsesGlobalLocalePriority = true,
				}, function(translator)
					expect(translator:GetOrderedLocaleIds()[1]).is("en-us")
					expect(translator:FormatByKey("GREETING")).is("Hello from base")

					ExtendedTranslator.SetGlobalLocaleIdsByPriority({
						["ja-jp"] = 5,
						["en-us"] = 1,
					})
					task.wait()

					expect(translator:GetOrderedLocaleIds()[1]).is("ja-jp")
					expect(translator:FormatByKey("GREETING")).is("こんにちは（基本）")
				end)
			end)
		end)
	end)
end
