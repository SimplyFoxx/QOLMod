-- =============================================================================
-- QOLMod: Ultra-Stable Bag Management for WoW 3.3.5a
-- =============================================================================
-- This version uses a Two-Step Swap process to prevent "Gray Item" locks.
-- Logic: [Normal/Gear] -> [Reagents] -> [Consumables] -> [Empty] -> [Whitelist]
-- =============================================================================

DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00QOLMod Script Loading...|r")

local QOLMod = CreateFrame("Frame", "QOLModCore", UIParent)
local q = {}
local timer = 0
local startTime = 0

-- WHITELIST CONFIGURATION
local whitelist = { 
    6948,   -- Hearthstone
    9017,   -- Book of Maf
    601109, -- Wondrous Quest Helper
}

-- GROUPING WEIGHTS
local typeWeights = { ["Armor"] = 1, ["Weapon"] = 2 }
local armorWeights = { ["Plate"] = 1, ["Mail"] = 2, ["Leather"] = 3, ["Cloth"] = 4 }

-- HELPER FUNCTIONS
local function IsWhitelisted(id)
    if not id then return nil end
    for i, val in ipairs(whitelist) do 
        if val == id then return i end 
    end
    return nil
end

local function InitDB()
    if not QOLModDB then QOLModDB = {} end
    if QOLModDB.sellMaxQual == nil then QOLModDB.sellMaxQual = 0 end
    if QOLModDB.sortOrder == nil then QOLModDB.sortOrder = "Ascending" end
    if QOLModDB.destroyUnsellables == nil then QOLModDB.destroyUnsellables = false end
end

-- QUEUE SYSTEM
-- Processes actions one at a time. Two-Step swaps ensure stability.
QOLMod:SetScript("OnUpdate", function(self, elapsed)
    if #q == 0 then 
        if startTime > 0 then
            local dur = floor((GetTime() - startTime) * 10) / 10
            print("|cFF00FF00[QOLMod]|r Sorting finished in " .. dur .. "s.")
            startTime = 0
        end
        return 
    end
    
    timer = timer + elapsed
    if timer >= 0.1 then -- Mandatory 0.1s delay between every single click
        local action = table.remove(q, 1)
        if action then 
            action() 
        end
        timer = 0
    end
end)

local function AddTask(func) 
    table.insert(q, func) 
end

-- SELLING LOGIC
local function ProcessJunk()
    if not MerchantFrame:IsVisible() then return end
    CloseDropDownMenus()
    
    local count = 0
    for bag = 0, 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local _, _, qual, _, _, iType, iSub, _, _, _, price = GetItemInfo(link)
                local id = tonumber(link:match("item:(%d+)"))
                
                local isProtected = (iType == "Reagent" or iType == "Trade Goods" or iType == "Consumable" or iType == "Recipe")
                if iType == "Quest" and not QOLModDB.destroyUnsellables then
                    isProtected = true
                end
                
                if not IsWhitelisted(id) and not isProtected then
                    if qual <= QOLModDB.sellMaxQual then
                        if (price or 0) > 0 then
                            AddTask(function() UseContainerItem(bag, slot) end)
                            count = count + 1
                        elseif QOLModDB.destroyUnsellables then
                            AddTask(function() PickupContainerItem(bag, slot) DeleteCursorItem() end)
                            count = count + 1
                        end
                    end
                end
            end
        end
    end
end

