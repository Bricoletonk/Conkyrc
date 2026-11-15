-- ==========================================================
--  Commandes lentes lancées en arrière-plan
--
--  curl, apt-get, tailscale... peuvent prendre plusieurs secondes.
--  Lancées directement, elles figeraient tout l'affichage.
--  Ici, chaque commande tourne en tâche de fond et écrit son résultat
--  dans un fichier ; on affiche la dernière valeur connue en attendant.
-- ==========================================================
local A = { jobs = {}, mock = nil }

local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

function A.init()
    local base = os.getenv("XDG_RUNTIME_DIR")
    if not base or base == "" then base = "/tmp/conky-mcdu-" .. (os.getenv("USER") or "user") end
    A.dir = base .. "/conky-mcdu"
    os.execute("mkdir -p " .. q(A.dir))
end

-- Renvoie la dernière sortie connue de `cmd` (nil au début).
-- interval : secondes entre deux exécutions
-- keep     : garde l'ancienne valeur si la nouvelle sortie est vide (panne réseau)
function A.get(key, cmd, interval, now, keep)
    if A.mock then return A.mock[key] end
    if not A.dir then A.init() end
    local j = A.jobs[key]
    if not j then j = { next = 0 }; A.jobs[key] = j end
    local base = A.dir .. "/" .. key

    if j.running then
        local f = io.open(base .. ".out", "r")
        if f then
            local v = f:read("*a") or ""
            f:close()
            os.remove(base .. ".out")
            v = v:gsub("%s+$", "")
            if v ~= "" or not keep then j.value = v end
            j.running = false
        elseif now - j.started > 120 then
            j.running = false -- tâche perdue : on relancera
        end
    end

    if not j.running and now >= j.next then
        local sh = io.open(base .. ".sh", "w")
        if sh then
            sh:write(cmd, "\n")
            sh:close()
            os.execute(string.format(
                "(timeout 60 sh %s > %s 2>/dev/null; mv -f %s %s) >/dev/null 2>&1 &",
                q(base .. ".sh"), q(base .. ".tmp"), q(base .. ".tmp"), q(base .. ".out")))
            j.running, j.started, j.next = true, now, now + interval
        end
    end
    return j.value
end

return A
