local pairs = pairs
local wtonumber = require 'w3xparser'.tonumber
local reference = require 'slk.lni_reference'

local keydata
local is_remove_same
local w2l
local default
local metadata
local references

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

local function default_value(tp)
    if tp == 0 then
        return 0
    elseif tp == 1 or tp == 2 then
        return 0
    elseif tp == 3 then
        return ''
    end
end

local function is_same(a, b, meta)
    if meta and meta.type ~= 3 then
        a = a and wtonumber(a)
        b = b and wtonumber(b)
    end
    return a == b
end

local function remove_same_as_slk(meta, key, data, default, obj, ttype)
    local dest = default[key]
    if meta.reforge then
        dest = obj[meta.reforge] or dest
    end
    if type(dest) == 'table' then
        local new_data = {}
        if data then
            for i = 1, #data do
                local default
                if i > #dest then
                    default = dest[#dest]
                else
                    default = dest[i]
                end
                if not is_same(data[i], default, meta) then
                    new_data[i] = data[i]
                end
            end
        end
        if not next(new_data) then
            obj[key] = nil
            return
        end
        if is_remove_same then
            obj[key] = new_data
        end
    else
        if data == dest then
            obj[key] = nil
        elseif data == nil then
            obj[key] = default_value(meta.type)
        end
    end
end

local function remove_same_as_txt(meta, key, data, default, obj, ttype)
    local dest = default[key]
    if meta and meta.reforge then
        dest = obj[meta.reforge] or dest
    end
    if type(dest) == 'table' then
        local new_data = {}
        if meta and meta.appendindex then
            if data then
                for i = 1, #data do
                    if not is_same(data[i], dest[i] or '', meta) then
                        new_data[i] = data[i]
                    end
                end
            end
        else
            local valued
            if data then
                for i = #data, 1, -1 do
                    if dest[i] == nil then
                        if valued or (not is_same(data[i], data[i-1], meta)) then
                            new_data[i] = data[i]
                            valued = true
                        end
                    elseif not is_same(data[i], dest[i], meta) then
                        new_data[i] = data[i]
                        valued = true
                    end
                end
            end
        end
        if not next(new_data) then
            obj[key] = nil
            return
        end
        if is_remove_same then
            obj[key] = new_data
        end
    else
        if is_same(data, dest, meta) then
            obj[key] = nil
        elseif data == nil and meta then
            obj[key] = default_value(meta.type)
        end
    end
end

local function is_same_as_reforge(a, b, meta)
    if b == nil then
        -- reforge 字段为 nil 说明使用 a 的值
        return true
    end
    if type(b) == 'table' then
        for i = 1, #b do
            if not is_same(a[i], b[i], meta) then
                return false
            end
        end
        return true
    else
        return is_same(a, b, meta)
    end
end

local function preserve_skin_values(obj, ttype)
    local fields = {}
    for _, field in ipairs(obj._skin_fields or {}) do
        fields[field] = true
    end
    local values = {}
    local function save(metas)
        for key, meta in pairs(metas or {}) do
            local data = obj[key]
            if type(data) == 'table' then
                local levels = {}
                for level, value in pairs(data) do
                    if fields[meta.id .. ':' .. level] then
                        levels[level] = value
                    end
                end
                if next(levels) then
                    values[key] = levels
                end
            elseif data ~= nil and fields[meta.id .. ':1'] then
                values[key] = data
            end
        end
    end
    save(metadata[ttype])
    save(metadata[obj._code])
    return values
end

local function clean_obj(obj, ttype, default)
    local parent = obj._parent
    local default = default[parent]
    if not default then
        return
    end
    local skin_values = obj._skin_version and preserve_skin_values(obj, ttype)
    for key, meta in sortpairs(metadata[ttype]) do
        local data = obj[key]
        if meta.profile then
            remove_same_as_txt(meta, key, data, default, obj, ttype)
        else
            remove_same_as_slk(meta, key, data, default, obj, ttype)
        end
    end
    if metadata[obj._code] then
        for key, meta in pairs(metadata[obj._code]) do
            local data = obj[key]
            if meta.profile then
                remove_same_as_txt(meta, key, data, default, obj, ttype)
            else
                remove_same_as_slk(meta, key, data, default, obj, ttype)
            end
        end
    end
    -- 如果 art, art:hd, art:sd 中任意一项有变化，且他们的值
    -- 完全相同，则将变化挪到 art 上
    if w2l:isreforge() then
        for key, meta in pairs(metadata[ttype]) do
            local datahd = obj[key..':hd']
            local datasd = obj[key..':sd']
            if datahd or datasd then
                local def = obj[key] or default[key]
                if is_same_as_reforge(def, datahd, meta)
                and is_same_as_reforge(def, datasd, meta) then
                    obj[key] = datahd
                    obj[key..':hd'] = nil
                    obj[key..':sd'] = nil
                end
            end
        end
    end
    -- An explicit skin value equal to the stock value can still override a
    -- different value in the main object file. Preserve that precedence.
    for key, value in pairs(skin_values or {}) do
        if type(value) == 'table' then
            obj[key] = obj[key] or {}
            for level, data in pairs(value) do
                obj[key][level] = data
            end
        else
            obj[key] = value
        end
    end
end

-- Keep only editable field values, independent of arrays that cleanup may
-- replace or modify while restoring skin precedence. Capture one object at a
-- time so unchanged stock objects do not retain a second expanded dataset.
local function copy_value(value)
    if type(value) ~= 'table' then
        return value
    end
    local result = {}
    for key, item in pairs(value) do
        result[key] = copy_value(item)
    end
    return result
end

local function capture_reference(obj, ttype)
    if not references then
        return
    end
    local values = {}
    local function capture(metas)
        for key, meta in pairs(metas or {}) do
            if reference.is_field(key, meta) and obj[key] ~= nil then
                values[key] = copy_value(obj[key])
            end
        end
    end
    capture(metadata[ttype])
    capture(metadata[obj._code])
    return values
end

local function has_editable_value(value)
    if not value then
        return false
    end
    if type(value) ~= 'table' then
        return true
    end
    for key in pairs(value) do
        if type(key) == 'number' and key > 0 then
            return true
        end
    end
    return false
end

local function keep_reference(ttype, id, obj, values)
    if not values then
        return
    end
    local enabled = id ~= obj._parent or obj._object_version == 3
        or obj._skin_version or obj._object_extras or obj._skin_extras
    local function check(metas)
        for key, meta in pairs(metas or {}) do
            if reference.is_field(key, meta) then
                enabled = enabled or has_editable_value(obj[key])
            end
        end
    end
    check(metadata[ttype])
    check(metadata[obj._code])
    if enabled then
        references[ttype] = references[ttype] or {}
        references[ttype][id] = values
    end
end

local function clean_objs(type, t, check_keep)
    if not t then
        return
    end
    for id, obj in sortpairs(t) do
        if not check_keep or obj._keep_obj then
            local values = capture_reference(obj, type)
            clean_obj(obj, type, default[type])
            keep_reference(type, id, obj, values)
        end
    end
end

local function clean_txt(type, t)
    if not t then
        return
    end
    for id, obj in sortpairs(t) do
        local values = references and {}
        if values then
            for key, value in pairs(obj) do
                if key:sub(1, 1) ~= '_' then
                    values[key] = copy_value(value)
                end
            end
        end
        local default = default[type][id]
        if default then
            for key, data in pairs(obj) do
                remove_same_as_txt(nil, key, data, default, obj, type)
            end
        end
        if values then
            for key, value in pairs(obj) do
                if key:sub(1, 1) ~= '_' and has_editable_value(value) then
                    references[type] = references[type] or {}
                    references[type][id] = values
                    break
                end
            end
        end
    end
end

local function clean_misc(type, t)
    if not t then
        return
    end
    for name in pairs(default[type]) do
        if t[name] and (t[name]._source ~= 'slk' or w2l.setting.mode ~= 'slk') then
            local values = capture_reference(t[name], type)
            clean_obj(t[name], type, default[type])
            keep_reference(type, name, t[name], values)
        end
    end
end

local function clean_txt_keys(slk)
    for i, type in ipairs {'ability', 'buff', 'unit', 'item', 'upgrade', 'doodad', 'destructable'} do
        local metas = metadata[type]
        local removeKeys = {}
        for _, meta in pairs(metas) do
            removeKeys[meta.key] = true
        end
        for id in pairs(slk[type]) do
            local txtObj = slk.txt[id:lower()]
            if txtObj then
                for k in pairs(txtObj) do
                    if removeKeys[k] then
                        txtObj[k] = nil
                    end
                end
            end
            local values = references and references.txt and references.txt[id:lower()]
            if values then
                -- These fields are represented in the object INI, not txt.ini.
                for k in pairs(values) do
                    if removeKeys[k] then
                        values[k] = nil
                    end
                end
            end
        end
    end
end

return function (w2l_, slk)
    w2l = w2l_
    keydata = w2l:keydata()
    default = w2l:get_default()
    is_remove_same = w2l.setting.remove_same
    metadata = w2l:metadata()
    references = w2l.setting.mode == 'lni' and w2l.setting.show_inherited_fields and {} or nil
    if w2l.setting.mode == 'slk' then
        for i, type in ipairs {'ability', 'buff', 'unit', 'item', 'upgrade', 'doodad', 'destructable'} do
            clean_objs(type, slk[type], true)
            w2l.progress(i / 8)
        end
    else
        for i, type in ipairs {'ability', 'buff', 'unit', 'item', 'upgrade', 'doodad', 'destructable'} do
            clean_objs(type, slk[type], false)
            w2l.progress(i / 8)
        end
        local type = 'txt'
        clean_txt(type, slk[type])
    end
    local type = 'misc'
    clean_misc(type, slk[type])

    clean_txt_keys(slk)

    w2l.progress(1)
    return references
end
