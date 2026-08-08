--!nocheck

export type Method = (self: any, ...any) -> ...any

export type MemberTable = { [string]: any }

export type Object = { [string]: any }

export type Class = ((...any) -> Object) & { Name: string, [string]: any }

export type Interface = {
	__lehua: string,
	Name: string,
	Requires: { [string]: string },
	Extends: { Interface },
}

export type InterfaceSpec = {
	Name: string,
	Requires: { string } | { [string]: string },
	Extends: { Interface }?,
}

export type Metadata = { [any]: any }

export type InheritPick = {
	Class: Class,
	Public: { string }?,
	Private: { string }?,
	Static: { string }?,
	Meta: { string }?,
}

export type ClassDecl = {
	Name: string,
	Private: MemberTable?,
	Public: MemberTable?,
	Static: MemberTable?,
	Meta: MemberTable?,
	Inherits: (Class | { InheritPick })?,
	Interfaces: { Interface }?,
	Strict: boolean?,
	Abstract: boolean?,
	Sealed: boolean?,
	[string]: any,
}

export type LehuaClassModule = {
	None: any,
	NewClassData: (decl: ClassDecl) -> Class,
	BuildClassData: (class: Class, ...any) -> Object,
	SuperGet: (class: Class, memberName: string) -> ((self: any, ...any) -> ...any),
	Interface: (spec: InterfaceSpec) -> Interface,
	Implements: (value: any, iface: Interface) -> (boolean, { string }),
	IsA: (value: any, classOrName: Class | string) -> boolean,
	FetchClass: (value: any) -> Class?,
	GetMetaData: (value: any) -> Metadata,
	IsClass: (value: any) -> boolean,
	IsInstance: (value: any) -> boolean,
	Ref: (value: any) -> Object?,
	IsInterface: (value: any) -> boolean,
	TypeOf: (value: any) -> string,
	Inspect: (value: any) -> string,
	Globalize: (target: MemberTable?) -> LehuaClassModule,
}

local LehuaClass = {}

local INTERFACE_TAG = "LehuaClass.Interface"

local None = table.freeze(setmetatable({}, table.freeze({
	__tostring = function()
		return "LehuaClass.None"
	end,
})))
LehuaClass.None = None

local handleToDef = setmetatable({}, { __mode = "k" })
local outerToRecord = setmetatable({}, { __mode = "k" })
local innerToOuter = setmetatable({}, { __mode = "kv" })
local innerToDef = setmetatable({}, { __mode = "k" })
local classesByName = setmetatable({}, { __mode = "v" })

local instanceCounter = 0

local function wordList(t: { string }): string
	if #t == 0 then
		return "(none)"
	end
	return "'" .. table.concat(t, "', '") .. "'"
end

local function sortedKeys(map: { [string]: any }): { string }
	local keys = {}
	for k in pairs(map) do
		table.insert(keys, tostring(k))
	end
	table.sort(keys)
	return keys
end

local function deepCopy(value: any, seen: { [any]: any }): any
	if type(value) ~= "table" then
		return value
	end
	if value == None or outerToRecord[value] ~= nil or handleToDef[value] ~= nil then
		return value
	end
	local hit = seen[value]
	if hit ~= nil then
		return hit
	end
	local out = {}
	seen[value] = out
	for k, v in pairs(value) do
		out[deepCopy(k, seen)] = deepCopy(v, seen)
	end
	return setmetatable(out, getmetatable(value))
end

local function instantiateValue(v: any): any
	if v == None then
		return nil
	end
	return deepCopy(v, {})
end

local function mergeMetadata(into: Metadata, from: Metadata)
	local count = #from

	for i = 1, count do
		local value = from[i]
		local duplicate = false
		for j = 1, #into do
			if into[j] == value then
				duplicate = true
				break
			end
		end
		if not duplicate then
			table.insert(into, value)
		end
	end

	for k, v in pairs(from) do
		local isArrayEntry = type(k) == "number" and k % 1 == 0 and k >= 1 and k <= count
		if not isArrayEntry then
			local existing = into[k]
			if type(existing) == "table" and type(v) == "table" then
				local merged = {}
				mergeMetadata(merged, existing)
				mergeMetadata(merged, v)
				into[k] = merged
			else
				into[k] = v
			end
		end
	end
