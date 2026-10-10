-- Legacy LNI migration against metadata generated from the supplied game data.
local source = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/')
local root = assert(source:match('^(.*)/test/compat/legacy_profile_fields.lua$'))
local boot = dofile(root .. '/test/compat/bootstrap.lua')
local core = boot.core()
local lni = require 'lni'
local count = 0
local function test(name, fn)
    fn()
    count = count + 1
    print('PASS legacy profiles: ' .. name)
end

local function new_w2l(metadata)
    local w2l = core()
    w2l:set_setting {
        mode = 'obj', data = 'enUS-1.27.1', data_meta = 'enUS-1.27.1',
        data_wes = '${DEFAULT}', remove_unuse_object = false,
    }
    w2l:set_messager(function() end)
    w2l.cache_metadata = metadata
    w2l.default_data = {unit = {
        hfoo = {_id = 'hfoo', _parent = 'hfoo', _type = 'unit', _code = 'hfoo'},
    }}
    return w2l
end

local w2l = new_w2l()
local current_metadata = lni(require 'prebuilt.metadata'(w2l, nil, {reforge = true, casc = true}, function(name)
    return io.load(root .. '/data/warcraft-current/mpq/' .. name:gsub('\\', '/'):lower()) or nil
end))
assert(current_metadata.unit.file == nil)
assert(current_metadata.unit.file_1.id == 'umdl')
assert(current_metadata.unit.file_2.id == 'umd1')
assert(current_metadata.unit.file_3.id == 'umd2')

test('old file and HD/SD names migrate to the first indexed profile', function()
    local w2l = new_w2l(current_metadata)
    local data = w2l:frontend_lni('unit', [[
[H000]
_parent = "hfoo"
file = "Legacy.mdl"
"file:hd" = "LegacyHD.mdl"
"file:sd" = "LegacySD.mdl"
]], 'unit')
    local unit = data.H000
    assert(unit.file_1 == 'Legacy.mdl')
    assert(unit['file_1:hd'] == 'LegacyHD.mdl')
    assert(unit['file_1:sd'] == 'LegacySD.mdl')
    assert(unit.file == nil and unit['file:hd'] == nil and unit['file:sd'] == nil)
    local output = lni(w2l:backend_lni('unit', data))
    assert(output.H000.file_1 == 'Legacy.mdl')
    assert(output.H000['file_1:hd'] == 'LegacyHD.mdl')
    local raw = w2l:frontend_obj('unit', w2l:backend_obj('unit', data))
    assert(raw.H000.umdl[1] == 'Legacy.mdl')
end)

test('explicit modern model columns take priority independently', function()
    local w2l = new_w2l(current_metadata)
    local data = w2l:frontend_lni('unit', [[
[H000]
_parent = "hfoo"
file = "Legacy.mdl"
file_1 = "Current.mdl"
file_2 = "Portrait.mdl"
file_3 = "PortraitHD.mdl"
"file:hd" = "LegacyHD.mdl"
"file_1:hd" = "CurrentHD.mdl"
"file:sd" = "LegacySD.mdl"
"file_1:sd" = "CurrentSD.mdl"
]], 'unit')
    local unit = data.H000
    assert(unit.file_1 == 'Current.mdl')
    assert(unit.file_2 == 'Portrait.mdl' and unit.file_3 == 'PortraitHD.mdl')
    assert(unit['file_1:hd'] == 'CurrentHD.mdl')
    assert(unit['file_1:sd'] == 'CurrentSD.mdl')
    local raw = w2l:frontend_obj('unit', w2l:backend_obj('unit', data))
    assert(raw.H000.umdl[1] == 'Current.mdl')
    assert(raw.H000.umd1[1] == 'Portrait.mdl')
    assert(raw.H000.umd2[1] == 'PortraitHD.mdl')
end)

test('an older selected dataset retains its original field names', function()
    local metadata = lni(assert(io.load(root .. '/data/zhCN-1.32.8/prebuilt/metadata.ini')))
    local w2l = new_w2l(metadata)
    local unit = w2l:frontend_lni('unit', [[
[H000]
_parent = "hfoo"
file = "Legacy.mdl"
"file:hd" = "LegacyHD.mdl"
"file:sd" = "LegacySD.mdl"
]], 'unit').H000
    assert(unit.file == 'Legacy.mdl' and unit.file_1 == nil)
    assert(unit['file:hd'] == 'LegacyHD.mdl')
    assert(unit['file:sd'] == 'LegacySD.mdl')
end)

