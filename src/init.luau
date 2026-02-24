--[=[
	@class ExtendedTranslator
	
	LocalizationTable 또는 LocalizationService 우선순위를 관리하며 번역 문자열을 포맷팅하는 도우미입니다.
	스튜디오와 런타임 환경 모두에서 Locale 우선순위를 공유하거나 인스턴스별로 재정의할 수 있습니다.
]=]

local LocalizationService = game:GetService("LocalizationService")
local RunService = game:GetService("RunService")

local Maid = require("./roblox_packages/Maid")
local Signal = require("./roblox_packages/Signal")

local ExtendedTranslator = {}
ExtendedTranslator.__index = ExtendedTranslator
ExtendedTranslator.__type = "ExtendedTranslator"

local globalSettings = {
	LocaleIdsByPriority = { ["en-us"] = 0 },
	OrderedLocaleIds = { "en-us" },
	OrderedLocaleIdsChanged = Signal.new() :: Signal.ChangedSignal<{ string }>,
}

local function sortLocaleIdList(localeIdsByPriority: { [string]: number }): { string }
	local localeIds = {}
	for id in localeIdsByPriority do
		table.insert(localeIds, id)
	end
	table.sort(localeIds, function(a, b)
		local priorityA = localeIdsByPriority[a]
		local priorityB = localeIdsByPriority[b]
		if priorityA ~= priorityB then
			return priorityA > priorityB -- 우선순위 내림차순 (높은 숫자 먼저)
		else
			return a < b -- 이름 오름차순 (동일 우선순위 시)
		end
	end)
	return localeIds
end

local function updateGlobalOrderedLocaleIds()
	globalSettings.OrderedLocaleIds = sortLocaleIdList(globalSettings.LocaleIdsByPriority)
	globalSettings.OrderedLocaleIdsChanged:Fire(globalSettings.OrderedLocaleIds) -- 정렬된 목록으로 시그널 발생
end

--[=[
	@within ExtendedTranslator
	@type ExtendedTranslator ExtendedTranslator
	Locale 우선순위와 Translator 캐시, 상태 시그널을 관리하는 객체입니다.
]=]

export type ExtendedTranslator = setmetatable<{
	IsDestroyed: boolean,
	Maid: Maid.Maid,
	LocalizationTablesByPriority: { [LocalizationTable | LocalizationService]: number },
	OrderedLocalizationTables: { LocalizationTable | LocalizationService },
	LocaleIdsByPriority: { [string]: number },
	OrderedLocaleIds: { string },
	_usesGlobalLocalePriority: boolean,
	_translatorCachesByLocalizationTableAndLocaleId: {
		[LocalizationTable | LocalizationService]: { [string]: Translator },
	},

	LocalizationTableAdded: Signal.Signal<LocalizationTable | LocalizationService, number>,
	LocalizationTableRemoved: Signal.RemovedSignal<LocalizationTable | LocalizationService>,
	OrderedLocaleIdsChanged: Signal.ChangedSignal<{ string }>,
}, typeof(ExtendedTranslator)>

--[=[
	@interface ExtendedTranslatorParams
	@within ExtendedTranslator
	.LocalizationTables {LocalizationTable | LocalizationService} - 초기 등록할 LocalizationTable 목록.
	.LocaleIdsByPriority {[string]: number}? - 인스턴스 전용 Locale 우선순위.
	.UsesGlobalLocalePriority boolean? - true이면 글로벌 우선순위를 공유합니다.
]=]
export type ExtendedTranslatorParams = {
	LocalizationTables: { LocalizationTable | LocalizationService },
	LocaleIdsByPriority: { [string]: number }?,
	UsesGlobalLocalePriority: boolean?,
}

