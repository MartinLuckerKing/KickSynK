-- ============================================================
-- KickSync (KS)
-- - File d'interrupts (un seul contrôleur déterministe)
-- - Panneau "KS Peers" : ✔️/❌ (gauche, état kick) + icône de raid (droite)
--   * icône de raid réelle si posée, sinon fallback par rôle (Heal=rond, Tank=carré, DPS=triangle)
-- - Diffusion réseau : FOCUS / UNFOCUS / KUSED / READY -> UI de tout le monde à jour
-- ============================================================

local PREFIX  = "KSQueue"
local VERSION = "1.5.3"

C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)

-- Forward declarations
local AssignRoleIcons
local KS_UI_Update
local IconForPlayer
-- ==============================
--   Paramètres
-- ==============================
local PRIORITIZE_FOCUSER     = true   -- en 5-man, favorise le focuser si son kick est prêt
local MARK_RETRIES = 20
local SHOW_UI_PANEL_DEFAULT  = true
local UI_MAX_ROWS            = 10
local UI_ROW_HEIGHT          = 18
local UI_WIDTH               = 200
local UI_SCALE               = 1.0

-- ==============================
--   Helpers
-- ==============================
local function NameNoRealm(name)
  if not name then return nil end
  local i = string.find(name, "-")
  if i then return string.sub(name, 1, i-1) end
  return name
end

local function AddonChannel()
  if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
  if IsInRaid() then return "RAID" end
  if IsInGroup() then return "PARTY" end
  return nil
end

local function Send(msg)
  local ch = AddonChannel()
  if ch then C_ChatInfo.SendAddonMessage(PREFIX, msg, ch) end
end

local function CanMark()
  if not IsInRaid() then return true end
  return UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
end


local function IsHeroicPlusDungeon()
  local inInstance, instanceType = IsInInstance()
  if not inInstance or instanceType ~= "party" then return false end
  local _, _, difficultyID = GetInstanceInfo()
  -- 2 = 5H, 23 = 5M, 8 = Mythic Keystone
  return difficultyID == 2 or difficultyID == 23 or difficultyID == 8
end
-- ==============================
--   États / Icônes
-- ==============================
local ICON_TANK, ICON_HEAL = 1, 2
local DPS_ICONS = {4,5,7}                -- triangle, lune, croix
local ICON_FOR_TANK_ON_TARGET = 1        -- étoile quand le tank est actif
local function FocusIconForPlayerIcon(icon)
  return (icon==ICON_TANK) and ICON_FOR_TANK_ON_TARGET or icon
end

local playerIcons     = {}  -- [name] -> raid icon index by role
local playerFocus     = {}  -- [name] -> mobGUID
local playerKickReady = {}  -- [name] -> bool (nil = considéré prêt)
local mobQueues       = {}  -- [guid] -> {names}
local mobActive       = {}  -- [guid] -> name
local addonPeers      = {}  -- [name] -> true (installs connus)
local controllerName  = nil -- nom du contrôleur
local helloTimer
local uiTicker
local activeTickers = {}    -- watchers de CD par spellID

-- ==============================
--   Spells / CD
-- ==============================
local KICK_SPELLS = {
  [1766]=true,   -- Kick (Rogue)
  [6552]=true,   -- Pummel (Warrior)
  [2139]=true,   -- Counterspell (Mage)
  [19647]=true,  -- Spell Lock (Warlock pet)
  [47528]=true,  -- Mind Freeze (DK)
  [96231]=true,  -- Rebuke (Paladin)
  [57994]=true,  -- Wind Shear (Shaman)
  [116705]=true, -- Spear Hand Strike (Monk)
  [183752]=true, -- Disrupt (DH)
  [351338]=true, -- Quell (Evoker)
  [93985]=true,  -- Skull Bash (Feral old id, garde par sécurité)
}

