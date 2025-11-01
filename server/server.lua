local function loadPrompt(relPath)
    local res = Config.ResourceName
    local txt = LoadResourceFile(res, relPath)
    if not txt then
        local abs = ("%s/%s"):format(GetResourcePath(res), relPath)
        print(("^1Erreur: prompt introuvable -> %s (abs: %s)^0"):format(relPath, abs))
    end
    return txt
end

local missionPrompt = loadPrompt('server/prompts/mission_prompt.txt') or [[
Tu es un générateur de missions FiveM. Réponds UNIQUEMENT en JSON valide, sans texte autour.
Schéma: {"title":"string","steps":[{"desc":"string"},{"desc":"string"},{"desc":"string"}],"reward":2500,"positions":[{"x":-75.1,"y":-821.2,"z":326.9}]}
Contrainte: max 3 étapes, valeurs réalistes pour GTA V.
]]

RegisterCommand('missionai', function(src)
    local body = json.encode({
        model = Config.Model,
        prompt = missionPrompt,
        stream = false
    })
    PerformHttpRequest(Config.OllamaURL .. '/api/generate', function(code, data)
        if code ~= 200 then print(('^1Ollama HTTP %s^0'):format(code)) return end
        local ok, parsed = pcall(json.decode, data); if not ok or not parsed or not parsed.response then
            print('^1Réponse Ollama invalide^0'); return
        end
        local ok2, mission = pcall(json.decode, parsed.response); if not ok2 or type(mission) ~= 'table' then
            print('^3Mission JSON invalide:^7 ' .. tostring(parsed.response)); return
        end
        print(('Mission: ^2%s^0  Reward: ^2$%s^0'):format(mission.title or 'N/A', mission.reward or 0))
        for i, s in ipairs(mission.steps or {}) do print(('  - [%d] %s'):format(i, s.desc or '?')) end
        -- TODO: TriggerClientEvent('missionai:start', src, mission)
    end, 'POST', body, {['Content-Type']='application/json'})
end)