end

local function unwrapOne(v: any): any
	if type(v) == "table" then
		local rec = outerToRecord[v]
		if rec ~= nil then
			return rec.fields
		end
	end
	return v
end

local function rewrapOne(v: any): any
	if type(v) == "table" then
		local outer = innerToOuter[v]
		if outer ~= nil then
			return outer
		end
	end
	return v
end

local function rewrapResults(...: any): ...any
	local n = select("#", ...)
	if n == 0 then
		return
	elseif n == 1 then
		return rewrapOne(...)
	end
	local out = table.create(n)
	for i = 1, n do
		out[i] = rewrapOne((select(i, ...)))
	end
	return table.unpack(out, 1, n)
end

local function resolveInstance(value: any): (any, any, any)
	if type(value) ~= "table" then
		return nil
	end
	local rec = outerToRecord[value]
	if rec ~= nil then
		return rec.def, rec.fields, rec
	end
	local outer = innerToOuter[value]
	if outer ~= nil then
		rec = outerToRecord[outer]
		if rec ~= nil then
			return rec.def, rec.fields, rec
		end
	end
	local def = innerToDef[value]
	if def ~= nil then
		return def, value, nil
	end
	return nil
end

local function staticLookup(def: any, key: string): any
	local v = def.ownStatics[key]
	if v ~= nil then
		return v
	end
	for _, parent in ipairs(def.staticParents) do
		v = staticLookup(parent, key)
		if v ~= nil then
			return v
		end
	end
	return nil
end

local function makeBound(def: any, name: string): Method
	return function(selfArg, ...)
		local rec = type(selfArg) == "table" and outerToRecord[selfArg] or nil
		if rec == nil then
			error(
				("%s.%s is a method — call it as instance:%s(...)"):format(def.name, name, name),
				2
			)
		end
		local impl = rec.def.pubMethods[name] or def.pubMethods[name]
		return rewrapResults(impl(rec.fields, ...))
	end
end

local function getBound(def: any, name: string): Method
	local cached = def.boundCache[name]
	if cached == nil then
		cached = makeBound(def, name)
		def.boundCache[name] = cached
	end
	return cached
end

local SPECIAL_META = {
	__construct = true,
	__setup = true,
	__tostring = true,
	__type = true,
	__toconsole = true,
}

local RESERVED_META = {
	__index = true,
	__newindex = true,
	__metatable = true,
	__mode = true,
}

local function wrapMetamethod(fn: Method): Method
	return function(...)
		local n = select("#", ...)
		local args = table.create(n)
		for i = 1, n do
			args[i] = unwrapOne((select(i, ...)))
		end
		return rewrapResults(fn(table.unpack(args, 1, n)))
	end
end

