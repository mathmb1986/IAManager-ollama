-- ===== Event =====
AddEventHandler('onResourceStart', function(res)
  if res ~= GetCurrentResourceName() then return end
  TriggerClientEvent('chat:addSuggestion', -1, '/missionai', 'Générer une mission IA', {
    { name = 'difficulty', help = 'easy | medium | hard (défaut: medium)' }
  })
end)



-- ===== Utils Prompt =====
local function loadPrompt(relPath)
  local res = Config.ResourceName
  local txt = LoadResourceFile(res, relPath)
  if not txt then
    local abs = ("%s/%s"):format(GetResourcePath(res), relPath)
    print(("^1Erreur: prompt introuvable -> %s (abs: %s)^0"):format(relPath, abs))
  end
  return txt
end

local BasePrompt = loadPrompt('server/prompts/mission_prompt.txt') or [[
Tu es un générateur de missions FiveM. Réponds UNIQUEMENT en JSON valide sans texte autour.
{"title":"Mission","difficulty":"medium","steps":[{"desc":"A"},{"desc":"B"}],"reward":2500,"positions":[{"x":0,"y":0,"z":0}]}
]]

local function buildPrompt(difficulty)
  difficulty = (difficulty == "easy" or difficulty == "medium" or difficulty == "hard") and difficulty or "medium"
  return BasePrompt .. ("\nDifficulty demandée: \"%s\".\n"):format(difficulty)
end

-- ===== Validation JSON =====
local function isNumber(n) return type(n) == "number" end
local function isString(s) return type(s) == "string" and s ~= "" end
local function clamp(v, mn, mx) if v < mn then return mn elseif v > mx then return mx else return v end end

local function validateVec3(v)
  if type(v) ~= "table" then return false end
  return isNumber(v.x) and isNumber(v.y) and isNumber(v.z)
end

local function validateMission(m)
  if type(m) ~= "table" then return false, "root_not_table" end
  if not isString(m.title) then return false, "title" end
  if m.difficulty ~= "easy" and m.difficulty ~= "medium" and m.difficulty ~= "hard" then m.difficulty = "medium" end

  if type(m.steps) ~= "table" then return false, "steps_not_array" end
  local steps = {}
  for i=1, math.min(#m.steps, Config.MaxSteps) do
    local s = m.steps[i]
    if type(s) == "table" and isString(s.desc) then table.insert(steps, { desc = s.desc }) end
  end
  if #steps == 0 then return false, "no_valid_steps" end
  m.steps = steps

  if type(m.positions) ~= "table" or #m.positions == 0 then
    -- position par défaut (Maze Bank exterior par ex.)
    m.positions = { {x = -75.1, y = -821.2, z = 28.9} }
  else
    local pos = {}
    for i=1, math.min(#m.positions, 3) do
      if validateVec3(m.positions[i]) then table.insert(pos, m.positions[i]) end
    end
    if #pos == 0 then pos = { {x = -75.1, y = -821.2, z = 28.9} } end
    m.positions = pos
  end

  -- reward raisonnable selon difficulté
  local r = tonumber(m.reward or 0) or 0
  if m.difficulty == "easy" then r = r > 0 and r or 1000
  elseif m.difficulty == "hard" then r = r > 0 and r or 5000
  else r = r > 0 and r or 2500 end
  m.reward = clamp(math.floor(r), Config.MinReward, Config.MaxReward)

  return true, m
end

-- ===== Anti-spam simple =====
local lastUse = {}
local function canUse(src)
  local now = os.time()
  local t = lastUse[src] or 0
  if now - t < Config.RateLimitSec then return false, Config.RateLimitSec - (now - t) end
  lastUse[src] = now
  return true, 0
end

-- ===== Commande =====
RegisterCommand('missionai', function(src, args)
  local ok, wait = canUse(src)
  if not ok then
    if src ~= 0 then TriggerClientEvent('chat:addMessage', src, { args = {"IA", ("Patiente %ds avant de redemander."):format(wait)} }) end
    print(("^3RateLimit: %s reste %ds^0"):format(src, wait))
    return
  end

  local diff = (args[1] or "medium"):lower()
  local prompt = buildPrompt(diff)

  local body = json.encode({
    model = Config.Model,
    prompt = prompt,
    stream = false,
    format = "json",                -- ? Demande à Ollama de ne renvoyer que du JSON
    options = { temperature = 0.2 } -- ? Rend les réponses plus cohérentes
  })


  PerformHttpRequest(Config.OllamaURL .. '/api/generate', function(code, data)
    if code ~= 200 then
      print(("^1Ollama HTTP %s^0"):format(code))
      if src ~= 0 then TriggerClientEvent('chat:addMessage', src, { args = {"IA", "Erreur: génération indisponible."} }) end
      return
    end

    local ok1, parsed = pcall(json.decode, data)
    if not ok1 or not parsed or not parsed.response then
      print("^1Réponse Ollama invalide^0")
      return
    end

    local ok2, mission = pcall(json.decode, parsed.response)
    if not ok2 then
      print("^3Mission non JSON, tentative échouée:^7 " .. tostring(parsed.response))
      return
    end

    local valid, res = validateMission(mission)
    if not valid then
      print("^3Mission rejetée (validation: "..tostring(res)..")^0")
      return
    end
    -- ? >>>> C’EST ICI QUE TU PLACES TON CODE <<<< ?
    if src ~= 0 then
        TriggerClientEvent("missionai:start", src, res)  -- envoie la mission au joueur
        TriggerClientEvent('chat:addMessage', src, {
            args = {"IA", ("Mission: %s | diff=%s | $%d"):format(res.title, res.difficulty, res.reward)}
        })
    end

    print(("^2Mission: %s^0 | diff=%s | $%d"):format(res.title, res.difficulty, res.reward))
    for i,s in ipairs(res.steps) do print(("  - %d) %s"):format(i, s.desc)) end
    for i,p in ipairs(res.positions) do print(("  pos%d: (%.1f, %.1f, %.1f)"):format(i, p.x, p.y, p.z)) end

    -- TODO: ici, en fonction de ton framework:
    -- TriggerClientEvent("missionai:start", src, res)
    if src ~= 0 then
      TriggerClientEvent('chat:addMessage', src, {
        args = {"IA", ("Mission: %s | diff=%s | $%d"):format(res.title, res.difficulty, res.reward)}
      })
    end
  end, 'POST', body, { ['Content-Type'] = 'application/json' })
end)
