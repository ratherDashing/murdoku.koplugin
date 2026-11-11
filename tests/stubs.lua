--[[--
KOReader stubs for loading the plugin's modules outside KOReader.

require("tests/stubs").apply("/tmp/murdoku-test")   -- datadir for Store
--]]
return {
    apply = function(testdir)
        package.path = (debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./")
            .. "../?.lua;" .. package.path

        package.preload["datastorage"] = function()
            return { getDataDir = function() return testdir end }
        end

        package.preload["luasettings"] = function()
            local data = {}
            local LuaSettings = {}
            function LuaSettings:open() return self end
            function LuaSettings:readSetting(k) return data[k] end
            function LuaSettings:saveSetting(k, v) data[k] = v end
            function LuaSettings:delSetting(k) data[k] = nil end
            function LuaSettings:flush() end
            return LuaSettings
        end

        package.preload["libs/libkoreader-lfs"] = function()
            return {
                attributes = function() return nil end,
                dir = function() return function() end end,
                mkdir = function() end,
            }
        end

        package.preload["logger"] = function()
            return { warn = function() end, err = function() end, info = function() end }
        end

        package.preload["util"] = function()
            return { makePath = function(p) os.execute("mkdir -p '" .. p .. "'") end }
        end

        -- Minimal JSON decoder (KOReader bundles its own; the store falls back
        -- to require("json") when rapidjson is unavailable).
        package.preload["json"] = function()
            local parse
            local function skip(str, i)
                while true do
                    local c = str:sub(i, i)
                    if c == " " or c == "\t" or c == "\n" or c == "\r" then i = i + 1
                    else return i end
                end
            end
            local function parse_string(str, i)
                i = i + 1
                local out = {}
                while true do
                    local c = str:sub(i, i)
                    if c == "" then error("unterminated string") end
                    if c == '"' then return table.concat(out), i + 1 end
                    if c == "\\" then
                        local e = str:sub(i + 1, i + 1)
                        local rep = e == "n" and "\n" or e == "t" and "\t"
                            or e == "r" and "\r" or e
                        out[#out + 1] = rep
                        i = i + 2
                    else
                        out[#out + 1] = c
                        i = i + 1
                    end
                end
            end
            parse = function(str, i)
                i = skip(str, i)
                local c = str:sub(i, i)
                if c == "{" then
                    local obj = {}
                    i = skip(str, i + 1)
                    if str:sub(i, i) == "}" then return obj, i + 1 end
                    while true do
                        local k
                        k, i = parse_string(str, skip(str, i))
                        i = skip(str, i + 1) -- skip ':'
                        obj[k], i = parse(str, i)
                        i = skip(str, i)
                        if str:sub(i, i) == "," then i = i + 1 else return obj, i + 1 end
                    end
                elseif c == "[" then
                    local arr = {}
                    i = skip(str, i + 1)
                    if str:sub(i, i) == "]" then return arr, i + 1 end
                    while true do
                        arr[#arr + 1], i = parse(str, i)
                        i = skip(str, i)
                        if str:sub(i, i) == "," then i = i + 1 else return arr, i + 1 end
                    end
                elseif c == '"' then
                    return parse_string(str, i)
                elseif str:sub(i, i + 3) == "true" then
                    return true, i + 4
                elseif str:sub(i, i + 3) == "fals" then
                    return false, i + 5
                elseif str:sub(i, i + 3) == "null" then
                    return nil, i + 4
                else
                    local j = i
                    while str:sub(j + 1, j + 1):find("[-+.0-9eE]") do j = j + 1 end
                    return tonumber(str:sub(i, j)), j + 1
                end
            end
            return { decode = function(str) return parse(str, 1) end }
        end
    end,
}
