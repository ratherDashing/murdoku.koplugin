--[[--
Murdoku for KOReader.

Adds "Murdoku" to the Tools menu (both in the file browser and while reading).
Puzzles are downloaded from murdoku.com and cached for offline play.

@module koplugin.Murdoku
--]]

-- Make the plugin's own modules (puzzle, store, board, game, objects) requireable.
local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
if not package.path:find(plugin_dir, 1, true) then
    package.path = plugin_dir .. "?.lua;" .. package.path
end

local ButtonDialog = require("ui/widget/buttondialog")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local TextViewer = require("ui/widget/textviewer")
local Store = require("murdoku_store")

local ABOUT_HTML = [[
<h2>Murdoku for KOReader</h2>
<p>An <b>unofficial</b>, fan-made player for Murdoku logic-mystery cases. It is not affiliated with, endorsed by, or connected to Murdoku, Manuel Garand, or Digivoid Studios Inc.</p>
<p><b>Murdoku</b> is created by Manuel Garand. Play online, get the books and find more cases at <b>murdoku.com</b>.</p>

<h2>Get the book</h2>
<p>If you enjoy these cases, the best way to say thanks is to buy the books. <a href="https://link.amazon/B04hUyE9T">Murdoku Volume 1 on Amazon</a> (tap for a QR code) has the rest of the series on the same page.</p>
<p class="small">This is an affiliate link: buying through it supports the development of this plugin, at no extra cost to you.</p>

<h2>Where the cases come from</h2>
<p>The free cases from murdoku.com are downloaded straight onto your device. No murdoku.com puzzles are included with or redistributed by this plugin. All murdoku.com puzzles, names and clues are © their creators. Murdoku™ is a trademark of Digivoid Studios Inc.</p>
<p><b>Originals</b> (marked ◆) are cases written for this plugin by its own generator and ship with it. <b>Random</b> cases (marked ⚄) are generated on your device. Neither comes from murdoku.com.</p>

<h2>List symbols</h2>
<p>★ latest case &#160; ✓ solved &#160; … in progress &#160; ◌ solution revealed &#160; ⇩ not downloaded yet &#160; ◆ Original (bundled) &#160; ⚄ Random (made on this device; hold to delete)</p>

<h2>Credits</h2>
<p class="small">Object icons by Delapouite, Lorc, Skoll, Caro Asercion, John Redman, Pierre Leducq, Faithtoken and HeavenlyDog from game-icons.net (CC BY 3.0, recoloured); Fluent Emoji High Contrast © Microsoft Corporation (MIT); Material Design Icons © Pictogrammers (Apache 2.0); Temaki by Bryan Housel (CC0); toolbar icons from Lucide (ISC). Suspect portraits are built from Open Peeps by Pablo Stanley (CC0). Full details are in ATTRIBUTION.md in the plugin folder.</p>
]]
local Puzzle = require("murdoku_puzzle")

local Murdoku = WidgetContainer:extend{
    name = "murdoku",
    is_doc_only = false,
}

function Murdoku:init()
    Dispatcher:registerAction("murdoku_open", {
        category = "none", event = "OpenMurdoku", title = _("Murdoku"), general = true,
    })
    self.ui.menu:registerToMainMenu(self)
end

function Murdoku:addToMainMenu(menu_items)
    menu_items.murdoku = {
        text = _("Murdoku"),
        sorting_hint = "tools",
        callback = function() self:openCaseList() end,
    }
end

function Murdoku:onOpenMurdoku()
    self:openCaseList()
    return true
end

-- Run fn while showing a short "working" message (blocking work).
local function withMessage(text, fn)
    local msg = InfoMessage:new{ text = text }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local ok, a, b = pcall(fn)
    UIManager:close(msg)
    if not ok then
        logger.err("Murdoku:", a)
        return nil, tostring(a)
    end
    return a, b
end

local function statusFor(id)
    local st = Store.loadState(id)
    if type(st) ~= "table" then return nil end
    if st.solved then return st.revealed and "revealed" or "solved" end
    for _i, field in ipairs({ "placed", "marks", "notes" }) do
        if type(st[field]) == "table" and next(st[field]) then return "started" end
    end
    return nil