test('unknown ufil records remain unknown instead of becoming model aliases', function()
    local w2l = new_w2l(current_metadata)
    local fixture = string.pack('<i4i4i4c4c4i4c4i4zi4',
        2, 0, 1, 'hfoo', 'H000', 1, 'ufil', 3, 'Unknown.mdl', 0)
    local data = w2l:frontend_obj('unit', fixture)
    w2l:frontend_updateobj('unit', data, w2l:get_default().unit)
    assert(data.H000.file_1 == nil)
    assert(data.H000._object_extras[1][1] == 'ufil')
    local raw = w2l:frontend_obj('unit', w2l:backend_obj('unit', data))
    assert(raw.H000.ufil[1] == 'Unknown.mdl')
end)


-- Inherited-field references are opt-in comments, never additional overrides.
-- Synthetic parents make selected defaults, map overlays and zero/empty values
-- explicit without changing byte-sensitive game-data fixtures.
local object_kinds = {'ability', 'buff', 'unit', 'item', 'upgrade', 'doodad', 'destructable', 'misc', 'txt'}
local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
local function same(actual, expected, label)
    if type(actual) ~= 'table' or type(expected) ~= 'table' then
        assert(actual == expected, label or 'LNI values differ')
        return
    end
    for key, value in pairs(expected) do same(actual[key], value, (label or 'LNI') .. '.' .. tostring(key)) end
    for key in pairs(actual) do assert(expected[key] ~= nil, 'Unexpected LNI key: ' .. tostring(key)) end
end
local function empty_objects()
    local result = {}
    for _, kind in ipairs(object_kinds) do result[kind] = {} end
    return result
end
local function reference_w2l(enabled)
    local w2l = core()
    local settings = {
        mode = 'lni', data = 'enUS-1.27.1', data_meta = 'enUS-1.27.1',
        data_wes = '${DEFAULT}', remove_unuse_object = false, remove_same = true,
    }
    if enabled ~= nil then settings.show_inherited_fields = enabled end
    w2l:set_setting(settings)
    w2l:set_messager(function() end)
    local metadata = empty_objects()
    metadata.unit = {
        hp = {field = 'HP', type = 0, id = 'uhpm', key = 'hp'},
        spd = {field = 'spd', type = 0, id = 'umvs', key = 'spd'},
        regen = {field = 'regen', type = 2, id = 'uhpr', key = 'regen'},
        name = {field = 'Name', type = 3, id = 'unam', key = 'name', profile = true},
        editorsuffix = {field = 'EditorSuffix', type = 3, id = 'unsf', key = 'editorsuffix', profile = true},
        emptydefault = {field = 'EmptyDefault', type = 3, id = 'urac', key = 'emptydefault'},
        description = {field = 'Description', type = 3, id = 'utip', key = 'description', profile = true},
        missing = {field = 'Missing', type = 3, id = 'zzzz', key = 'missing', displayname = 'Missing editable string'},
    }
    metadata.ability = {
        levels = {field = 'levels', type = 0, id = 'alev', key = 'levels'},
        cool = {field = 'Cool', type = 2, id = 'acdn', key = 'cool', ['repeat'] = true},
        tip = {field = 'Tip', type = 3, id = 'atp1', key = 'tip', profile = true, ['repeat'] = true},
    }
    metadata.AHbz = {
        dataa = {field = 'DataA', type = 1, id = 'Hbz1', key = 'dataa', data = 1, ['repeat'] = true},
    }
    metadata.AInv = {
        carry = {field = 'CarryCapacity', type = 0, id = 'inv1', key = 'carry'},
    }
    w2l.cache_metadata = metadata
    w2l.cache_keydata = {}
    w2l.default_data = empty_objects()
    w2l.default_data.unit.hfoo = {
        _id = 'hfoo', _parent = 'hfoo', _type = 'unit', _code = 'hfoo',
        hp = 420, spd = 270, regen = 0, name = 'Footman', editorsuffix = 'default suffix', emptydefault = '',
        description = 'Line one\r\n[HACK]\r\n_parent = "hfoo"\r\nHP = 123',
    }
    w2l.default_data.ability.AHbz = {
        _id = 'AHbz', _parent = 'AHbz', _type = 'ability', _code = 'AHbz', _max_level = 3,
        levels = 3, cool = {10, 20, 30}, dataa = {1, 2, 3}, tip = {'first', 'second', 'third'},
    }
    return w2l
end
local function merged_objects(w2l, kind, overrides, source)
    local slk = empty_objects()
    slk[kind] = w2l:frontend_merge(kind, copy(source or w2l.default_data[kind]), copy(overrides))
    return slk
end
local function export_objects(w2l, kind, slk)
    local references = w2l:backend_cleanobj(slk)
    return w2l:backend_lni(kind, slk[kind], references and references[kind]), references
