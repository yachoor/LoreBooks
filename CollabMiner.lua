--[[
-------------------------------------------------------------------------------
-- LoreBooks, by Ayantir
-------------------------------------------------------------------------------
This software is under : CreativeCommons CC BY-NC-SA 4.0
Attribution-NonCommercial-ShareAlike 4.0 International (CC BY-NC-SA 4.0)

You are free to:

    Share — copy and redistribute the material in any medium or format
    Adapt — remix, transform, and build upon the material
    The licensor cannot revoke these freedoms as long as you follow the license terms.


Under the following terms:

    Attribution — You must give appropriate credit, provide a link to the license, and indicate if changes were made. You may do so in any reasonable manner, but not in any way that suggests the licensor endorses you or your use.
    NonCommercial — You may not use the material for commercial purposes.
    ShareAlike — If you remix, transform, or build upon the material, you must distribute your contributions under the same license as the original.
    No additional restrictions — You may not apply legal terms or technological measures that legally restrict others from doing anything the license permits.


Please read full licence at : 
http://creativecommons.org/licenses/by-nc-sa/4.0/legalcode
]]

local GPS = LibStub("LibGPS2")

local pinInserts
local creations
local eideticCreations
local canProcess
local iReport
local reportIndex
local bookDataIndex
local ExtractBookData
local losts = {}
local extractionDone
local mapIsShowing

local MAX_ZONE_ID = 1300 -- Need to be raised at each API bump
local NUM_MAPS = GetNumMaps()

-- The mastermind that will be sniffing all the data
local MASTER_MINER = "@Kyoma"
local DEADLINE = 20190815
local MINER_ESOVERSION = 439

local NEW_BOOKS_ONLY = false
local VERSION_MUST_MATCH = false
local SHALIDOR_ONLY = false

local lang = GetCVar("Language.2")

local function InvalidPoint(x, y)
	return x < 0 or x > 1 or y < 0 or y > 1
end

local function OnMailReadable(_, mailId)
	
	local mailDataSubject = "CM_DATA"
	local mailFixSubject = "CM_FIX"
	
	local mailIdStr = Id64ToString(mailId)
	if not COLLAB[mailIdStr] then
		local senderDisplayName, _, subject = GetMailItemInfo(mailId)
		if subject == mailDataSubject then
			local body = ReadMail(mailId)
			COLLAB[mailIdStr] = {body = body, sender = senderDisplayName, received = GetDate()}
			d("Don't forget to ReloadUI")
		elseif subject == mailFixSubject then
			local body = ReadMail(mailId)
			d(body)
		end
	end
	
end

local function CoordsNearby(locX, locY, x, y)

	local nearbyIs = 0.0005 --It should be 0.00028, but we add a large diff just in case of. 0.0004 is not enough.
	if math.abs(locX - x) < nearbyIs and math.abs(locY - y) < nearbyIs then
		return true
	end
	return false
	
end


------------------------------
--        Base Parsing      --
------------------------------
function Base62(value)
	local r = false
	local state = type( value )
	if state == "number" then
		local k = math.floor( value )
		if k == value  and  value > 0 then
			local m
			r = ""
			while k > 0 do
				m = k % 62
				k = ( k - m ) / 62
				if m >= 36 then
					m = m + 61
				elseif m >= 10 then
					m = m + 55
				else
					m = m + 48
				end
				r = string.char( m ) .. r
			end
		elseif value == 0 then
			r = "0"
		end
	elseif state == "string" then
		if value:match( "^%w+$" ) then
			local n = #value
			local k = 1
			local c
			r = 0
			for i = n, 1, -1 do
				c = value:byte( i, i )
				if c >= 48  and  c <= 57 then
					c = c - 48
				elseif c >= 65  and  c <= 90 then
					c = c - 55
				elseif c >= 97  and  c <= 122 then
					c = c - 61
				else    -- How comes?
					r = nil
					break    -- for i
				end
				r = r + c * k
				k = k * 62
			end -- for i
		end
	end
	return r
end

-- Dirty trick
local function UnsignedBase62(value)
	if not value or value == "" or value == 0 then
		return "" --compression optimization
	end
	local isNegative = value < 0
	local value62 = Base62(math.abs(value))
	if isNegative then return "-" .. value62 end
	return value62
end

local function RevertUnsignedBase62(value)
	local isNegative = value:find("^%-%w+$")
	if isNegative then
		return 0 - Base62(string.sub(value, 2))
	end
	return Base62(value)
end

local function Explode(divider, stringtoParse)
	if divider == "" then return false end
	local position, values = 0, {}
	for st, sp in function() return string.find(stringtoParse, divider, position, true) end do
		table.insert(values,string.sub(stringtoParse, position, st-1))
		position = sp + 1
	end
	table.insert(values,string.sub(stringtoParse, position))
	return values
end


------------------------------
--    Miner Callback & Co   --
------------------------------
local function EideticValidEntry(categoryIndex)
	-- Check if book actually exists in Shalidor's Library or Eidetic Memory
	if categoryIndex and (categoryIndex == 1 or (categoryIndex == 3 and not SHALIDOR_ONLY)) then
		return true
	end
end