-- TWO-STEP STABLE SORTING
local function SortBags()
    if #q > 0 then return end
    if CursorHasItem() then ClearCursor() end -- Ensure cursor is clean before starting
    
    print("|cFF00FF00[QOLMod]|r Mapping linear inventory...")
    startTime = GetTime()

    local allSlots = {}
    local linearInventory = {}

    -- 1. Scan everything
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local slotIdx = #allSlots + 1
            table.insert(allSlots, {b = bag, s = slot})
            
            local link = GetContainerItemLink(bag, slot)
            if link then
                local name, _, qual, _, _, iType, iSub = GetItemInfo(link)
                local id = tonumber(link:match("item:(%d+)"))
                table.insert(linearInventory, {
                    uid = slotIdx, id = id, n = name, q = qual, t = iType, st = iSub,
                    wIdx = IsWhitelisted(id)
                })
            else
                table.insert(linearInventory, "EMPTY")
            end
        end
    end

    -- 2. Categorize contents
    local normalPile = {}
    local reagentPile = {}
    local consumablePile = {}
    local priorityPile = {}

    for _, entry in ipairs(linearInventory) do
        if entry ~= "EMPTY" then
            if entry.wIdx then
                table.insert(priorityPile, entry)
            elseif entry.t == "Trade Goods" or entry.t == "Reagent" or entry.t == "Recipe" then
                table.insert(reagentPile, entry)
            elseif entry.t == "Consumable" then
                table.insert(consumablePile, entry)
            else
                table.insert(normalPile, entry)
            end
        end
    end

    -- 3. Sort logic
    table.sort(normalPile, function(a, b)
        if a.q ~= b.q then
            if QOLModDB.sortOrder == "Ascending" then return a.q < b.q else return a.q > b.q end
        end
        local aw, bw = typeWeights[a.t] or 99, typeWeights[b.t] or 99
        if aw ~= bw then return aw < bw end
        if a.t == "Armor" and b.t == "Armor" then
            local asw, bsw = armorWeights[a.st] or 99, armorWeights[b.st] or 99
            if asw ~= bsw then return asw < bsw end
        end
        return a.n < b.n
    end)
    
    local function AlphaSort(a, b) return a.n < b.n end
    table.sort(reagentPile, AlphaSort)
    table.sort(consumablePile, AlphaSort)
    table.sort(priorityPile, function(a, b) return a.wIdx > b.wIdx end)

    -- 4. Construct Final Map: Normals -> Reagents -> Consumables -> Empties -> Whitelist
    local targetMap = {}
    for _, v in ipairs(normalPile) do table.insert(targetMap, v) end
    for _, v in ipairs(reagentPile) do table.insert(targetMap, v) end
    for _, v in ipairs(consumablePile) do table.insert(targetMap, v) end
    
    local totalItems = #targetMap + #priorityPile
    for i = 1, (#allSlots - totalItems) do table.insert(targetMap, "EMPTY") end
    for _, v in ipairs(priorityPile) do table.insert(targetMap, v) end

    -- 5. Execution: TWO-STEP SWAP
    local currentMap = {}
    for i, entry in ipairs(linearInventory) do
        currentMap[i] = (entry == "EMPTY") and "EMPTY" or entry.uid
    end

    for i = 1, #allSlots do
        local goalEntry = targetMap[i]
        local goalUID = (goalEntry == "EMPTY") and "EMPTY" or goalEntry.uid
        
        if currentMap[i] ~= goalUID then
            for j = i + 1, #allSlots do
                if currentMap[j] == goalUID then
                    local s = allSlots[j]
                    local t = allSlots[i]
                    
                    -- STEP 1: Pickup Item from Source
                    AddTask(function() 
                        if not CursorHasItem() then PickupContainerItem(s.b, s.s) end 
                    end)
                    
                    -- STEP 2: Place Item in Target (This completes the swap)
                    AddTask(function() 
                        if CursorHasItem() then PickupContainerItem(t.b, t.s) end 
                    end)
                    
                    -- Sync memory
                    local temp = currentMap[i]
                    currentMap[i] = currentMap[j]
                    currentMap[j] = temp
                    break
                end
            end
        end
    end
end

-- UI
local function CreateUI()
    local f = CreateFrame("Frame", "QOLMenu", UIParent)
    f:SetSize(320, 260); f:SetPoint("CENTER")
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", 
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", 
        tile = true, tileSize = 32, edgeSize = 32, 
        insets = { left = 8, right = 8, top = 8, bottom = 8 }
    })
    f:EnableMouse(true); f:SetMovable(true); f:SetClampedToScreen(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", -5, -5)

    local function CreateDrop(label, y, var, options)
        local l = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        l:SetPoint("TOPLEFT", 25, y); l:SetText(label)
        local dd = CreateFrame("Frame", "QOLModDD" .. var, f, "UIDropDownMenuTemplate")
        dd:SetPoint("TOPLEFT", 10, y - 15); UIDropDownMenu_SetWidth(dd, 160)
        UIDropDownMenu_Initialize(dd, function()
            for _, o in ipairs(options) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = (type(o) == "table") and o.t or o; info.value = (type(o) == "table") and o.v or o
                info.func = function(self)
                    QOLModDB[var] = self.value
                    UIDropDownMenu_SetSelectedValue(dd, self.value)
                    UIDropDownMenu_SetText(dd, self:GetText())
                end
                UIDropDownMenu_AddButton(info)
            end
        end)
        UIDropDownMenu_SetSelectedValue(dd, QOLModDB[var])
        local initialText = QOLModDB[var]
        if var == "sellMaxQual" then 
            local names = {"Poor (Grey)", "Common (White)", "Uncommon (Green)", "Rare (Blue)", "Epic (Purple)"}
            initialText = names[QOLModDB[var] + 1]
        end
        UIDropDownMenu_SetText(dd, initialText)
    end

    CreateDrop("Sell Threshold (and under):", -50, "sellMaxQual", {{t="Poor (Grey)",v=0},{t="Common (White)",v=1},{t="Uncommon (Green)",v=2},{t="Rare (Blue)",v=3},{t="Epic (Purple)",v=4}})
    CreateDrop("Sort Direction:", -105, "sortOrder", {"Ascending", "Descending"})

    local cb = CreateFrame("CheckButton", "QOLDestroyCB", f, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", 20, -170); _G[cb:GetName() .. "Text"]:SetText("Destroy Quest/0-Value Items")
    cb:SetChecked(QOLModDB.destroyUnsellables)
    cb:SetScript("OnClick", function(self) QOLModDB.destroyUnsellables = self:GetChecked() end)
    f:Hide(); return f
end

QOLMod:RegisterEvent("ADDON_LOADED")
QOLMod:SetScript("OnEvent", function(self, event, addon)
    if addon == "QOLMod" then
        InitDB(); self.menu = CreateUI()
        local b = CreateFrame("Button", "QOLSellBtn", MerchantFrame, "UIPanelButtonTemplate")
        b:SetSize(85, 24); b:SetPoint("TOPRIGHT", -110, -35); b:SetText("Sell Junk")
        b:SetScript("OnClick", ProcessJunk)
        print("|cFF00FF00QOLMod Loaded.|r")
    end
end)

SLASH_QOL1 = "/qol"
SlashCmdList["QOL"] = function(msg)
    if msg == "sort" then SortBags() else if QOLMenu:IsShown() then QOLMenu:Hide() else QOLMenu:Show() end end
end