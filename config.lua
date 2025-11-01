Config = {
  ResourceName = 'IAManager-ValStudios',-- mets EXACTEMENT le nom du dossier ressource
  OllamaURL    = 'http://192.168.1.2:30768', -- ex: http://192.168.1.10  -- Caddy
  Model        = 'artifish/llama3.2-uncensored',
  Temperature  = 0.2,
  KeepAlive    = "30m",

  -- limites & sécurité
  MaxSteps     = 3,
  MinReward    = 250,
  MaxReward    = 25000,
  RateLimitSec = 8,   -- anti-spam / joueur
}
