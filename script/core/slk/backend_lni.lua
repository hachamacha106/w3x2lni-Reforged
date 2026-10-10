local lang = require 'lang'
local convertreal = require 'convertreal'
local reference = require 'slk.lni_reference'
local table_insert = table.insert
local table_sort = table.sort
local math_type = math.type
local table_concat = table.concat
local string_char = string.char
local type = type
local os_clock = os.clock

local w2l
local metadata
local remove_unuse_object
local ttype
local str
local references

local function get_len(tbl)
    local n = 0
    for k in pairs(tbl) do
        if type(k) == 'number' and k > n then
            n = k
        end
    end
    return n
end

local function format_value(tp, value, is_reference)
    if value == nil then
        return 'nil'
    end
    if tp == 0 then
        return ('%d'):format(math.floor(value))
    elseif tp == 1 or tp == 2 then
        return convertreal(value)
    elseif tp == 3 then
        if is_reference then
            -- The pinned parser accepts decimal and newline escapes. A quoted
            -- reference preserves control bytes and cannot collide with a long
            -- string delimiter when the assignment is later uncommented.
            return ('%q'):format(value):gsub('\n', 'n')
        end
        value = w2l:get_editstring(value)
        if value:match '[\n\r]' then
            return ('[=[\r\n%s]=]'):format(value)
        else
            return ('%q'):format(value)
        end
    end
    return 'nil'
end

