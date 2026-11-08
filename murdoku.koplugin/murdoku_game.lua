--[[--
The Murdoku game screen.

Finger-friendly controls (no stylus needed):
  * Tap a suspect chip to select them.
  * Place mode: tap a square to put the selected suspect there; tap it again to remove.
  * Mark mode: tap a square to toggle an X.
  * Note mode: tap a square to pencil the selected suspect's letter in as a candidate.
  * Swipe across squares (any mode) to X out a whole line at once.
  * Hold a square to see what's there; hold a chip to read that suspect's clue.
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
local Screen = Device.screen

local RULES = [[
Goal
Place every character on the crime scene, then reveal the killer. The murderer was alone with the victim (in the same area).

Rules
• Exactly one person per row and per column.
• Nobody can stand on obstacles (tables, trees, plants…). These are shown as dark grey blocks. Chairs, beds and carpets are fine.
• "Beside" means directly left, right, above or below AND in the same area.
• North/south/east/west mean anywhere above/below/right/left, in any area.
• Areas are outlined with thick walls and shaded in different greys.
• Some cases also have general clues that apply to everyone. They are shown in the clue box when no suspect is selected, and at the top of "All clues".
• Big objects (cars, beds, buses…) cover more than one square. Standing on any of its squares counts as being on it.

Controls
• Tap a suspect at the bottom to select them and read their clue.
• Place: tap a square to put the selected suspect there. Tap them again to remove them.
• Mark: tap a square to cross it out (X).
• Note: tap a square to pencil in the selected suspect's letter as a possibility.
• Swipe across a row or column of squares to cross them all out.
• Hold a square to see the area and object in it. Hold a suspect to read their clue.
• With nothing selected, tapping a square in Place mode crosses it out.
• Dotted squares are in the same row or column as someone you have already placed.

About
Murdoku is created by Manuel Garand – play more and get the books at https://murdoku.com
This plugin is an unofficial fan project and is not affiliated with or endorsed by Murdoku.
]]

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
        auto_shade = Store.getOption("auto_shade", true),
        room_names = Store.getOption("room_names", true),
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
    self.mode = "place"
    self.selected = nil
    self.started_at = os.time()
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
        title = p.title,
        subtitle = subtitle,
        with_bottom_line = true,
        left_icon = "appbar.menu",
        left_icon_tap_callback = function() self:showMenu() end,
        close_callback = function() self:onClose() end,
    }

    self.landscape = sw > sh
    self.built_w, self.built_h = sw, sh
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.clue_face = Font:getFace("cfont", 19)
    local line_h = self.clue_face.ftsize:getHeightAndAscender()
    local body_h = sh - self.title_bar:getHeight() - margin

    local function makeButtons(width, rows)
        local mode_row = {
            { id = "place", text = self:modeLabel("place"), callback = function() self:setMode("place") end },
            { id = "mark", text = self:modeLabel("mark"), callback = function() self:setMode("mark") end },
            { id = "note", text = self:modeLabel("note"), callback = function() self:setMode("note") end },
        }
        local action_row = {
            { id = "undo", text = "Undo", callback = function() self:undo() end },
            { id = "check", text = "Check", callback = function() self:check() end },
        }
        local buttons
        if rows == 2 then
            buttons = { mode_row, action_row }
        else
            buttons = { mode_row }
            for _, b in ipairs(action_row) do table.insert(buttons[1], b) end
        end
        return ButtonTable:new{ width = width, buttons = buttons, zero_sep = true, show_parent = self }
    end

    local content
    if not self.landscape then
        -- Portrait: board on top, suspects / clue / buttons underneath.
        local w = sw - 2 * margin
        self.button_table = makeButtons(w, 1)
        self.suspect_bar = Widgets.SuspectBar:new{ puzzle = p, game = self, width = w }
        self.clue_height = math.floor(line_h * 3 + Size.padding.default)
        self:makeClueBox(w)
        local board_h = body_h - self.button_table:getSize().h - self.suspect_bar.dimen.h
            - self.clue_height - 3 * margin
        self.board = Widgets.Board:new{ puzzle = p, game = self, width = w, height = board_h }
        content = VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = margin },
            CenterContainer:new{ dimen = Geom:new{ w = sw, h = board_h }, self.board },
            self.suspect_bar,
            VerticalSpan:new{ width = margin },
            self.clue_box,
            VerticalSpan:new{ width = margin },
            self.button_table,
        }
    else
        -- Landscape: board on the left, a control panel on the right.
        local panel_min = math.max(math.floor(sw * 0.32), Screen:scaleBySize(240))
        local board_h = body_h - margin
        self.board = Widgets.Board:new{
            puzzle = p, game = self,
            width = sw - panel_min - 3 * margin,
            height = board_h,
        }
        local panel_w = sw - self.board.dimen.w - 3 * margin
        self.button_table = makeButtons(panel_w, 2)
        self.suspect_bar = Widgets.SuspectBar:new{ puzzle = p, game = self, width = panel_w }
        self.clue_height = body_h - self.button_table:getSize().h - self.suspect_bar.dimen.h - 3 * margin
        self.clue_height = math.max(self.clue_height, math.floor(line_h * 2))
        self:makeClueBox(panel_w)
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
                self.suspect_bar,
                VerticalSpan:new{ width = margin },
                self.clue_box,
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