local function GetCooldownInfo(spellID)
  if C_Spell and C_Spell.GetSpellCooldown then
    local info = C_Spell.GetSpellCooldown(spellID)
    if info then return info.startTime or 0, info.duration or 0, info.isEnabled and 1 or 0 end
  elseif _G.GetSpellCooldown then
    local s,d,e = _G.GetSpellCooldown(spellID)
    return s or 0, d or 0, e or 0
  end
  return 0,0,0
end

local function PlayerHasSpell(spellID)
  if IsPlayerSpell then return IsPlayerSpell(spellID) end
  return GetSpellInfo(spellID) ~= nil
end

local function IsLocalKickReady()
  for id in pairs(KICK_SPELLS) do
    if PlayerHasSpell(id) then
      local _, d, en = GetCooldownInfo(id)
      if en ~= 0 then return d == 0 end
    end
  end
  return true
end

local function RefreshLocalKickState()
  local me = NameNoRealm(UnitName("player"))
  if me then playerKickReady[me] = IsLocalKickReady() end
end

-- Moi ou mon pet (Warlock Spell Lock, etc.)
local function IsSelfOrPet(sourceGUID)
  if not sourceGUID then return false end
  if sourceGUID == UnitGUID("player") then return true end
  local petGUID = UnitGUID("pet")
  if petGUID and sourceGUID == petGUID then return true end
  return false
end