end

local DIFFICULTIES = { "very-easy", "easy", "medium", "hard", "expert" }
local SORTS = {
    { id = "newest", label = _("Newest") },
    { id = "oldest", label = _("Oldest") },
    { id = "difficulty", label = _("Difficulty") },
    { id = "name", label = _("Name") },
    { id = "size", label = _("Size") },
}
local SOURCE_FILTERS = {
    { id = "all", label = _("All") },
    { id = "site", label = _("murdoku.com") },
    { id = "original", label = _("Originals") },
    { id = "random", label = _("Random") },
}
local SOURCE_MARK = { original = "◆ ", random = "⚄ " }
local SOURCE_TAG = { original = _("Original"), random = _("Random") }
local STATUS_FILTERS = {
    { id = "all", label = _("All") },
    { id = "unsolved", label = _("Unsolved") },
    { id = "solved", label = _("Solved") },
}

local function gridCells(e)
    local w, h = (e.size or ""):match("(%d+)x(%d+)")
    return (tonumber(w) or 0) * (tonumber(h) or 0)
end

-- Sort keys per mode; ties fall back to newest first, then id.
local SORT_KEYS = {
    newest = function(e) return { -e.release } end,
    oldest = function(e) return { e.release } end,
    difficulty = function(e) return { e.difficulty_rank, -e.release } end,
    name = function(e) return { e.title:lower() } end,
    size = function(e) return { gridCells(e), e.difficulty_rank, -e.release } end,
}

local function sortList(list, how)
    local keyfn = SORT_KEYS[how] or SORT_KEYS.newest
    local sorted = {}
    for i, e in ipairs(list) do
        sorted[i] = { e = e, k = keyfn(e) }
    end
    table.sort(sorted, function(a, b)
        for i = 1, #a.k do
            if a.k[i] ~= b.k[i] then return a.k[i] < b.k[i] end
        end
        return a.e.id < b.e.id
    end)
    for i, item in ipairs(sorted) do sorted[i] = item.e end
    return sorted
end

function Murdoku:filterState()
    return {
        difficulty = Store.getOption("filter_difficulty", "all"),
        status = Store.getOption("filter_status", "all"),
        source = Store.getOption("filter_source", "all"),
        sort = Store.getOption("sort", "newest"),
    }
end

--- murdoku.com catalogue + bundled Originals + saved Random cases.
function Murdoku:allEntries()
    local list = {}
    for __, e in ipairs(self.catalog or {}) do table.insert(list, e) end
    for __, e in ipairs(Store.originals()) do table.insert(list, e) end
    for __, e in ipairs(Store.randomCases()) do table.insert(list, e) end
    return list
end