local function BuildDataToShare(bookId)
	
	--d(bookId)
	if bookId then
		local dataToShare
		
		if SetMapToPlayerLocation() == SET_MAP_RESULT_MAP_CHANGED then
			CALLBACK_MANAGER:FireCallbacks("OnWorldMapChanged")
		end
		
		local dontDatamine = {
			--[4575] = true, 
		}
		
		if dontDatamine[bookId] then
			return
		end
		
		if GetCurrentZoneHouseId() ~= 0 then
			return -- You can now read books in houses
		end
		
		-- Will only returns the zone and not the subzone
		local zoneIndex = GetUnitZoneIndex("player")
		local zoneId = GetZoneId(zoneIndex)
		
		-- mapType of the subzone. Needed when we are elsewhere than zone or subzone.
		local mapContentType = GetMapContentType()
		
		local xGPS, yGPS, mapIndexGPS = GPS:LocalToGlobal(GetMapPlayerPosition("player"))
		
		if mapIndexGPS == 1 and zoneId == 0 then
			return
		end

		if not mapIndexGPS then
			mapIndexGPS = 0
		end
		
		local locX = zo_round(xGPS*100000) -- 5 decimals because of Cyrodiil map
		local locY = zo_round(yGPS*100000)
		
		-- v1		= 2.4.0	LOC_DATA_UPDATE	= locX, locY, zoneIndex, mapType, lastInteractionActionWas
		-- v2		= 2.4.2	LOC_DATA_UPDATE	= locX, locY, zoneIndex, mapContentType, mapIndex, lastInteractionActionWas
		-- v3		= 2.4.4	LOC_DATA_UPDATE	= locX, locY, zoneIndex, mapContentType, mapIndex, lastInteractionActionWas, langCode
		-- v4		= 2.4.5	LOC_DATA_UPDATE	= locX, locY, zoneIndex, mapContentType, mapIndex, lastInteractionActionWas, langCode, apiVersion
		-- v5		= 2.5		LOC_DATA_UPDATE	= locX, locY, zoneIndex, mapContentType, mapIndex, lastInteractionActionWas, langCode, apiVersion, currentZoneDungeonDifficulty
		-- v6		= 2.5.1	LOC_DATA_UPDATE	= locX, locY, zoneIndex, mapContentType, mapIndex, lastInteractionActionWas, langCode, apiVersion, currentZoneDungeonDifficulty, reticleAway, associatedQuest
		-- v7		= 4		BOOK_DATA_UPDATE	= categoryIndex, collectionIndex, bookIndex, mediumIndex
		-- v8		= 5		LOC_DATA_UPDATE	= locX, locY, zoneId, mapContentType, mapIndex, lastInteractionActionWas, langCode, ESOVersion, interactionType, associatedQuest
		-- v9		= 5.1		LOC_DATA_UPDATE	= locX, locY, zoneId, mapContentType, mapIndex, lastInteractionActionWas, langCode, LorebooksVersion, ESOVersion, interactionType, associatedQuest
		-- v10	= 5.3		DAT_UPDATE			= Added collection 52.
		-- v11	= 5.4		BOOK_DATA_UPDATE	= categoryIndex, collectionIndex, bookIndex, mediumIndex, bookId
		-- v12	= 5.4		BOOK_DATA_UPDATE	= locX, locY, zoneId, mapContentType, mapIndex, isObject, langCode, LorebooksVersion, ESOVersion, interactionType, associatedQuest
		-- v13	= 6		BOOK_DATA_UPDATE	= bookId
		dataToShare = UnsignedBase62(locX) .. ";" .. UnsignedBase62(locY) .. ";" .. UnsignedBase62(zoneId) .. ";" .. UnsignedBase62(mapContentType) .. ";" .. UnsignedBase62(mapIndexGPS)
		
		local isObject = IsPlayerInteractingWithObject()
		if isObject then
			dataToShare = dataToShare ..";" -- means 0
		else
			dataToShare = dataToShare ..";1"
            -- dont return here because we want quest info
			--return -- Bookshelve & others 
		end
		
		local clang
		if lang == "en" then clang = 1 end
		if lang == "fr" then clang = 2 end
		if lang == "de" then clang = 3 end
		
		local MINER_VERSION = 15
		dataToShare = dataToShare ..";" .. clang .. ";" .. UnsignedBase62(MINER_VERSION) ..";" .. UnsignedBase62(tonumber(ESOVersion))
		
		local categoryIndex, collectionIndex, bookIndex = GetLoreBookIndicesFromBookId(bookId)
		
		local bookName = GetLoreBookInfo(categoryIndex, collectionIndex, bookIndex)
		
		local associatedQuest = ""
		local interactionType = GetInteractionType() -- If user runs an addon which break interaction, the result will return INTERACTION_NONE even if he was reading a book.
		if interactionType == INTERACTION_NONE then --book read from inventory or case above.
			for questIndex, questData in pairs(SHARED_INVENTORY.questCache) do
				for itemIndex, itemData in pairs(questData) do
					if string.lower(itemData.name) == string.lower(bookName) then
						associatedQuest = GetJournalQuestInfo(questIndex)
                        isObject = true -- so we don't skip this 
                        --d(associatedQuest)
						break
					end
				end
			end
		end
        --df("Book [%d] |H1:book:%d|h|h - %s", bookId, bookId, associatedQuest)

		dataToShare = dataToShare .. ";" .. UnsignedBase62(interactionType) .. ";" .. associatedQuest
		
		if EideticValidEntry(categoryIndex) then
			
			local bookData = LoreBooks_GetNewEideticDataFromBookId(bookId, categoryIndex == 1)
			if bookData and bookData.c and bookData.e then
                if not isObject and (not bookData.r or (bookData.r and type(bookData.m) == "table" and bookData.m[mapIndexGPS])) then
					return -- Found a random book and this book is already tagged as random for the same map or got a static position
                elseif associatedQuest ~= "" and not bookData.q then
                    -- we always want the quest data right now for books that don't have any yet
				else
					for _, data in ipairs(bookData.e) do
						if not data.r then
							if interactionType == INTERACTION_NONE then
								return -- User read book from inventory but we already found pin from a static position
							elseif CoordsNearby(xGPS, yGPS, data.x, data.y) then
								if data.d then
									if data.z == zoneId then
										--d("Pin already found")
										return
									end
								else
                                    --d("Pin already found")
									return -- Pin already found
								end
							end
						end
					end
				end
			end
			
			dataToShare = dataToShare .. "@" .. bookId
			
		else
			return -- We don't collect anymore books from users which didn't yet unlocked Eidetic Memory
		end
		return dataToShare
		
	end
		
end


-- Book we know that they are book quest but not mined for now (mainly used to avoid  tons of pins everywhere).
local function IsBookQuest(bookId)
	
	local data = LoreBooks_GetAdditionnalBookData(bookId)
	if data and data.q then
		return true
	end
	
end

local function GetQuestData(bookId)
	
	local data = LoreBooks_GetAdditionnalBookData(bookId)
	if data and data.q then
		return data.q
	end
	
end

local function GetQuestMapData(bookId)

	local data = LoreBooks_GetAdditionnalBookData(bookId)
	if data and data.m then
		return data.m
	end

end

local function CheckShalidorBook(bookId)

	local dontCheck = {
		[117] = true, -- Shalidor special book
		[101] = true, -- Shalidor special book
		[119] = true, -- Shalidor special book
	}
	
	if dontCheck[bookId] then
		return false
	end

	return true

end

