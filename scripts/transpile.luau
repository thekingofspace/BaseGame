local csvOptions = {
	delimiter = ",",
	headers = true,
	trim = true,
	numbers = true,
	booleans = true,
	keys = "raw",
	skipBlank = true,
	emptyAsNil = false,
}

local tsvOptions = {
	delimiter = "\t",
	headers = true,
	trim = true,
	numbers = true,
	booleans = true,
	keys = "raw",
	skipBlank = true,
	emptyAsNil = false,
}

local psvOptions = {
	delimiter = "|",
	headers = true,
	trim = true,
	numbers = true,
	booleans = true,
	keys = "raw",
	skipBlank = true,
	emptyAsNil = false,
}

local xmlOptions = {
	trim = true,
	keepWhitespace = false,
	attributeValues = false,
	tagUnion = true,
}

local enumOptions = {
	auto = "path",
	prefix = true,
}

local textOptions = {
	lines = false,
	trim = false,
}

local iniOptions = {
	trim = true,
	numbers = true,
	booleans = true,
	emptyAsNil = false,
	nest = true,
}

local propertyOptions = {
	nest = true,
	escapes = true,
}

local yarnOptions = {
	keyed = true,
}

local docOptions = {
	frontmatter = true,
	sections = true,
	skip = {
		README = true,
		CHANGELOG = true,
		LICENSE = true,
		CONTRIBUTING = true,
	},
}

local moduleOptions = {
	strict = true,
	header = true,
	freeze = true,
	meta = "source",
}

local frontmatterFences = {
	["---"] = true,
	["+++"] = true,
}

local freezeSource = [[
local function freeze(value: any): any
	if table.isfrozen(value) then
		return value
	end
	for _, item in pairs(value) do
		if type(item) == "table" then
			freeze(item)
		end
	end
	return table.freeze(value)
end]]

local function stripBom(text)
	if string.sub(text, 1, 3) == "\239\187\191" then
		return string.sub(text, 4)
	end
	return text
end

local function escapePattern(value)
	return (string.gsub(value, "(%W)", "%%%1"))
end

local function lineAt(text, index)
	local line = 1
	local cursor = 1
	while true do
		local hit = string.find(text, "\n", cursor, true)
		if not hit or hit >= index then
			return line
		end
		line = line + 1
		cursor = hit + 1
	end
end

local function toNumber(value)
	local plain = string.match(value, "^[-+]?%d+$")
	local trailing = string.match(value, "^[-+]?%d+%.%d*$")
	local leading = string.match(value, "^[-+]?%d*%.%d+$")
	if not plain and not trailing and not leading then
		return nil
	end
	if string.match(value, "^[-+]?0%d") then
		return nil
	end
	return tonumber(value)
end

local function coerce(value, options)
	if options.trim then
		value = roflux.text.trim(value)
	end
	if value == "" then
		if options.emptyAsNil then
			return nil
		end
		return value
	end
	if options.booleans then
		local lowered = string.lower(value)
		if lowered == "true" then
			return true
		end
		if lowered == "false" then
			return false
		end
	end
	if options.numbers then
		local number = toNumber(value)
		if number then
			return number
		end
	end
	return value
end

local function valueType(options)
	local parts = { "string" }
	if options.numbers then
		table.insert(parts, "number")
	end
	if options.booleans then
		table.insert(parts, "boolean")
	end
	return table.concat(parts, " | ")
end

local function isBlankRow(row)
	for _, value in ipairs(row) do
		if roflux.text.trim(value) ~= "" then
			return false
		end
	end
	return true
end

local function headerKey(value, index, used, options)
	local name = roflux.text.trim(value)
	if options.keys == "camel" then
		name = roflux.text.camel(name)
	elseif options.keys == "pascal" then
		name = roflux.text.pascal(name)
	elseif options.keys == "snake" then
		name = roflux.text.snake(name)
	end
	if name == "" then
		name = string.format("column%d", index)
	end

	local unique = name
	local suffix = 2
	while used[unique] do
		unique = string.format("%s%d", name, suffix)
		suffix = suffix + 1
	end

	used[unique] = true
	return unique
end

local function parseDelimited(text, delimiter, label)
	local stop = string.format('[%s"\r\n]', escapePattern(delimiter))
	local rows = {}
	local row = {}
	local field = {}
	local quoted = false
	local index = 1
	local length = #text

	local function endField()
		table.insert(row, table.concat(field))
		table.clear(field)
	end

	local function endRow()
		endField()
		table.insert(rows, row)
		row = {}
	end

	while index <= length do
		if quoted then
			local close = string.find(text, '"', index, true)
			if not close then
				error(string.format("%s:%d: a quoted field was never closed", label, lineAt(text, index)), 0)
			end
			table.insert(field, string.sub(text, index, close - 1))
			if string.sub(text, close + 1, close + 1) == '"' then
				table.insert(field, '"')
				index = close + 2
			else
				quoted = false
				index = close + 1
			end
		else
			local hit = string.find(text, stop, index)
			if not hit then
				table.insert(field, string.sub(text, index))
				index = length + 1
			else
				if hit > index then
					table.insert(field, string.sub(text, index, hit - 1))
				end

				local char = string.sub(text, hit, hit)
				if char == '"' then
					quoted = true
					index = hit + 1
				elseif char == "\n" then
					endRow()
					index = hit + 1
				elseif char == "\r" then
					endRow()
					if string.sub(text, hit + 1, hit + 1) == "\n" then
						index = hit + 2
					else
						index = hit + 1
					end
				else
					endField()
					index = hit + 1
				end
			end
		end
	end

	if #field > 0 or #row > 0 then
		endRow()
	end

	return rows
end