local function buildOuterMeta(def: any)
	local meta = {}

	meta.__index = function(proxy, key)
		local rec = outerToRecord[proxy]
		if def.pubMethods[key] ~= nil then
			return getBound(def, key)
		end
		if def.privateKeySet[key] then
			error(
				("'%s.%s' is private — only %s methods can reach it through self"):format(
					def.name, tostring(key), def.name
				),
				2
			)
		end
		if def.publicFieldSet[key] or rec.extraPublic[key] then
			return rec.fields[key]
		end
		local sv = staticLookup(def, key)
		if sv ~= nil then
			return sv
		end
		if def.strict then
			error(
				("'%s' is not a member of class '%s' (public: %s)"):format(
					tostring(key), def.name, wordList(sortedKeys(def.publicFieldSet))
				),
				2
			)
		end
		return nil
	end

	meta.__newindex = function(proxy, key, value)
		local rec = outerToRecord[proxy]
		if def.privateKeySet[key] then
			error(("cannot write private member '%s.%s' from outside"):format(def.name, tostring(key)), 2)
		end
		if def.pubMethods[key] ~= nil then
			error(("cannot overwrite method '%s.%s' on an instance"):format(def.name, tostring(key)), 2)
		end
		if def.publicFieldSet[key] or rec.extraPublic[key] then
			rec.fields[key] = value
			return
		end
		if staticLookup(def, key) ~= nil then
			error(
				("'%s' is a static of '%s' — assign it on the class handle, not an instance"):format(
					tostring(key), def.name
				),
				2
			)
		end
		if def.strict then
			error(
				("cannot create undeclared member '%s' on strict class '%s'"):format(tostring(key), def.name),
				2
			)
		end
		rec.extraPublic[key] = true
		rec.fields[key] = value
	end

	meta.__tostring = function(proxy)
		local rec = outerToRecord[proxy]
		local custom = def.meta.__tostring
		if custom ~= nil then
			return tostring(custom(rec.fields))
		end
		return def.name .. "#" .. rec.id
	end

	meta.__metatable = "The metatable is locked"

	for name, fn in pairs(def.meta) do
		if not SPECIAL_META[name] and type(fn) == "function" then
			meta[name] = wrapMetamethod(fn)
		end
	end

	return meta
end

local function buildInnerMeta(def: any)
	return {
		__index = function(_, key)
			local m = def.pubMethods[key] or def.privMethods[key]
			if m ~= nil then
				return m
			end
			return staticLookup(def, key)
		end,
		__tostring = function(fields)
			local outer = innerToOuter[fields]
			if outer ~= nil then
				return tostring(outer)
			end
			return def.name .. "<inner>"
		end,
	}
end

function LehuaClass.Interface(spec: InterfaceSpec): Interface
	if type(spec) ~= "table" then
		error("Interface expects a table { Name = ..., Requires = ... }", 2)
	end
	if type(spec.Name) ~= "string" or spec.Name == "" then
		error("Interface requires a non-empty string Name", 2)
	end
	if type(spec.Requires) ~= "table" then
		error(("Interface '%s' requires a Requires table"):format(spec.Name), 2)
	end

	local requires = {}
	for k, v in pairs(spec.Requires) do
		if type(k) == "number" then
			if type(v) ~= "string" then
				error(("Interface '%s': Requires entries must be member-name strings"):format(spec.Name), 2)
			end
			requires[v] = "any"
		elseif type(k) == "string" then
			if type(v) ~= "string" then
				error(("Interface '%s': expected type for '%s' must be a string"):format(spec.Name, k), 2)
			end
			requires[k] = v
		else
			error(("Interface '%s': invalid Requires key of type %s"):format(spec.Name, type(k)), 2)
		end
	end

	local extends = {}
	if spec.Extends ~= nil then
		if type(spec.Extends) ~= "table" then
			error(("Interface '%s': Extends must be a list of interfaces"):format(spec.Name), 2)
		end
		for i, parent in ipairs(spec.Extends) do
			if type(parent) ~= "table" or parent.__lehua ~= INTERFACE_TAG then
				error(("Interface '%s': Extends[%d] is not an Interface"):format(spec.Name, i), 2)
			end
			extends[i] = parent
		end
	end

	return table.freeze({
		__lehua = INTERFACE_TAG,
		Name = spec.Name,
		Requires = table.freeze(requires),
		Extends = table.freeze(extends),
	})
end

local function isInterface(v: any): boolean
	return type(v) == "table" and rawget(v, "__lehua") == INTERFACE_TAG
end

local function gatherRequirements(iface: Interface, out: { [string]: string }, seen: { [any]: boolean }): { [string]: string }
	if seen[iface] then
		return out
	end
	seen[iface] = true
	for _, parent in ipairs(iface.Extends) do
		gatherRequirements(parent, out, seen)
	end
	for member, expected in pairs(iface.Requires) do
		out[member] = expected
	end
	return out
end