local function GetQuestsDataByName(questName)
	
	local languageFrom = 0
	local questCode = 0
	local questNames = {en = 0, fr = 0, de = 0}
	local quests = LoreBooks_GetGameWholeQuestsData("en")
	
	for questId, questNameInArray in pairs(quests) do
		if questName == questNameInArray then
			languageFrom = 1
			questCode = questId
			break
		end
	end
	
	if questCode == 0 then
		quests = LoreBooks_GetGameWholeQuestsData("fr")
		for questId, questNameInArray in pairs(quests) do
			if questName == questNameInArray then
				languageFrom = 2
				questCode = questId
				break
			end
		end
	end
	
	if questCode == 0 then
		quests = LoreBooks_GetGameWholeQuestsData("de")
		for questId, questNameInArray in pairs(quests) do
			if questName == questNameInArray then
				languageFrom = 3
				questCode = questId
				break
			end
		end
	end
	
	if questCode ~= 0 then
		local questNameEN, questNameFR, questNameDE = LoreBooks_GetGameQuestData(questCode)
		questNames = {en = questNameEN, fr = questNameFR, de = questNameDE}
	end
	
	return questCode, languageFrom, questNames
	
end


--/script local list = {} for id=1, 1200 do local index = GetMapIndexByZoneId(id) if index ~= nil then list[index] = id end end DATAMINED_DATA.maps = list

-- 100026
local function GetZoneIdWithMapIndex(mapIndex)

	local maps = 
    {
        [2] = 3,
        [3] = 20,
        [4] = 19,
        [5] = 104,
        [6] = 92,
        [7] = 383,
        [8] = 58,
        [9] = 117,
        [10] = 57,
        [11] = 41,
        [12] = 103,
        [13] = 101,
        [14] = 181,
        [15] = 381,
        [16] = 108,
        [17] = 382,
        [18] = 281,
        [19] = 534,
        [20] = 535,
        [21] = 537,
        [22] = 280,
        [23] = 347,
        [25] = 888,
        [26] = 584,
        [27] = 684,
        [28] = 816,
        [29] = 823,
        [30] = 849,
        [31] = 980,
        [32] = 1011,
        [33] = 1027,
        [34] = 726,
        [35] = 1072,
        [36] = 1086,
    }
	return maps[mapIndex]

end
local function ExtractBookData() end
local function JumpToNextBook(index)

	if DATAMINED_DATA.decoded[index + 1] then
		
		if index % 2000 == 0 then
			d("ExtractBookData -> " .. index)
		end
		
		if index % 100 == 0 then
			zo_callLater(function() ExtractBookData(index + 1) end, 1) -- Mandatory or game will crash
		else
			ExtractBookData(index + 1)
		end
		
	else
		d("Process complete")
		d(pinInserts .. " pinInserts")
		d(creations .. " creations")
		d(eideticCreations .. " eideticCreations")
	end
	
end

local ignoreList = 
{
    [1138] = true, -- Begger's Prince, at Illumination Academy but is otherwise random
}

local forceRandom = 
{
    [4877] = true, -- [Words and Power]
    [4896] = true, -- [Words of the Fallen]
    [4494] = true,
    [4879] = true,
    [5108] = true,
}

local eideticMemory = LoreBooks_GetBookData()