local function shapeDelimited(rows, options)
	local records = {}

	if not options.headers then
		for _, row in ipairs(rows) do
			if not options.skipBlank or not isBlankRow(row) then
				local record = {}
				for index, value in ipairs(row) do
					local shaped = coerce(value, options)
					if shaped == nil then
						shaped = ""
					end
					record[index] = shaped
				end
				table.insert(records, record)
			end
		end
		return records
	end

	local header = rows[1]
	if not header then
		return records
	end

	local used = {}
	local keys = {}
	for index, value in ipairs(header) do
		keys[index] = headerKey(value, index, used, options)
	end

	for rowIndex = 2, #rows do
		local row = rows[rowIndex]
		if not options.skipBlank or not isBlankRow(row) then
			while #keys < #row do
				keys[#keys + 1] = headerKey("", #keys + 1, used, options)
			end

			local record = {}
			for index, key in ipairs(keys) do
				local shaped = coerce(row[index] or "", options)
				if shaped ~= nil then
					record[key] = shaped
				end
			end
			table.insert(records, record)
		end
	end

	return records
end

local entities = {
	lt = "<",
	gt = ">",
	amp = "&",
	quot = '"',
	apos = "'",
}

local function decodeEntity(entity)
	local named = entities[entity]
	if named then
		return named
	end

	local point = nil
	local hex = string.match(entity, "^#[xX](%x+)$")
	if hex then
		point = tonumber(hex, 16)
	else
		local decimal = string.match(entity, "^#(%d+)$")
		if decimal then
			point = tonumber(decimal)
		end
	end

	if not point then
		return nil
	end
	if point < 128 then
		return string.char(point)
	end
	return utf8.char(point)
end

local function decodeEntities(text)
	if not string.find(text, "&", 1, true) then
		return text
	end
	return (string.gsub(text, "&(#?%w+);", decodeEntity))
end

local function findTagEnd(text, from)
	local index = from
	while true do
		local hit = string.find(text, "[\"'>]", index)
		if not hit then
			return nil
		end

		local char = string.sub(text, hit, hit)
		if char == ">" then
			return hit
		end

		local close = string.find(text, char, hit + 1, true)
		if not close then
			return nil
		end
		index = close + 1
	end
end

local function parseAttributes(body, options)
	local attributes = {}
	for name, _, value in string.gmatch(body, "([%w_:%-%.]+)%s*=%s*([\"'])(.-)%2") do
		local decoded = decodeEntities(value)
		if options.attributeValues then
			attributes[name] = coerce(decoded, options)
		else
			attributes[name] = decoded
		end
	end
	return attributes
end

local function parseXml(text, label, options)
	local index = 1
	local length = #text
	local stack = {}
	local root = nil

	local function fail(message, at)
		error(string.format("%s:%d: %s", label, lineAt(text, at or index), message), 0)
	end

	local function current()
		return stack[#stack]
	end

	local function addText(value, raw)
		local node = current()
		if not node then
			return
		end

		local decoded = value
		if not raw then
			decoded = decodeEntities(value)
			if not options.keepWhitespace then
				if roflux.text.trim(decoded) == "" then
					return
				end
				if options.trim then
					decoded = roflux.text.trim(decoded)
				end
			end
		end

		if node.text == "" then
			node.text = decoded
		elseif options.trim and not options.keepWhitespace then
			node.text = string.format("%s %s", node.text, decoded)
		else
			node.text = node.text .. decoded
		end
	end

	while index <= length do
		local open = string.find(text, "<", index, true)
		if not open then
			addText(string.sub(text, index), false)
			break
		end
		if open > index then
			addText(string.sub(text, index, open - 1), false)
		end

		local marker = string.sub(text, open + 1, open + 1)
		if marker == "!" then
			if string.sub(text, open, open + 3) == "<!--" then
				local close = string.find(text, "-->", open + 4, true)
				if not close then
					fail("a comment was never closed", open)
				end
				index = close + 3
			elseif string.sub(text, open, open + 8) == "<![CDATA[" then
				local close = string.find(text, "]]>", open + 9, true)
				if not close then
					fail("a CDATA section was never closed", open)
				end
				addText(string.sub(text, open + 9, close - 1), true)
				index = close + 3
			else
				local close = string.find(text, ">", open + 1, true)
				if not close then
					fail("a declaration was never closed", open)
				end
				index = close + 1
			end
		elseif marker == "?" then
			local close = string.find(text, "?>", open + 2, true)
			if not close then
				fail("a processing instruction was never closed", open)
			end
			index = close + 2
		elseif marker == "/" then
			local close = string.find(text, ">", open + 2, true)
			if not close then
				fail("a closing tag was never closed", open)
			end

			local name = roflux.text.trim(string.sub(text, open + 2, close - 1))
			local node = current()
			if not node then
				fail(string.format('closing tag "%s" has nothing open', name), open)
			end
			if node.tag ~= name then
				fail(string.format('closing tag "%s" does not match "%s"', name, node.tag), open)
			end

			table.remove(stack)
			index = close + 1
		else
			local close = findTagEnd(text, open + 1)
			if not close then
				fail("a tag was never closed", open)
			end

			local body = string.sub(text, open + 1, close - 1)
			local selfClosing = string.sub(body, -1) == "/"
			if selfClosing then
				body = string.sub(body, 1, -2)
			end

			local name, attributeText = string.match(body, "^([^%s]+)%s*(.*)$")
			if not name or name == "" then
				fail("a tag has no name", open)
			end

			local node = {
				tag = name,
				attributes = parseAttributes(attributeText or "", options),
				children = {},
				text = "",
			}

			local parent = current()
			if parent then
				table.insert(parent.children, node)
			elseif root then
				fail(string.format('"%s" is a second root element', name), open)
			else
				root = node
			end

			if not selfClosing then
				table.insert(stack, node)
			end
			index = close + 1
		end
	end

	local unclosed = current()
	if unclosed then
		fail(string.format('"%s" was never closed', unclosed.tag), length)
	end
	if not root then
		fail("there is no root element", 1)
	end

	return root
end

local function skipTrivia(text, index)
	local length = #text
	while index <= length do
		local _, stop = string.find(text, "^%s+", index)
		if stop then
			index = stop + 1
		elseif string.sub(text, index, index + 1) == "--" or string.sub(text, index, index) == "#" then
			local newline = string.find(text, "\n", index, true)
			if not newline then
				return length + 1
			end
			index = newline + 1
		else
			break
		end
	end
	return index
end

local function findEntryEnd(text, from)
	local index = from
	while true do
		local hit = string.find(text, "[\"';}]", index)
		if not hit then
			return nil
		end

		local char = string.sub(text, hit, hit)
		if char == ";" or char == "}" then
			return hit, char
		end

		local close = string.find(text, char, hit + 1, true)
		if not close then
			return nil
		end
		index = close + 1
	end
end

local function autoValue(stem, enumName, valueName, index, options)
	if options.auto == "index" then
		return index
	end
	if options.auto == "name" then
		return valueName
	end
	if options.prefix then
		return string.format("%s.%s.%s", stem, enumName, valueName)
	end
	return string.format("%s.%s", enumName, valueName)
end

local function parseEnums(text, label, stem, options)
	local index = 1
	local length = #text
	local enums = {}
	local declared = {}

	local function fail(message, at)
		error(string.format("%s:%d: %s", label, lineAt(text, at or index), message), 0)
	end

	local function readValue(body, at)
		local opening = string.sub(body, 1, 1)
		if opening == '"' or opening == "'" then
			local close = string.find(body, opening, 2, true)
			if not close then
				fail("a quoted value was never closed", at)
			end
			return string.sub(body, 2, close - 1), roflux.text.trim(string.sub(body, close + 1))
		end

		local first, second = string.match(body, "^(%S+)%s+(%S+)$")
		if not first then
			return nil, body
		end

		if first == "true" then
			return true, second
		end
		if first == "false" then
			return false, second
		end

		local number = tonumber(first)
		if number then
			return number, second
		end
		if not string.match(first, "^[%w_%.%-]+$") then
			fail(string.format('"%s" is not a value a name can hold', first), at)
		end
		return first, second
	end

	while true do
		index = skipTrivia(text, index)
		if index > length then
			break
		end

		local keyword, afterKeyword = string.match(text, "^(%a+)()", index)
		if not keyword or string.lower(keyword) ~= "enum" then
			fail("every block starts with Enum or enum", index)
		end

		index = skipTrivia(text, afterKeyword)
		local name, afterName = string.match(text, "^([%a_][%w_]*)()", index)
		if not name then
			fail("Enum needs a name", index)
		end
		if declared[name] then
			fail(string.format('"%s" is declared twice', name), index)
		end
		declared[name] = true

		index = skipTrivia(text, afterName)
		if string.sub(text, index, index) ~= "{" then
			fail(string.format('"%s" needs a { after it', name), index)
		end
		index = index + 1

		local block = { name = name, order = {}, values = {} }
		local nextIndex = 1

		while true do
			index = skipTrivia(text, index)
			if index > length then
				fail(string.format('"%s" was never closed', name), length)
			end

			if string.sub(text, index, index) == "}" then
				index = index + 1
				break
			end

			local stop, closer = findEntryEnd(text, index)
			if not stop then
				fail(string.format('"%s" was never closed', name), index)
			end
			if closer == "}" then
				fail("every name ends with a ;", index)
			end

			local body = roflux.text.trim(string.sub(text, index, stop - 1))
			if body == "" then
				fail("there is a ; with no name before it", index)
			end

			local value, valueName = readValue(body, index)
			if not string.match(valueName, "^[%a_][%w_]*$") then
				fail(string.format('"%s" is not a name', valueName), index)
			end
			if block.values[valueName] ~= nil then
				fail(string.format('"%s" is listed twice in "%s"', valueName, name), index)
			end

			if value == nil then
				value = autoValue(stem, name, valueName, nextIndex, options)
			end
			if type(value) == "number" then
				nextIndex = value + 1
			else
				nextIndex = nextIndex + 1
			end

			block.values[valueName] = value
			table.insert(block.order, valueName)
			index = stop + 1
		end

		if #block.order == 0 then
			fail(string.format('"%s" holds no names', name), index)
		end
		table.insert(enums, block)
	end

	if #enums == 0 then
		fail("there are no Enum blocks in this file", 1)
	end

	return enums
end

local function isArray(value)
	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" then
			return false
		end
		count = count + 1
	end
	return count == #value
end

local function formatKey(key)
	if type(key) == "number" then
		return string.format("[%s]", tostring(key))
	end
	if roflux.luau.isIdentifier(key) then
		return key
	end
	return string.format("[%s]", roflux.luau.quote(key))
end

local function encode(value, indent)
	local kind = type(value)
	if kind == "string" then
		return roflux.luau.quote(value)
	elseif kind == "number" or kind == "boolean" then
		return tostring(value)
	elseif kind == "nil" then
		return "nil"
	elseif kind ~= "table" then
		error(string.format("a %s cannot be written into a module", kind), 0)
	end

	local inner = indent .. "\t"
	local parts = {}

	if isArray(value) then
		for _, item in ipairs(value) do
			table.insert(parts, string.format("%s%s,", inner, encode(item, inner)))
		end
	else
		local keys = {}
		for key in pairs(value) do
			table.insert(keys, key)
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		for _, key in ipairs(keys) do
			table.insert(parts, string.format("%s%s = %s,", inner, formatKey(key), encode(value[key], inner)))
		end
	end

	if #parts == 0 then
		return "{}"
	end
	return string.format("{\n%s\n%s}", table.concat(parts, "\n"), indent)
end

local function buildModule(file, value, typeName, typeSource)
	local lines = {}

	if moduleOptions.strict then
		table.insert(lines, "--!strict")
	end
	if moduleOptions.header then
		table.insert(lines, string.format("-- generated from %s, edit that file instead", file.path))
	end
	if #lines > 0 then
		table.insert(lines, "")
	end

	table.insert(lines, typeSource)
	table.insert(lines, "")
	table.insert(lines, string.format("local data: %s = %s", typeName, encode(value, "")))
	table.insert(lines, "")

	if moduleOptions.freeze and type(value) == "table" then
		table.insert(lines, freezeSource)
		table.insert(lines, "")
		table.insert(lines, string.format("return freeze(data) :: %s", typeName))
	else
		table.insert(lines, "return data")
	end

	return table.concat(lines, "\n")
end

local function describeType(value, indent)
	local kind = type(value)
	if kind == "string" or kind == "number" or kind == "boolean" then
		return kind
	end
	if kind ~= "table" then
		return "any"
	end

	local inner = indent .. "\t"

	local function unionParts(items)
		local seen = {}
		local parts = {}
		for _, item in ipairs(items) do
			if not seen[item] then
				seen[item] = true
				table.insert(parts, item)
			end
		end
		table.sort(parts)
		return table.concat(parts, " | ")
	end

	if isArray(value) then
		if #value == 0 then
			return "{ any }"
		end

		local kinds = {}
		for _, item in ipairs(value) do
			table.insert(kinds, describeType(item, indent))
		end
		return string.format("{ %s }", unionParts(kinds))
	end

	local keys = {}
	local plain = true
	for key in pairs(value) do
		if type(key) ~= "string" then
			plain = false
		end
		table.insert(keys, key)
	end

	if #keys == 0 then
		return "{ [string]: any }"
	end

	if not plain then
		local keyKinds = {}
		local valueKinds = {}
		for key, item in pairs(value) do
			table.insert(keyKinds, type(key))
			table.insert(valueKinds, describeType(item, indent))
		end
		return string.format("{ [%s]: %s }", unionParts(keyKinds), unionParts(valueKinds))
	end

	table.sort(keys)

	local fields = {}
	for _, key in ipairs(keys) do
		table.insert(fields, string.format("%s%s: %s,", inner, formatKey(key), describeType(value[key], inner)))
	end
	return string.format("{\n%s\n%s}", table.concat(fields, "\n"), indent)
end

local function unionOf(kinds)
	local names = {}
	for kind in pairs(kinds) do
		table.insert(names, kind)
	end
	table.sort(names)
	return table.concat(names, " | ")
end

local function rowTypeSource(records, options)
	if #records == 0 then
		if options.headers then
			return string.format("export type Row = { [string]: %s }", valueType(options))
		end
		return string.format("export type Row = { %s }", valueType(options))
	end

	if not options.headers then
		local kinds = {}
		for _, record in ipairs(records) do
			for _, value in ipairs(record) do
				kinds[type(value)] = true
			end
		end
		return string.format("export type Row = { %s }", unionOf(kinds))
	end

	local columns = {}
	local order = {}
	for _, record in ipairs(records) do
		for key, value in pairs(record) do
			local column = columns[key]
			if not column then
				column = { kinds = {}, count = 0 }
				columns[key] = column
				table.insert(order, key)
			end
			column.kinds[type(value)] = true
			column.count = column.count + 1
		end
	end

	table.sort(order)

	local fields = {}
	for _, key in ipairs(order) do
		local column = columns[key]
		local kind = unionOf(column.kinds)
		if column.count < #records then
			if string.find(kind, "|", 1, true) then
				kind = string.format("(%s)?", kind)
			else
				kind = string.format("%s?", kind)
			end
		end
		table.insert(fields, string.format("\t%s: %s,", formatKey(key), kind))
	end

	return string.format("export type Row = {\n%s\n}", table.concat(fields, "\n"))
end

local function collectTags(node, seen, order)
	if not seen[node.tag] then
		seen[node.tag] = true
		table.insert(order, node.tag)
	end
	for _, child in ipairs(node.children) do
		collectTags(child, seen, order)
	end
end

local function nodeTypeSource(root, options)
	local attributeType = "string"
	if options.attributeValues then
		attributeType = valueType(options)
	end

	local tagType = "string"
	local lines = {}

	if options.tagUnion then
		local seen = {}
		local order = {}
		collectTags(root, seen, order)
		table.sort(order)

		local tags = {}
		for _, tag in ipairs(order) do
			table.insert(tags, roflux.luau.quote(tag))
		end

		table.insert(lines, string.format("export type Tag = %s", table.concat(tags, " | ")))
		table.insert(lines, "")
		tagType = "Tag"
	end

	table.insert(lines, "export type Node = {")
	table.insert(lines, string.format("\ttag: %s,", tagType))
	table.insert(lines, string.format("\tattributes: { [string]: %s },", attributeType))
	table.insert(lines, "\tchildren: { Node },")
	table.insert(lines, "\ttext: string,")
	table.insert(lines, "}")

	return table.concat(lines, "\n")
end

local function singletonType(value)
	local kind = type(value)
	if kind == "string" then
		return roflux.luau.quote(value)
	end
	if kind == "boolean" then
		return tostring(value)
	end
	return "number"
end

local function enumTypeSource(enums, container)
	local order = table.clone(enums)
	table.sort(order, function(a, b)
		return a.name < b.name
	end)

	local lines = {}
	for _, block in ipairs(order) do
		local names = table.clone(block.order)
		table.sort(names)

		local seen = {}
		local parts = {}
		for _, valueName in ipairs(names) do
			local kind = singletonType(block.values[valueName])
			if not seen[kind] then
				seen[kind] = true
				table.insert(parts, kind)
			end
		end

		table.insert(lines, string.format("export type %s = %s", block.name, table.concat(parts, " | ")))
	end

	table.insert(lines, "")
	table.insert(lines, string.format("export type %s = {", container))

	for _, block in ipairs(order) do
		local names = table.clone(block.order)
		table.sort(names)

		table.insert(lines, string.format("\t%s: {", block.name))
		for _, valueName in ipairs(names) do
			table.insert(lines, string.format("\t\t%s: %s,", valueName, singletonType(block.values[valueName])))
		end
		table.insert(lines, "\t},")
	end

	table.insert(lines, "}")
	return table.concat(lines, "\n")
end

local function transpileEnum(file, options)
	local text = stripBom(file.text or file.source or "")
	local enums = parseEnums(text, file.path, file.stem, options)

	local taken = {}
	local data = {}
	for _, block in ipairs(enums) do
		taken[block.name] = true
		data[block.name] = block.values
	end

	local container = "Enums"
	while taken[container] do
		container = container .. "s"
	end

	local typeSource = enumTypeSource(enums, container)

	return {
		source = buildModule(file, data, container, typeSource),
		value = data,
		typeName = container,
		typeSource = typeSource,
	}
end

local function unquote(value)
	local doubled = string.match(value, '^"(.*)"$')
	if doubled then
		return doubled
	end
	return string.match(value, "^'(.*)'$")
end

local function codepoint(value)
	if value < 128 then
		return string.char(value)
	end
	return utf8.char(value)
end

local simpleEscapes = {
	n = "\n",
	t = "\t",
	r = "\r",
}

local function unescape(value)
	if not string.find(value, "\\", 1, true) then
		return value
	end

	local out = {}
	local index = 1
	local length = #value

	while index <= length do
		local char = string.sub(value, index, index)
		if char ~= "\\" then
			table.insert(out, char)
			index = index + 1
		else
			local following = string.sub(value, index + 1, index + 1)
			if following == "u" then
				local hex = string.match(value, "^%x%x%x%x", index + 2)
				if hex then
					table.insert(out, codepoint(tonumber(hex, 16)))
					index = index + 6
				else
					table.insert(out, following)
					index = index + 2
				end
			else
				table.insert(out, simpleEscapes[following] or following)
				index = index + 2
			end
		end
	end

	return table.concat(out)
end

local function keyParts(key)
	local parts = {}
	for part in string.gmatch(key, "[^%.]+") do
		table.insert(parts, part)
	end
	return parts
end

local function nestBranch(root, key)
	local parts = keyParts(key)
	if #parts == 0 then
		return nil
	end

	local section = root
	for _, part in ipairs(parts) do
		local child = section[part]
		if child == nil then
			child = {}
			section[part] = child
		elseif type(child) ~= "table" then
			return nil
		end
		section = child
	end

	return section
end

local function nestInto(root, key, value)
	local parts = keyParts(key)
	if #parts == 0 then
		return false
	end

	local section = root
	for index = 1, #parts - 1 do
		local child = section[parts[index]]
		if child == nil then
			child = {}
			section[parts[index]] = child
		elseif type(child) ~= "table" then
			return false
		end
		section = child
	end

	local leaf = parts[#parts]
	if type(section[leaf]) == "table" then
		return false
	end

	section[leaf] = value
	return true
end

local function sourceLines(file)
	return roflux.text.lines(stripBom(file.text or file.source or ""))
end

local function dataModule(file, value, typeName)
	local typeSource = string.format("export type %s = %s", typeName, describeType(value, ""))
	return {
		source = buildModule(file, value, typeName, typeSource),
		value = value,
		typeName = typeName,
		typeSource = typeSource,
	}
end

local function transpileIni(file, options)
	local data = {}
	local section = data

	for number, line in ipairs(sourceLines(file)) do
		local trimmed = roflux.text.trim(line)
		local opening = string.sub(trimmed, 1, 1)
		if trimmed ~= "" and opening ~= ";" and opening ~= "#" then
			local header = string.match(trimmed, "^%[%s*(.-)%s*%]$")
			if header then
				if header == "" then
					error(string.format("%s:%d: this section has no name", file.path, number), 0)
				end

				if options.nest then
					section = nestBranch(data, header)
					if not section then
						error(string.format('%s:%d: "%s" cannot nest, a value already sits there', file.path, number, header), 0)
					end
				else
					local existing = data[header]
					if type(existing) == "table" then
						section = existing
					else
						section = {}
						data[header] = section
					end
				end
			else
				local key, value = string.match(trimmed, "^(.-)%s*[=:]%s*(.*)$")
				if not key or roflux.text.trim(key) == "" then
					error(string.format("%s:%d: this line is not a name and a value", file.path, number), 0)
				end

				local literal = unquote(value)
				section[roflux.text.trim(key)] = literal or coerce(value, options)
			end
		end
	end

	return dataModule(file, data, "Data")
end

local function transpileProperties(file, options)
	local data = {}

	for number, line in ipairs(sourceLines(file)) do
		local trimmed = roflux.text.trim(line)
		local opening = string.sub(trimmed, 1, 1)
		if trimmed ~= "" and opening ~= "#" and opening ~= "!" then
			local key, value = string.match(trimmed, "^(.-)%s*[=:]%s*(.*)$")
			if not key or roflux.text.trim(key) == "" then
				key = trimmed
				value = ""
			end

			key = roflux.text.trim(key)
			if options.escapes then
				value = unescape(value)
			end

			if options.nest then
				if not nestInto(data, key, value) then
					error(
						string.format('%s:%d: "%s" cannot nest, another name already sits there', file.path, number, key),
						0
					)
				end
			else
				data[key] = value
			end
		end
	end

	return dataModule(file, data, "Data")
end

local function transpilePo(file)
	local messages = {}
	local contexts = {}
	local entry = nil
	local slot = 0
	local field = nil

	local function start()
		if not entry then
			entry = { id = nil, context = nil, plural = nil, values = {} }
		end
		return entry
	end

	local function append(text)
		local value = unescape(unquote(roflux.text.trim(text)) or "")
		if not entry or not field then
			return
		end

		if field == "context" then
			entry.context = (entry.context or "") .. value
		elseif field == "id" then
			entry.id = (entry.id or "") .. value
		elseif field == "plural" then
			entry.plural = (entry.plural or "") .. value
		else
			entry.values[slot] = (entry.values[slot] or "") .. value
		end
	end

	local function flush()
		if entry and entry.id and entry.id ~= "" then
			local value = entry.values[1] or ""
			if entry.plural then
				value = entry.values
			end

			if entry.context and entry.context ~= "" then
				local bucket = contexts[entry.context]
				if not bucket then
					bucket = {}
					contexts[entry.context] = bucket
				end
				bucket[entry.id] = value
			else
				messages[entry.id] = value
			end
		end

		entry = nil
		field = nil
		slot = 0
	end

	for _, line in ipairs(sourceLines(file)) do
		local trimmed = roflux.text.trim(line)
		if trimmed == "" then
			flush()
		elseif string.sub(trimmed, 1, 1) ~= "#" then
			local indexed, indexedText = string.match(trimmed, "^msgstr%[(%d+)%]%s*(.*)$")
			if indexed then
				start()
				field = "value"
				slot = (tonumber(indexed) or 0) + 1
				append(indexedText)
			elseif string.sub(trimmed, 1, 1) == '"' then
				append(trimmed)
			else
				local keyword, rest = string.match(trimmed, "^([%a_]+)%s*(.*)$")
				if keyword == "msgctxt" then
					start()
					field = "context"
					append(rest)
				elseif keyword == "msgid" then
					start()
					field = "id"
					append(rest)
				elseif keyword == "msgid_plural" then
					start()
					field = "plural"
					append(rest)
				elseif keyword == "msgstr" then
					start()
					field = "value"
					slot = 1
					append(rest)
				end
			end
		end
	end

	flush()

	return dataModule(file, { messages = messages, contexts = contexts }, "Data")
end

local function subtitleTime(text, path, number)
	local hours, minutes, seconds, fraction = string.match(text, "^(%d+):(%d+):(%d+)[,%.](%d+)$")
	if not hours then
		hours = "0"
		minutes, seconds, fraction = string.match(text, "^(%d+):(%d+)[,%.](%d+)$")
	end
	if not minutes then
		error(string.format("%s:%d: %s is not a time", path, number, text), 0)
	end

	return (tonumber(hours) or 0) * 3600
		+ (tonumber(minutes) or 0) * 60
		+ (tonumber(seconds) or 0)
		+ (tonumber("0." .. fraction) or 0)
end

local function transpileSubtitles(file)
	local cues = {}
	local block = {}
	local blockStart = 1

	local function flush()
		if #block == 0 then
			return
		end

		local timing = nil
		for position, line in ipairs(block) do
			if string.find(line, "-->", 1, true) then
				timing = position
				break
			end
		end

		if timing then
			local startText, finishText = string.match(block[timing], "^%s*(%S+)%s*%-%->%s*(%S+)")
			if not startText then
				error(string.format("%s:%d: this cue has no start and end", file.path, blockStart + timing - 1), 0)
			end

			local id = ""
			if timing > 1 then
				id = roflux.text.trim(block[timing - 1])
			end

			table.insert(cues, {
				index = #cues + 1,
				id = id,
				start = subtitleTime(startText, file.path, blockStart + timing - 1),
				finish = subtitleTime(finishText, file.path, blockStart + timing - 1),
				text = roflux.text.trim(table.concat(block, "\n", timing + 1)),
			})
		end

		table.clear(block)
	end

	for number, line in ipairs(sourceLines(file)) do
		if roflux.text.trim(line) == "" then
			flush()
		else
			if #block == 0 then
				blockStart = number
			end
			table.insert(block, line)
		end
	end

	flush()

	if #cues == 0 then
		error(string.format("%s holds no cues", file.path), 0)
	end

	return dataModule(file, cues, "Data")
end

local function transpileYarn(file, options)
	local lines = sourceLines(file)
	local nodes = {}
	local keyed = {}
	local index = 1

	while index <= #lines do
		if roflux.text.trim(lines[index]) == "" then
			index = index + 1
		else
			local headers = {}
			local opened = false
			local start = index

			while index <= #lines do
				local current = roflux.text.trim(lines[index])
				index = index + 1
				if current == "---" then
					opened = true
					break
				end
				if current ~= "" then
					local key, value = string.match(current, "^([%w_]+)%s*:%s*(.*)$")
					if not key then
						error(string.format("%s:%d: this header is not a name and a value", file.path, index - 1), 0)
					end
					headers[key] = roflux.text.trim(value)
				end
			end

			if not opened then
				error(string.format("%s:%d: this node never reaches ---", file.path, start), 0)
			end
			if not headers.title or headers.title == "" then
				error(string.format("%s:%d: this node has no title", file.path, start), 0)
			end

			local body = {}
			local closed = false
			while index <= #lines do
				local current = lines[index]
				index = index + 1
				if roflux.text.trim(current) == "===" then
					closed = true
					break
				end
				table.insert(body, current)
			end

			if not closed then
				error(string.format('%s:%d: "%s" never reaches ===', file.path, start, headers.title), 0)
			end
			if keyed[headers.title] then
				error(string.format('%s:%d: "%s" is declared twice', file.path, start, headers.title), 0)
			end

			local node = {
				title = headers.title,
				headers = headers,
				body = roflux.text.trim(table.concat(body, "\n")),
			}
			keyed[headers.title] = node
			table.insert(nodes, node)
		end
	end

	if #nodes == 0 then
		error(string.format("%s holds no nodes", file.path), 0)
	end

	local typeSource = table.concat({
		"export type Node = {",
		"\ttitle: string,",
		"\theaders: { [string]: string },",
		"\tbody: string,",
		"}",
		"",
		if options.keyed then "export type Data = { [string]: Node }" else "export type Data = { Node }",
	}, "\n")

	local value = nodes
	if options.keyed then
		value = keyed
	end

	return {
		source = buildModule(file, value, "Data", typeSource),
		value = value,
		typeName = "Data",
		typeSource = typeSource,
	}
end

local function transpilePalette(file)
	local lines = sourceLines(file)
	local kind = roflux.text.trim(lines[1] or "")
	local palette = { name = file.stem, colors = {} }

	local function add(red, green, blue, label)
		local name = roflux.text.trim(label or "")
		if name == "" then
			name = string.format("color%d", #palette.colors + 1)
		end

		local r = tonumber(red) or 0
		local g = tonumber(green) or 0
		local b = tonumber(blue) or 0

		table.insert(palette.colors, {
			name = name,
			red = r,
			green = g,
			blue = b,
			hex = string.format("#%02X%02X%02X", r, g, b),
		})
	end

	if kind == "GIMP Palette" then
		for number = 2, #lines do
			local trimmed = roflux.text.trim(lines[number])
			local named = string.match(trimmed, "^Name:%s*(.+)$")
			if named then
				palette.name = named
			elseif trimmed ~= "" and string.sub(trimmed, 1, 1) ~= "#" and not string.match(trimmed, "^Columns:") then
				local red, green, blue, label = string.match(trimmed, "^(%d+)%s+(%d+)%s+(%d+)%s*(.*)$")
				if not red then
					error(string.format("%s:%d: this line is not a colour", file.path, number), 0)
				end
				add(red, green, blue, label)
			end
		end
	elseif kind == "JASC-PAL" then
		for number = 4, #lines do
			local trimmed = roflux.text.trim(lines[number])
			if trimmed ~= "" then
				local red, green, blue = string.match(trimmed, "^(%d+)%s+(%d+)%s+(%d+)")
				if not red then
					error(string.format("%s:%d: this line is not a colour", file.path, number), 0)
				end
				add(red, green, blue, "")
			end
		end
	else
		error(string.format("%s is neither a GIMP nor a JASC palette", file.path), 0)
	end

	if #palette.colors == 0 then
		error(string.format("%s holds no colours", file.path), 0)
	end

	return dataModule(file, palette, "Data")
end

local function transpileToml(file)
	local data = roflux.toml.decode(stripBom(file.text or file.source or ""))
	if type(data) ~= "table" then
		error(string.format("%s does not hold a table", file.path), 0)
	end

	local typeSource = string.format("export type Data = %s", describeType(data, ""))

	return {
		source = buildModule(file, data, "Data", typeSource),
		value = data,
		typeName = "Data",
		typeSource = typeSource,
	}
end

local function transpileText(file, options)
	local text = stripBom(file.text or file.source or "")
	if options.trim then
		text = roflux.text.trim(text)
	end

	local value = text
	local typeName = "string"
	if options.lines then
		value = roflux.text.lines(text)
		if #value > 0 and value[#value] == "" then
			table.remove(value)
		end
		typeName = "{ string }"
	end

	local typeSource = string.format("export type Data = %s", typeName)

	return {
		source = buildModule(file, value, "Data", typeSource),
		value = value,
		typeName = "Data",
		typeSource = typeSource,
	}
end

local function transpileJsonLines(file)
	local records = {}
	for index, line in ipairs(roflux.text.lines(stripBom(file.text or file.source or ""))) do
		local trimmed = roflux.text.trim(line)
		if trimmed ~= "" then
			local ok, decoded = pcall(roflux.json.decode, trimmed)
			if not ok then
				error(string.format("%s:%d: %s", file.path, index, tostring(decoded)), 0)
			end
			table.insert(records, decoded)
		end
	end

	local typeSource = string.format("export type Data = %s", describeType(records, ""))

	return {
		source = buildModule(file, records, "Data", typeSource),
		value = records,
		typeName = "Data",
		typeSource = typeSource,
	}
end

local function frontmatterValue(text)
	local quoted = string.match(text, '^"(.*)"$') or string.match(text, "^'(.*)'$")
	if quoted then
		return quoted
	end
	if text == "true" then
		return true
	end
	if text == "false" then
		return false
	end

	local number = toNumber(text)
	if number then
		return number
	end
	return text
end

local function transpileMarkdown(file, options)
	local lines = roflux.text.lines(stripBom(file.text or file.source or ""))
	local meta = {}
	local start = 1

	if options.frontmatter and #lines > 0 then
		local fence = roflux.text.trim(lines[1])
		if frontmatterFences[fence] then
			local closed = false
			for index = 2, #lines do
				if roflux.text.trim(lines[index]) == fence then
					start = index + 1
					closed = true
					break
				end

				local key, value = string.match(lines[index], "^%s*([%w_%-%.]+)%s*[:=]%s*(.*)$")
				if key then
					meta[key] = frontmatterValue(roflux.text.trim(value))
				end
			end
			if not closed then
				error(string.format("%s:1: the frontmatter block was never closed", file.path), 0)
			end
		end
	end

	local sections = {}
	if options.sections then
		local pending = nil

		local function close()
			if not pending then
				return
			end
			pending.text = roflux.text.trim(table.concat(pending.body, "\n"))
			pending.body = nil
			table.insert(sections, pending)
			pending = nil
		end

		for index = start, #lines do
			local hashes, heading = string.match(lines[index], "^(#+)%s+(.+)$")
			if hashes then
				close()
				pending = { heading = roflux.text.trim(heading), level = #hashes, text = "", body = {} }
			elseif pending then
				table.insert(pending.body, lines[index])
			end
		end

		close()
	end

	local data = {
		meta = meta,
		text = roflux.text.trim(table.concat(lines, "\n", math.min(start, #lines + 1), #lines)),
		sections = sections,
	}

	local typeSource = table.concat({
		"export type Section = {",
		"\theading: string,",
		"\tlevel: number,",
		"\ttext: string,",
		"}",
		"",
		"export type Data = {",
		string.format("\tmeta: %s,", describeType(meta, "\t")),
		"\tsections: { Section },",
		"\ttext: string,",
		"}",
	}, "\n")

	return {
		source = buildModule(file, data, "Data", typeSource),
		value = data,
		typeName = "Data",
		typeSource = typeSource,
	}
end

local function yamlComment(text)
	local index = 1
	local length = #text
	local quote = nil

	while index <= length do
		local char = string.sub(text, index, index)
		if quote then
			if char == quote then
				quote = nil
			end
		elseif char == '"' or char == "'" then
			quote = char
		elseif char == "#" and (index == 1 or string.sub(text, index - 1, index - 1) == " ") then
			return roflux.text.trim(string.sub(text, 1, index - 1))
		end
		index = index + 1
	end

	return text
end

local yamlNulls = {
	[""] = true,
	["~"] = true,
	["null"] = true,
}

local yamlBooleans = {
	["true"] = true,
	["yes"] = true,
	["on"] = true,
	["false"] = false,
	["no"] = false,
	["off"] = false,
}

local yamlMarkers = {
	["&"] = true,
	["*"] = true,
	["!"] = true,
}

local function yamlScalar(text, path, line)
	if yamlNulls[text] then
		return nil
	end

	if yamlMarkers[string.sub(text, 1, 1)] then
		error(string.format("%s:%d: anchors, aliases and tags are more yaml than this reads", path, line), 0)
	end

	local quoted = unquote(text)
	if quoted then
		return unescape(quoted)
	end

	local flag = yamlBooleans[text]
	if flag ~= nil then
		return flag
	end

	local numeric = tonumber(text)
	if numeric and string.match(text, "^[-+]?[%d%.eE+-]+$") then
		return numeric
	end
	return text
end

local function yamlFlow(text, path, number)
	local list = string.match(text, "^%[(.*)%]$")
	if list then
		local items = {}
		for piece in string.gmatch(list, "[^,]+") do
			local value = yamlScalar(roflux.text.trim(piece), path, number)
			if value ~= nil then
				table.insert(items, value)
			end
		end
		return items, true
	end

	local map = string.match(text, "^{(.*)}$")
	if map then
		local fields = {}
		for piece in string.gmatch(map, "[^,]+") do
			local key, value = string.match(piece, "^%s*(.-)%s*:%s*(.*)$")
			if key and key ~= "" then
				fields[unquote(key) or key] = yamlScalar(roflux.text.trim(value), path, number)
			end
		end
		return fields, true
	end

	return nil, false
end

local function parseYaml(file)
	local path = file.path
	local items = {}
	local documents = 0

	for number, line in ipairs(sourceLines(file)) do
		if string.match(line, "^\t") then
			error(string.format("%s:%d: yaml is written with spaces, not tabs", path, number), 0)
		end

		local content = roflux.text.trim(line)
		if content ~= "" and string.sub(content, 1, 1) ~= "#" then
			content = yamlComment(content)
			if content == "---" or content == "..." then
				documents = documents + 1
				if documents > 1 then
					error(string.format("%s:%d: this file holds more than one document", path, number), 0)
				end
			elseif content ~= "" then
				table.insert(items, {
					indent = #(string.match(line, "^ *") or ""),
					text = content,
					number = number,
				})
			end
		end
	end

	if #items == 0 then
		error(string.format("%s holds nothing", path), 0)
	end

	local cursor = 1

	local function isEntry(text)
		return string.sub(text, 1, 2) == "- " or text == "-"
	end

	local function parseValue(indent)
		local item = items[cursor]
		if not item or item.indent < indent then
			return nil
		end

		if isEntry(item.text) then
			local list = {}
			while true do
				item = items[cursor]
				if not item or item.indent < indent or not isEntry(item.text) then
					break
				end

				local rest = roflux.text.trim(string.sub(item.text, 2))
				local position = cursor
				cursor = cursor + 1

				if rest == "" then
					table.insert(list, parseValue(item.indent + 1))
				else
					local flow, isFlow = yamlFlow(rest, path, item.number)
					if isFlow then
						table.insert(list, flow)
					elseif string.find(rest, ":", 1, true) then
						items[position] = { indent = item.indent + 2, text = rest, number = item.number }
						cursor = position
						table.insert(list, parseValue(item.indent + 2))
					else
						table.insert(list, yamlScalar(rest, path, item.number))
					end
				end
			end
			return list
		end

		local fields = {}
		while true do
			item = items[cursor]
			if not item or item.indent < indent or isEntry(item.text) then
				break
			end

			local key, rest = string.match(item.text, "^(.-)%s*:%s*(.*)$")
			if not key or key == "" then
				error(string.format("%s:%d: this line is not a name and a value", path, item.number), 0)
			end

			local depth = item.indent
			cursor = cursor + 1
			key = unquote(key) or key

			if rest == "|" or rest == ">" then
				local parts = {}
				while true do
					local following = items[cursor]
					if not following or following.indent <= depth then
						break
					end
					table.insert(parts, following.text)
					cursor = cursor + 1
				end
				if rest == "|" then
					fields[key] = table.concat(parts, "\n")
				else
					fields[key] = table.concat(parts, " ")
				end
			elseif rest == "" then
				local nested = parseValue(depth + 1)
				if nested ~= nil then
					fields[key] = nested
				end
			else
				local flow, isFlow = yamlFlow(rest, path, item.number)
				if isFlow then
					fields[key] = flow
				else
					local value = yamlScalar(rest, path, item.number)
					if value ~= nil then
						fields[key] = value
					end
				end
			end
		end

		return fields
	end

	return parseValue(0)
end

local function transpileYaml(file)
	local data = parseYaml(file)
	if type(data) ~= "table" then
		error(string.format("%s does not hold a table", file.path), 0)
	end
	return dataModule(file, data, "Data")
end

local function tiledChild(node, tag)
	for _, child in ipairs(node.children) do
		if child.tag == tag then
			return child
		end
	end
	return nil
end

local function tiledProperties(node)
	local properties = {}
	local holder = tiledChild(node, "properties")
	if not holder then
		return properties
	end

	for _, child in ipairs(holder.children) do
		if child.tag == "property" and child.attributes.name then
			local value = child.attributes.value or child.text
			local kind = child.attributes.type or "string"
			if kind == "int" or kind == "float" then
				properties[child.attributes.name] = tonumber(value) or 0
			elseif kind == "bool" then
				properties[child.attributes.name] = value == "true"
			else
				properties[child.attributes.name] = value
			end
		end
	end

	return properties
end

local function tiledNumbers(text)
	local values = {}
	for piece in string.gmatch(text, "[^,%s]+") do
		local number = tonumber(piece)
		if number then
			table.insert(values, number)
		end
	end
	return values
end

local tiledTypeSource = table.concat({
	"export type Property = { [string]: string | number | boolean }",
	"",
	"export type Object = {",
	"\tid: number,",
	"\tname: string,",
	"\tkind: string,",
	"\tx: number,",
	"\ty: number,",
	"\twidth: number,",
	"\theight: number,",
	"\tgid: number,",
	"\tproperties: Property,",
	"}",
	"",
	"export type Layer = {",
	"\tkind: string,",
	"\tname: string,",
	"\twidth: number,",
	"\theight: number,",
	"\tvisible: boolean,",
	"\tproperties: Property,",
	"\ttiles: { number },",
	"\tobjects: { Object },",
	"}",
	"",
	"export type Tileset = {",
	"\tfirstGid: number,",
	"\tname: string,",
	"\tsource: string,",
	"\ttileWidth: number,",
	"\ttileHeight: number,",
	"}",
	"",
	"export type Data = {",
	"\torientation: string,",
	"\twidth: number,",
	"\theight: number,",
	"\ttileWidth: number,",
	"\ttileHeight: number,",
	"\tproperties: Property,",
	"\ttilesets: { Tileset },",
	"\tlayers: { Layer },",
	"}",
}, "\n")

local function transpileTiled(file, options)
	local root = parseXml(stripBom(file.text or file.source or ""), file.path, options)
	if root.tag ~= "map" then
		error(string.format("%s does not start with a map", file.path), 0)
	end

	local map = {
		orientation = root.attributes.orientation or "orthogonal",
		width = tonumber(root.attributes.width) or 0,
		height = tonumber(root.attributes.height) or 0,
		tileWidth = tonumber(root.attributes.tilewidth) or 0,
		tileHeight = tonumber(root.attributes.tileheight) or 0,
		properties = tiledProperties(root),
		tilesets = {},
		layers = {},
	}

	for _, child in ipairs(root.children) do
		if child.tag == "tileset" then
			table.insert(map.tilesets, {
				firstGid = tonumber(child.attributes.firstgid) or 0,
				name = child.attributes.name or "",
				source = child.attributes.source or "",
				tileWidth = tonumber(child.attributes.tilewidth) or 0,
				tileHeight = tonumber(child.attributes.tileheight) or 0,
			})
		elseif child.tag == "layer" then
			local name = child.attributes.name or ""
			local data = tiledChild(child, "data")
			if not data then
				error(string.format('%s: the layer "%s" holds no data', file.path, name), 0)
			end

			local encoding = data.attributes.encoding
			if encoding ~= "csv" then
				error(
					string.format('%s: the layer "%s" is %s, save the map with csv layer data', file.path, name, encoding or "plain xml"),
					0
				)
			end

			table.insert(map.layers, {
				kind = "tiles",
				name = name,
				width = tonumber(child.attributes.width) or map.width,
				height = tonumber(child.attributes.height) or map.height,
				visible = child.attributes.visible ~= "0",
				properties = tiledProperties(child),
				tiles = tiledNumbers(data.text),
				objects = {},
			})
		elseif child.tag == "objectgroup" then
			local objects = {}
			for _, object in ipairs(child.children) do
				if object.tag == "object" then
					table.insert(objects, {
						id = tonumber(object.attributes.id) or 0,
						name = object.attributes.name or "",
						kind = object.attributes.type or "",
						x = tonumber(object.attributes.x) or 0,
						y = tonumber(object.attributes.y) or 0,
						width = tonumber(object.attributes.width) or 0,
						height = tonumber(object.attributes.height) or 0,
						gid = tonumber(object.attributes.gid) or 0,
						properties = tiledProperties(object),
					})
				end
			end

			table.insert(map.layers, {
				kind = "objects",
				name = child.attributes.name or "",
				width = 0,
				height = 0,
				visible = child.attributes.visible ~= "0",
				properties = tiledProperties(child),
				tiles = {},
				objects = objects,
			})
		end
	end

	return {
		source = buildModule(file, map, "Data", tiledTypeSource),
		value = map,
		typeName = "Data",
		typeSource = tiledTypeSource,
	}
end

local function transpileDelimited(file, options)
	local text = stripBom(file.text or file.source or "")
	local rows = parseDelimited(text, options.delimiter, file.path)
	local records = shapeDelimited(rows, options)
	local rowType = rowTypeSource(records, options)

	return {
		source = buildModule(file, records, "{ Row }", rowType),
		value = records,
		typeName = "{ Row }",
		typeSource = rowType,
	}
end

local function transpileXml(file, options)
	local text = stripBom(file.text or file.source or "")
	local root = parseXml(text, file.path, options)
	local nodeType = nodeTypeSource(root, options)

	return {
		source = buildModule(file, root, "Node", nodeType),
		value = root,
		typeName = "Node",
		typeSource = nodeType,
	}
end

local function writeMeta(file, built)
	local style = moduleOptions.meta
	if not style then
		return
	end

	if style == "data" then
		roflux.meta(file, built.value)
	elseif style == "source" then
		roflux.meta(file, built.source)
	else
		roflux.meta(file, string.format("%s\n\nreturn (nil :: any) :: %s\n", built.typeSource, built.typeName))
	end
end

local function guard(file, run)
	local ok, result = pcall(function()
		local built = run()
		writeMeta(file, built)
		return built.source
	end)

	if ok then
		return result
	end

	local message = tostring(result)
	roflux.error(string.format("transpile failed for %s: %s", file.path, message))
	return string.format(
		"--!strict\n\nerror(%s)\n",
		roflux.luau.quote(string.format("%s could not be transpiled: %s", file.path, message))
	)
end

local transpiler = {
	csv = csvOptions,
	tsv = tsvOptions,
	psv = psvOptions,
	xml = xmlOptions,
	enum = enumOptions,
	text = textOptions,
	doc = docOptions,
	ini = iniOptions,
	properties = propertyOptions,
	yarn = yarnOptions,
	module = moduleOptions,
	parseDelimited = parseDelimited,
	shapeDelimited = shapeDelimited,
	parseXml = parseXml,
	parseEnums = parseEnums,
	parseYaml = parseYaml,
	describeType = describeType,
	encode = encode,
	build = buildModule,
}

roflux.transpile("csv", function(file)
	return guard(file, function()
		return transpileDelimited(file, csvOptions)
	end)
end)

roflux.transpile("tsv", function(file)
	return guard(file, function()
		return transpileDelimited(file, tsvOptions)
	end)
end)

roflux.transpile("xml", function(file)
	return guard(file, function()
		return transpileXml(file, xmlOptions)
	end)
end)

roflux.transpile("enum", function(file)
	return guard(file, function()
		return transpileEnum(file, enumOptions)
	end)
end)

roflux.transpile("psv", function(file)
	return guard(file, function()
		return transpileDelimited(file, psvOptions)
	end)
end)

roflux.transpile("toml", function(file)
	return guard(file, function()
		return transpileToml(file)
	end)
end)

for _, extension in { "yaml", "yml" } do
	roflux.transpile(extension, function(file)
		return guard(file, function()
			return transpileYaml(file)
		end)
	end)
end

for _, extension in { "jsonl", "ndjson" } do
	roflux.transpile(extension, function(file)
		return guard(file, function()
			return transpileJsonLines(file)
		end)
	end)
end

for _, extension in { "ini", "cfg" } do
	roflux.transpile(extension, function(file)
		return guard(file, function()
			return transpileIni(file, iniOptions)
		end)
	end)
end

for _, extension in { "properties", "lang" } do
	roflux.transpile(extension, function(file)
		return guard(file, function()
			return transpileProperties(file, propertyOptions)
		end)
	end)
end

for _, extension in { "po", "pot" } do
	roflux.transpile(extension, function(file)
		return guard(file, function()
			return transpilePo(file)
		end)
	end)
end

for _, extension in { "srt", "vtt" } do
	roflux.transpile(extension, function(file)
		return guard(file, function()
			return transpileSubtitles(file)
		end)
	end)
end

roflux.transpile("yarn", function(file)
	return guard(file, function()
		return transpileYarn(file, yarnOptions)
	end)
end)

for _, extension in { "gpl", "pal" } do
	roflux.transpile(extension, function(file)
		return guard(file, function()
			return transpilePalette(file)
		end)
	end)
end

roflux.transpile("tmx", function(file)
	return guard(file, function()
		return transpileTiled(file, xmlOptions)
	end)
end)

roflux.transpile("txt", function(file)
	return guard(file, function()
		return transpileText(file, textOptions)
	end)
end)

for _, extension in { "md", "markdown" } do
	roflux.transpile(extension, function(file)
		if docOptions.skip[file.stem] then
			return nil
		end
		return guard(file, function()
			return transpileMarkdown(file, docOptions)
		end)
	end)
end

return transpiler