local function classProbe(def: any): (name: string) -> (boolean, string)
	return function(name)
		if def.pubMethods[name] ~= nil then
			return true, "function"
		end
		local fv = def.pubFields[name]
		if fv ~= nil then
			return true, fv == None and "nil" or type(fv)
		end
		local sv = staticLookup(def, name)
		if sv ~= nil then
			return true, type(sv)
		end
		local mv = def.meta[name]
		if mv ~= nil then
			return true, type(mv)
		end
		return false, "nil"
	end
end

local function instanceProbe(def: any, fields: any, rec: any): (name: string) -> (boolean, string)
	return function(name)
		if def.pubMethods[name] ~= nil then
			return true, "function"
		end
		if def.publicFieldSet[name] or (rec ~= nil and rec.extraPublic[name]) then
			return true, type(fields[name])
		end
		local sv = staticLookup(def, name)
		if sv ~= nil then
			return true, type(sv)
		end
		local mv = def.meta[name]
		if mv ~= nil then
			return true, type(mv)
		end
		return false, "nil"
	end
end

local function checkInterface(probe: (name: string) -> (boolean, string), iface: Interface): (boolean, { string })
	local missing = {}
	for member, expected in pairs(gatherRequirements(iface, {}, {})) do
		local present, valueType = probe(member)
		if not present then
			table.insert(missing, ("%s (missing)"):format(member))
		elseif expected ~= "any" and valueType ~= expected then
			table.insert(missing, ("%s (expected %s, got %s)"):format(member, expected, valueType))
		end
	end
	table.sort(missing)
	return #missing == 0, missing
end

function LehuaClass.Implements(value: any, iface: Interface): (boolean, { string })
	if not isInterface(iface) then
		error("Implements expects an Interface as its second argument", 2)
	end

	local def, fields, rec = resolveInstance(value)
	if def ~= nil then
		return checkInterface(instanceProbe(def, fields, rec), iface)
	end

	local classDef = handleToDef[value]
	if classDef ~= nil then
		return checkInterface(classProbe(classDef), iface)
	end

	if type(value) == "table" then
		return checkInterface(function(name)
			local v = value[name]
			if v == nil then
				return false, "nil"
			end
			return true, type(v)
		end, iface)
	end

	return false, { "(value is not a table, instance, or class)" }
end

local KNOWN_DECL_KEYS = {
	Name = true,
	Private = true,
	Public = true,
	Static = true,
	Meta = true,
	Inherits = true,
	Interfaces = true,
	Strict = true,
	Abstract = true,
	Sealed = true,
}

local function assertMemberTable(className: string, t: any, label: string): MemberTable
	if t ~= nil and type(t) ~= "table" then
		error(("class '%s': %s must be a table"):format(className, label), 3)
	end
	return t or {}
end

local function absorbMembers(className: string, src: MemberTable, fieldsDst: MemberTable, methodsDst: MemberTable, label: string)
	for k, v in pairs(src) do
		if type(k) ~= "string" then
			error(("class '%s': %s member names must be strings"):format(className, label), 3)
		end
		if k:sub(1, 2) == "__" then
			error(
				("class '%s': metamethod '%s' belongs at the top level of the declaration, not inside %s"):format(
					className, k, label
				),
				3
			)
		end
		if type(v) == "function" then
			methodsDst[k] = v
			fieldsDst[k] = nil
		else
			fieldsDst[k] = v
			methodsDst[k] = nil
		end
	end
end

local function absorbMeta(def: any, key: string, value: any, className: string)
	if RESERVED_META[key] then
		error(("class '%s': metamethod '%s' is reserved by LehuaClass"):format(className, key), 3)
	end
	if key == "__construct" then
		if type(value) ~= "function" then
			error(("class '%s': __construct must be a function"):format(className), 3)
		end
		def.construct = value
		return
	end
	if key == "__setup" then
		if type(value) ~= "function" then
			error(("class '%s': __setup must be a function"):format(className), 3)
		end
		def.setup = value
		return
	end
	if key == "__metadata" then
		if type(value) ~= "table" then
			error(("class '%s': __metadata must be a table"):format(className), 3)
		end
		def.ownMetadata = value
		return
	end
	if key ~= "__type" and type(value) ~= "function" then
		error(("class '%s': metamethod '%s' must be a function"):format(className, key), 3)
	end
	def.meta[key] = value