end
local function import_objects(w2l, kind, text)
    local data = w2l:frontend_lni(kind, text, kind)
    w2l:frontend_updatelni(kind, data, w2l.default_data[kind])
    return merged_objects(w2l, kind, data)
end
local function binary_from_lni(w2l, kind, text)
    local slk = import_objects(w2l, kind, text)
    w2l.setting.mode = 'obj'
    assert(w2l:backend_cleanobj(slk) == nil, 'Reference snapshots must be LNI-only')
    return w2l:backend_obj(kind, slk[kind]), w2l:backend_obj(kind, slk[kind], nil, true)
end
local function unit_override(values)
    local obj = {_id = 'H000', _parent = 'hfoo', _type = 'unit', _code = 'hfoo'}
    for key, value in pairs(values or {}) do obj[key] = value end
    return {H000 = obj}
end
local function ability_override(values)
    local obj = {_id = 'A000', _parent = 'AHbz', _type = 'ability', _code = 'AHbz', _max_level = 3}
    for key, value in pairs(values or {}) do obj[key] = value end
    return {A000 = obj}
end
local function commented(text, field, value)
    local assignment = field .. ' = ' .. value
    for line in text:gmatch('[^\r\n]+') do
        if line:match('^%s*%-%- ') and line:find(assignment, 1, true) then return true end
    end
    return false
end

local function commented_value(text, field, object_id)
    local section
    for line in text:gmatch('[^\r\n]+') do
        section = line:match('^%[([^%]]+)%]$') or section
        if (not object_id or section == object_id) and line:match('^%s*%-%- ') and line:find(field .. ' = ', 1, true) then
            local assignment = line:gsub('^%s*%-%- ', '')
            return lni('[reference]\n' .. assignment).reference[field]
        end
    end
end

test('inherited field comments default off and never dump untouched stock sections', function()
    local w2l = reference_w2l()
    assert(w2l.setting.show_inherited_fields == false, 'New option must default off')
    local compact, references = export_objects(w2l, 'unit', merged_objects(w2l, 'unit', unit_override {hp = 900}))
    assert(references == nil, 'Disabled references must not retain a snapshot')
    assert(not commented(compact, 'spd', '270'))
    local annotated = reference_w2l(true)
    local untouched = merged_objects(annotated, 'unit', {})
    assert(not export_objects(annotated, 'unit', untouched), 'Untouched stock objects must stay omitted')
    annotated.setting.mode = 'obj'
    assert(annotated:backend_cleanobj(merged_objects(annotated, 'unit', unit_override {hp = 900})) == nil)
end)

test('comments preserve active zero and empty overrides, parsing and binary output', function()
    local overrides = unit_override {hp = 900, spd = 0, editorsuffix = ''}
    local compact_w2l = reference_w2l(false)
    local compact = export_objects(compact_w2l, 'unit', merged_objects(compact_w2l, 'unit', overrides))
    local annotated_w2l = reference_w2l(true)
    local annotated = export_objects(annotated_w2l, 'unit', merged_objects(annotated_w2l, 'unit', overrides))
    same(lni(annotated), lni(compact), 'Commented references must not change assignments')
    assert(lni(annotated).H000.spd == 0 and lni(annotated).H000.EditorSuffix == '')
    assert(commented(annotated, 'regen', '0'))
    assert(commented(annotated, 'EmptyDefault', '""'))
    assert(not annotated:find('-- EmptyDefault = "" -- (no default)', 1, true),
        'A known empty default must not be labeled as missing')
    assert(not annotated:find('Inherited field: uncomment the entire assignment to override.', 1, true),
        'Object references must omit the repeated inherited-field instruction')
    assert(annotated:find('-- Reference values:', 1, true), 'Object references must retain their context header')
    assert(lni(annotated).hfoo == nil and lni(annotated).HACK == nil, 'Multiline comments must not create sections')
    assert(annotated:find('-- Missing editable string\r\n-- Missing = "" -- (no default)', 1, true),
        'An unavailable string must retain its label and an explicitly marked commented placeholder')
    assert(lni(annotated).H000.Missing == nil, 'A missing-value placeholder must remain inactive')
    assert(not annotated:find('effective value unavailable; no default was invented.', 1, true),
        'Typed placeholders must replace the verbose unavailable-value message')
    local compact_bin = binary_from_lni(reference_w2l(false), 'unit', compact)
    local annotated_bin = binary_from_lni(reference_w2l(true), 'unit', annotated)
    assert(annotated_bin == compact_bin, 'Unedited commented LNI must produce identical binary modifications')
end)