local function write(format, ...)
    str[#str+1] = format:format(...)
end

local function write_data(meta, data, lines, is_reference)
    local len
    local key = meta.field
    if type(data) == 'table' then
        len = get_len(data)
        if len == 0 then
            return
        end
    end
    if key:match '[^%w%_]' then
        key = ('%q'):format(key)
    end
    if meta.displayname then
        local comment = is_reference and reference.label(w2l, meta.displayname)
            or w2l:get_editstring(meta.displayname)
        lines[#lines+1] = {is_reference and '%s' or '-- %s', comment:gsub('^%s*(.-)%s*$', '%1')}
    end
    if not len then
        lines[#lines+1] = {'%s = %s', key, format_value(meta.type, data, is_reference)}
        return
    end
    if len <= 1 then
        lines[#lines+1] = {'%s = %s', key, format_value(meta.type, data[1], is_reference)}
        return
    end

    local values = {}
    local is_string = meta.type == 3
    for i = 1, len do
        if len >= 10 then
            values[i] = ('%d = %s'):format(i, format_value(meta.type, data[i], is_reference))
        else
            values[i] = format_value(meta.type, data[i], is_reference)
        end
    end

    if is_string or len >= 10 then
        lines[#lines+1] = {'%s = {\r\n%s,\r\n}', key, table_concat(values, ',\r\n')}
        return
    end
    
    lines[#lines+1] = {'%s = {%s}', key, table_concat(values, ', ')}
end

-- Reserved fields carry format information that has no editable SLK field.
-- Arrays also preserve unrecognized modifications without a stale WTS index.
local object_format_fields = {
    '_object_version', '_object_data', '_object_extras',
    '_skin_version', '_skin_data', '_skin_parent', '_skin_original',
    '_skin_only', '_skin_fields', '_skin_extras',
}

local function format_internal(value)
    if type(value) == 'table' then
        local values = {}
        for i, item in ipairs(value) do
            values[i] = format_internal(item)
        end
        return '{' .. table_concat(values, ', ') .. '}'
    elseif type(value) == 'string' then
        return ('%q'):format(value):gsub('\n', 'n')
    elseif type(value) == 'number' or type(value) == 'boolean' then
        return tostring(value)
    end
    error('Invalid preserved object format data.')
end

local function same_value(a, b)
    if type(a) ~= type(b) then
        return false
    end
    if type(a) ~= 'table' then
        return a == b
    end
    for key, value in pairs(a) do
        if value ~= b[key] then
            return false
        end
    end
    for key in pairs(b) do
        if a[key] == nil then
            return false
        end
    end
    return true
end

local function write_references(id, obj)
    if not w2l.setting.show_inherited_fields or w2l.setting.mode ~= 'lni' then
        return
    end
    local effective = references and references[id] or {}
    local metas, keys = {}, {}
    local function collect(source)
        for key, meta in pairs(source or {}) do
            if not keys[key] and reference.is_field(key, meta) then
                keys[key] = true
                metas[#metas+1] = {key = key, meta = meta}
            end
        end
    end
    collect(metadata[obj._code])
    collect(metadata[ttype])
    table_sort(metas, function(a, b) return a.meta.field < b.meta.field end)
    write('%s', reference.header(w2l, obj._parent))
    for _, item in ipairs(metas) do
        local key, meta = item.key, item.meta
        local active, value = obj[key], effective[key]
        local inherited = active == nil
        local partial = type(active) == 'table' and value ~= nil and not same_value(active, value)
        if inherited or partial then
            local lines = {}
            -- Missing or unusable values get explicitly marked, inactive edit
            -- templates. They never become inherited defaults or active overrides.
            local ok = value ~= nil and pcall(write_data, meta, value, lines, true)
            if ok and #lines > 0 then
                if partial then
                    write('%s', reference.comment(lang.script.LNI_REFERENCE_ARRAY))
                end
                for _, line in ipairs(lines) do
                    write('%s', reference.comment(line[1]:format(table.unpack(line, 2))))
                end
            else
                write('%s', reference.placeholder(w2l, meta))
            end
        end
    end
end

local function write_obj(id, obj)
    local metas = {}
    local datas = {}
    local haskey = {}
    if metadata[obj._code] then
        for key, meta in pairs(metadata[obj._code]) do
            local data = obj[key]
            if data then
                metas[#metas+1] = meta
                datas[meta] = data
            end
            haskey[key] = true
        end
    end
    if metadata[ttype] then
        for key, meta in pairs(metadata[ttype]) do
            if not haskey[key] then
                local data = obj[key]
                if data then
                    metas[#metas+1] = meta
                    datas[meta] = data
                end
            end
        end
    end
    table_sort(metas, function(meta1, meta2)
        return meta1.field < meta2.field
    end)
    local lines = {}
    for _, meta in ipairs(metas) do
        write_data(meta, datas[meta], lines)
    end
    local has_format_data = obj._object_version == 3 or obj._skin_version or obj._object_extras or obj._skin_extras
    if #lines == 0 and id == obj._parent and not has_format_data then
        return
    end
    if id:match '[^%w%_]' then
        write('[%q]', id)
    else
        write('[%s]', id)
    end
    if obj._parent then
        write('%s = %q', '_parent', obj._parent)
    end
    for _, key in ipairs(object_format_fields) do
        local value = obj[key]
        if value ~= nil and not (key == '_object_version' and value == 2) then
            write('%s = %s', key, format_internal(value))
        end
    end
    if obj._skin_version or #(obj._object_data or {}) > 0 or obj._object_extras or obj._skin_extras then
        write('_keep_obj = true')
    end
    for i = 1, #lines do
        write(table.unpack(lines[i]))
    end
    -- Decide section eligibility from active data above, before adding references.
    write_references(id, obj)
    write ''
end

local function write_table(slk)
    local list = {}
    for id, obj in pairs(slk) do
        if not remove_unuse_object or obj._mark then
            list[#list+1] = id
        end
    end
    table_sort(list, function(a, b)
        local is_origin_a = a == slk[a]._parent
        local is_origin_b = b == slk[b]._parent
        if is_origin_a and not is_origin_b then
            return true
        end
        if not is_origin_a and is_origin_b then
            return false
        end
        return a < b
    end)
    local clock = os_clock()
    for i = 1, #list do
        local obj = slk[list[i]]
        write_obj(list[i], obj)
        if os_clock() - clock >= 0.1 then
            clock = os_clock()
            w2l.messager.text(lang.script.CONVERT_FILE:format(ttype, obj._id, i, #list))
            w2l.progress(i / #list)
        end
    end
end

return function (w2l_, type, slk, references_)
    if not slk then
        return
    end
    w2l = w2l_
    metadata = w2l:metadata()
    remove_unuse_object = w2l.setting.remove_unuse_object
    ttype = type
    references = references_
    str = {}
    write_table(slk)
    return #str > 0 and table_concat(str, '\r\n')
end