end

local function pickMembers(className: string, parentDef: any, names: { string }?, sources: { { from: MemberTable, into: MemberTable } }, label: string)
	if names == nil then
		return
	end
	if type(names) ~= "table" then
		error(("class '%s': Inherits entry %s must be a list of member names"):format(className, label), 3)
	end
	for _, name in ipairs(names) do
		if type(name) ~= "string" then
			error(("class '%s': Inherits entry %s must contain strings"):format(className, label), 3)
		end
		local found = false
		for _, route in ipairs(sources) do
			local v = route.from[name]
			if v ~= nil then
				route.into[name] = v
				found = true
				break
			end
		end
		if not found then
			error(
				("class '%s': parent '%s' has no %s member named '%s'"):format(
					className, parentDef.name, label, name
				),
				3
			)
		end
	end
end

local function appendSetup(list: { any }, fn: any)
	for _, existing in ipairs(list) do
		if existing == fn then
			return
		end
	end
	table.insert(list, fn)
end

function LehuaClass.NewClassData(decl: ClassDecl): Class
	if type(decl) ~= "table" then
		error("NewClassData expects a declaration table", 2)
	end
	if type(decl.Name) ~= "string" or decl.Name == "" then
		error("NewClassData: declaration requires a non-empty string Name", 2)
	end
	local className = decl.Name
	if classesByName[className] ~= nil then
		error(("NewClassData: a class named '%s' already exists"):format(className), 2)
	end
	for k in pairs(decl) do
		if type(k) ~= "string" or (not KNOWN_DECL_KEYS[k] and k:sub(1, 2) ~= "__") then
			error(("class '%s': unknown declaration key '%s'"):format(className, tostring(k)), 2)
		end
	end

	local def = {
		name = className,
		strict = decl.Strict ~= false,
		abstract = decl.Abstract == true,
		sealed = decl.Sealed == true,
		privFields = {},
		privMethods = {},
		pubFields = {},
		pubMethods = {},
		ownStatics = {},
		staticParents = {},
		meta = {},
		construct = nil,
		setup = nil,
		setups = {},
		metadata = {},
		ownMetadata = nil,
		interfaces = {},
		ancestors = {},
		ancestorNames = {},
		boundCache = {},
	}

	local inherits = decl.Inherits
	if inherits ~= nil then
		local singleParent = handleToDef[inherits]
		if singleParent ~= nil then
			if singleParent.sealed then
				error(("class '%s': parent '%s' is sealed"):format(className, singleParent.name), 2)
			end
			for k, v in pairs(singleParent.privFields) do def.privFields[k] = v end
			for k, v in pairs(singleParent.privMethods) do def.privMethods[k] = v end
			for k, v in pairs(singleParent.pubFields) do def.pubFields[k] = v end
			for k, v in pairs(singleParent.pubMethods) do def.pubMethods[k] = v end
			for k, v in pairs(singleParent.meta) do def.meta[k] = v end
			def.construct = singleParent.construct
			for _, setupFn in ipairs(singleParent.setups) do
				appendSetup(def.setups, setupFn)
			end
			table.insert(def.staticParents, singleParent)
			mergeMetadata(def.metadata, singleParent.metadata)
			for h in pairs(singleParent.ancestors) do def.ancestors[h] = true end
			for n in pairs(singleParent.ancestorNames) do def.ancestorNames[n] = true end
			for _, iface in ipairs(singleParent.interfaces) do
				table.insert(def.interfaces, iface)
			end
		elseif type(inherits) == "table" then
			for i, entry in ipairs(inherits) do
				if type(entry) ~= "table" then
					error(("class '%s': Inherits[%d] must be { Class = ..., Public = {...} }"):format(className, i), 2)
				end
				if handleToDef[entry] ~= nil then
					error(
						("class '%s': Inherits[%d] is a bare class — multiple inheritance needs explicit picks: { Class = %s, Public = {...} }"):format(
							className, i, tostring(entry)
						),
						2
					)
				end
				local parentDef = handleToDef[entry.Class]
				if parentDef == nil then
					error(("class '%s': Inherits[%d].Class is not a Lehua class"):format(className, i), 2)
				end
				if parentDef.sealed then
					error(("class '%s': parent '%s' is sealed"):format(className, parentDef.name), 2)
				end
				pickMembers(className, parentDef, entry.Public, {
					{ from = parentDef.pubMethods, into = def.pubMethods },
					{ from = parentDef.pubFields, into = def.pubFields },
				}, "Public")
				pickMembers(className, parentDef, entry.Private, {
					{ from = parentDef.privMethods, into = def.privMethods },
					{ from = parentDef.privFields, into = def.privFields },
				}, "Private")
				pickMembers(className, parentDef, entry.Meta, {
					{ from = parentDef.meta, into = def.meta },
				}, "Meta")
				if entry.Static ~= nil then
					for _, name in ipairs(entry.Static) do
						local v = staticLookup(parentDef, name)
						if v == nil then
							error(
								("class '%s': parent '%s' has no static named '%s'"):format(
									className, parentDef.name, name
								),
								2
							)
						end
						def.ownStatics[name] = v
					end
				end
				mergeMetadata(def.metadata, parentDef.metadata)
				for h in pairs(parentDef.ancestors) do def.ancestors[h] = true end
				for n in pairs(parentDef.ancestorNames) do def.ancestorNames[n] = true end
				for _, setupFn in ipairs(parentDef.setups) do
					appendSetup(def.setups, setupFn)
				end
			end
		else
			error(("class '%s': Inherits must be a class or a list of { Class = ... } entries"):format(className), 2)
		end
	end

	absorbMembers(className, assertMemberTable(className, decl.Private, "Private"), def.privFields, def.privMethods, "Private")
	absorbMembers(className, assertMemberTable(className, decl.Public, "Public"), def.pubFields, def.pubMethods, "Public")
	for k, v in pairs(assertMemberTable(className, decl.Static, "Static")) do
		if type(k) ~= "string" then
			error(("class '%s': Static member names must be strings"):format(className), 2)
		end
		def.ownStatics[k] = v
	end
	for k, v in pairs(assertMemberTable(className, decl.Meta, "Meta")) do
		absorbMeta(def, k, v, className)
	end
	for k, v in pairs(decl) do
		if type(k) == "string" and k:sub(1, 2) == "__" then
			absorbMeta(def, k, v, className)
		end
	end

	if def.setup ~= nil then
		appendSetup(def.setups, def.setup)
	end

	if def.ownMetadata ~= nil then
		mergeMetadata(def.metadata, def.ownMetadata)
	end
	table.freeze(def.metadata)

	local function collide(k: string)
		error(("class '%s': member '%s' is declared both private and public"):format(className, k), 2)
	end
	for k in pairs(def.privFields) do
		if def.pubFields[k] ~= nil or def.pubMethods[k] ~= nil then collide(k) end
	end
	for k in pairs(def.privMethods) do
		if def.pubFields[k] ~= nil or def.pubMethods[k] ~= nil then collide(k) end
	end

	def.privateKeySet = {}
	for k in pairs(def.privFields) do def.privateKeySet[k] = true end
	for k in pairs(def.privMethods) do def.privateKeySet[k] = true end
	def.publicFieldSet = {}
	for k in pairs(def.pubFields) do def.publicFieldSet[k] = true end

	if decl.Interfaces ~= nil then
		if type(decl.Interfaces) ~= "table" then
			error(("class '%s': Interfaces must be a list"):format(className), 2)
		end
		local seen = {}
		for _, iface in ipairs(def.interfaces) do
			seen[iface] = true
		end
		for i, iface in ipairs(decl.Interfaces) do
			if not isInterface(iface) then
				error(("class '%s': Interfaces[%d] is not an Interface"):format(className, i), 2)
			end
			if not seen[iface] then
				seen[iface] = true
				table.insert(def.interfaces, iface)
			end
		end
	end
	local probe = classProbe(def)
	for _, iface in ipairs(def.interfaces) do
		local ok, missing = checkInterface(probe, iface)
		if not ok then
			error(
				("class '%s' does not satisfy interface '%s': %s"):format(
					className, iface.Name, table.concat(missing, ", ")
				),
				2
			)
		end
	end

	local handle = setmetatable({}, {
		__index = function(_, key)
			if key == "Name" then
				return def.name
			end
			local sv = staticLookup(def, key)
			if sv ~= nil then
				return sv
			end
			if def.strict then
				error(
					("'%s' is not a static member of class '%s' (statics: %s)"):format(
						tostring(key), def.name, wordList(sortedKeys(def.ownStatics))
					),
					2
				)
			end
			return nil
		end,
		__newindex = function(_, key, value)
			if key == "Name" then
				error(("class '%s': Name is read-only"):format(def.name), 2)
			end
			if value == nil then
				error(("class '%s': statics cannot hold nil"):format(def.name), 2)
			end
			def.ownStatics[key] = value
		end,
		__call = function(h, ...)
			return LehuaClass.BuildClassData(h, ...)
		end,
		__tostring = function()
			return "Class<" .. def.name .. ">"
		end,
		__metatable = "The metatable is locked",
	})

	def.handle = handle
	def.ancestors[handle] = true
	def.ancestorNames[className] = true
	def.innerMeta = buildInnerMeta(def)
	def.outerMeta = buildOuterMeta(def)

	handleToDef[handle] = def
	classesByName[className] = handle
	return handle