test('unavailable fields use labeled typed placeholders without creating overrides', function()
    local w2l = reference_w2l(true)
    local slk = merged_objects(w2l, 'unit', unit_override {hp = 900})
    local references = w2l:backend_cleanobj(slk)
    -- Add absent editable fields after cleanup to isolate reference formatting
    -- from the ordinary active-value cleanup and binary metadata.
    local missing = {
        missinginteger = {field = 'MissingInteger', type = 0, id = 'zz01', key = 'missinginteger', displayname = 'Missing integer'},
        missingreal = {field = 'MissingReal', type = 1, id = 'zz02', key = 'missingreal', displayname = 'WESTRING_MISSING_REAL'},
        missingunreal = {field = 'MissingUnreal', type = 2, id = 'zz03', key = 'missingunreal', displayname = 'Missing unreal'},
        ['missing:hd'] = {field = 'Missing:hd', type = 3, id = 'zz04', key = 'missing:hd', displayname = 'Missing HD text'},
        unusable = {field = 'UnusableReal', type = 2, id = 'zz05', key = 'unusable', displayname = 'Unusable effective real'},
        emptyarray = {field = 'EmptyArray', type = 3, id = 'zz06', key = 'emptyarray', displayname = 'Empty effective array', ['repeat'] = true},
    }
    for key, meta in pairs(missing) do w2l.cache_metadata.unit[key] = meta end
    w2l.editstring = {WESTRING_MISSING_REAL = 'Missing real'}
    references.unit.H000.unusable = false
    references.unit.H000.emptyarray = {}
    local annotated = w2l:backend_lni('unit', slk.unit, references.unit)
    local compact_w2l = reference_w2l(false)
    local compact = export_objects(compact_w2l, 'unit', merged_objects(compact_w2l, 'unit', unit_override {hp = 900}))
    same(lni(annotated), (lni(compact)), 'Missing placeholders must never create active overrides')
    local expected = {
        {'Missing integer', 'MissingInteger', '0'},
        {'Missing real', 'MissingReal', '0.0'},
        {'Missing unreal', 'MissingUnreal', '0.0'},
        {'Missing HD text', '"Missing:hd"', '""'},
        {'Unusable effective real', 'UnusableReal', '0.0'},
        {'Empty effective array', 'EmptyArray', '""'},
    }
    for _, row in ipairs(expected) do
        local label, field, value = table.unpack(row)
        local assignment = field .. ' = ' .. value .. ' -- (no default)'
        assert(annotated:find('-- ' .. label .. '\r\n-- ' .. assignment, 1, true),
            'Missing placeholder must retain its field label and type: ' .. field)
        local parsed = lni('[reference]\n' .. assignment).reference
        local name = field:gsub('^"(.*)"$', '%1')
        local expected_value = value == '""' and '' or tonumber(value)
        assert(parsed[name] == expected_value, 'The inline marker must remain a parser comment: ' .. field)
    end
    assert(not annotated:find('effective value unavailable; no default was invented.', 1, true))
    assert(not annotated:find(' -- (no default)\r\n-- \r\n', 1, true),
        'Localized placeholder markers must not create an empty comment line')
    assert(binary_from_lni(reference_w2l(true), 'unit', annotated)
        == binary_from_lni(reference_w2l(false), 'unit', compact),
        'Unedited missing-value comments must produce identical binary modifications')
    local edited, changes = annotated:gsub('%-%- MissingInteger = 0 %-%- %(no default%)',
        'MissingInteger = 7 -- (no default)', 1)
    assert(changes == 1, 'A placeholder must be available as an ordinary commented assignment')
    local values = lni(edited)
    assert(values.H000.MissingInteger == 7 and values.H000.HP == 900,
        'Uncommenting a placeholder must only activate the explicitly edited field')
    values.H000.MissingInteger = nil
    same(values, (lni(compact)))
    for _, row in ipairs {
        {'MissingInteger', '0', 'zz01', 0},
        {'MissingReal', '0.0', 'zz02', 0},
        {'MissingUnreal', '0.0', 'zz03', 0},
        {'Missing', '""', 'zzzz', ''},
    } do
        local field, value, object_field, expected_value = table.unpack(row)
        local line = '-- ' .. field .. ' = ' .. value .. ' -- (no default)'
        local first, last = assert(annotated:find(line, 1, true))
        local edited = annotated:sub(1, first - 1) .. line:sub(4) .. annotated:sub(last + 1)
        local importer = reference_w2l(true)
        importer.cache_metadata = copy(w2l.cache_metadata)
        local slk = import_objects(importer, 'unit', edited)
        assert(slk.unit.H000[field:lower()] == expected_value,
            'Uncommented zero/empty template must be an explicit typed override: ' .. field)
        local binary = binary_from_lni(importer, 'unit', edited)
        local raw = importer:frontend_obj('unit', binary)
        local actual = raw.H000[object_field][1]
        if type(expected_value) == 'number' then actual = tonumber(actual) end
        assert(actual == expected_value,
            'Zero/empty placeholder must survive native object reimport: ' .. field)
    end
end)

