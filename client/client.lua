local currentBlip = nil
local markerActive = false
local markerPos = nil

local function clearBlip()
  if currentBlip then
    RemoveBlip(currentBlip)
    currentBlip = nil
  end
  markerActive = false
  markerPos = nil
end

local function createBlipAt(x, y, z, text)
  clearBlip()
  currentBlip = AddBlipForCoord(x + 0.0, y + 0.0, z + 0.0)
  SetBlipSprite(currentBlip, 161)        -- icône simple (tu peux changer)
  SetBlipScale(currentBlip, 1.0)
  SetBlipColour(currentBlip, 5)
  SetBlipAsShortRange(currentBlip, false)
  BeginTextCommandSetBlipName("STRING")
  AddTextComponentString(text or "Mission IA")
  EndTextCommandSetBlipName(currentBlip)
  SetNewWaypoint(x + 0.0, y + 0.0)
  markerPos = vector3(x + 0.0, y + 0.0, z + 0.0)
  markerActive = true
end

RegisterNetEvent("missionai:start", function(mission)
  -- mission = { title, difficulty, steps=[{desc}], reward, positions=[{x,y,z}, ...] }
  if not mission or not mission.positions or not mission.positions[1] then
    print("^1[missionai] Mission invalide côté client^0")
    return
  end
  local p = mission.positions[1]
  createBlipAt(p.x, p.y, p.z, mission.title or "Mission IA")
  print(("[missionai] Blip créé: %.1f %.1f %.1f"):format(p.x, p.y, p.z))
end)

-- petit marker visuel au sol
CreateThread(function()
  while true do
    Wait(0)
    if markerActive and markerPos then
      DrawMarker(1, markerPos.x, markerPos.y, markerPos.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                 1.0, 1.0, 1.0, 255, 255, 0, 120, false, true, 2, nil, nil, false)
      -- E pour “valider” la zone (exemple)
      local ped = PlayerPedId()
      local pos = GetEntityCoords(ped)
      if #(pos - markerPos) < 2.0 then
        SetTextComponentFormat('STRING')
        AddTextComponentString("~INPUT_CONTEXT~ Valider l'objectif")
        DisplayHelpTextFromStringLabel(0, 0, 1, -1)
        if IsControlJustReleased(0, 38) then -- E
          print("[missionai] Objectif validé")
          -- ici tu peux déclencher la suite de l'étape
          clearBlip()
        end
      end
    end
  end
end)