end

function LehuaClass.BuildClassData(classHandle: Class, ...: any): Object
	local def = handleToDef[classHandle]
	if def == nil then
		error("BuildClassData expects a class created by NewClassData", 2)
	end
	if def.abstract then
		error(("class '%s' is abstract and cannot be built"):format(def.name), 2)
	end

	instanceCounter += 1
	local fields = {}
	for k, v in pairs(def.privFields) do
		fields[k] = instantiateValue(v)
	end
	for k, v in pairs(def.pubFields) do
		fields[k] = instantiateValue(v)
	end

	local proxy = setmetatable({}, def.outerMeta)
	outerToRecord[proxy] = {
		def = def,
		fields = fields,
		extraPublic = {},
		id = instanceCounter,
	}
	innerToOuter[fields] = proxy
	innerToDef[fields] = def
	setmetatable(fields, def.innerMeta)

	for _, setupFn in ipairs(def.setups) do
		setupFn(fields, ...)
	end
	if def.construct ~= nil then
		def.construct(fields, ...)
	end
	return proxy
end

function LehuaClass.SuperGet(classHandle: Class, memberName: string): (self: any, ...any) -> ...any
	local def = handleToDef[classHandle]
	if def == nil then
		error("SuperGet expects a class as its first argument", 2)
	end
	local fn
	if memberName == "__construct" then
		fn = def.construct
		if fn == nil then
			error(("SuperGet: class '%s' has no constructor"):format(def.name), 2)
		end
	elseif memberName == "__setup" then
		fn = def.setup
		if fn == nil then
			error(("SuperGet: class '%s' has no __setup"):format(def.name), 2)
		end
	elseif def.pubMethods[memberName] ~= nil then
		fn = def.pubMethods[memberName]
	elseif type(def.meta[memberName]) == "function" then
		fn = def.meta[memberName]
	else
		error(
			("SuperGet: class '%s' has no public method or metamethod '%s' (methods: %s)"):format(
				def.name, tostring(memberName), wordList(sortedKeys(def.pubMethods))
			),
			2
		)
	end
	return function(selfArg, ...)
		return rewrapResults(fn(unwrapOne(selfArg), ...))
	end