test('uncommenting one inherited field edits only that field', function()
    local w2l = reference_w2l(true)
    local annotated = export_objects(w2l, 'unit', merged_objects(w2l, 'unit', unit_override {hp = 900}))
    assert(commented(annotated, 'spd', '270'))
    local edited, count = annotated:gsub('%-%- spd = 270', 'spd = 300', 1)
    assert(count == 1, 'An inherited scalar must have an ordinary commented assignment')
    local expected = lni(annotated)
    expected.H000.spd = 300
    same(lni(edited), expected)
    local merged = import_objects(reference_w2l(true), 'unit', edited)
    assert(merged.unit.H000.spd == 300 and merged.unit.H000.hp == 900)
end)

test('unchanged comments inherit updated dataset values instead of freezing an export', function()
    local w2l = reference_w2l(true)
    local annotated = export_objects(w2l, 'unit', merged_objects(w2l, 'unit', unit_override {hp = 900}))
    local newer = reference_w2l(true)
    newer.default_data.unit.hfoo.spd = 350
    newer.default_data.unit.hfoo.name = 'Updated stock name'
    local imported = import_objects(newer, 'unit', annotated)
    assert(imported.unit.H000.spd == 350 and imported.unit.H000.name == 'Updated stock name')
    assert(imported.unit.H000.hp == 900, 'Actual overrides must remain active across datasets')
end)

test('code-specific references and sparse arrays retain complete effective level values', function()
    local override = ability_override {cool = {[2] = 0}, dataa = {[2] = 7}}
    local compact_w2l = reference_w2l(false)
    local compact = export_objects(compact_w2l, 'ability', merged_objects(compact_w2l, 'ability', override))
    local annotated_w2l = reference_w2l(true)
    local slk = merged_objects(annotated_w2l, 'ability', override)
    local annotated, references = export_objects(annotated_w2l, 'ability', slk)
    same(lni(annotated), (lni(compact)))
    same(references.ability.A000.cool, {10, 0, 30})
    same(references.ability.A000.dataa, {1, 7, 3})
    same(commented_value(annotated, 'Cool'), {10, 0, 30}, 'Sparse overrides need a complete effective reference')
    same(commented_value(annotated, 'DataA'), {1, 7, 3})
    assert(annotated:find('-- Effective array for reference only; edit the active assignment above.', 1, true),
        'Sparse object overrides must retain their partial-array safety instruction')
    assert(not annotated:find('Inherited field: uncomment the entire assignment to override.', 1, true))
    assert(not annotated:find('CarryCapacity', 1, true), 'Fields for other ability codes must not be shown')
    -- Exercise serializer metadata precedence independently of cleanup, whose
    -- common/code schemas ordinarily have disjoint keys.
    annotated_w2l.cache_metadata.ability.dataa = {field = 'GenericDataA', type = 1, id = 'xxxx', key = 'dataa'}
    local precedence = annotated_w2l:backend_lni('ability', slk.ability, references.ability)
    same(lni(precedence), (lni(annotated)))
    assert(not precedence:find('GenericDataA', 1, true), 'Code-specific metadata must override a common-field alias')
    assert(slk.ability.A000.cool[1] == nil and slk.ability.A000.cool[2] == 0)
    assert(binary_from_lni(reference_w2l(true), 'ability', annotated)
        == binary_from_lni(reference_w2l(false), 'ability', compact))
    slk.ability.A000.cool[2] = 99
    assert(references.ability.A000.cool[2] == 0, 'References must not alias mutable sparse arrays')
end)

test('references use merged map overlays rather than guessed stock parents', function()
    local w2l = reference_w2l(true)
    local overlay = copy(w2l.default_data.ability)
    overlay.AHbz.cool = {10, 25, 35}
    local slk = merged_objects(w2l, 'ability', ability_override {cool = {[2] = 0}}, overlay)
    local annotated, references = export_objects(w2l, 'ability', slk)
    same(references.ability.A000.cool, {10, 0, 35})
    same(commented_value(annotated, 'Cool', 'A000'), {10, 0, 35})
    local direct = w2l:backend_lni('ability', slk.ability)
    assert(not commented(direct, 'Tip', '{'), 'Direct serialization must not guess inherited arrays without a snapshot')
end)

