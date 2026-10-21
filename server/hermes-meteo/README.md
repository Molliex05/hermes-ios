# hermes-meteo — weather through Open-Meteo

Tool `meteo` (toolset `meteo`): current conditions and 1–7 days of forecast for a place name or coordinates. Free, no key. Only `geocoding-api.open-meteo.com` and `api.open-meteo.com` are contacted. Optional default place per profile: `hermes -p <profile> config set meteo.lieu_defaut "Québec"`.

Install: copy to `/opt/data/plugins/hermes-meteo`, link into `<profile>/plugins/`, `hermes -p <profile> plugins enable hermes-meteo`. Deployed 2026-10-20 on `noriven` and `personnel`.