ExtractBookData = function(index)
	
	local key = ""
	
	local bookData = DATAMINED_DATA.decoded[index]
	if not bookData then return end
	
	local coordsOK = false
	local bookOK = false
	
	local x							= bookData.x / 100000
	local y							= bookData.y / 100000
	
	local version					= bookData.v
	local questLinked				= bookData.q
	local zoneId					= bookData.z
	local mapIndex					= bookData.m
	local mapContentType			= bookData.d
	local langCode					= bookData.a
	local interactionType			= bookData.i
	local bookId					= bookData.k
	
	local categoryIndex, collectionIndex, bookIndex = GetLoreBookIndicesFromBookId(bookId)

	if not categoryIndex or (version ~= MINER_ESOVERSION and VERSION_MUST_MATCH) or ignoreList[bookId] then
		JumpToNextBook(index)
		return
	end

	--if not forceRandom[bookId] then
	--	JumpToNextBook(index)
	--	return
    --end
    
	if LoreBooks_GetNewEideticDataFromBookId(bookId).c and NEW_BOOKS_ONLY then
		JumpToNextBook(index)
		return
	end

	local isRandom					= true

    if bookData.r == 0 and not forceRandom[bookId] then
		isRandom = false
	end
	
	local bookConfirmed
	local bookLost
	
	local inDungeon				= mapContentType == MAP_CONTENT_DUNGEON
	
	if mapIndex == GetCyrodiilMapIndex() and (zoneId == 584 or zoneId == 643 or zoneId == 678 or zoneId == 688) then -- IC/Sewers/ICP/WGT
		mapIndex = GetImperialCityMapIndex()
	end
	
	if zoneId < 1 or zoneId > MAX_ZONE_ID or mapIndex < 1 or mapIndex > NUM_MAPS then
	
		if mapIndex > 1 and mapIndex ~= 24 then
			zoneId = GetZoneIdWithMapIndex(mapIndex)
			inDungeon = true
			bookLost = true
		elseif not InvalidPoint(x, y) then
			
			ZO_WorldMap_SetMapByIndex(1) -- Tamriel
			local wouldProcess, resultingMapIndex = WouldProcessMapClick(x, y)
			if wouldProcess then
				mapIndex = resultingMapIndex
				zoneId = GetZoneIdWithMapIndex(mapIndex)
				inDungeon = true
				bookLost = true
			end
			
		else
			d("Book Lost : [".. GetLoreBookInfo(categoryIndex, collectionIndex, bookIndex) .."]")
		end
		
	end
	
	if EideticValidEntry(categoryIndex) then
		
		if not DATAMINED_DATA.build[bookId] then DATAMINED_DATA.build[bookId] = {} end
		
		if not DATAMINED_DATA.build[bookId].c then
		
			DATAMINED_DATA.build[bookId].c = true
			DATAMINED_DATA.build[bookId].k = bookId
			
			creations = creations + 1
			
			if categoryIndex == 3 then
				eideticCreations = eideticCreations + 1
			end
		end

		if (DATAMINED_DATA.build[bookId].e and #DATAMINED_DATA.build[bookId].e >= 1) or DATAMINED_DATA.build[bookId].r then
			
			if interactionType == INTERACTION_NONE then
				
				-- book have quest data but reference don't have
				if questLinked ~= "0" and (not DATAMINED_DATA.build[bookId].q or DATAMINED_DATA.build[bookId].q == "0") then
					DATAMINED_DATA.build[bookId].q = questLinked
				end

				-- If book was read from inventory (or with case addon breaking interaction) and we have a book read from an interaction, don't push it
				for entryIndex, entryData in ipairs(DATAMINED_DATA.build[bookId].e) do
					
					if entryData.i == INTERACTION_BOOK then
						JumpToNextBook(index)
						return
					end
					
				end
			else
			
				-- If book was read from inventory (or with case addon breaking interaction) and we have a book read from an interaction, don't push it
				if DATAMINED_DATA.build[bookId].e then
					for entryIndex = #DATAMINED_DATA.build[bookId].e, 1, -1 do
						
						if DATAMINED_DATA.build[bookId].e[entryIndex].i == INTERACTION_NONE then
							table.remove(DATAMINED_DATA.build[bookId].e, entryIndex)
						end
						
					end
				end
			
			end
			
			if isRandom then
				
				-- Was 100% random
				if DATAMINED_DATA.build[bookId].r then
					
					-- If random was only found in 1 map and it is the same map
					if NonContiguousCount(DATAMINED_DATA.build[bookId].m) == 1 and DATAMINED_DATA.build[bookId].m[mapIndex] then
						
						-- Random at the same loc.
						if DATAMINED_DATA.build[bookId].e then
							for entryIndex, entryData in ipairs(DATAMINED_DATA.build[bookId].e) do
								
								if entryData.z == zoneId and entryData.d == inDungeon and CoordsNearby(x, y, entryData.x, entryData.y) then
									bookFound = true
									break
								end
								
							end
						end
						
						-- New pin
						if not bookFound then
						
							DATAMINED_DATA.build[bookId].m[mapIndex] = DATAMINED_DATA.build[bookId].m[mapIndex] + 1
							
							table.insert(DATAMINED_DATA.build[bookId].e, {
								r = isRandom,
								x = x,
								y = y,
								z = zoneId,
								m = mapIndex,
								d = inDungeon,
								i = interactionType,
								l = bookLost,
							})
							
							if questLinked ~= "0" then
								DATAMINED_DATA.build[bookId].q = questLinked
							end
							
							pinInserts = pinInserts + 1
							
						end
					
					-- Keep books with q flag. they'll be stripped later after checking
					elseif not DATAMINED_DATA.build[bookId].q then
						
						-- Random on multiple maps, delete pins
						DATAMINED_DATA.build[bookId].e = {}
						if not DATAMINED_DATA.build[bookId].m[mapIndex] then
							DATAMINED_DATA.build[bookId].m[mapIndex] = 1
						else
							DATAMINED_DATA.build[bookId].m[mapIndex] = DATAMINED_DATA.build[bookId].m[mapIndex] + 1
						end
						
					end
					
				end
				
			else
				
				--
				if DATAMINED_DATA.build[bookId].r then
					DATAMINED_DATA.build[bookId].r = nil
					DATAMINED_DATA.build[bookId].m = nil
					DATAMINED_DATA.build[bookId].e = {}
				end
                
                --if LoreBooks_GetNewEideticDataFromBookId(bookId).c then
                --    DATAMINED_DATA.build[bookId].u = true
                --    --DATAMINED_DATA.build[bookId].e =  LoreBooks_GetNewEideticDataFromBookId(bookId).e
                --end
				
				local bookFound
				
				-- Check if we have the book at its coordinates
				if DATAMINED_DATA.build[bookId].e then
					for entryIndex = #DATAMINED_DATA.build[bookId].e, 1, -1 do
						if DATAMINED_DATA.build[bookId].e[entryIndex].d == inDungeon and CoordsNearby(x, y, DATAMINED_DATA.build[bookId].e[entryIndex].x, DATAMINED_DATA.build[bookId].e[entryIndex].y) then
							if DATAMINED_DATA.build[bookId].e[entryIndex].z == zoneId then
								bookFound = true
								break
							elseif DATAMINED_DATA.build[bookId].e[entryIndex].z == GetZoneIdWithMapIndex(DATAMINED_DATA.build[bookId].e[entryIndex].m) then
								d("DungeonCorrection: Book: " .. bookId .. " ; Entry: " .. entryIndex .. " NewZoneEntry: " .. zoneId .. " (" .. zo_strformat(SI_WINDOW_TITLE_WORLD_MAP, GetZoneNameByIndex(GetZoneIndex(zoneId))) .. ") ; Was: " .. DATAMINED_DATA.build[bookId].e[entryIndex].z .. " (" .. zo_strformat(SI_WINDOW_TITLE_WORLD_MAP, GetZoneNameByIndex(GetZoneIndex(DATAMINED_DATA.build[bookId].e[entryIndex].z)))..")")
								table.remove(DATAMINED_DATA.build[bookId].e, entryIndex)
							end
						end
					end
				end
				
				-- New pin
				if not bookFound then
				
					d("NewStaticPos: " .. categoryIndex .."/" .. collectionIndex .."/" .. bookIndex .. " [".. GetLoreBookInfo(categoryIndex, collectionIndex, bookIndex) .."]")
					
					table.insert(DATAMINED_DATA.build[bookId].e, {
						r = isRandom,
						x = x,
						y = y,
						z = zoneId,
						m = mapIndex,
						d = inDungeon,
						i = interactionType,
						l = bookLost,
					})
					
					if questLinked ~= "0" then
						DATAMINED_DATA.build[bookId].q = questLinked
					end
					
					pinInserts = pinInserts + 1
				
				end
				
			end
			
		-- New random entry
		elseif isRandom then
		
			d("NewRandom: " .. categoryIndex .."/" .. collectionIndex .."/" .. bookIndex .. " [".. GetLoreBookInfo(categoryIndex, collectionIndex, bookIndex) .."]")
		
			DATAMINED_DATA.build[bookId].e = {}
			
			table.insert(DATAMINED_DATA.build[bookId].e, {
				r = isRandom,
				x = x,
				y = y,
				z = zoneId,
				m = mapIndex,
				d = inDungeon,
				i = interactionType,
				l = bookLost,
			})
			
			DATAMINED_DATA.build[bookId].r = true
			DATAMINED_DATA.build[bookId].m = {}
			DATAMINED_DATA.build[bookId].m[mapIndex] = 1
			
			if questLinked ~= "0" then
				DATAMINED_DATA.build[bookId].q = questLinked
			end
			
			pinInserts = pinInserts + 1
			
		else
			
			d("NewStatic: " .. categoryIndex .."/" .. collectionIndex .."/" .. bookIndex .. " [".. GetLoreBookInfo(categoryIndex, collectionIndex, bookIndex) .."]")
			
			-- New static entry
			DATAMINED_DATA.build[bookId].e = {}
			
			table.insert(DATAMINED_DATA.build[bookId].e, {
				r = isRandom,
				x = x,
				y = y,
				z = zoneId,
				m = mapIndex,
				d = inDungeon,
				i = interactionType,
				l = bookLost,
			})
			
			if questLinked ~= "0" then
				DATAMINED_DATA.build[bookId].q = questLinked
			end
			
			pinInserts = pinInserts + 1
			
		end
		
	end
	
	JumpToNextBook(index)
	
end

local function ExtractData()
	
	if not ZO_WorldMap_IsWorldMapShowing() and (not LBooks_SavedVariables or (LBooks_SavedVariables and LBooks_SavedVariables.Default[GetDisplayName()][GetUnitName("player")].unlockEidetic == false)) then
	
		d("DO NOT OPEN MAP UNTIL PROCESS IS FINISHED")
		d("LOREBOOKS PREHOOKING MUST BE DISABLED WHILE EXTRACTING")
		
		losts = {}
		creations = 0
		eideticCreations = 0
		pinInserts = 0
		extractionDone = true
		
		if not DATAMINED_DATA.build then DATAMINED_DATA.build = {} end
		
		ExtractBookData(1)
		
	end

end

-- those errors are still not understood and ned to be wiped
local function CleanUnknownErrors()

end

-- those errors are made to help people because ZOS data can be wrong
local function CleanKnownErrors()

	local neverDatamined = {
		--[3170] = true, -- [A Less Rude Song] can now be found in Clockwork City bookshelves
	}
	
	local questRelated = {
	--	[3046] = select(3, GetQuestsDataByName("Taking the Undaunted Pledge")), -- [Tome of the Undaunted]
	}
    
    --local forceRandom = {
    --    [4879] = 32, -- [The Inexplicable Patron: Mephala]
    --    [4896] = 32, -- [Words of the Fallen]
    --}
	
	local bugged = {
	--	[1733] = true, -- [A Plea for the Elder Scrolls]
	}
	
	for bookId in pairs(neverDatamined) do
		if not DATAMINED_DATA.build[bookId] then
			DATAMINED_DATA.build[bookId] = {k = bookId, l = true}
		elseif DATAMINED_DATA.build[bookId].r or DATAMINED_DATA.build[bookId].e then
			d("Book tagged Unknown (NeverFound) has been found : " .. bookId)
		end
	end
	
	for bookId, questData in pairs(questRelated) do
		if not DATAMINED_DATA.build[bookId] then
			DATAMINED_DATA.build[bookId] = {k = bookId, q = questData}
		elseif DATAMINED_DATA.build[bookId].r or DATAMINED_DATA.build[bookId].e then
			d("Book tagged Unknown (QuestLnked) has been found : " .. bookId)
		end
	end
	
	for bookId in pairs(bugged) do
		if not DATAMINED_DATA.build[bookId] then
			DATAMINED_DATA.build[bookId] = {k = bookId, l = true}
		elseif DATAMINED_DATA.build[bookId].r or DATAMINED_DATA.build[bookId].e then
			d("Book tagged Unknown (Bugged) has been found : " .. bookId)
		end
	end
	
end

local function BuildBooks()
	
	d("LOREBOOKS PREHOOKING MUST BE DISABLED WHILE EXTRACTING")

    DATAMINED_DATA.additionalQuestData = {}
	if not LBooks_SavedVariables or LBooks_SavedVariables.Default[GetDisplayName()][GetUnitName("player")].unlockEidetic == false then
		
		if extractionDone then
			DATAMINED_DATA.decoded = nil -- too much data in sv will crash eso
		end
		
		for bookId, bookData in pairs(DATAMINED_DATA.build) do
			
			if bookData.e then
				local categoryIndex, collectionIndex, bookIndex = GetLoreBookIndicesFromBookId(bookId)
				
				if categoryIndex == 3 then
					-- Add q flag to books we know they are book quests
					if IsBookQuest(bookId) then
						bookData.q = GetQuestData(bookId)
						bookData.qm = GetQuestMapData(bookId)
						bookData.r = false
						
					elseif bookData.q and type(bookData.q) == "string" and bookData.q ~= "0" then
						local questCode, _, questNames = GetQuestsDataByName(bookData.q)
						if questCode then
							--local questInfos = "{ en = \"" .. tostring(questNames.en) .. "\", fr = \"" .. tostring(questNames.fr) .. "\", de = \"" .. tostring(questNames.de) .. "\" }, -- " .. questCode
							--d("q = " .. bookData.q .. " " .. questInfos .. " : Book " .. bookId .. " [" .. GetLoreBookInfo(categoryIndex, collectionIndex, bookIndex) .. "]")
                            bookData.q = questCode
                            bookData.qm = bookData.m
						else
							d("New quest to add: " .. bookData.q)
						end
					end
				else
					bookData.q = nil
				end
				
				if #bookData.e >= 1 then
					
					for entryIndex, entryData in ipairs(bookData.e) do
						
						-- Shalidor warning
						if categoryIndex == 1 and zo_strformat(SI_WINDOW_TITLE_WORLD_MAP, GetMapNameByIndex(entryData.m)) == zo_strformat(SI_WINDOW_TITLE_WORLD_MAP, GetZoneNameByIndex(GetZoneIndex(entryData.z))) then
							
							local bookFound
							if CheckShalidorBook(bookId) then
								local mapData = LoreBooks_GetMapIndexMainData(entryData.m)
								if mapData then
									for index, data in ipairs(mapData) do
										if data[3] == collectionIndex and data[4] == bookIndex then
											local gX, gY = GPS:ZoneToGlobal(entryData.m, data[1], data[2])
											if CoordsNearby(gX, gY, entryData.x, entryData.y) then
												bookFound = true
												break
											end
										end
									end
									if not bookFound then
										local xT, yT, coords
										if entryData.zx then
											xT = ("%0.05f"):format(zo_round(entryData.zx*10000)/100)
											yT = ("%0.05f"):format(zo_round(entryData.zy*10000)/100)
											coords= "Z"
										else
											xT = entryData.x
											yT = entryData.y
											coords = "G"
										end
										d("Shali : [" .. GetLoreBookInfo(categoryIndex, collectionIndex, bookIndex) .."], Coords : " .. zo_strformat(SI_WINDOW_TITLE_WORLD_MAP, GetZoneNameByIndex(GetZoneIndex(entryData.z))) .. " : " .. coords .. " " .. xT .. "x" .. yT .. " (Dungeon=" .. tostring(entryData.d) .. ")")
									end
								end
							end
						end
						
					end
					
				end
			elseif extractionDone and not bookData.r then
				if EideticValidEntry(categoryIndex) then
					d("StillUnknown : " .. categoryIndex .. "/" .. collectionIndex .. "/" .. bookIndex .. " [".. GetLoreBookInfo(categoryIndex, collectionIndex, bookIndex) .."]")
				end
			end
		
		end
		
		CleanUnknownErrors()
		CleanKnownErrors()

		d("DATAMINED_DATA.build done")
		d("Order is /lbd (decode) /lbb (each language prebuild) /lbe (extract) /lbc (coords) /lbb (postbuild)")
	
	end

end

local function CalculateCoordsForMap(mapIndex)

	for bookId, bookData in pairs(DATAMINED_DATA.build) do
		if bookData.e and #bookData.e >= 1 then
			for entryIndex, entryData in ipairs(bookData.e) do
				if not entryData.zx and entryData.m == mapIndex then
					local xLoc, yLoc = GPS:GlobalToLocal(entryData.x, entryData.y)
					if xLoc ~= nil and yLoc ~= nil and xLoc > 0 and yLoc > 0 and xLoc < 1 and yLoc < 1 then
						entryData.zx = xLoc
						entryData.zy = yLoc
					end
				end
			end
		end
	end
	
end

local function PrecalculateCoords(mapIndex)
	
	if mapIndex == "" then mapIndex = 1 end
	
	if not LBooks_SavedVariables or LBooks_SavedVariables.Default[GetDisplayName()][GetUnitName("player")].unlockEidetic == false then
		if mapIndex <= NUM_MAPS then
			if mapIndex ~= 0 and mapIndex ~= 1 and mapIndex ~= 24 then -- Tamriel & Aurbis
				ZO_WorldMap_SetMapByIndex(mapIndex)
				CalculateCoordsForMap(mapIndex)
			end
		end
	end
	
	if mapIndex == NUM_MAPS then
		d("PrecalculateCoords finished")
	else
		zo_callLater(function() PrecalculateCoords(mapIndex + 1) end, 10)
	end
	
end

local function SetEmptyDataToZero(array)
	local t = {}
	for i in ipairs(array) do
		if array[i] == "" then --2nd is a bug client side (v10)
			t[i] = "0" -- Optimization client side
		else
			t[i] = array[i]
		end
	end
	return t
end

local function DecodeData(data, onlyOne)

	for entryIndex, entryData in ipairs(data) do
		
		local rawEntry = Explode("@", entryData)
		local coordsEntry = Explode(";", rawEntry[1])
		
		if #coordsEntry >= 11 then
			
			local bookEntry = Explode(";", rawEntry[2])
			
			local coordsRewrited = SetEmptyDataToZero(coordsEntry)
			local bookRewrited = SetEmptyDataToZero(bookEntry)
			
			local miscEntry, miscRewrited
			if rawEntry[3] then
				miscEntry = Explode(";", rawEntry[3])
				miscRewrited = SetEmptyDataToZero(miscEntry)
			end
			
			-- Coordinates
			local xGPS					= RevertUnsignedBase62(coordsRewrited[1]) -- can be negative
			local yGPS					= RevertUnsignedBase62(coordsRewrited[2]) -- can be negative
			local zoneId				= Base62(coordsRewrited[3])
			
			local mapContentType		= tonumber(coordsRewrited[4])
			local mapIndex				= Base62(coordsRewrited[5])
			local randomFlag			= tonumber(coordsRewrited[6])
			local langCode				= tonumber(coordsRewrited[7])
			
			local minerVersion		= Base62(coordsRewrited[8])
			local esoVersion			= Base62(coordsRewrited[9])
			local interactionType	= Base62(coordsRewrited[10])
			local associatedQuest	= coordsRewrited[11]
			
			-- Book Data
			local bookId				= tonumber(bookRewrited[1])
         
         if xGPS == false or yGPS == false then
				d(entryData)
         else --if esoVersion >= 335 and minerVersion == 15 then
				
				local data = {
					x		= xGPS,					-- X
					y		= yGPS,					-- Y
					z		= zoneId,				-- Zone
					d		= mapContentType,		-- Dungeon
					m		= mapIndex,				-- Map
					r		= randomFlag,			-- Random
					a		= langCode,				-- Lang
					v		= esoVersion,			-- Version
					i		= interactionType,	-- Interaction
					q		= associatedQuest,	-- Quest
					e		= minerVersion,		-- LoreBooks Version
					k		= bookId,				-- bookId
				}
				--d(data)
				if onlyOne then
					return data
				else
					table.insert(DATAMINED_DATA.decoded, data)
				end
				
			end
		end
		
	end

	return false

end

local function CleanCollab()
	
	for entryIndex, entryData in pairs(COLLAB) do
		if entryData.decoded then entryData.decoded = nil end
	end
	
	DATAMINED_DATA.build = {}
	DATAMINED_DATA.decoded = {}
	DATAMINED_DATA.libraryData = {}
	
	d("Cleaned")
	
end

local function DecodeReport(reportData)
	
	if canProcess then
	
		canProcess = false
		
		local rawReport = Explode("\n", reportData.body)
		
		DecodeData(rawReport)
		
		reportIndex = reportIndex + 1
		reportData.decoded = true
		
		if reportIndex == iReport then
			d("Decode complete")
			d(tostring(#DATAMINED_DATA.decoded) .. " entries in .decoded")
		elseif reportIndex % 500 == 0 then
			d("DecodeCollab -> " .. reportIndex)
		end

		canProcess = true
		
	else
		d("Report tried to be processed before end of other one, raise timeShift")
	end
	
end

local function SeeData(rawData)
	local rawReport = Explode("\n", rawData)
	local data = DecodeData(rawReport, true)
	
	if data then
			d("GPS-X=" .. tostring(data.x))
			d("GPS-Y=" .. tostring(data.y))
			d("ZoneId=" .. tostring(data.z) .. " " .. zo_strformat(SI_WINDOW_TITLE_WORLD_MAP, GetZoneNameByIndex(GetZoneIndex(data.z))))
			d("InDungeon=" .. tostring(data.d))
			d("Map=" .. tostring(data.m) .. " " .. zo_strformat(SI_WINDOW_TITLE_WORLD_MAP, GetMapNameByIndex(data.m)))
			d("IsRandom=" .. tostring(data.r))
			d("Lang=" .. tostring(data.a))
			d("EsoVersion=" .. tostring(data.v))
			d("Interaction=" .. tostring(data.i))
			d("Quest=" .. tostring(data.q))
			d("MinerVersion=" .. tostring(data.e))
			d("BookId=" .. tostring(data.k) .. " " .. GetLoreBookInfo(GetLoreBookIndicesFromBookId(data.k)))
	else
		d("Data has not being pushed")
	end
	
end

local function PushData(data)
	local rawReport = Explode("\n", data)
	DecodeData(rawReport)
	d("Data pushed")
end

local function DecodeCollab()
	
	local timeShift = 0
	iReport = 0
	reportIndex = 0
	canProcess = true
	
	if not DATAMINED_DATA.decoded then DATAMINED_DATA.decoded = {} end
	
	for reportId, reportData in pairs(COLLAB) do
		--if not reportData.decoded then
			zo_callLater(function() DecodeReport(reportData) end, timeShift)
			timeShift = timeShift + 3 -- Mandatory or game will crash
			iReport = iReport + 1
		--end
	end
	
	d(iReport .. " to check")

end

local function SortLibrary()
	
	df("Sorting %d books", #DATAMINED_DATA.build)
	local function CompareData(data1, data2)
		local result = false
		for index, entryData in pairs(data1.e) do
			local new = true
			if data2.e then
				for index2, entryData2 in pairs(data2.e) do
					if entryData.m ~= entryData2.m then
						--d("different map")
					elseif entryData.i ~= entryData2.i then
						--d("different index")
					elseif entryData.z ~= entryData2.z then
						--d("different zone")
					elseif entryData.d and entryData2.d and entryData.d ~= entryData2.d then
						--d("different dungeon")
					elseif entryData.r and entryData2.r and entryData.r ~= entryData2.r then
						--d("different random")
					else
						if entryData.zx and entryData2.zx then
							if CoordsNearby(entryData.zx, entryData.zy, entryData2.zx, entryData2.zy) then
								--d("nearby zone coords")
								new = false
							end
						elseif CoordsNearby(entryData.x, entryData.y, entryData2.x, entryData2.y) then
							--d("nearby coords")
							new = false
						end
					end
				end
			end
			result = result or new
		end
		return result
	end
	
	local newBuild = {}
	local shaliBuild = {}

	DATAMINED_DATA.buildSorted = {}
	DATAMINED_DATA.buildSorted["new"] = {}
	DATAMINED_DATA.buildSorted["shalidor"] = {}
	DATAMINED_DATA.buildSorted["shelves"] = {}
	
	local shali = DATAMINED_DATA.buildSorted["shalidor"]
	local new = DATAMINED_DATA.buildSorted["new"]
	local shelves = DATAMINED_DATA.buildSorted["shelves"]

	for bookId, bookData in pairs(DATAMINED_DATA.build) do
		local existingData = LoreBooks_GetNewEideticDataFromBookId(bookId)
		local categoryIndex, collectionIndex, bookIndex = GetLoreBookIndicesFromBookId(bookId)
		local bookName = GetLoreBookInfo(categoryIndex, collectionIndex, bookIndex)
		local isNew = false
		if not existingData.c or not existingData.e then
			isNew = true
		end
		local isUpdate = not isNew and CompareData(bookData, existingData)
		if categoryIndex == 1 then
			shali[bookId] = bookData
			for _, e in pairs(bookData.e) do
				if e.l then
					d("LOST BOOK")
				end
				d(string.format("[\"%s\"]{ %.4f, %.4f, %d, %d }, -- %s", GetZoneNameById(e.z), e.zx, e.zy, collectionIndex, bookIndex, bookName))
			end
		elseif isNew then
			new[bookId] = bookData
		end
	end

	for k, v in pairs(DATAMINED_DATA.buildSorted) do
		df("%s #%d", k, #v)
	end
	
	--for bookId, bookData in pairs(LoreBooks_GetBookData()) do
	--	local categoryIndex, collectionIndex, bookIndex = GetLoreBookIndicesFromBookId(bookId)
	--	if categoryIndex == 1 then
	--		shaliBuild[bookId] = bookData
	--	else
	--		newBuild[bookId] = bookData
	--	end
	--end

	--DATAMINED_DATA.build = newBuild
	DATAMINED_DATA.shaliBuild = shaliBuild

end

local function CompletedQuests()
	if not DATAMINED_DATA then DATAMINED_DATA = {} end
    if not DATAMINED_DATA.quests then DATAMINED_DATA.quests = {} end
    
    --local en, de, fr = {}, {}, {}
    --
    --local processedQuests = {}
    --
    --for _, map in pairs(DATAMINED_DATA.quests2) do
    --    d("Checking")
    --    for questId, data in pairs(map) do
    --        if not processedQuests[questId] then
    --            processedQuests[questId] = true
    --            en[questId] = data.n.en
    --            de[questId] = data.n.de
    --            fr[questId] = data.n.fr
    --        end
    --    end
    --end
    --DATAMINED_DATA.quests3 = {en=en, de=de, fr=fr}
	--local lang = GetCVar("Language.2")
    local gameQuestData = LoreBooks_GetGameWholeQuestsData(lang)
    local questId = GetNextCompletedQuestId()
    while questId ~= nil do
        if not gameQuestData[questId] then
            --if not DATAMINED_DATA.quests[questId] then
            --    DATAMINED_DATA.quests[questId] = {k=questId, n={}}
            --end
            --local questData = DATAMINED_DATA.quests[questId]
            local questName, questType = GetCompletedQuestInfo(questId)
			DATAMINED_DATA.quests[questId] = questName
            --if not questData.n[lang] then
            --    questData.n[lang] = questName
            --end
            
            
            --df("%d (%d) - %s", questId, questType, questName)
        end
    
        questId = GetNextCompletedQuestId(questId)
    end
end

local function InitLibrary()

	if not DATAMINED_DATA.bookDB then DATAMINED_DATA.bookDB = {} end
	local db = DATAMINED_DATA.bookDB
	
	for categoryIndex = 1, GetNumLoreCategories() do
		
		local categoryName, numCollections = GetLoreCategoryInfo(categoryIndex)
		if not db[categoryIndex] then db[categoryIndex] = {} end
		
		for collectionIndex = 1, numCollections do
			local collectionName, collectionDescription, _, totalBooks, hidden, gamepadIcon, collectionId = GetLoreCollectionInfo(categoryIndex, collectionIndex)

			if not db[categoryIndex][collectionIndex] then db[categoryIndex][collectionIndex] = {} end
			db[categoryIndex][collectionIndex].t = totalBooks
			db[categoryIndex][collectionIndex].g = gamepadIcon
			db[categoryIndex][collectionIndex].h = hidden
			db[categoryIndex][collectionIndex].k = collectionId
			
			if not db[categoryIndex][collectionIndex].d then db[categoryIndex][collectionIndex].d = {} end
			db[categoryIndex][collectionIndex].d[lang] = collectionDescription

			if not db[categoryIndex][collectionIndex].n then db[categoryIndex][collectionIndex].n = {} end
			db[categoryIndex][collectionIndex].n[lang] = collectionName
			
		end
	end

end

local function CollectLoreLibrary()

	local totalEidetic = 0
	DATAMINED_DATA.libraryData = DATAMINED_DATA.libraryData or {}
	local libraryData = DATAMINED_DATA.libraryData
    for categoryIndex = 1, GetNumLoreCategories() do
        local categoryName, numCollections = GetLoreCategoryInfo(categoryIndex)
        for collectionIndex = 1, numCollections do
			local collectionName, description, numKnownBooks, totalBooks, hidden, gamepadIcon, collectionId  = GetLoreCollectionInfo(categoryIndex, collectionIndex)
			if not libraryData[categoryIndex] then
				libraryData[categoryIndex] = {}
			end
			if not libraryData[categoryIndex][collectionIndex] then
				libraryData[categoryIndex][collectionIndex] = 
				{
					t = totalBooks,
					h = hidden,
					g = gamepadIcon,
					n = {},
					d = {},
					k = collectionId,
				}
			end
			libraryData[categoryIndex][collectionIndex].n[lang] = collectionName
			libraryData[categoryIndex][collectionIndex].d[lang] = description
			if categoryIndex == 3 then
				totalEidetic = totalEidetic + totalBooks
			end
		end
	end
	df("Collected Library with %d books", totalEidetic)
end

local function PrintBook(bookId)
    df("%s |H1:book:%s|h|h", bookId, bookId)
end

--[[
function LB_CleanEideticData()
	
	local keysToNil = { "xLoc", "yLoc", "i", "b", "c", "q", "qm" }
	
	local eideticData = {}
	for bookId, bookData in pairs(LoreBooks_GetBookData()) do
		bookData = ZO_DeepTableCopy(bookData)
		if bookData.e then
			for _, entry in ipairs(bookData.e) do
				for _, key in ipairs(keysToNil) do
					if entry[key] ~= nil then
						entry[key] = nil
					end
				end
			end
		end
		
		if type(bookData.q) == "table" then
			bookData.q = GetQuestsDataByName(bookData.q.en)
		end
		eideticData[bookId] = bookData
	end
	DATAMINED_DATA.eideticData = eideticData
end

function LB_MergeEideticData()
	
	local function AddEntryIfNew(existingData, entry)
		local insert = true
		if existingData.e then
			for _, e in ipairs(existingData.e) do
				if e.z == entry.z and e.m == entry.m and CoordsNearby(e.x, e.y, entry.x, entry.y) then
					insert = false
				end
			end
		end

		if insert then
			existingData.e = existingData.e or {}
			table.insert(existingData.e, entry)
		end
	end
	
	local eideticData = LoreBooks_GetBookData()
	for bookId, buildData in pairs(DATAMINED_DATA.build) do
		local bookData = LoreBooks_GetNewEideticDataFromBookId(bookId)
		for _, entry in ipairs(buildData.e or {}) do
			AddEntryIfNew(bookData, entry)
		end
		
		if buildData.r then
			bookData.r = buildData.r
		end
		if buildData.q then
			bookData.q = buildData.q
		end
		if buildData.qm then
			bookData.qm = buildData.qm
		end
		bookData.c = true
	end
	
	LB_CleanEideticData()
end
--]]

function LoreBooks_InitializeCollab()

	if MASTER_MINER == GetDisplayName() then
	
		if not COLLAB then COLLAB = {} end
		if not DATAMINED_DATA then DATAMINED_DATA = {} end

        SLASH_COMMANDS["/lbq"] = CompletedQuests
		SLASH_COMMANDS["/lbe"] = ExtractData
		SLASH_COMMANDS["/lbb"] = BuildBooks
		SLASH_COMMANDS["/lbc"] = PrecalculateCoords

		SLASH_COMMANDS["/lbd"] = DecodeCollab
		SLASH_COMMANDS["/lbs"] = SeeData
		SLASH_COMMANDS["/lbp"] = PushData
		SLASH_COMMANDS["/lbi"] = InitLibrary
		SLASH_COMMANDS["/lbcollab"] = CleanCollab
		SLASH_COMMANDS["/lblibrary"] = CollectLoreLibrary
		SLASH_COMMANDS["/lbsort"] = SortLibrary
		SLASH_COMMANDS["/lbtest"] = Test
		
		EVENT_MANAGER:RegisterForEvent("PostmailDeamon", EVENT_MAIL_READABLE, OnMailReadable)

        SLASH_COMMANDS["/book"] = PrintBook
	end

end

function LoreBooks_IsMinerEnabled()
	ESOVersion = GetESOVersionString():gsub("eso%.%a+%.(%d)%.(%d)%.(%d+)%.%d+", "%1%2%3")
	if GetAPIVersion() == 100028 and (lang == "fr" or lang == "en" or lang == "de") then
		if (GetDate() - DEADLINE) < 1 then
			return true, BuildDataToShare
		end
	end
	if GetDisplayName("player") == MASTER_MINER then
		return true, BuildDataToShare
	end
	return false
end