end

function LehuaClass.IsA(value: any, classOrName: Class | string): boolean
	local def = resolveInstance(value)
	if def == nil then
		def = handleToDef[value]
	end
	if def == nil then
		return false
	end
	if type(classOrName) == "string" then
		return def.ancestorNames[classOrName] == true
	end
	if handleToDef[classOrName] == nil then
		error("IsA expects a class or class name as its second argument", 2)
	end
	return def.ancestors[classOrName] == true
end

function LehuaClass.FetchClass(value: any): Class?
	local def = resolveInstance(value)
	if def ~= nil then
		return def.handle
	end
	if handleToDef[value] ~= nil then
		return value
	end
	if type(value) == "string" then
		return classesByName[value]
	end
	return nil
end

function LehuaClass.GetMetaData(value: any): Metadata
	local def = resolveInstance(value)
	if def == nil then
		def = handleToDef[value]
	end
	if def == nil and type(value) == "string" then
		local named = classesByName[value]
		if named ~= nil then
			def = handleToDef[named]
		end
	end
	if def == nil then
		error("GetMetaData expects a class, an instance, or a class name", 2)
	end
	return def.metadata
end

function LehuaClass.IsClass(value: any): boolean
	return handleToDef[value] ~= nil
end

function LehuaClass.IsInstance(value: any): boolean
	return (resolveInstance(value)) ~= nil