-- ==============================
--   Unités / GUID
-- ==============================
local function IterateGroupUnits()
  local list={"player"}
  if IsInRaid() then for i=1,GetNumGroupMembers() do list[#list+1]="raid"..i end
  else for i=1,GetNumSubgroupMembers() do list[#list+1]="party"..i end end
  return list
end

local function IterateUnitTokens()
  local t={"target","focus","mouseover","targettarget","focustarget"}
  if IsInRaid() then
    for i=1,40 do t[#t+1]="raid"..i; t[#t+1]="raid"..i.."target" end
  else
    t[#t+1]="player"; for i=1,4 do t[#t+1]="party"..i; t[#t+1]="party"..i.."target" end
  end
  for i=1,5 do t[#t+1]="boss"..i; t[#t+1]="boss"..i.."target"; t[#t+1]="arena"..i; t[#t+1]="arena"..i.."target" end
  for i=1,40 do t[#t+1]="nameplate"..i end
  return t
end

local function FindUnitByGUID(guid)
  for _,u in ipairs(IterateUnitTokens()) do
    if UnitExists(u) and UnitGUID(u) == guid then return u end
  end
  return nil
end

local function UnitTokenForName(targetName)
  if not targetName then return nil end
  targetName = targetName:lower()
  local n = UnitName("player")
  if n and NameNoRealm(n):lower() == targetName then return "player" end
  if IsInRaid() then
    for i=1,GetNumGroupMembers() do
      local u="raid"..i
      if UnitExists(u) then local nu=UnitName(u); if nu and NameNoRealm(nu):lower()==targetName then return u end end
    end
  else
    for i=1,GetNumSubgroupMembers() do
      local u="party"..i
      if UnitExists(u) then local nu=UnitName(u); if nu and NameNoRealm(nu):lower()==targetName then return u end end
    end
  end
  return nil
end

-- ==============================
--   Contrôleur (un seul !)
-- ==============================
local function RecomputeController()
  local candidates={}
  for _,u in ipairs(IterateGroupUnits()) do
    if UnitExists(u) then
      local n=NameNoRealm(UnitName(u))
      if n and addonPeers[n] then candidates[#candidates+1]=n end
    end
  end
  if #candidates==0 then
    for _,u in ipairs(IterateGroupUnits()) do
      if UnitExists(u) then local n=NameNoRealm(UnitName(u)); if n then candidates[#candidates+1]=n end end
    end
  end
  table.sort(candidates)
  controllerName = candidates[1]
end

local function IsController()
  if not IsInGroup() then return true end
  if not controllerName then RecomputeController() end
  return NameNoRealm(UnitName("player")) == controllerName
end

-- ==============================
--   Marquage MOB (GUID) — robuste
-- ==============================
local markJobs = {}  -- [guid] = { icon=idx, tries=0, ticker=<Ticker> }

local function CancelMarkJob(guid)
  local job = markJobs[guid]
  if job and job.ticker then job.ticker:Cancel() end
  markJobs[guid] = nil
end

-- Pose l'icône et réessaie tant que l'actif subsiste
local function SetIconOnGUID(guid, icon, _attempt_ignored)
  if not guid or not icon or not CanMark() then return false end
  if not mobActive[guid] then return false end

  CancelMarkJob(guid)
  local tries = 0
  markJobs[guid] = { icon = icon }
  markJobs[guid].ticker = C_Timer.NewTicker(0.20, function()
    tries = tries + 1
    if not mobActive[guid] then
      CancelMarkJob(guid)
      return
    end
    local u = FindUnitByGUID(guid)
    if u then
      SetRaidTarget(u, icon)
      if GetRaidTargetIndex(u) == icon then
        CancelMarkJob(guid) -- succès confirmé
        return
      end
    end
    if tries >= MARK_RETRIES then
      CancelMarkJob(guid) -- abandon propre
    end
  end)
  return true
end

-- Clear l'icône seulement s'il n'y a plus d'actif
local function ClearIconOnGUIDIf(guid, expectedIcon, _attempt_ignored)
  if not guid or not CanMark() then return end
  if mobActive[guid] then return end

  CancelMarkJob(guid)
  local u = FindUnitByGUID(guid)
  if u then
    if not expectedIcon or GetRaidTargetIndex(u) == expectedIcon then
      SetRaidTarget(u, 0)
    end
  end
end
-- ==============================
--   Icônes de rôle
-- ==============================
AssignRoleIcons = function()
  wipe(playerIcons)
  local dpsIdx=1
  for _,unit in ipairs(IterateGroupUnits()) do
    if UnitExists(unit) then
      local name = NameNoRealm(UnitName(unit))
      if name then
        local role = UnitGroupRolesAssigned(unit)
        local icon
        if role=="TANK" then icon=ICON_TANK
        elseif role=="HEALER" then icon=ICON_HEAL
        else icon=DPS_ICONS[dpsIdx] or DPS_ICONS[#DPS_ICONS]; dpsIdx=math.min(dpsIdx+1,#DPS_ICONS) end
        playerIcons[name]=icon
        if playerKickReady[name]==nil then playerKickReady[name]=true end -- nil = prêt
      end
    end
  end
  if KS_UI_Update then KS_UI_Update() end
end

-- ==============================
--   File d'interrupts
-- ==============================
local function EnsureQueue(guid) if not mobQueues[guid] then mobQueues[guid]={} end; return mobQueues[guid] end
local function RemoveFromQueue(q, player) for i,p in ipairs(q) do if p==player then table.remove(q,i); return true end end end

local function FirstReadyInQueue(q)
  for _,p in ipairs(q) do
    -- nil => prêt par défaut ; seul false bloque
    if playerKickReady[p] ~= false then return p end
  end
  return nil
end

local function ApplyActiveForGUID(guid, player)
  if not playerKickReady[player] then
    local q = EnsureQueue(guid)
    local nxt = FirstReadyInQueue(q)
    if nxt then
      mobActive[guid] = nxt
      SetIconOnGUID(guid, FocusIconForPlayerIcon(IconForPlayer(nxt)))
    else
      mobActive[guid] = nil
      ClearIconOnGUIDIf(guid, nil)
    end
    if KS_UI_Update then KS_UI_Update() end
    return
  end

  -- >>> cette partie manquait chez toi <<<
  mobActive[guid] = player
  SetIconOnGUID(guid, FocusIconForPlayerIcon(IconForPlayer(player)))
  if KS_UI_Update then KS_UI_Update() end
end

local function AdvanceQueue(guid)
  local nxt = FirstReadyInQueue(EnsureQueue(guid))
  if nxt then ApplyActiveForGUID(guid, nxt) else ClearIconOnGUIDIf(guid,nil); mobActive[guid]=nil; if KS_UI_Update then KS_UI_Update() end end
end

local function Controller_OnFocus(player, guid)
  local prev = playerFocus[player]
  if prev and prev ~= guid and mobQueues[prev] then
    RemoveFromQueue(mobQueues[prev], player)
    if mobActive[prev] == player then mobActive[prev]=nil; AdvanceQueue(prev) end
  end
  playerFocus[player]=guid
  local q=EnsureQueue(guid); RemoveFromQueue(q,player); table.insert(q,player)
  if playerKickReady[player]==nil then playerKickReady[player]=true end

  if PRIORITIZE_FOCUSER and not IsInRaid() then
    if playerKickReady[player] then ApplyActiveForGUID(guid, player)
    elseif not mobActive[guid] then AdvanceQueue(guid) end
    return
  end
  if not mobActive[guid] then AdvanceQueue(guid) end
end

local function Controller_OnUnfocus(player)
  local guid=playerFocus[player]; if not guid then return end
  playerFocus[player]=nil; local q=EnsureQueue(guid); local was=(mobActive[guid]==player)
  RemoveFromQueue(q,player); if was then mobActive[guid]=nil; AdvanceQueue(guid) end
end

local function Controller_OnKickUsed(player)
  playerKickReady[player]=false
  local guid=playerFocus[player]
  -- remet le joueur au bout de la file de CE guid (rotation "juste")
  if guid and mobQueues[guid] then
    local q=mobQueues[guid]; RemoveFromQueue(q,player); table.insert(q,player)
  end
  if not guid then if KS_UI_Update then KS_UI_Update() end; return end
  if mobActive[guid]==player then mobActive[guid]=nil; AdvanceQueue(guid) else if KS_UI_Update then KS_UI_Update() end end
end

local function Controller_OnKickReady(player)
  playerKickReady[player] = true
  local guid = playerFocus[player]
  if not guid then
    if KS_UI_Update then KS_UI_Update() end
    return
  end

  -- En 5-man avec prio focuser : le joueur reprend la main dès que son kick revient.
  if PRIORITIZE_FOCUSER and not IsInRaid() then
    local q = EnsureQueue(guid)
    RemoveFromQueue(q, player)
    table.insert(q, 1, player)
    ApplyActiveForGUID(guid, player)   -- pose (ou re-pose) l’icône via l’enforcer
    return
  end

  -- Si c'est déjà l'actif, on re-assert l'icône (au cas où un clear tardif est passé).
  if mobActive[guid] == player then
    SetIconOnGUID(guid, FocusIconForPlayerIcon(IconForPlayer(player)))
    if KS_UI_Update then KS_UI_Update() end
    return
  end

  if not mobActive[guid] then
    AdvanceQueue(guid)
  else
    if KS_UI_Update then KS_UI_Update() end
  end
end
-- ==============================
--   UI utils & panneau
-- ==============================
local function SetRaidIconTexture(tex, index)
  if not index or index < 1 or index > 8 then tex:Hide(); return end
  tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
  SetRaidTargetIconTexture(tex, index) -- atlas 4x2 natif
  tex:Show()
end

local function KS_EffectiveRole(unit)
  local role=UnitGroupRolesAssigned(unit)
  if role and role~="NONE" then return role end
  if UnitIsUnit(unit,"player") and GetSpecialization then
    local spec=GetSpecialization(); local r=spec and GetSpecializationRole(spec)
    if r=="HEALER" then return "HEALER" elseif r=="TANK" then return "TANK" else return "DAMAGER" end
  end
  return "DAMAGER"
end

local function KS_RaidIndexForRole(role)
  if role=="TANK" then return 6 elseif role=="HEALER" then return 2 else return 4 end
end
IconForPlayer = function(name)
  local icon = playerIcons[name]
  if icon then return icon end
  local unit = UnitTokenForName(name) or "player"
  local role = KS_EffectiveRole(unit)
  return KS_RaidIndexForRole(role)
end
local function KS_RaidIconIndexForName(name)
  local u=UnitTokenForName(name)
  if u then
    local mark=GetRaidTargetIndex(u); if mark and mark>=1 and mark<=8 then return mark end
    return KS_RaidIndexForRole(KS_EffectiveRole(u))
  end
  return IconForPlayer(name)
end
-- Panneau
local KS_UI = CreateFrame("Frame", "KSPanel", UIParent, "BackdropTemplate")
KS_UI:SetSize(UI_WIDTH, UI_ROW_HEIGHT*(UI_MAX_ROWS+2)); KS_UI:SetScale(UI_SCALE)
KS_UI:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
KS_UI:SetMovable(true); KS_UI:EnableMouse(true)
KS_UI:RegisterForDrag("LeftButton")
KS_UI:SetScript("OnDragStart", KS_UI.StartMoving)
KS_UI:SetScript("OnDragStop", KS_UI.StopMovingOrSizing)
KS_UI:SetBackdrop({
  bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
  edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
  tile=true, tileSize=16, edgeSize=16, insets={left=4,right=4,top=4,bottom=4}
})
KS_UI:Hide()

KS_UI.title = KS_UI:CreateFontString(nil,"OVERLAY","GameFontNormal")
KS_UI.title:SetPoint("TOPLEFT",10,-8); KS_UI.title:SetText("KS Peers")

KS_UI.close = CreateFrame("Button", nil, KS_UI, "UIPanelCloseButton")
KS_UI.close:SetPoint("TOPRIGHT",0,0)

local scrollFrame = CreateFrame("ScrollFrame","KS_FauxScroll",KS_UI,"FauxScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT",8,-26); scrollFrame:SetPoint("BOTTOMRIGHT",-28,8)

local content = CreateFrame("Frame", nil, KS_UI)
content:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 0, 0)
content:SetSize(UI_WIDTH-36, UI_ROW_HEIGHT*UI_MAX_ROWS)

local rows={}
for i=1,UI_MAX_ROWS do
  local r=CreateFrame("Frame", nil, content)
  r:SetSize(UI_WIDTH-36, UI_ROW_HEIGHT)
  if i==1 then r:SetPoint("TOPLEFT",0,0) else r:SetPoint("TOPLEFT",rows[i-1],"BOTTOMLEFT",0,-2) end

  r.icon = r:CreateTexture(nil,"ARTWORK"); r.icon:SetSize(14,14); r.icon:SetPoint("LEFT",2,0)

  r.name = r:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
  r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
  r.name:SetPoint("RIGHT", -22, 0) -- réserve la place pour l'icône droite
  r.name:SetJustifyH("LEFT"); r.name:SetText("")

  r.mark = r:CreateTexture(nil,"ARTWORK"); r.mark:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
  r.mark:SetSize(12,12); r.mark:SetPoint("RIGHT",-6,0); r.mark:Hide()

  rows[i]=r
end

local function CollectUIPeers()
  local me=NameNoRealm(UnitName("player")); if me then addonPeers[me]=true end
  local t={}; for n,_ in pairs(addonPeers) do if type(n)=="string" and n~="" then t[#t+1]=n end end
  table.sort(t, function(a,b)
    local ia,ib=(playerIcons[a] or 9),(playerIcons[b] or 9)
    if ia~=ib then return ia<ib end
    if me and a==me then return true end
    if me and b==me then return false end
    return a<b
  end)
  return t
end

function KS_UI_Update()
  if not KS_UI:IsShown() then return end
  local list=CollectUIPeers(); local total=#list
  FauxScrollFrame_Update(scrollFrame, total, UI_MAX_ROWS, UI_ROW_HEIGHT)
  local offset=FauxScrollFrame_GetOffset(scrollFrame) or 0
  for i=1,UI_MAX_ROWS do
    local idx=i+offset; local row=rows[i]; local name=list[idx]
    if name then
      row:Show(); row.name:SetText(name)
      if playerKickReady[name] ~= false then
        row.icon:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
      else
        row.icon:SetTexture("Interface\\RaidFrame\\ReadyCheck-NotReady")
      end
      row.icon:SetDesaturated(false); row.icon:Show()
      SetRaidIconTexture(row.mark, KS_RaidIconIndexForName(name))
    else
      row:Hide(); row.name:SetText(""); row.icon:Hide(); row.mark:Hide()
    end
  end
end

scrollFrame:SetScript("OnVerticalScroll", function(self, off) FauxScrollFrame_OnVerticalScroll(self, off, UI_ROW_HEIGHT, KS_UI_Update) end)

KS_UI:HookScript("OnShow", function()
  if uiTicker then uiTicker:Cancel() end
  uiTicker=C_Timer.NewTicker(0.5,function() if KS_UI:IsShown() then KS_UI_Update() end end)
end)
KS_UI:HookScript("OnHide", function() if uiTicker then uiTicker:Cancel(); uiTicker=nil end end)

-- ==============================
--   Réseau / Handshake
-- ==============================
local function AddSelfAsPeer() local me=NameNoRealm(UnitName("player")); if me then addonPeers[me]=true end end
local function BroadcastHELLO() local me=NameNoRealm(UnitName("player")) or "?"; Send(("HELLO|%s|%s"):format(me,VERSION)) end
local function SendIAM() local me=NameNoRealm(UnitName("player")) or "?"; Send(("IAM|%s|%s"):format(me,VERSION)) end

local function ScheduleRosterSync()
  if helloTimer then helloTimer:Cancel() end
  helloTimer=C_Timer.NewTimer(0.5,function()
    if InCombatLockdown() then C_Timer.After(1.0, ScheduleRosterSync)
    else AssignRoleIcons(); RecomputeController(); if KS_UI_Update then KS_UI_Update() end end
  end)
end

-- ==============================
--   Events
-- ==============================
local f=CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("GROUP_ROSTER_UPDATE")
f:RegisterEvent("PLAYER_FOCUS_CHANGED")
f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("RAID_TARGET_UPDATE")
f:RegisterEvent("PLAYER_ROLES_ASSIGNED")
f:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("PLAYER_DIFFICULTY_CHANGED")

f:SetScript("OnEvent", function(_, event, ...)
  if event=="PLAYER_ENTERING_WORLD" then
    -- [MODIFIÉ] n’auto-ouvre que si 5H+ ; sinon laisse fermé
    if IsHeroicPlusDungeon() then KS_UI:Show() else KS_UI:Hide() end

    AddSelfAsPeer(); BroadcastHELLO(); ScheduleRosterSync()
    RefreshLocalKickState(); RecomputeController(); if KS_UI_Update then KS_UI_Update() end

  elseif event=="ZONE_CHANGED_NEW_AREA" or event=="PLAYER_DIFFICULTY_CHANGED" then
    -- [NOUVEAU] ajuste l’ouverture/fermeture quand tu entres/sors/changes diff
    if IsHeroicPlusDungeon() then KS_UI:Show() else KS_UI:Hide() end

  elseif event=="GROUP_ROSTER_UPDATE" then
    wipe(addonPeers); AddSelfAsPeer(); BroadcastHELLO(); ScheduleRosterSync(); RecomputeController(); if KS_UI_Update then KS_UI_Update() end

  elseif event=="PLAYER_FOCUS_CHANGED" then
    local me=NameNoRealm(UnitName("player"))
    if UnitExists("focus") then
      local g=UnitGUID("focus"); playerFocus[me]=g
      if IsController() then Controller_OnFocus(me,g) end
      Send(("FOCUS|%s|%s"):format(me,g))   -- broadcast pour UI partout
    else
      if IsController() then Controller_OnUnfocus(me) end
      Send(("UNFOCUS|%s"):format(me))
    end
    if KS_UI_Update then KS_UI_Update() end

  elseif event=="COMBAT_LOG_EVENT_UNFILTERED" then
    local _, sub, _, sourceGUID, sourceName, _, _, _, _, _, _, spellID = CombatLogGetCurrentEventInfo()
    if sub=="SPELL_CAST_SUCCESS" and KICK_SPELLS[spellID] then
      if IsSelfOrPet(sourceGUID) then
        local me=NameNoRealm(UnitName("player"))
        playerKickReady[me]=false; if KS_UI_Update then KS_UI_Update() end
        if IsController() then Controller_OnKickUsed(me) end
        Send(("KUSED|%s"):format(me))
        if not activeTickers[spellID] then
          activeTickers[spellID]=C_Timer.NewTicker(0.5,function()
            local _, dur, en = GetCooldownInfo(spellID)
            if en~=0 and dur==0 then
              playerKickReady[me]=true; if KS_UI_Update then KS_UI_Update() end
              if IsController() then Controller_OnKickReady(me) end
              Send(("READY|%s"):format(me))
              if activeTickers[spellID] then activeTickers[spellID]:Cancel(); activeTickers[spellID]=nil end
            end
          end)
        end
      end
    end

  elseif event=="CHAT_MSG_ADDON" then
    local prefix, msg, _, sender = ...
    if prefix~=PREFIX then return end
    sender=NameNoRealm(sender)
    local a,b,c = strsplit("|", msg)

    if a=="HELLO" then
      if sender then addonPeers[sender]=true; if playerKickReady[sender]==nil then playerKickReady[sender]=true end end
      SendIAM(); RecomputeController(); if KS_UI_Update then KS_UI_Update() end

    elseif a=="IAM" then
      if sender then addonPeers[sender]=true; if playerKickReady[sender]==nil then playerKickReady[sender]=true end end
      RecomputeController(); if KS_UI_Update then KS_UI_Update() end

    elseif a=="KUSED" then
      playerKickReady[b]=false; if KS_UI_Update then KS_UI_Update() end
      if IsController() then Controller_OnKickUsed(b) end

    elseif a=="READY" then
      playerKickReady[b]=true; if KS_UI_Update then KS_UI_Update() end
      if IsController() then Controller_OnKickReady(b) end

    elseif a=="FOCUS" then
      if IsController() then Controller_OnFocus(b, c) end
      if KS_UI_Update then KS_UI_Update() end

    elseif a=="UNFOCUS" then
      if IsController() then Controller_OnUnfocus(b) end
      if KS_UI_Update then KS_UI_Update() end
    end

  elseif event=="RAID_TARGET_UPDATE" or event=="PLAYER_ROLES_ASSIGNED" or event=="PLAYER_SPECIALIZATION_CHANGED" then
    AssignRoleIcons(); if KS_UI_Update then KS_UI_Update() end
  end
end)

-- ==============================
--   Slash
-- ==============================
SLASH_KS1="/ks"
SlashCmdList.KS=function(msg)
  msg=(msg or ""):lower()
  if msg=="ui" then
    if KS_UI:IsShown() then KS_UI:Hide() else KS_UI:Show(); if KS_UI_Update then KS_UI_Update() end end
  elseif msg=="" or msg=="status" then
    print("|cFFFFA500KS|r v"..VERSION, "- Contrôleur:", controllerName or "?")
    local peers={}; for n,_ in pairs(addonPeers) do peers[#peers+1]=n end; table.sort(peers)
    print(" Peers KS:", #peers>0 and table.concat(peers,", ") or "(aucun)")
    for guid,active in pairs(mobActive) do
      local q = mobQueues[guid] or {}; local qs = table.concat(q, " -> ")
      print((" GUID %s : actif=%s | file=[%s]"):format(guid, active or "-", qs))
    end
    print(" Cmd: /ks ui | /ks status")
  else
    print("Usage: /ks [ui|status]")
  end
end
