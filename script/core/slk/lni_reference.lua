-- Reference text must stay inert even when values contain newlines or INI syntax.
local lang = require 'lang'
local reference = {}

-- Metadata also contains classifiers such as type = 'misc'. Only actual
-- named field records belong in the editable reference snapshot.
function reference.is_field(key, meta)
    return type(key) == 'string' and key:sub(1, 1) ~= '_'
        and type(meta) == 'table' and type(meta.field) == 'string'
        and meta.field ~= ''
        and (meta.type == 0 or meta.type == 1 or meta.type == 2 or meta.type == 3)
end

function reference.comment(text)
    text = text:gsub('%z', '\\0'):gsub('\r\n', '\n'):gsub('\r', '\n')
    return '-- ' .. text:gsub('\n', '\r\n-- ')
end

function reference.header(w2l, parent)
    return reference.comment(lang.script.LNI_REFERENCE_HEADER:format(
        tostring(w2l.setting.data or ''), tostring(w2l.setting.version or ''),
        tostring(parent or '')))
end

-- Resolve labels from already loaded dictionaries without generating new
-- conversion warnings or changing the literal reference field values.
function reference.label(w2l, source)
    local key = source:upper()
    if key:sub(1, 9) ~= 'WESTRING_' then
        return source
    end
    local strings, seen = w2l.editstring or {}, {}
    while strings[key] and not seen[key] do
        seen[key] = true
        key = strings[key]
    end
    if key ~= source:upper() then
        return key
    end
    return lang.wes[key]
end

-- These are edit templates, not inherited defaults. Warcraft stores boolean
-- object fields as integer 0/1, so type 0 must remain numeric when uncommented.
local placeholders = {[0] = '0', [1] = '0.0', [2] = '0.0', [3] = '""'}
function reference.placeholder(w2l, meta)
    local lines = {}
    if type(meta.displayname) == 'string' then
        local ok, label = pcall(reference.label, w2l, meta.displayname)
        if ok and type(label) == 'string' then
            label = label:gsub('^%s*(.-)%s*$', '%1')
            if label ~= '' then
                lines[#lines+1] = reference.comment(label)
            end
        end
    end
    local key = meta.field
    if key:match '[^%w%_]' then
        key = ('%q'):format(key)
    end
    local marker = lang.script.LNI_NO_DEFAULT:gsub('^%s*(.-)%s*$', '%1')
    lines[#lines+1] = reference.comment(('%s = %s -- %s'):format(
        key, assert(placeholders[meta.type]), marker))
    return table.concat(lines, '\r\n')
end

return reference