--[=[
	@within ExtendedTranslator
	
	@param params - 초기 설정 값
	@return - 생성된 ExtendedTranslator 인스턴스
]=]
function ExtendedTranslator.new(params: ExtendedTranslatorParams): ExtendedTranslator
	local self = setmetatable({}, ExtendedTranslator)

	self.IsDestroyed = false
	self.Maid = Maid.new()
	self.LocalizationTablesByPriority = {}
	self.OrderedLocalizationTables = {}
	self.LocaleIdsByPriority = {}
	self.OrderedLocaleIds = {}
	self._translatorCachesByLocalizationTableAndLocaleId = {}

	self.LocalizationTableAdded = Signal.new()
	self.LocalizationTableRemoved = Signal.new()
	self.OrderedLocaleIdsChanged = Signal.new()

	local useGlobal = params.UsesGlobalLocalePriority == nil
		or params.UsesGlobalLocalePriority == true
	if params.LocaleIdsByPriority ~= nil or not useGlobal then
		self.LocaleIdsByPriority = params.LocaleIdsByPriority or {}
		self:_updateOrderedLocaleIds()
		self._usesGlobalLocalePriority = false
	else
		if params.LocaleIdsByPriority then
			error(
				`"LocaleIdsByPriority" cannot be provided when "UsesGlobalLocalePriority" is true.`
			)
		end

		self.LocaleIdsByPriority = globalSettings.LocaleIdsByPriority
		self.OrderedLocaleIds = globalSettings.OrderedLocaleIds
		self._usesGlobalLocalePriority = true
		self.Maid:GiveTask(
			globalSettings.OrderedLocaleIdsChanged:Connect(function(newGlobalOrderedList)
				if self._usesGlobalLocalePriority then
					self.LocaleIdsByPriority = globalSettings.LocaleIdsByPriority
					self.OrderedLocaleIds = newGlobalOrderedList
					self.OrderedLocaleIdsChanged:Fire(newGlobalOrderedList)
				end
			end)
		)
	end

	for _, localizationTable in ipairs(params.LocalizationTables) do
		self:AddLocalizationTable(localizationTable, 0)
	end

	self.Maid:GiveTask(self.LocalizationTableAdded)
	self.Maid:GiveTask(self.LocalizationTableRemoved)
	self.Maid:GiveTask(self.OrderedLocaleIdsChanged)

	return self
end

type FormatByKey = (key: string, args: { [string]: any }?) -> string

function ExtendedTranslator.GetFormatByKeyFunction(params: ExtendedTranslatorParams): FormatByKey
	local translator = ExtendedTranslator.new(params)
	return function(key: string, args: { [string]: any }?)
		return translator:FormatByKey(key, args)
	end
end

--[=[
	지정한 우선순위로 LocalizationTable을 추가하고 정렬된 목록을 갱신합니다.
	@param localizationTable - 추가할 테이블.
	@param - @default 0
]=]
function ExtendedTranslator:AddLocalizationTable(
	localizationTable: LocalizationTable | LocalizationService,
	priority: number?
)
	priority = priority or 0
	local isAdded = self.LocalizationTablesByPriority[localizationTable] ~= nil

	self.LocalizationTablesByPriority[localizationTable] = priority
	self:_sortOrderedLocalizationTables()

	if not isAdded then
		self.LocalizationTableAdded:Fire(localizationTable, priority)
	end
end

function ExtendedTranslator:_sortOrderedLocalizationTables()
	local tables = {}
	for tbl in self.LocalizationTablesByPriority do
		table.insert(tables, tbl)
	end
	table.sort(tables, function(a, b)
		local priorityA = self.LocalizationTablesByPriority[a]
		local priorityB = self.LocalizationTablesByPriority[b]
		if priorityA ~= priorityB then
			return priorityA > priorityB
		else
			return a.Name < b.Name
		end
	end)
	self.OrderedLocalizationTables = tables
end

--[=[
	등록된 LocalizationTable을 제거하고 연결된 Translator 캐시를 정리합니다.
	@param localizationTable LocalizationTable | - 제거할 테이블.
]=]
function ExtendedTranslator:RemoveLocalizationTable(
	localizationTable: LocalizationTable | LocalizationService
)
	local existingPriority = self.LocalizationTablesByPriority[localizationTable]
	if not existingPriority then
		return
	end

	self.LocalizationTablesByPriority[localizationTable] = nil
	self._translatorCachesByLocalizationTableAndLocaleId[localizationTable] = nil
	self:_sortOrderedLocalizationTables()
	self.LocalizationTableRemoved:Fire(localizationTable)
end

--[=[
	등록된 Locale 우선순위에 따라 번역 키를 포맷팅합니다.
	@param key - Localization 키.
	@param args - 포맷팅 매개변수.
	@return - 번역된 문자열 또는 키 자체.
]=]
function ExtendedTranslator:FormatByKey(key: string, args: { [string]: any }?): string
	local orderedLocaleIds = self.OrderedLocaleIds

	for _, localeId in ipairs(orderedLocaleIds) do
		local translated = self:_tryFormatByKey(key, args, localeId)
		if translated then
			return translated
		end
	end

	-- 없으면 로컬리제이션 테이블의 SourceLocaleId 로 번역 시도
	local attemptedSourceLocaleIdSet = {}
	for _, localizationTable in ipairs(self.OrderedLocalizationTables) do
		local sourceLocaleId = localizationTable.SourceLocaleId
		local shouldAttempt = not attemptedSourceLocaleIdSet[sourceLocaleId]
			and not table.find(orderedLocaleIds, sourceLocaleId)
		if shouldAttempt then
			attemptedSourceLocaleIdSet[sourceLocaleId] = true
			local translated = self:_tryFormatByKey(key, args, sourceLocaleId)
			if translated then
				return translated
			end
		end
	end

	warn(`Translation not found for Key "{key}" in any specified or source locale.`, 2)
	return key