test('long multiline arrays are entirely commented and remain ignored by native LNI parser', function()
    local w2l = reference_w2l(true)
    local parent = w2l.default_data.ability.AHbz
    parent.levels, parent._max_level = 12, 12
    for i = 4, 12 do parent.cool[i], parent.dataa[i], parent.tip[i] = i, i, 'level ' .. i end
    parent.tip[5] = 'line one\r\n[INJECTED]\r\nHP = 123'
    local overrides = ability_override {levels = 12, _max_level = 12, dataa = {[2] = 7}}
    local slk = merged_objects(w2l, 'ability', overrides)
    local annotated = export_objects(w2l, 'ability', slk)
    local compact_w2l = reference_w2l(false)
    compact_w2l.default_data = copy(w2l.default_data)
    local compact = export_objects(compact_w2l, 'ability', merged_objects(compact_w2l, 'ability', overrides))
    same(lni(annotated), (lni(compact)))
    assert(lni(annotated).INJECTED == nil, 'A newline in a reference value must never escape its comment')
    assert(commented(annotated, 'Tip', '{'), 'Long repeated string references must be visible')
    assert(annotated:find('level 12', 1, true), 'Reference arrays must not truncate higher levels')
end)

test('skin precedence and unknown native modifications remain byte-identical', function()
    local override = unit_override {
        hp = 420, _object_version = 3, _object_data = {17, -9},
        _object_extras = {{'zz01', 0, 0, 0, 12345, 0}},
        _skin_version = 3, _skin_data = {88}, _skin_parent = 'hfoo', _skin_original = false,
        _skin_fields = {'uhpm:1'}, _skin_extras = {{'zz02', 3, 0, 0, 'opaque skin', 0}},
    }
    local compact_w2l = reference_w2l(false)
    local compact = export_objects(compact_w2l, 'unit', merged_objects(compact_w2l, 'unit', override))
    local annotated_w2l = reference_w2l(true)
    local annotated = export_objects(annotated_w2l, 'unit', merged_objects(annotated_w2l, 'unit', override))
    same(lni(annotated), (lni(compact)))
    assert(lni(annotated).H000.HP == 420, 'Explicit equal-stock skin assignments must stay active')
    local compact_main, compact_skin = binary_from_lni(reference_w2l(false), 'unit', compact)
    local annotated_main, annotated_skin = binary_from_lni(reference_w2l(true), 'unit', annotated)
    assert(compact_main == annotated_main and compact_skin == annotated_skin,
        'Reference comments must preserve both main and skin native payloads')
    local raw = reference_w2l(false):frontend_obj('unit', annotated_main)
    assert(raw.H000.zz01[1] == 12345)
    local skin = reference_w2l(false):frontend_obj('unit', annotated_skin)
    assert(skin.H000.zz02[1] == 'opaque skin' and skin.H000.uhpm[1] == 420)
end)


test('control bytes, multiline labels and headers cannot hide later active sections', function()
    local w2l = reference_w2l(true)
    local value = 'line one\r\n[VALUE]\0]=]\nHP = 123'
    w2l.default_data.unit.hfoo.description = value
    w2l.cache_metadata.unit.description.displayname = 'Label\r\n[LABEL]\0HP = 456'
    local overrides = unit_override {hp = 900}
    overrides.H001 = copy(overrides.H000)
    overrides.H001._id, overrides.H001.hp = 'H001', 901
    w2l.setting.data, w2l.setting.version = 'dataset\r\n[HEADER]\0', 'Custom\r[VERSION]'
    local annotated = export_objects(w2l, 'unit', merged_objects(w2l, 'unit', overrides))
    local compact_w2l = reference_w2l(false)
    compact_w2l.default_data = copy(w2l.default_data)
    local compact = export_objects(compact_w2l, 'unit', merged_objects(compact_w2l, 'unit', overrides))
    same(lni(annotated), (lni(compact)))
    assert(lni(annotated).H001.HP == 901, 'NUL inside a reference must not truncate later objects')
    assert(not annotated:find('\0', 1, true), 'References must contain no raw NUL bytes')
    assert(commented_value(annotated, 'Description', 'H000') == value,
        'Uncommented string reference must preserve control bytes and delimiter text exactly')
    local disabled = reference_w2l(false)
    local compact_again = export_objects(disabled, 'unit', merged_objects(disabled, 'unit', unit_override {hp = 900}))
    assert(not compact_again:find('Reference values:', 1, true), 'Reference state must not leak into a later disabled export')
end)