--- Subtitle like the website's "42 puzzles · 0 completed".
function Murdoku:subtitle()
    local list = self:allEntries()
    local solved = 0
    for __, e in ipairs(list) do
        if statusFor(e.id) == "solved" then solved = solved + 1 end
    end
    local f = self:filterState()
    local parts = { string.format(_("%d cases · %d solved"), #list, solved) }
    if f.source ~= "all" then
        for __, sf in ipairs(SOURCE_FILTERS) do if sf.id == f.source then table.insert(parts, sf.label) end end
    end
    if f.difficulty ~= "all" then table.insert(parts, Store.DIFFICULTY_LABEL[f.difficulty]) end
    if f.status ~= "all" then
        for __, sf in ipairs(STATUS_FILTERS) do if sf.id == f.status then table.insert(parts, sf.label) end end
    end
    for __, so in ipairs(SORTS) do
        if so.id == f.sort then table.insert(parts, _("by ") .. so.label:lower()) end
    end
    return table.concat(parts, " · ")
end

function Murdoku:buildItems()
    local items = {}
    local show_retired = Store.getOption("show_retired", false)
    local f = self:filterState()
    local list = self:allEntries()
    local seen = {}
    -- The site publishes a new case every week or so; flag the newest one.
    local latest
    for __, e in ipairs(list) do
        seen[e.id] = true
        if e.source == Store.SOURCE_SITE and not e.retired and (not latest or e.release > latest.release) then latest = e end
    end
    for __, e in ipairs(sortList(list, f.sort)) do
        local status = statusFor(e.id)
        local keep = (f.difficulty == "all" or e.difficulty == f.difficulty)
            and (f.source == "all" or e.source == f.source)
            and (f.status == "all"
                or (f.status == "solved" and status == "solved")
                or (f.status == "unsolved" and status ~= "solved" and status ~= "revealed"))
        if keep then
        local mark = status == "solved" and "✓ " or (status == "revealed" and "◌ " or (status == "started" and "… " or ""))
        local right = {}
        if SOURCE_TAG[e.source] then table.insert(right, SOURCE_TAG[e.source]) end
        if e.difficulty then table.insert(right, Store.DIFFICULTY_LABEL[e.difficulty]) end
        if e.size then table.insert(right, (e.size:gsub("x", "×"))) end
        if e.source == Store.SOURCE_SITE and not Store.isDownloaded(e.id) then table.insert(right, "⇩") end
        if e.retired then table.insert(right, "retired") end
        local is_latest = e == latest
        table.insert(items, {
            text = mark .. (SOURCE_MARK[e.source] or "") .. (is_latest and "★ " or "") .. e.title
                .. (is_latest and "  (latest)" or ""),
            mandatory = table.concat(right, " · "),
            callback = function() self:openCase(e) end,
            hold_callback = e.source == Store.SOURCE_RANDOM and function() self:confirmDeleteRandom(e) end or nil,
        })
        end
    end
    -- downloaded puzzles no longer in the catalogue are still playable
    for __, id in ipairs(Store.downloadedIds()) do
        if not seen[id] and (show_retired or not self.catalog) and f.difficulty == "all"
                and (f.source == "all" or f.source == "site") then
            local status = statusFor(id)
            table.insert(items, {
                text = (status == "solved" and "✓ " or "") .. id:gsub("^puzzle%-", ""):gsub("%-", " "),
                mandatory = "offline",
                callback = function() self:openCase({ id = id, title = id }) end,
            })
        end
    end
    if #items == 0 and #list > 0 then
        table.insert(items, {
            text = _("No cases match this filter – tap to show all"),
            callback = function()
                Store.setOption("filter_difficulty", "all")
                Store.setOption("filter_status", "all")
                Store.setOption("filter_source", "all")
                self:updateMenu()
            end,
        })
    elseif #items == 0 then
        table.insert(items, {
            text = _("No cases yet – tap to download the case list"),
            callback = function() self:refreshCatalog() end,
        })
    end
    return items
end

function Murdoku:openCaseList()
    local show_retired = Store.getOption("show_retired", false)
    self.catalog = Store.cachedCatalog(show_retired)
    self.menu = Menu:new{
        title = _("Murdoku cases"),
        subtitle = self:subtitle(),
        item_table = self:buildItems(),
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        title_bar_fm_style = true,
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function() self:showListMenu() end,
        close_callback = function()
            UIManager:close(self.menu)
            self.menu = nil
        end,
    }
    -- Keep the list open behind a case (Menu closes itself on select by default).
    self.menu.onMenuSelect = function(_menu, item)
        if item.callback then item.callback() end
        return true
    end
    self.menu.onMenuHold = function(_menu, item)
        if item.hold_callback then item.hold_callback() end
        return true
    end
    UIManager:show(self.menu)
    -- Fetch a fresh list if we've never got one, or quietly if already online.
    if not self.catalog then
        self:refreshCatalog()
    elseif NetworkMgr:isOnline() then
        local fresh = withMessage(_("Checking for new cases…"), function()
            return Store.fetchCatalog(show_retired)
        end)
        if fresh then
            self.catalog = fresh
            self:updateMenu()
        end
    end
end

function Murdoku:updateMenu()
    if self.menu then
        self.menu:switchItemTable(nil, self:buildItems(), -1, nil, self:subtitle())
    end
end

function Murdoku:refreshCatalog()
    NetworkMgr:runWhenOnline(function()
        local list, err = withMessage(_("Downloading case list…"), function()
            return Store.fetchCatalog(Store.getOption("show_retired", false))
        end)
        if list then
            self.catalog = list
            self:updateMenu()
        else
            UIManager:show(InfoMessage:new{
                text = _("Couldn't download the case list.") .. "\n" .. tostring(err or ""),
            })
        end
    end)
end

function Murdoku:showListMenu()
    local dialog
    local show_retired = Store.getOption("show_retired", false)
    local f = self:filterState()
    local function choice(label, selected, option, value)
        return {
            text = (selected and "● " or "") .. label,
            callback = function()
                UIManager:close(dialog)
                Store.setOption(option, value)
                self:updateMenu()
                self:showListMenu() -- stay open so several choices can be made
            end,
        }
    end
    local diff_rows = { {}, {} }
    table.insert(diff_rows[1], choice(_("All"), f.difficulty == "all", "filter_difficulty", "all"))
    for i, d in ipairs(DIFFICULTIES) do
        local row = i <= 2 and 1 or 2
        table.insert(diff_rows[row], choice(Store.DIFFICULTY_LABEL[d], f.difficulty == d, "filter_difficulty", d))
    end
    local source_row = {}
    for __, sf in ipairs(SOURCE_FILTERS) do
        table.insert(source_row, choice(sf.label, f.source == sf.id, "filter_source", sf.id))
    end
    local status_row = {}
    for __, sf in ipairs(STATUS_FILTERS) do
        table.insert(status_row, choice(sf.label, f.status == sf.id, "filter_status", sf.id))
    end
    local sort_rows = { {}, {} }
    for i, so in ipairs(SORTS) do
        table.insert(sort_rows[i <= 3 and 1 or 2], choice(so.label, f.sort == so.id, "sort", so.id))
    end
    local buttons = {
        { { text = _("New random case…"), callback = function()
            UIManager:close(dialog)
            self:showRandomDialog()
        end } },
        { { text = _("Source"), enabled = false } },
        source_row,
        { { text = _("Difficulty"), enabled = false } },
        diff_rows[1], diff_rows[2],
        { { text = _("Show"), enabled = false } },
        status_row,
        { { text = _("Sort by"), enabled = false } },
        sort_rows[1], sort_rows[2],
    }
    for __, row in ipairs({
            { { text = _("Refresh case list"), callback = function()
                UIManager:close(dialog)
                self:refreshCatalog()
            end } },
            { { text = _("Download all cases for offline play"), callback = function()
                UIManager:close(dialog)
                self:downloadAll()
            end } },
            { { text = (show_retired and "☑ " or "☐ ") .. _("Show retired cases"), callback = function()
                UIManager:close(dialog)
                Store.setOption("show_retired", not show_retired)
                self.catalog = Store.cachedCatalog(not show_retired) or self.catalog
                self:updateMenu()
            end } },
            { { text = _("About"), callback = function()
                UIManager:close(dialog)
                require("murdoku_html").show(_("About Murdoku for KOReader"), ABOUT_HTML)
            end } },
        }) do
        table.insert(buttons, row)
    end
    dialog = ButtonDialog:new{
        title = _("Murdoku"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- Save every listed case on the device so they can be played offline.
function Murdoku:downloadAll()
    local Trapper = require("ui/trapper")
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            if not Trapper:info(_("Updating case list…")) then return end
            local list = Store.fetchCatalog(Store.getOption("show_retired", false)) or self.catalog or {}
            self.catalog = list
            local todo = {}
            for __, e in ipairs(list) do
                if not Store.isDownloaded(e.id) then table.insert(todo, e) end
            end
            if #todo == 0 then
                Trapper:clear()
                UIManager:show(InfoMessage:new{ text = _("All cases are already downloaded.") })
                self:updateMenu()
                return
            end
            local done, failed = 0, 0
            for i, e in ipairs(todo) do
                local go_on = Trapper:info(string.format(_("Downloading case %d of %d…\n%s\n\n(tap to stop)"),
                    i, #todo, e.title))
                if not go_on then break end
                local ok = Store.fetchPuzzle(e.id)
                if ok then done = done + 1 else failed = failed + 1 end
            end
            Trapper:clear()
            self:updateMenu()
            local msg = string.format(_("Downloaded %d case(s)."), done)
            if failed > 0 then msg = msg .. "\n" .. string.format(_("%d failed – try again later."), failed) end
            UIManager:show(InfoMessage:new{ text = msg })
        end)
    end)
end

-- Random cases ---------------------------------------------------------------

-- What the on-device generator offers. Desktop LuaJIT timings (tests/test_generator.lua):
-- very easy/easy/medium take well under a second up to 7x7 and about 1-4 s on
-- average at 8x8/9x9; hard takes about 1.5 s at 5x5/6x6 but 5-16 s (up to ~50 s)
-- at 7x7-9x9. A Kindle is roughly 8-15x slower, so hard is limited to 6x6 here;
-- bigger hard cases are in the bundled Originals.
local RANDOM_DIFFICULTIES = { "very-easy", "easy", "medium", "hard" }
local RANDOM_SIZES = { 5, 6, 7, 8, 9 }
local RANDOM_MAX_SIZE = { hard = 6 }
local RANDOM_TRIES = 3
-- seconds (wall clock) per attempt before starting over with a new seed
local function tryBudget(size) return size <= 7 and 40 or 90 end

function Murdoku:showRandomDialog()
    local dialog
    local diff = Store.getOption("random_difficulty", "easy")
    local size = Store.getOption("random_size", 7)
    if size > (RANDOM_MAX_SIZE[diff] or 9) then size = RANDOM_MAX_SIZE[diff] end
    local function pick(option, value)
        return function()
            UIManager:close(dialog)
            Store.setOption(option, value)
            self:showRandomDialog()
        end
    end
    local diff_row, size_row = {}, {}
    for __, d in ipairs(RANDOM_DIFFICULTIES) do
        table.insert(diff_row, { text = (d == diff and "● " or "") .. Store.DIFFICULTY_LABEL[d],
            callback = pick("random_difficulty", d) })
    end
    for __, n in ipairs(RANDOM_SIZES) do
        table.insert(size_row, { text = (n == size and "● " or "") .. n .. "×" .. n,
            enabled = n <= (RANDOM_MAX_SIZE[diff] or 9),
            callback = pick("random_size", n) })
    end
    dialog = ButtonDialog:new{
        title = _("New random case") .. "\n" .. _("Made on this device by the plugin's own generator. Bigger boards can take a minute or two. Hard is limited to 6×6 (bigger hard cases are in the Originals)."),
        buttons = {
            { { text = _("Difficulty"), enabled = false } },
            diff_row,
            { { text = _("Size"), enabled = false } },
            size_row,
            { { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
              { text = _("Generate"), callback = function()
                    UIManager:close(dialog)
                    self:generateRandom(diff, size)
                end } },
        },
    }
    UIManager:show(dialog)
end

--- Generate a case in time slices so the UI stays responsive; tap the message to cancel.
function Murdoku:generateRandom(diff, size)
    local Gen = require("murdoku_gen")
    local cancelled, msg, co, slice_start = false, nil, nil, 0
    local tries = 0
    local seed
    local label = string.format("%d×%d %s", size, size, Store.DIFFICULTY_LABEL[diff]:lower())

    local function showMsg()
        local m = InfoMessage:new{
            text = string.format(_("Making a new %s case…%s\n\nTap to cancel."), label,
                tries > 1 and string.format(_("\n(attempt %d of %d)"), tries, RANDOM_TRIES) or ""),
            dismiss_callback = function() if msg then cancelled = true end end,
        }
        msg = m
        UIManager:show(m)
    end
    local function closeMsg()
        local m = msg
        msg = nil
        if m then UIManager:close(m) end
    end
    local function newTry()
        tries = tries + 1
        seed = (os.time() % 100000000) * 10 + tries
        local deadline = os.time() + tryBudget(size)
        co = coroutine.create(function()
            return Gen.generate{
                size = size, difficulty = diff, seed = seed,
                clock = os.time, deadline = deadline,
                yield = function()
                    if os.clock() - slice_start > 0.15 then coroutine.yield() end
                end,
            }
        end)
    end
    local function finish(data, res)
        closeMsg()
        local id = "random-" .. seed
        local title = (data.CHARACTERS.title_en_ or _("Random case")) .. " · " .. os.date("%b %d %H:%M")
        data.CHARACTERS.title_en_ = title
        data.META = data.META or {}
        data.META.id = id
        data.META.created = os.time()
        local ok, err = Store.saveRandom(id, data)
        if not ok then
            UIManager:show(InfoMessage:new{ text = _("Couldn't save the new case.") .. "\n" .. tostring(err) })
            return
        end
        logger.info("Murdoku: generated", id, res.grade, "trials", res.logic.trials, "attempts", res.attempts)
        self:updateMenu()
        self:startGame({ id = id, title = title, difficulty = res.grade, source = Store.SOURCE_RANDOM,
            size = size .. "x" .. size }, data)
    end
    local step
    step = function()
        if cancelled then
            co = nil
            UIManager:show(InfoMessage:new{ text = _("Cancelled."), timeout = 1 })
            return
        end
        slice_start = os.clock()
        local ok, data, res = coroutine.resume(co)
        if not ok then
            closeMsg()
            logger.err("Murdoku: generator failed:", data)
            UIManager:show(InfoMessage:new{ text = _("Sorry, the generator failed:") .. "\n" .. tostring(data) })
            return
        end
        if coroutine.status(co) ~= "dead" then
            UIManager:scheduleIn(0.05, step)
            return
        end
        if data then return finish(data, res) end
        if tries < RANDOM_TRIES then
            closeMsg()
            newTry()
            showMsg()
            UIManager:scheduleIn(0.05, step)
        else
            closeMsg()
            UIManager:show(InfoMessage:new{
                text = _("No case found in time. Try again, or pick a smaller size or an easier difficulty."),
            })
        end
    end
    newTry()
    showMsg()
    UIManager:scheduleIn(0.3, step)
end

function Murdoku:confirmDeleteRandom(entry)
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = string.format(_("Delete the random case \"%s\" and its progress?"), entry.title),
        ok_text = _("Delete"),
        ok_callback = function()
            Store.deleteRandom(entry.id)
            self:updateMenu()
        end,
    })
end

function Murdoku:openCase(entry)
    local data = Store.loadCachedPuzzle(entry.id)
    if data then
        return self:startGame(entry, data)
    end
    if Store.sourceOf(entry.id) ~= Store.SOURCE_SITE then
        UIManager:show(InfoMessage:new{ text = _("This case file is missing.") })
        return
    end
    NetworkMgr:runWhenOnline(function()
        local fetched, err = withMessage(_("Downloading case…"), function()
            return Store.fetchPuzzle(entry.id)
        end)
        if not fetched then
            UIManager:show(InfoMessage:new{
                text = _("Couldn't download this case.") .. "\n" .. tostring(err or ""),
            })
            return
        end
        self:startGame(entry, fetched)
    end)
end

function Murdoku:startGame(entry, data)
    local puzzle, err = Puzzle.parse(data, entry.id)
    if not puzzle then
        UIManager:show(InfoMessage:new{ text = _("This case can't be played here: ") .. tostring(err) })
        return
    end
    if entry.title and entry.title ~= entry.id then puzzle.title = entry.title end
    local Game = require("murdoku_game")
    UIManager:show(Game:new{
        ui = self.ui,
        puzzle = puzzle,
        entry = entry,
        on_close = function() self:updateMenu() end,
    })
end

return Murdoku