end

function ExtendedTranslator:_tryFormatByKey(
	key: string,
	args: { [string]: any }?,
	localeId: string
): string?
	for _, localizationTable in self.OrderedLocalizationTables do
		local translator = self:_getTranslator(localizationTable, localeId)
		local success, result = pcall(translator.FormatByKey, translator, key, args)

		if success then
			return result
		end
	end
	return nil
end

function ExtendedTranslator:_getTranslator(
	localizationTable: LocalizationTable | LocalizationService,
	localeId: string
): Translator
	local tableCache = self._translatorCachesByLocalizationTableAndLocaleId[localizationTable]
	if not tableCache then
		tableCache = {}
		self._translatorCachesByLocalizationTableAndLocaleId[localizationTable] = tableCache
	end

	local cachedTranslator = tableCache[localeId]
	if cachedTranslator then
		return cachedTranslator
	else
		local translator = if localizationTable == LocalizationService
			then LocalizationService:GetTranslatorForLocaleAsync(localeId)
			else (localizationTable :: LocalizationTable):GetTranslator(localeId)

		if translator then
			tableCache[localeId] = translator
		end
		return translator
	end
end

--[=[
	인스턴스 전용 Locale 우선순위를 설정하고 변경 시그널을 발생시킵니다.
	@param localeIdsByPriority - Locale ID와 우선순위 매핑.
]=]
function ExtendedTranslator:SetLocaleIdsByPriority(localeIdsByPriority: { [string]: number })
	self.LocaleIdsByPriority = localeIdsByPriority
	self:_updateOrderedLocaleIds()
	self._usesGlobalLocalePriority = false
end

function ExtendedTranslator:_updateOrderedLocaleIds()
	self.OrderedLocaleIds = sortLocaleIdList(self.LocaleIdsByPriority)
	self.OrderedLocaleIdsChanged:Fire(self.OrderedLocaleIds)
end

--[=[
	현재 적용 중인 Locale 우선순위 사본을 반환합니다.
	@return - Locale 우선순위 매핑.
]=]
function ExtendedTranslator:GetLocaleIdsByPriority(): { [string]: number }
	if self._usesGlobalLocalePriority then
		return table.clone(globalSettings.LocaleIdsByPriority)
	else
		return self.LocaleIdsByPriority
	end
end

--[=[
	정렬된 Locale ID 목록의 사본을 제공합니다.
	@return - 우선순위 및 이름 순으로 정렬된 Locale ID 배열.
]=]
function ExtendedTranslator:GetOrderedLocaleIds(): { string }
	if self._usesGlobalLocalePriority then
		return table.clone(globalSettings.OrderedLocaleIds)
	else
		return self.OrderedLocaleIds
	end
end

--[=[
	시그널과 Maid를 정리하고 Translator 캐시를 해제합니다.
]=]
function ExtendedTranslator:Destroy()
	if self.IsDestroyed then
		return
	end
	self.IsDestroyed = true

	self.Maid:Destroy()
	table.clear(self.LocalizationTablesByPriority)
	table.clear(self.OrderedLocalizationTables)
	table.clear(self.LocaleIdsByPriority)
	table.clear(self.OrderedLocaleIds)
	table.clear(self._translatorCachesByLocalizationTableAndLocaleId)
end

--[=[
	글로벌 Locale 우선순위를 갱신하고 공유 시그널을 발행합니다.
	@param localeIdsByPriority - Locale ID 우선순위 매핑.
]=]
function ExtendedTranslator.SetGlobalLocaleIdsByPriority(localeIdsByPriority: { [string]: number })
	assert(typeof(localeIdsByPriority) == "table", "localeIdsByPriority must be a table.")
	globalSettings.LocaleIdsByPriority = localeIdsByPriority
	updateGlobalOrderedLocaleIds()
end

--[=[
	@return - 글로벌 Locale 우선순위 사본.
]=]
function ExtendedTranslator.GetGlobalLocaleIdsByPriority(): { [string]: number }
	return table.clone(globalSettings.LocaleIdsByPriority)
end

--[=[
	@within ExtendedTranslator
	@return - 글로벌 Locale ID 목록 사본.
]=]
function ExtendedTranslator.GetGlobalOrderedLocaleIds(): { string }
	return table.clone(globalSettings.OrderedLocaleIds)
end

--[=[
	@within ExtendedTranslator
	@return - 글로벌 Locale 목록 변경 시그널.
]=]
function ExtendedTranslator.GetGlobalOrderedLocaleIdsChangedSignal(): Signal.Signal<{ string }>
	return globalSettings.OrderedLocaleIdsChanged
end

return ExtendedTranslator