test('stock sections retained by synthesized overrides still keep known references', function()
    local w2l = reference_w2l(true)
    local source = copy(w2l.default_data.unit)
    source.hfoo.hp = nil
    local annotated, references = export_objects(w2l, 'unit', merged_objects(w2l, 'unit', {}, source))
    assert(lni(annotated).hfoo.HP == 0, 'Keep the existing cleanup behavior for missing effective stock fields')
    assert(references.unit.hfoo.spd == 270 and commented_value(annotated, 'spd', 'hfoo') == 270,
        'A cleanup-created active field must not cause all known references to be dropped')
    assert(references.unit.hfoo.hp == nil, 'Missing effective values must not be replaced with guessed parent data')
end)

test('txt references are pruned for object profile fields and stay mode-isolated', function()
    local w2l = reference_w2l(true)
    w2l.default_data.txt.hfoo = {name = {'Footman'}, extra = {'one', 'two', 'three'}, inherited = {'unchanged'}}
    w2l.default_data.txt.untouched = {unmodified = {'default'}}
    local slk = merged_objects(w2l, 'unit', unit_override {hp = 900})
    slk.txt.hfoo = {name = {'Footman'}, extra = {'one', 'changed', 'three'}, inherited = {'unchanged'}}
    slk.txt.untouched = {unmodified = {'default'}}
    local references = w2l:backend_cleanobj(slk)
    assert(references.txt.hfoo.name == nil, 'Object profile columns must not reappear as txt references')
    assert(references.txt.untouched == nil, 'Unchanged txt sections must not acquire references')
    local annotated = w2l:backend_txtlni(slk.txt, references.txt)
    same(commented_value(annotated, 'extra', 'hfoo'), {'one', 'changed', 'three'})
    assert(commented_value(annotated, 'inherited', 'hfoo') == 'unchanged')
    assert(not annotated:find('Inherited field: uncomment the entire assignment to override.', 1, true),
        'TXT references must omit the repeated inherited-field instruction')
    assert(annotated:find('-- Effective array for reference only; edit the active assignment above.', 1, true),
        'Sparse TXT overrides must retain their partial-array safety instruction')
    assert(annotated:find('-- Reference values:', 1, true), 'TXT references must retain their context header')
    assert(not annotated:find('name =', 1, true) and lni(annotated).untouched == nil)
    w2l.setting.show_inherited_fields = false
    local compact = w2l:backend_txtlni(slk.txt, references.txt)
    same(lni(annotated), (lni(compact)))
    w2l.setting.mode, w2l.setting.show_inherited_fields = 'obj', true
    assert(w2l:backend_txtlni(slk.txt, references.txt) == compact,
        'OBJ and SLK operations must ignore a retained reference argument')
end)

test('misc comments keep the same exported sections and active gameplay constants', function()
    local w2l = reference_w2l(true)
    w2l.cache_metadata.misc = {
        xp = {field = 'XP', type = 0, id = 'mxp1', key = 'xp'},
        bonus = {field = 'Bonus', type = 2, id = 'mbn1', key = 'bonus'},
    }
    w2l.default_data.misc.Misc = {_id = 'Misc', _parent = 'Misc', _type = 'misc', xp = 10, bonus = 1.5}
    local slk = empty_objects()
    slk.misc = copy(w2l.default_data.misc)
    slk.misc.Misc.xp = 20
    local annotated = export_objects(w2l, 'misc', slk)
    local compact_w2l = reference_w2l(false)
    compact_w2l.cache_metadata = copy(w2l.cache_metadata)
    compact_w2l.default_data = copy(w2l.default_data)
    local compact_slk = empty_objects()
    compact_slk.misc = copy(compact_w2l.default_data.misc)
    compact_slk.misc.Misc.xp = 20
    local compact = export_objects(compact_w2l, 'misc', compact_slk)
    same(lni(annotated), (lni(compact)))
    assert(lni(annotated).Misc.XP == 20 and commented_value(annotated, 'Bonus', 'Misc') == 1.5)
end)


-- Real metadata contains classification records as well as editable fields.
-- In particular Misc.type is the scalar "misc", not a field descriptor.
local function real_reference_w2l(dataset, enabled)
    local w2l = core()
    w2l:set_setting {
        mode = 'lni', data = dataset, data_meta = dataset, data_wes = '${DEFAULT}',
        remove_unuse_object = false, remove_same = false, show_inherited_fields = enabled,
    }
    w2l:set_messager(function() end)
    return w2l
end
local function real_export(w2l, kind, overrides, parent)
    local source = {[parent] = copy(assert(w2l:get_default()[kind][parent]))}
    local slk = merged_objects(w2l, kind, overrides, source)
    w2l:backend_searchparent(slk)
    return export_objects(w2l, kind, slk)
