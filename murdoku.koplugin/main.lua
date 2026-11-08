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

local ABOUT_TEXT = _([[
Murdoku for KOReader is an UNOFFICIAL, fan-made player.
It is not affiliated with, endorsed by, or connected to Murdoku, Manuel Garand, or Digivoid Studios Inc.

Murdoku is created by Manuel Garand.
Play online, get the books and find more cases at:
https://murdoku.com

The free cases shown here are downloaded straight from murdoku.com onto your device. No puzzles are included with or redistributed by this plugin. All puzzles, names and clues are © their creators. Murdoku™ is a trademark of Digivoid Studios Inc.

If you enjoy the cases, please support the creator by buying the Murdoku books.

List symbols:
★ latest case   ✓ solved   … in progress   ◌ solution revealed   ⇩ not downloaded yet
]])
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
    if st.placed and next(st.placed) then return "started" end
    return nil
end

function Murdoku:buildItems()
    local items = {}
    local show_retired = Store.getOption("show_retired", false)
    local list = self.catalog or {}
    local seen = {}
    -- The site publishes a new case every week or so; flag the newest one.
    local latest
    for _, e in ipairs(list) do
        if not e.retired and (not latest or e.release > latest.release) then latest = e end
    end
    for _, e in ipairs(list) do
        seen[e.id] = true
        local status = statusFor(e.id)
        local mark = status == "solved" and "✓ " or (status == "revealed" and "◌ " or (status == "started" and "… " or ""))
        local right = {}
        if e.difficulty then table.insert(right, Store.DIFFICULTY_LABEL[e.difficulty]) end
        if e.size then table.insert(right, (e.size:gsub("x", "×"))) end
        if not Store.isDownloaded(e.id) then table.insert(right, "⇩") end
        if e.retired then table.insert(right, "retired") end
        local is_latest = e == latest
        table.insert(items, {
            text = mark .. (is_latest and "★ " or "") .. e.title .. (is_latest and "  (latest)" or ""),
            mandatory = table.concat(right, " · "),
            callback = function() self:openCase(e) end,
        })
    end
    -- downloaded puzzles no longer in the catalogue are still playable
    for _, id in ipairs(Store.downloadedIds()) do
        if not seen[id] and (show_retired or not self.catalog) then
            local status = statusFor(id)
            table.insert(items, {
                text = (status == "solved" and "✓ " or "") .. id:gsub("^puzzle%-", ""):gsub("%-", " "),
                mandatory = "offline",
                callback = function() self:openCase({ id = id, title = id }) end,
            })
        end
    end
    if #items == 0 then
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
        self.menu:switchItemTable(nil, self:buildItems(), -1)
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
    dialog = ButtonDialog:new{
        title = _("Murdoku"),
        buttons = {
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
                UIManager:show(TextViewer:new{
                    title = _("About Murdoku for KOReader"),
                    text = ABOUT_TEXT,
                })
            end } },
        },
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
            for _, e in ipairs(list) do
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

function Murdoku:openCase(entry)
    local data = Store.loadCachedPuzzle(entry.id)
    if data then
        return self:startGame(entry, data)
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
