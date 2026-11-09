--[[--
The Murdoku game screen.

Finger-friendly controls (no stylus needed), matching murdoku.com:
  * Tap a suspect to select them (tap again to deselect).
  * With a suspect selected: tap a square to toggle a note, hold a square to
    place them there (their row and column get X marks, and the selection
    is cleared).
  * With nobody selected: tap a square to toggle an X; tap a placed person
    to select them.
  * Toolbar: X (mark mode), eraser, undo, hint, check, menu.
  * Swipe across squares to X out a whole line at once.
  * Hold a square (with nobody selected) or a suspect for details.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local GestureRange = require("ui/gesturerange")
local CenterContainer = require("ui/widget/container/centercontainer")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextViewer = require("ui/widget/textviewer")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Puzzle = require("murdoku_puzzle")
local Store = require("murdoku_store")
local Widgets = require("murdoku_board")
local Html = require("murdoku_html")
local Cards = require("murdoku_cards")
local Parse = require("murdoku_clueparse")
local Screen = Device.screen


local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

local function fmtTime(secs)
    secs = math.floor(secs or 0)
    local h = math.floor(secs / 3600)
    local m = math.floor(secs % 3600 / 60)
    local s = secs % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

local Game = InputContainer:extend{
    puzzle = nil,
    entry = nil,      -- catalogue entry (title, difficulty...)
    on_close = nil,
    covers_fullscreen = true,
}

function Game:init()
    local p = self.puzzle
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.options = {
        room_names = Store.getOption("room_names", true),
        highlight = Store.getOption("highlight", true),
        textures = Store.getOption("textures", false),
    }
    local saved = Store.loadState(p.id)
    self.state = {
        placed = {}, marks = {}, notes = {}, history = {},
        solved = false, elapsed = 0, hints_shown = 0,
    }
    if type(saved) == "table" then
        for k, v in pairs(saved) do self.state[k] = v end
        -- LuaSettings may turn integer keys into strings; normalise.
        local placed = {}
        for k, v in pairs(self.state.placed or {}) do placed[tonumber(k)] = v end
        self.state.placed = placed
        local notes = {}
        for k, set in pairs(self.state.notes or {}) do
            notes[k] = {}
            for i, on in pairs(set) do notes[k][tonumber(i)] = on end
        end
        self.state.notes = notes
    end
    self.state.history = self.state.history or {}
    self.tool = nil      -- nil | "mark" | "erase"
    self.selected = nil
    self.started_at = Game.now()
    self:updateConflicts()

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    self:buildLayout()
end

function Game:buildLayout()
    local p = self.puzzle
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local margin = Size.padding.default

    local diff = self.entry and self.entry.difficulty and Store.DIFFICULTY_LABEL[self.entry.difficulty]
    local subtitle = string.format("%s%d×%d · %d suspects", diff and (diff .. " · ") or "", p.w, p.h, #p.suspects)
    self.title_bar = TitleBar:new{
        width = sw,
        fullscreen = true,
        title = self:titleText(),
        subtitle = subtitle,
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
    }

    self.landscape = sw > sh
    self.built_w, self.built_h = sw, sh
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.clue_face = Font:getFace("cfont", 19)
    local line_h = self.clue_face.ftsize:getHeightAndAscender()
    local body_h = sh - self.title_bar:getHeight() - margin

    local function makeToolbar(width)
        local function toolActive(t) return function() return self.tool == t end end
        return Widgets.Toolbar:new{
            width = width,
            height = Screen:scaleBySize(46),
            items = {
                { id = "mark", icon = "x", label = "X: each tap crosses a square out (or back in).",
                  active = toolActive("mark"), callback = function() self:setTool("mark") end },
                { id = "erase", icon = "eraser", label = "Eraser: each tap clears a square.",
                  active = toolActive("erase"), callback = function() self:setTool("erase") end },
                { id = "undo", icon = "undo-2", label = "Undo", callback = function() self:undo() end },
                { id = "hint", icon = "lightbulb", label = "Hint",
                  enabled = function() return #p.hints > 0 end, callback = function() self:showHint() end },
                { id = "check", icon = "check", label = "Check", callback = function() self:check() end },
                { id = "menu", icon = "menu", label = "Menu", callback = function() self:showMenu() end },
            },
        }
    end

    local content
    if not self.landscape then
        -- Portrait: board on top, suspect cards and the toolbar underneath.
        local w = sw - 2 * margin
        self.button_table = makeToolbar(w)
        local tb_h = self.button_table:getSize().h
        local board_max = math.floor((body_h - tb_h) * 0.6)
        self.board = Widgets.Board:new{ puzzle = p, game = self, width = w, height = board_max }
        local board_h = self.board.dimen.h
        local panel_h = body_h - tb_h - board_h - 3 * margin
        self.panel = Cards.SuspectPanel:new{ puzzle = p, game = self, width = w, height = panel_h }
        content = VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = margin },
            CenterContainer:new{ dimen = Geom:new{ w = sw, h = board_h }, self.board },
            VerticalSpan:new{ width = margin },
            self.panel,
            VerticalSpan:new{ width = margin },
            self.button_table,
        }
    else
        -- Landscape: board on the left; cards and the toolbar on the right.
        local panel_min = math.max(math.floor(sw * 0.32), Screen:scaleBySize(240))
        local board_h = body_h - margin
        self.board = Widgets.Board:new{
            puzzle = p, game = self,
            width = sw - panel_min - 3 * margin,
            height = board_h,
        }
        local panel_w = sw - self.board.dimen.w - 3 * margin
        self.button_table = makeToolbar(panel_w)
        local panel_h = body_h - self.button_table:getSize().h - 2 * margin
        self.panel = Cards.SuspectPanel:new{ puzzle = p, game = self, width = panel_w, height = panel_h }
        content = HorizontalGroup:new{
            align = "top",
            HorizontalSpan:new{ width = margin },
            VerticalGroup:new{
                VerticalSpan:new{ width = margin },
                CenterContainer:new{ dimen = Geom:new{ w = self.board.dimen.w, h = board_h }, self.board },
            },
            HorizontalSpan:new{ width = margin },
            VerticalGroup:new{
                align = "left",
                VerticalSpan:new{ width = margin },
                self.panel,
                VerticalSpan:new{ width = margin },
                self.button_table,
            },
        }
    end
    self:updateClue()

    self[1] = FrameContainer:new{
        width = sw,
        height = sh,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            self.title_bar,
            content,
        },
    }
end

-- Re-layout if the screen was rotated while we were open.
function Game:paintTo(bb, x, y)
    if Screen:getWidth() ~= self.built_w or Screen:getHeight() ~= self.built_h then
        self:buildLayout()
    end
    InputContainer.paintTo(self, bb, x, y)
end

-- Rotation requested while the game is the top widget (e.g. by the
-- accelerometer): let the main UI rotate so everything underneath re-lays out
-- too, then rebuild ourselves.
function Game:onSetRotationMode(mode)
    if mode == nil or mode == Screen:getRotationMode() then return true end
    if self.ui then
        self.ui:handleEvent(Event:new("SetRotationMode", mode))
    else
        Screen:setRotationMode(mode)
    end
    self:buildLayout()
    UIManager:setDirty("all", "full")
    return true
end

function Game:onScreenResize()
    self:buildLayout()
    UIManager:setDirty(self, "full")
    return false
end

function Game:rotate()
    local rota = Screen:getRotationMode()
    -- portrait modes are even, landscape odd
    local target = (rota % 2 == 0) and ((rota + 1) % 4) or ((rota + 3) % 4)
    self:onSetRotationMode(target)
end

function Game:titleText()
    local t = (self.state.elapsed or 0) + (self.runningSpan and self:runningSpan() or 0)
    return string.format("%s   %s", self.puzzle.title, fmtTime(t))
end

function Game:updateTitle()
    if self.title_bar then self.title_bar:setTitle(self:titleText(), true) end
end

function Game:setTool(tool)
    if self.tool == tool then tool = nil end
    self.tool = tool
    if tool then self.selected = nil end
    self:updateHighlight()
    self:updateClue()
    self:refresh()
end

-- Text for the strip above the suspect cards.
function Game:statusText()
    local p = self.puzzle
    if self.state.solved then
        local m = p.murderer and p.suspects[p.murderer]
        return "Case closed" .. (m and (": " .. m.name .. " is the murderer!") or "!")
            .. " Tap here for all clues."
    elseif self.tool == "mark" then
        return "X mode: tap squares to cross them out. Tap the X button again to stop."
    elseif self.tool == "erase" then
        return "Eraser: tap squares to clear them. Tap the eraser button again to stop."
    elseif p.general_clues and #p.general_clues > 0 then
        return "General: " .. table.concat(p.general_clues, " ")
    elseif self.selected then
        return p.suspects[self.selected].name .. ": tap\u{00A0}=\u{00A0}note, hold\u{00A0}=\u{00A0}place."
    end
    return "Pick a suspect: tap a square for a note, hold it to place."
end

function Game:updateClue()
    if self.panel then
        self.panel:showSuspect(self.selected)
        self.panel:build()
    end
end

function Game:refresh()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

-- State changes ---------------------------------------------------------------

-- Undo history: unlimited, and saved with the case. Each entry is the list of
-- {field, key, old_value} changes one action made, so it stays small.
function Game:change(field, key, value)
    local t = self.state[field]
    local old = t[key]
    if old == value then return end
    table.insert(self.tx, { field, key, deepcopy(old) })
    t[key] = value
end

-- Run fn as a single undoable action.
function Game:action(fn)
    self.tx = {}
    fn()
    if #self.tx > 0 then table.insert(self.state.history, self.tx) end
    self.tx = nil
    self:afterChange()
end

function Game:undo()
    if self.state.solved then
        UIManager:show(InfoMessage:new{ text = "This case is closed. Use Restart case to play it again.", timeout = 2 })
        return
    end
    local h = table.remove(self.state.history)
    if not h then
        UIManager:show(InfoMessage:new{ text = "Nothing to undo.", timeout = 1 })
        return
    end
    for i = #h, 1, -1 do
        local field, key, old = h[i][1], h[i][2], h[i][3]
        self.state[field][key] = old
    end
    self:afterChange()
end

function Game:updateConflicts()
    self.conflicts = Puzzle.conflicts(self.puzzle, self.state.placed)
end

function Game:occupantAt(r, c)
    for i, pos in pairs(self.state.placed) do
        if pos[1] == r and pos[2] == c then return i end
    end
end

function Game:afterChange()
    self.wrong_cells = nil
    self:updateConflicts()
    self:save()
    self:updateHighlight()
    self:updateClue()
    self:updateTitle()
    self:refresh()
    local count = 0
    for _ in pairs(self.state.placed) do count = count + 1 end
    if count == #self.puzzle.suspects and not self.state.solved then
        UIManager:nextTick(function() self:check(true) end)
    end
end

function Game:onSuspectTap(i)
    if self.selected == i then
        self.selected = nil
    else
        self.selected = i
        self.tool = nil
    end
    self:updateHighlight()
    self:updateClue()
    self:refresh()
end

function Game:onSuspectHold(i)
    Cards.showSuspectPopup(self.puzzle, i, self.state.placed)
end

function Game:select(i)
    self.selected = i
    self:updateHighlight()
    self:updateClue()
    self:refresh()
end

-- Clear a square: the person on it, its X and its notes (one undo step).
function Game:erase(r, c)
    local k = r .. "," .. c
    local who = self:occupantAt(r, c)
    if not who and not self.state.marks[k] and not self.state.notes[k] then return end
    self:action(function()
        if who then self:clearAutoMarks(who); self:change("placed", who, nil) end
        self:change("marks", k, nil)
        self:change("notes", k, nil)
    end)
end

function Game:toggleMark(r, c)
    local k = r .. "," .. c
    if self:occupantAt(r, c) or not Puzzle.standable(self.puzzle, r, c) then return end
    self:action(function() self:change("marks", k, not self.state.marks[k] or nil) end)
end

function Game:toggleNote(i, r, c)
    local k = r .. "," .. c
    local notes = deepcopy(self.state.notes[k] or {})
    notes[i] = not notes[i] or nil
    if next(notes) == nil then notes = nil end
    self:action(function() self:change("notes", k, notes) end)
end

-- Remove the automatic X marks a placed person put on their row and column,
-- keeping hand-made X marks and squares still crossed by someone else.
function Game:clearAutoMarks(i)
    local pos = self.state.placed[i]
    if not pos then return end
    local p, r, c = self.puzzle, pos[1], pos[2]
    local function covered(rr, cc)
        for j, q in pairs(self.state.placed) do
            if j ~= i and (q[1] == rr or q[2] == cc) then return true end
        end
    end
    local function un(rr, cc)
        local k = rr .. "," .. cc
        if self.state.marks[k] == "auto" and not covered(rr, cc) then self:change("marks", k, nil) end
    end
    for cc = 1, p.w do un(r, cc) end
    for rr = 1, p.h do un(rr, c) end
end

-- Place suspect i on (r, c). The rest of their row and column get real X
-- marks (undoable along with the placement). The selection is cleared.
function Game:place(i, r, c)
    local p = self.puzzle
    local k = r .. "," .. c
    local who = self:occupantAt(r, c)
    self.selected = nil
    if who == i then
        -- holding your own square again takes the person back off the board
        self:action(function() self:clearAutoMarks(i); self:change("placed", i, nil) end)
        return
    end
    self:action(function()
        if who then self:clearAutoMarks(who); self:change("placed", who, nil) end
        self:clearAutoMarks(i)
        self:change("placed", i, { r, c })
        self:change("marks", k, nil)
        self:change("notes", k, nil)
        local function cross(rr, cc)
            local mk = rr .. "," .. cc
            if (rr ~= r or cc ~= c) and Puzzle.standable(p, rr, cc) and not self:occupantAt(rr, cc)
                    and not self.state.marks[mk] then
                self:change("marks", mk, "auto")
            end
        end
        for cc = 1, p.w do cross(r, cc) end
        for rr = 1, p.h do cross(rr, c) end
    end)
end

function Game:onCellTap(r, c)
    if self.state.solved then return end
    local p = self.puzzle
    if p.cells[r][c].void then return end
    local who = self:occupantAt(r, c)

    if self.tool == "erase" then return self:erase(r, c) end
    if self.tool == "mark" then return self:toggleMark(r, c) end

    if who then
        -- tapping someone on the board selects them (hold elsewhere to move)
        self:select(self.selected ~= who and who or nil)
        return
    end
    if not Puzzle.standable(p, r, c) then
        UIManager:show(InfoMessage:new{ text = "You can't stand here.", timeout = 1 })
        return
    end
    if self.selected then
        self:toggleNote(self.selected, r, c)
    else
        self:toggleMark(r, c)
    end
end

function Game:onCellHold(r, c)
    local p = self.puzzle
    if self.selected and not self.state.solved and not self.tool
            and Puzzle.standable(p, r, c) then
        return self:place(self.selected, r, c)
    end
    self:showCellCard(r, c)
end

function Game:showCellCard(r, c)
    local x, y = self.board:cellRect(r, c)
    local who = self:occupantAt(r, c)
    Cards.showCellCard(self.puzzle, r, c, { x = x, y = y, w = self.board.cell, h = self.board.cell },
        who and self.puzzle.suspects[who])
end

-- Squares the selected suspect's clue refers to (an option, on by default).
function Game:updateHighlight()
    self.highlight = nil
    if self.options.highlight and self.selected and not self.state.solved then
        local ok, set = pcall(Parse.cells, self.puzzle, self.selected, self.state.placed)
        if ok then self.highlight = set end
    end
end

function Game:onCellsSwipe(cells)
    if self.state.solved then return end
    local p = self.puzzle
    -- if every empty square on the line is already crossed, uncross them instead
    local all_marked = true
    for _, rc in ipairs(cells) do
        local k = rc[1] .. "," .. rc[2]
        if Puzzle.standable(p, rc[1], rc[2]) and not self:occupantAt(rc[1], rc[2]) and not self.state.marks[k] then
            all_marked = false
        end
    end
    self:action(function()
        for _, rc in ipairs(cells) do
            local k = rc[1] .. "," .. rc[2]
            if Puzzle.standable(p, rc[1], rc[2]) and not self:occupantAt(rc[1], rc[2]) then
                self:change("marks", k, (not all_marked) or nil)
            end
        end
    end)
end

-- Checking --------------------------------------------------------------------

function Game:check(auto)
    local p = self.puzzle
    if not p.has_solution then
        UIManager:show(InfoMessage:new{ text = "This case has no solution data, so it can't be checked." })
        return
    end
    local res = Puzzle.check(p, self.state.placed)
    if res.solved then
        if not self.state.solved then
            self:bankTime()
            self.state.solved = true
            -- a clean final board: no notes, no X marks
            self.state.marks = {}
            self.state.notes = {}
            self.selected = nil
            self.tool = nil
            self.highlight = nil
            self:save()
        end
        self:updateTitle()
        self:updateClue()
        self:refresh()
        local m = p.murderer and p.suspects[p.murderer]
        local v = p.suspects[p.victim]
        UIManager:show(InfoMessage:new{
            text = string.format("Case closed!\n\n%s was alone with %s.\n%s is the murderer!\n\nTime: %s",
                m and m.name or "?", v.name, m and m.name or "?", fmtTime(self.state.elapsed)),
        })
        return
    end
    local conflicts = 0
    for _ in pairs(self.conflicts) do conflicts = conflicts + 1 end
    if auto then
        UIManager:show(InfoMessage:new{
            text = "Everyone is placed, but something isn't right yet.\nTap Check to see who is misplaced.",
        })
        return
    end
    if res.placed == 0 then
        UIManager:show(InfoMessage:new{ text = "Place some suspects first.", timeout = 2 })
        return
    end
    self.wrong_cells = {}
    for _, i in ipairs(res.wrong) do
        local pos = self.state.placed[i]
        self.wrong_cells[pos[1] .. "," .. pos[2]] = true
    end
    self:refresh()
    local msg
    if #res.wrong == 0 then
        msg = string.format("So far so good: all %d placed suspects are in the right spot.", res.placed)
    else
        msg = string.format("%d of %d placed suspects %s in the wrong spot (marked with !).",
            #res.wrong, res.placed, #res.wrong == 1 and "is" or "are")
    end
    if conflicts > 0 then
        msg = msg .. "\n\nSome suspects share a row or column."
    end
    UIManager:show(InfoMessage:new{ text = msg })
end

-- Menu ------------------------------------------------------------------------

function Game:showAllClues()
    local p = self.puzzle
    local lines = {}
    if p.general_clues and #p.general_clues > 0 then
        local g = {}
        for _, t in ipairs(p.general_clues) do table.insert(g, "• " .. t) end
        table.insert(lines, "General clues (apply to everyone)\n" .. table.concat(g, "\n"))
    end
    for i, s in ipairs(p.suspects) do
        local pos = self.state.placed[i]
        local label = s.name:sub(1, 1):upper() == s.letter and s.name or (s.letter .. " · " .. s.name)
        table.insert(lines, string.format("%s%s%s\n%s", label,
            s.is_victim and " (victim)" or (s.female and " (woman)" or " (man)"),
            pos and string.format("  [R%d C%d]", pos[1], pos[2]) or "",
            s.clue))
    end
    local areas = {}
    for _, room in pairs(p.rooms) do table.insert(areas, room.name) end
    table.sort(areas)
    table.insert(lines, "Areas: " .. table.concat(areas, ", "))
    UIManager:show(TextViewer:new{
        title = p.title .. " – Clues",
        text = table.concat(lines, "\n\n"),
    })
end

function Game:showHint()
    local p = self.puzzle
    if #p.hints == 0 then
        UIManager:show(InfoMessage:new{ text = "This case has no hints." })
        return
    end
    local function show()
        local n = math.min(self.state.hints_shown, #p.hints)
        local parts = {}
        for i = 1, n do table.insert(parts, string.format("Hint %d/%d\n%s", i, #p.hints, p.hints[i])) end
        UIManager:show(TextViewer:new{
            title = "Hints",
            text = table.concat(parts, "\n\n"),
        })
    end
    if self.state.hints_shown >= #p.hints then
        show()
        return
    end
    UIManager:show(ConfirmBox:new{
        text = string.format("Reveal hint %d of %d?", self.state.hints_shown + 1, #p.hints),
        ok_text = "Reveal",
        ok_callback = function()
            self.state.hints_shown = self.state.hints_shown + 1
            self:save()
            show()
        end,
    })
end

function Game:showQuickTips()
    UIManager:show(InfoMessage:new{
        text = "Quick tips\n\n"
            .. "• Tap a suspect, then tap squares to note where they might be.\n"
            .. "• Hold a square to place the selected suspect there.\n"
            .. "• With nobody selected, a tap crosses a square out.\n"
            .. "• Dark squares are obstacles: nobody can stand there.\n"
            .. "• Hold a square or a suspect for details.\n\n"
            .. "Full rules: Menu › How to play.",
    })
end

function Game:showMenu()
    local p = self.puzzle
    local dialog
    local function close() UIManager:close(dialog) end
    local function toggle(name)
        self.options[name] = not self.options[name]
        Store.setOption(name, self.options[name])
        close()
        self:refresh()
    end
    dialog = ButtonDialog:new{
        title = p.title,
        buttons = {
            { { text = "All clues", callback = function() close(); self:showAllClues() end },
              { text = string.format("Hint (%d/%d)", math.min(self.state.hints_shown, #p.hints), #p.hints),
                enabled = #p.hints > 0,
                callback = function() close(); self:showHint() end } },
            { { text = "How to play", callback = function()
                    close()
                    Html.show("How to play", Html.HOW_TO_PLAY)
                end },
              { text = string.format("Time: %s", fmtTime((self.state.elapsed or 0) + self:runningSpan())),
                enabled = false } },
            { { text = (self.options.highlight and "☑" or "☐") .. " Highlight clue squares",
                callback = function() toggle("highlight"); self:updateHighlight(); self:refresh() end },
              { text = (self.options.room_names and "☑" or "☐") .. " Show area names",
                callback = function() toggle("room_names") end } },
            { { text = (self.options.textures and "☑" or "☐") .. " Area textures",
                callback = function() toggle("textures") end },
              { text = "Quick tips", callback = function() close(); self:showQuickTips() end } },
            { { text = "Clear X marks & notes", callback = function()
                    close()
                    self:action(function()
                        for k in pairs(deepcopy(self.state.marks)) do self:change("marks", k, nil) end
                        for k in pairs(deepcopy(self.state.notes)) do self:change("notes", k, nil) end
                    end)
                end },
              { text = "Restart case", callback = function()
                    close()
                    UIManager:show(ConfirmBox:new{
                        text = "Clear the whole board and start this case again?",
                        ok_text = "Restart",
                        ok_callback = function()
                            self.state = { placed = {}, marks = {}, notes = {}, history = {},
                                solved = false, elapsed = 0, hints_shown = 0 }
                            self.started_at = Game.now()
                            self.selected = nil
                            self.tool = nil
                            self:afterChange()
                        end,
                    })
                end } },
            { { text = "Reveal solution", enabled = p.has_solution, callback = function()
                    close()
                    UIManager:show(ConfirmBox:new{
                        text = "Show the full solution? This fills in the board.",
                        ok_text = "Reveal",
                        ok_callback = function()
                            self.state.revealed = true
                            self:action(function()
                                for i, s in ipairs(p.suspects) do self:change("placed", i, { s.sol[1], s.sol[2] }) end
                            end)
                        end,
                    })
                end },
              { text = "Rotate screen", callback = function() close(); self:rotate() end } },
            { { text = "Back to cases", callback = function() close(); self:onClose() end } },
        },
    }
    UIManager:show(dialog)
end

-- Lifecycle -------------------------------------------------------------------

-- The clock only counts time spent playing. It runs on the monotonic clock,
-- which stops while the Kindle sleeps (wall-clock time kept counting if a
-- Suspend event went astray). Each stretch without a tap is also capped, so
-- a game left open on the screen doesn't run up the time.
local MAX_SPAN = 300
local ok_time, ktime = pcall(require, "ui/time")

local function now()
    if ok_time and ktime and ktime.monotonic then return ktime.to_s(ktime.monotonic()) end
    return os.time()
end
Game.now = now

function Game:runningSpan()
    if self.state.solved or self.paused then return 0 end
    local d = now() - (self.started_at or now())
    if d < 0 then return 0 end
    return math.floor(math.min(d, MAX_SPAN))
end

function Game:bankTime()
    self.state.elapsed = (self.state.elapsed or 0) + self:runningSpan()
    self.started_at = now()
end

function Game:save()
    self:bankTime()
    local s = deepcopy(self.state)
    -- string keys survive serialisation reliably
    local placed = {}
    for i, pos in pairs(s.placed) do placed[tostring(i)] = pos end
    s.placed = placed
    s.updated = os.time()
    Store.saveState(self.puzzle.id, s)
end

function Game:onClose()
    self:save()
    UIManager:close(self, "full")
    if self.on_close then self.on_close() end
    return true
end

function Game:onSuspend()
    self:save()
    self.paused = true
end

function Game:onResume()
    self.paused = false
    self.started_at = now()
end

function Game:onCloseWidget()
    UIManager:setDirty(nil, "full")
end

function Game:onShow()
    UIManager:setDirty(self, "full")
    if not Store.getOption("seen_quick_tips", false) then
        Store.setOption("seen_quick_tips", true)
        UIManager:nextTick(function() self:showQuickTips() end)
    end
end

return Game