end
local function real_binary_from_lni(w2l, kind, text)
    local slk = import_objects(w2l, kind, text)
    w2l:backend_searchparent(slk)
    w2l.setting.mode = 'obj'
    w2l:backend_cleanobj(slk)
    return w2l:backend_obj(kind, slk[kind])
end

test('real Spell Book and Blizzard metadata keep common and ability-specific reference fields', function()
    for _, dataset in ipairs {'enUS-1.27.1', 'warcraft-current'} do
        for _, code in ipairs {'Aspb', 'AHbz'} do
            local overrides = {A000 = {
                _id = 'A000', _parent = code, _code = code, _type = 'ability',
                name = 'Edited ability name',
            }}
            local compact = real_export(real_reference_w2l(dataset, false), 'ability', overrides, code)
            local w2l = real_reference_w2l(dataset, true)
            local annotated = real_export(w2l, 'ability', overrides, code)
            same(lni(annotated), (lni(compact)))
            assert(annotated:find('-- DataA =', 1, true), dataset .. ' ' .. code .. ' must show code-specific DataA')
            assert(annotated:find('-- Cool =', 1, true), dataset .. ' ' .. code .. ' must show common Cool')
            assert(not annotated:find('type =', 1, true), 'Metadata classification must not be exported as a field')
            assert(real_binary_from_lni(real_reference_w2l(dataset, true), 'ability', annotated)
                == real_binary_from_lni(real_reference_w2l(dataset, false), 'ability', compact),
                dataset .. ' ' .. code .. ' reference comments must not change object modifications')
        end
    end
end)

test('real misc scalar classification is excluded without losing editable gameplay constants', function()
    for _, dataset in ipairs {'enUS-1.27.1', 'warcraft-current'} do
        local overrides = {Misc = {
            _id = 'Misc', _parent = 'Misc', _code = 'Misc', _type = 'misc',
            abilsaleaggrorange = 2500,
        }}
        local compact = real_export(real_reference_w2l(dataset, false), 'misc', overrides, 'Misc')
        local w2l = real_reference_w2l(dataset, true)
        assert(w2l:metadata().Misc.type == 'misc', 'Fixture must include the real scalar classification record')
        local annotated = real_export(w2l, 'misc', overrides, 'Misc')
        same(lni(annotated), (lni(compact)))
        assert(lni(annotated).Misc.AbilSaleAggroRange == 2500)
        assert(annotated:find('-- AgiAttackSpeedBonus =', 1, true), 'Valid Misc code-specific fields must remain visible')
        assert(annotated:find('W2LObject', 1, true), 'Common misc metadata must remain represented')
        assert(not annotated:find('type =', 1, true), 'Scalar misc classification is not an editable field')
        assert(real_binary_from_lni(real_reference_w2l(dataset, true), 'misc', annotated)
            == real_binary_from_lni(real_reference_w2l(dataset, false), 'misc', compact),
            dataset .. ' misc reference comments must not change gameplay constants')
    end
end)

test('non-field metadata cannot crash reference sorting or shadow valid common fields', function()
    local w2l = reference_w2l(true)
    local slk = merged_objects(w2l, 'unit', unit_override {hp = 900})
    local annotated, references = export_objects(w2l, 'unit', slk)
    -- Add generator bookkeeping and incomplete metadata only after normal
    -- cleanup, isolating the reference collector from unrelated validators.
    w2l.cache_metadata.hfoo = {
        type = 'unit',
        bookkeeping = {type = 0, key = 'bookkeeping'},
        spd = {type = 0, key = 'spd'}, -- No field name: do not hide common spd.
        emptyfield = {field = '', type = 0},
        numericfield = {field = 123, type = 0},
        missingtype = {field = 'MissingType'},
        unsupported = {field = 'Unsupported', type = 77},
        boolean = false,
        [1] = {field = 'NumericKey', type = 0},
    }
    local filtered = w2l:backend_lni('unit', slk.unit, references.unit)
    same(lni(filtered), (lni(annotated)))
    assert(commented_value(filtered, 'spd', 'H000') == 270, 'Invalid code metadata must not shadow a valid common field')
    for _, name in ipairs {'bookkeeping', 'MissingType', 'Unsupported', 'NumericKey'} do
        assert(not filtered:find(name, 1, true), 'Non-field metadata must not be advertised as editable: ' .. name)
    end
    assert(not filtered:find('type =', 1, true), 'Scalar classifications must remain excluded')
    assert(binary_from_lni(reference_w2l(true), 'unit', filtered)
        == binary_from_lni(reference_w2l(false), 'unit', annotated))
end)

print(('Legacy profile migration tests passed: %d'):format(count))
