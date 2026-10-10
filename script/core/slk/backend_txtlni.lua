
local lang = require 'lang'
local reference = require 'slk.lni_reference'

local function sortpairs(t)
    local sort = {}
    for k, v in pairs(t) do
        sort[#sort+1] = {k, v}
    end
    table.sort(sort, function (a, b)
        return a[1] < b[1]
    end)
    local n = 1
    return function()
        local v = sort[n]
        if not v then
            return
        end
        n = n + 1
        return v[1], v[2]
    end
end

local function format_value(value, is_reference)
    if tonumber(value) then
        return tostring(value)
    elseif type(value) == 'string' then
        if is_reference then
            return ('%q'):format(value):gsub('\n', 'n')
        end
        if value:match '[\n\r]' then
            return ('[=[\r\n%s]=]'):format(value)
        else
            return ('%q'):format(value)
        end
    end
end

local function maxindex(t)
    local i = 0
    for k in pairs(t) do
        i = math.max(i, k)
    end
    return i
end

local function write_data(f, k, v, is_reference)
    if k:find '[^%w_]' then
        k = ('%q'):format(k)
    end
    if type(v) == 'table' then
        local l = {}
        for i = 1, maxindex(v) do
            l[i] = format_value(v[i], is_reference) or ''
        end
        if #l == 0 then
            return
        elseif#l == 1 then
            f[#f+1] = ('%s = %s'):format(k, l[1])
        else
            f[#f+1] = ('%s = {%s}'):format(k, table.concat(l, ', '))
        end
    else
        f[#f+1] = ('%s = %s'):format(k, format_value(v, is_reference))
    end
end

local function is_enable(obj)
    for key, value in pairs(obj) do
        if key:sub(1, 1) ~= '_' then
            if type(value) == 'table' then
                if next(value) then
                    return true
                end
            else
                return true
            end
        end
    end
    return false
end

return function (w2l, t, references)
    if not t then
        return
    end
    local f = {}
    for i, o in sortpairs(t) do
        if is_enable(o) then
            f[#f+1] = ('[%s]'):format(i)
            for k, v in sortpairs(o) do
                if k:sub(1, 1) ~= '_' then
                    write_data(f, k, v)
                end
            end
            if w2l.setting.mode == 'lni' and w2l.setting.show_inherited_fields then
                f[#f+1] = reference.header(w2l, i)
                for key, value in sortpairs(references and references[i] or {}) do
                    local active = o[key]
                    local partial = false
                    if type(active) == 'table' and type(value) == 'table' then
                        for index, item in pairs(value) do
                            if item ~= active[index] then
                                partial = true
                                break
                            end
                        end
                    end
                    if active == nil or partial then
                        local lines = {}
                        local ok = pcall(write_data, lines, key, value, true)
                        if ok and #lines > 0 then
                            if partial then
                                f[#f+1] = reference.comment(lang.script.LNI_REFERENCE_ARRAY)
                            end
                            for _, line in ipairs(lines) do
                                f[#f+1] = reference.comment(line)
                            end
                        else
                            f[#f+1] = reference.comment(lang.script.LNI_VALUE_UNAVAILABLE:format(key))
                        end
                    end
                end
            end
            f[#f+1] = ''
        end
    end
    return #f > 0 and table.concat(f, '\r\n')
end