function Game:makeClueBox(width)
    self.clue_box = InputContainer:new{
        dimen = Geom:new{ w = width, h = self.clue_height },
    }
    self.clue_box.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = function() return self.clue_box.dimen end } },
    }
    self.clue_box.onTap = function()
        self:showAllClues()
        return true
    end
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

function Game:modeLabel(mode)
    local names = { place = "Place", mark = "Mark ✕", note = "Note" }
    if self.mode == mode then return "● " .. names[mode] end
    return names[mode]
end

function Game:setMode(mode)
    self.mode = mode
    for _, m in ipairs({ "place", "mark", "note" }) do
        local b = self.button_table:getButtonById(m)
        b:setText(self:modeLabel(m), b.width)
    end
    self:updateClue()
    self:refresh()
end

function Game:updateClue()
    local p = self.puzzle
    local text
    if self.state.solved then
        local m = p.murderer and p.suspects[p.murderer]
        text = "Case closed" .. (m and (": " .. m.name .. " is the murderer!") or "!")
            .. "  (tap here for all clues)"
    elseif self.selected then
        local s = p.suspects[self.selected]
        text = string.format("%s · %s: %s", s.letter, s.name, s.clue)
    elseif p.general_clues and #p.general_clues > 0 then
        text = "General clue" .. (#p.general_clues > 1 and "s" or "") .. ": "
            .. table.concat(p.general_clues, " ") .. "  (tap here for all clues)"
    elseif self.mode == "mark" then
        text = "Mark mode: tap squares to cross them out. Tap a suspect to read their clue."
    else
        text = "Tap a suspect, then tap a square to place them. Hold a square to see what's there. Tap here for all clues."
    end
    self.clue_box[1] = FrameContainer:new{
        width = self.clue_box.dimen.w,
        height = self.clue_height,
        padding = Size.padding.small,
        bordersize = Size.border.thin,
        color = Blitbuffer.COLOR_DARK_GRAY,
        TextBoxWidget:new{
            text = text,
            face = self.clue_face,
            width = self.clue_box.dimen.w - 2 * Size.padding.small - 2 * Size.border.thin,
            height = self.clue_height - 2 * Size.padding.small - 2 * Size.border.thin,
            height_overflow_show_ellipsis = true,
        },
    }
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
    self:updateClue()
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
        if self.mode == "mark" then self.mode = "place"; self:setMode("place") end
    end
    self:updateClue()
    self:refresh()
end

function Game:onSuspectHold(i)
    local s = self.puzzle.suspects[i]
    local pos = self.state.placed[i]
    local where = pos and string.format("\n\nPlaced at row %d, column %d.", pos[1], pos[2]) or ""
    UIManager:show(InfoMessage:new{
        text = string.format("%s · %s%s\n\n%s%s", s.letter, s.name,
            s.is_victim and " (the victim)" or (s.female and " (woman)" or " (man)"), s.clue, where),
    })
end

function Game:onCellTap(r, c)
    if self.state.solved then return end
    local p = self.puzzle
    local cell = p.cells[r][c]
    if cell.void then return end
    local k = r .. "," .. c
    local who = self:occupantAt(r, c)

    if self.mode == "mark" or (self.mode == "place" and not self.selected and not who) then
        if who or not Puzzle.standable(p, r, c) then return end
        self:action(function() self:change("marks", k, not self.state.marks[k] or nil) end)
        return
    end

    if self.mode == "note" then
        if not self.selected then
            UIManager:show(InfoMessage:new{ text = "Select a suspect first, then tap squares to note where they might be.", timeout = 3 })
            return
        end
        if who then return end
        local notes = deepcopy(self.state.notes[k] or {})
        notes[self.selected] = not notes[self.selected] or nil
        if next(notes) == nil then notes = nil end
        self:action(function() self:change("notes", k, notes) end)
        return
    end

    -- place mode
    if who then
        if self.selected == who then
            self:action(function() self:change("placed", who, nil) end)
        else
            -- tapping someone already placed selects them (so you can move them)
            self.selected = who
            self:updateClue()
            self:refresh()
        end
        return
    end
    if not Puzzle.standable(p, r, c) then
        local o = Puzzle.objectInfo(cell.obj)
        UIManager:show(InfoMessage:new{
            text = string.format("Nobody can be on the %s.", o and o.name:lower() or "obstacle"),
            timeout = 2,
        })
        return
    end
    self:action(function()
        self:change("placed", self.selected, { r, c })
        self:change("marks", k, nil)
    end)
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

function Game:onCellHold(r, c)
    local p = self.puzzle
    local text = Puzzle.describe(p, r, c)
    local who = self:occupantAt(r, c)
    if who then
        local s = p.suspects[who]
        text = text .. string.format("\n\nPlaced here: %s · %s", s.letter, s.name)
    end
    UIManager:show(InfoMessage:new{ text = text })
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
            self.state.solved = true
            self.state.elapsed = (self.state.elapsed or 0) + (os.time() - self.started_at)
            self.started_at = os.time()
            self.selected = nil
            self:save()
        end
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
        table.insert(lines, string.format("%s · %s%s%s\n%s", s.letter, s.name,
            s.is_victim and " (victim)" or (s.female and " (woman)" or " (man)"),
            pos and string.format("  [row %d, col %d]", pos[1], pos[2]) or "",
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
                    UIManager:show(TextViewer:new{ title = "How to play", text = RULES })
                end },
              { text = string.format("Time: %s", fmtTime((self.state.elapsed or 0)
                    + (self.state.solved and 0 or (os.time() - self.started_at)))),
                enabled = false } },
            { { text = (self.options.auto_shade and "☑" or "☐") .. " Dot blocked rows/cols",
                callback = function() toggle("auto_shade") end },
              { text = (self.options.room_names and "☑" or "☐") .. " Show area names",
                callback = function() toggle("room_names") end } },
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
                            self.started_at = os.time()
                            self.selected = nil
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

function Game:save()
    local s = deepcopy(self.state)
    if not s.solved then
        s.elapsed = (s.elapsed or 0) + (os.time() - self.started_at)
    end
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

function Game:onCloseWidget()
    UIManager:setDirty(nil, "full")
end

function Game:onShow()
    UIManager:setDirty(self, "full")
end

return Game
