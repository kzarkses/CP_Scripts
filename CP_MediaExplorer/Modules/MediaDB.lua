-- CP_MediaExplorer — MediaDB
-- Bootstrap from REAPER's native Media Explorer databases: the plain-text
-- <resource>/MediaDB/*.ReaperFileList files list every file the user has
-- already indexed. Reading them makes global search cover the whole library
-- instantly, without waiting for our own filesystem indexer.
--
-- Format (verified against Soundmole's parser and local files):
--   FILE "<fullpath>" <size> <n> <n> <n>
--   DATA <quoted key:value tags...>          (ignored here — paths only)
--
-- Reading is streamed line-by-line across defer frames with a wall-clock
-- budget, one database at a time (never blocks the UI).

local MediaDB = {}

local r  -- reaper, injected

MediaDB.count   = 0      -- files handed to the sink so far
MediaDB.loading = false
MediaDB.loaded  = false  -- one full pass completed this session

local queue  = nil       -- pending .ReaperFileList paths
local file   = nil       -- open handle being streamed

function MediaDB.init(reaper_api)
    r = reaper_api
end

-- Queue every database for streaming. Safe to call again (restarts).
function MediaDB.Start()
    if file then file:close(); file = nil end
    queue = {}
    local dir = r.GetResourcePath() .. "/MediaDB"
    local i = 0
    while true do
        local name = r.EnumerateFiles(dir, i)
        if not name then break end
        if name:match("%.ReaperFileList$") then
            queue[#queue + 1] = dir .. "/" .. name
        end
        i = i + 1
    end
    MediaDB.loading = #queue > 0
    if not MediaDB.loading then MediaDB.loaded = true end
end

function MediaDB.Stop()
    if file then file:close(); file = nil end
    queue = nil
    MediaDB.loading = false
end

-- Stream for up to budget_s seconds; sink(path) is called for each FILE
-- entry. Returns true while more work remains.
function MediaDB.Step(budget_s, sink)
    if not MediaDB.loading then return false end
    local deadline = r.time_precise() + (budget_s or 0.003)

    while true do
        if not file then
            if not queue or #queue == 0 then
                queue = nil
                MediaDB.loading = false
                MediaDB.loaded = true
                return false
            end
            file = io.open(table.remove(queue), "rb")
            if not file then
                -- Unreadable database: skip it, keep going next call.
                return true
            end
        end

        -- A batch of lines, then a clock check — line reads are too cheap
        -- to time individually.
        for _ = 1, 200 do
            local line = file:read("*l")
            if not line then
                file:close()
                file = nil
                break
            end
            local path = line:match('^FILE%s+"(.-)"')
            if path and path ~= "" then
                sink(path)
                MediaDB.count = MediaDB.count + 1
            end
        end

        if r.time_precise() >= deadline then
            return true
        end
    end
end

return MediaDB