end

function LehuaClass.Ref(value: any): Object?
	if type(value) ~= "table" then
		return nil
	end
	if outerToRecord[value] ~= nil then
		return value
	end
	local outer = innerToOuter[value]
	if outer ~= nil then
		return outer
	end
	return nil
end

LehuaClass.IsInterface = isInterface

function LehuaClass.TypeOf(value: any): string
	local def, fields = resolveInstance(value)
	if def ~= nil then
		local t = def.meta.__type
		if type(t) == "function" then
			return tostring(t(fields))
		elseif t ~= nil then
			return tostring(t)
		end
		return def.name
	end
	if handleToDef[value] ~= nil then
		return "class"
	end
	if isInterface(value) then
		return "interface"
	end
	return typeof(value)
end

function LehuaClass.Inspect(value: any): string
	local def, fields, rec = resolveInstance(value)
	if def == nil then
		return tostring(value)
	end
	local custom = def.meta.__toconsole
	if custom ~= nil then
		return tostring(custom(fields))
	end

	local lines = { rec ~= nil and (def.name .. "#" .. rec.id) or def.name }
	local publicKeys = {}
	for k in pairs(def.publicFieldSet) do
		table.insert(publicKeys, k)
	end
	if rec ~= nil then
		for k in pairs(rec.extraPublic) do
			table.insert(publicKeys, k)
		end
	end
	table.sort(publicKeys)
	for _, k in ipairs(publicKeys) do
		table.insert(lines, ("  %s = %s"):format(k, tostring(fields[k])))
	end
	for _, k in ipairs(sortedKeys(def.pubMethods)) do
		table.insert(lines, ("  %s = <method>"):format(k))
	end
	for _, k in ipairs(sortedKeys(def.ownStatics)) do
		table.insert(lines, ("  %s = %s (static)"):format(k, tostring(def.ownStatics[k])))
	end
	if #def.interfaces > 0 then
		local names = {}
		for _, iface in ipairs(def.interfaces) do
			table.insert(names, iface.Name)
		end
		table.insert(lines, "  implements: " .. table.concat(names, ", "))
	end
	return table.concat(lines, "\n")
end

local LEHUA_GLOBALS = {
	"NewClassData", "BuildClassData", "SuperGet",
	"Interface", "Implements", "IsA", "FetchClass",
}

function LehuaClass.Globalize(target: MemberTable?): LehuaClassModule
	target = target or _G
	if type(target) ~= "table" then
		error("Globalize expects a table (or a reachable _G)", 2)
	end
	for _, name in ipairs(LEHUA_GLOBALS) do
		target[name] = LehuaClass[name]
	end
	return (LehuaClass :: any) :: LehuaClassModule
end

return (LehuaClass :: any) :: LehuaClassModule
