
-- ===== Suggestion chat au démarrage =====
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
  return BasePrompt .. ("\nIMPORTANT: Réponds uniquement en JSON strict (RFC 8259). Difficulty demandée: \"%s\".\n"):format(difficulty)
end

-- ===== Nettoyage JSON retourné par le LLM =====
local function stripCodeFences(s)
  if not s or s == "" then return s end
  s = s:gsub("```json", ""):gsub("```", "")
  return s
end

local function extractLargestJsonObject(s)
  if not s then return nil end
  local depth, start, bestS, bestE = 0, nil, nil, nil
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == '{' then
      if depth == 0 then start = i end
      depth = depth + 1
    elseif c == '}' and depth > 0 then
      depth = depth - 1
      if depth == 0 and start then
        bestS, bestE = start, i
      end
    end
  end
  if bestS then return s:sub(bestS, bestE) end
  return nil
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
    m.positions = { {x = -75.1, y = -821.2, z = 28.9} }
  else
    local pos = {}
    for i=1, math.min(#m.positions, 3) do
      if validateVec3(m.positions[i]) then table.insert(pos, m.positions[i]) end
    end
    if #pos == 0 then pos = { {x = -75.1, y = -821.2, z = 28.9} } end
    m.positions = pos
  end

  local r = tonumber(m.reward or 0) or 0
  if m.difficulty == "easy" then r = r > 0 and r or 1000
  elseif m.difficulty == "hard" then r = r > 0 and r or 5000
  else r = r > 0 and r or 2500 end
  m.reward = clamp(math.floor(r), Config.MinReward, Config.MaxReward)

  return true, m
end

-- ===== Anti-spam =====
local lastUse = {}
local function canUse(src)
  local now = os.time()
  local t = lastUse[src] or 0
  if now - t < Config.RateLimitSec then return false, Config.RateLimitSec - (now - t) end
  lastUse[src] = now
  return true, 0
end

-- ===== Attente modèle (optionnelle) =====
local function waitForOllamaModel(modelName, max_wait_ms, interval_ms, cb)
  max_wait_ms = max_wait_ms or 30000
  interval_ms = interval_ms or 2000
  local attempts = math.max(1, math.ceil(max_wait_ms / interval_ms))
  local target = tostring(modelName):lower()

  Citizen.CreateThread(function()
    for _ = 1, attempts do
      local finished, httpCode, body = false, nil, nil
      PerformHttpRequest(Config.OllamaURL .. "/api/ps", function(code, data)
        httpCode, body = code, data
        finished = true
      end, "GET", nil, { ["Content-Type"] = "application/json" })
      local waited = 0
      while not finished and waited < interval_ms do Wait(50); waited = waited + 50 end

      if finished and httpCode == 200 and body then
        local ok, parsed = pcall(json.decode, body)
        if ok and type(parsed) == "table" then
          local list = type(parsed.models) == "table" and parsed.models or (#parsed > 0 and parsed or nil)
          if type(list) == "table" then
            for _, entry in ipairs(list) do
              local mname = entry.name or entry.model or entry.model_name or entry.modelId
              if mname and tostring(mname):lower():find(target, 1, true) then cb(true); return end
            end
          end
        end
      end

      Wait(interval_ms)
    end
    cb(false)
  end)
end

-- ===== Warm-up modèle au démarrage (garde en mémoire) =====
local function warmUpModel()
  CreateThread(function()
    local body = json.encode({
      model      = Config.Model,
      prompt     = "OK",
      stream     = false,
      keep_alive = Config.KeepAlive,
      options    = { temperature = 0.0 }
    })
    print(("[IAManager] Warm-up modèle: %s"):format(Config.Model))
    PerformHttpRequest(Config.OllamaURL .. "/api/generate", function(code) 
      print(("[IAManager] Warm-up HTTP=%s"):format(code))
    end, "POST", body, { ["Content-Type"] = "application/json" })
  end)
end

AddEventHandler('onResourceStart', function(res)
  if res ~= GetCurrentResourceName() then return end
  warmUpModel()
end)

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

  -- (facultatif) informer le joueur
  if src ~= 0 then
    TriggerClientEvent('chat:addMessage', src, { args = { "IA", "Initialisation du modèle IA..." } })
  end

  waitForOllamaModel(Config.Model, 15000, 1000, function(_ready)
    -- Même si /api/ps échoue, on tente quand même la génération (Ollama chargera si besoin)
    local body = json.encode({
      model      = Config.Model,
      prompt     = prompt,
      stream     = false,
      format     = "json",
      keep_alive = Config.KeepAlive,
      options    = { temperature = Config.Temperature }
    })

    PerformHttpRequest(Config.OllamaURL .. '/api/generate', function(code, data)
      if code ~= 200 then
        print(("Ollama HTTP %s"):format(code))
        if src ~= 0 then TriggerClientEvent('chat:addMessage', src, { args = {"IA", "Erreur: génération indisponible."} }) end
        return
      end

      local ok1, parsed = pcall(json.decode, data)
      if not ok1 or not parsed or not parsed.response then print("^1Réponse Ollama invalide^0"); return end

      local raw = tostring(parsed.response or "")
      local cleaned = stripCodeFences(raw)
      local candidate = extractLargestJsonObject(cleaned) or cleaned

      local ok2, mission = pcall(json.decode, candidate)
      if not ok2 or type(mission) ~= "table" then
        print("^3Mission non JSON (après nettoyage). Échantillon:^7 "..string.sub(raw, 1, 200))
        return
      end

      local valid, res = validateMission(mission)
      if not valid then print(("Mission rejetée (validation: %s)"):format(res)); return end

      -- Envoi au joueur
      if src ~= 0 then
        TriggerClientEvent("missionai:start", src, res)
        TriggerClientEvent('chat:addMessage', src, {
          args = {"IA", ("Mission: %s | diff=%s | $%d"):format(res.title, res.difficulty, res.reward)}
        })
      end

      -- Logs console
      print(("^2Mission: %s^0 | diff=%s | $%d"):format(res.title, res.difficulty, res.reward))
      for i,s in ipairs(res.steps) do print(("  - %d) %s"):format(i, s.desc)) end
      for i,p in ipairs(res.positions) do print(("  pos%d: (%.1f, %.1f, %.1f)"):format(i, p.x, p.y, p.z)) end

    end, 'POST', body, { ['Content-Type'] = 'application/json' })
  end)
end, false)
