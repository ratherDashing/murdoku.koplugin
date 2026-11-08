--[[--
A full-screen, scrollable HTML page (How to play, About) with a title bar.
Rendered by MuPDF through ScrollHtmlWidget, so it gets real paragraphs,
headings and bold text instead of choppy plain-text lines.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local CSS = [[
@page { margin: 0; }
body { margin: 0; padding: 0; line-height: 1.3; text-align: left; }
h2 { font-size: 1.15em; font-weight: bold; margin: 0.9em 0 0.3em 0; border-bottom: 1px solid black; }
h2:first-child { margin-top: 0.2em; }
p { margin: 0.35em 0; text-indent: 0; }
ul { margin: 0.2em 0 0.4em 0; padding-left: 1.2em; }
li { margin: 0.25em 0; }
ul ul { margin: 0.15em 0; }
.ex { font-style: italic; }
.small { font-size: 0.85em; }
.box { border: 1px solid black; padding: 0.3em 0.5em; margin: 0.5em 0; }
a { color: black; text-decoration: underline; }
]]

local HtmlPage = InputContainer:extend{
    title = "",
    html = "",
    covers_fullscreen = true,
    on_link = nil,   -- function(uri)
}

function HtmlPage:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    local tb = TitleBar:new{
        width = sw,
        fullscreen = true,
        title = self.title,
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
    }
    local pad = Size.padding.large
    local h = sh - tb:getHeight() - 2 * pad
    local w = sw - 2 * pad
    self.scroll = ScrollHtmlWidget:new{
        html_body = self.html,
        css = CSS,
        default_font_size = Screen:scaleBySize(19),
        width = w,
        height = h,
        dialog = self,
        html_link_tapped_callback = function(link)
            local uri = link and link.uri
            if uri and self.on_link then self.on_link(uri) end
        end,
    }
    self[1] = FrameContainer:new{
        width = sw, height = sh, padding = 0, margin = 0, bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            tb,
            FrameContainer:new{ padding = pad, bordersize = 0, self.scroll },
        },
    }
end

function HtmlPage:onClose()
    UIManager:close(self, "full")
    return true
end

function HtmlPage:onShow()
    UIManager:setDirty(self, "full")
end

-- Show a link as a QR code (KOReader can't open a browser on most e-readers).
local function showLink(uri)
    local ok, QRMessage = pcall(require, "ui/widget/qrmessage")
    if ok and QRMessage then
        UIManager:show(QRMessage:new{ text = uri, width = Screen:getWidth() * 0.7, height = Screen:getWidth() * 0.7 })
    else
        UIManager:show(require("ui/widget/infomessage"):new{ text = uri })
    end
end

local M = {}

function M.show(title, html)
    UIManager:show(HtmlPage:new{ title = title, html = html, on_link = showLink })
end

M.HtmlPage = HtmlPage

M.HOW_TO_PLAY = [[
<h2>The goal</h2>
<p>Someone has been murdered. Work out where every person was standing, then you'll know who did it.</p>
<p>The murderer is the one person who was <b>alone with the victim</b>: the victim's area holds exactly two people, the victim and the murderer.</p>

<h2>The grid</h2>
<ul>
<li>Each <b>row</b> has exactly one person, and each <b>column</b> has exactly one person. So when you place someone, the rest of their row and column get crossed out for you.</li>
<li>The map is split into <b>areas</b> (rooms, gardens, lakes…) by thick walls.</li>
<li>An area can be empty, unless a general clue says otherwise ("No area was empty").</li>
<li>Rows are labelled <b>R1, R2…</b> down the side and columns <b>C1, C2…</b> across the top.</li>
</ul>

<h2>Where people can stand</h2>
<ul>
<li><b>Dark squares</b> are obstacles (tables, trees, shelves…). Nobody can stand there.</li>
<li><b>Light squares</b> are fine: empty floor, carpets, and things you can stand, sit or lie on (chairs, beds, cars, boats…).</li>
<li>Big things (a car, a bed, a bus) cover two or more squares. Standing on any one of them counts as being on it.</li>
</ul>

<h2>Reading the clues</h2>
<ul>
<li><b>"in the Kitchen"</b>: on any square of the Kitchen.</li>
<li><b>"on a chair" / "in a car"</b>: standing on that object's square.</li>
<li><b>"beside the table"</b>: directly left, right, above or below a table square, <b>and in the same area as it</b>. Diagonals don't count, and a table on the other side of a wall doesn't count.
<ul><li class="ex">Example: the table is at R3 C3 in the Kitchen. R3 C4 is beside it only if R3 C4 is also in the Kitchen.</li></ul></li>
<li><b>"north of Bella"</b>: in any row above Bella's row, in any column and any area. <b>South</b> = any row below; <b>west</b> = any column to the left; <b>east</b> = any column to the right.</li>
<li><b>"exactly one row north of Bella"</b>: in the row directly above Bella's row (in any column).</li>
<li><b>"in a corner of her area"</b>: her square has a wall or the map edge on two sides that touch, such as top and left. Walls between areas count, not just the map edge.</li>
<li><b>"alone"</b>: nobody else is in the same area.</li>
<li><b>"alone with Dan"</b>: exactly two people in the area, her and Dan.</li>
<li><b>"with Dan"</b>: Dan is in the same area (others may be too).</li>
<li><b>"not with Dan"</b>: Dan is in a different area.</li>
<li><b>"the only person on a chair"</b>: nobody else, the victim included, is on any chair anywhere.</li>
<li><b>"There was a woman in his area"</b>: at least one <i>other</i> person in his area is a woman.</li>
<li><b>General clues</b> (shown above the suspects) apply to everyone, the victim included.</li>
</ul>

<h2>Controls</h2>
<ul>
<li><b>Tap a suspect</b> to select them. Their clue cells are highlighted on the board (you can turn this off in the menu).</li>
<li>With a suspect selected, <b>tap a square</b> to pencil in a <b>note</b> (a small letter). Tap again to remove it.</li>
<li>With a suspect selected, <b>hold a square</b> to <b>place</b> them there (a big letter). The rest of their row and column are crossed out for you, and the selection is cleared.</li>
<li>With nobody selected, <b>tap a square</b> to cross it out with an <b>X</b>, or tap a placed person to select them again (hold another square to move them).</li>
<li><b>Swipe</b> across a row or column of squares to cross them all out.</li>
<li><b>Hold</b> a square to see what's there, or hold a suspect to read their clue in full.</li>
</ul>
<p>The toolbar under the board, from left to right:</p>
<ul>
<li><b>X</b>: mark mode. Every tap crosses a square out (or back in).</li>
<li><b>Eraser</b>: every tap clears a square: the person, the X and the notes.</li>
<li><b>Undo</b>: takes back the last action. There is no limit.</li>
<li><b>Lightbulb</b>: reveal the next hint.</li>
<li><b>Check</b>: shows whether the people you've placed are right.</li>
<li><b>Menu</b>: all clues, options, restart, reveal the solution, rotate.</li>
</ul>

<h2>Tips</h2>
<ul>
<li>Start with the clue that allows the fewest squares.</li>
<li>Use X marks on every square someone can't be on. Use notes for the two or three squares a person might be on.</li>
<li>If a guess leads to someone having nowhere to go, the guess was wrong.</li>
<li>The victim's clue is always the same: they were alone with the murderer. It often settles the last step.</li>
</ul>

<h2>About Murdoku</h2>
<p>Murdoku is created by Manuel Garand. Play more and get the books at murdoku.com. This plugin is an unofficial fan project and is not affiliated with or endorsed by Murdoku.</p>
]]

M.QUICK_TIPS = [[
<h2>Quick tips</h2>
<ul>
<li><b>Tap a suspect</b>, then <b>tap squares</b> to note where they might be.</li>
<li><b>Hold a square</b> to place the selected suspect there.</li>
<li>With nobody selected, a tap crosses a square out.</li>
<li><b>Dark squares</b> are obstacles: nobody can stand there.</li>
<li>Hold a square or a suspect for details.</li>
</ul>
<p>The full rules are under Menu &gt; How to play.</p>
]]

return M
