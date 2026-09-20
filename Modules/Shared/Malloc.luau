--!strict
--!optimize 2

local Malloc = {}

export type TypeDef = {
	id: number,
	name: string,
	size: number,
	kind: string?,
	write: (target: buffer, offset: number, value: any) -> (),
	read: (target: buffer, offset: number) -> any,
}

export type Stats = {
	capacity: number,
	used: number,
	free: number,
	overhead: number,
	blocks: number,
	fragments: number,
	largestFree: number,
	allocations: number,
	frees: number,
	peak: number,
}

export type Malloc = {
	data: buffer,
	control: buffer,
	released: boolean,

	GenerateAddress: (self: Malloc, request: number | TypeDef, count: number?) -> number?,
	Free: (self: Malloc, address: number) -> (),
	Realloc: (self: Malloc, address: number, request: number | TypeDef, count: number?) -> number?,

	Write: (self: Malloc, address: number, value: any, index: number?) -> (),
	Read: (self: Malloc, address: number, index: number?) -> any,
	WriteAs: (self: Malloc, address: number, definition: TypeDef, value: any, offset: number?) -> (),
	ReadAs: (self: Malloc, address: number, definition: TypeDef, offset: number?) -> any,
	WriteBytes: (self: Malloc, address: number, source: buffer | string | any, offset: number?, count: number?) -> (),
	ReadBytes: (self: Malloc, address: number, offset: number?, count: number?) -> buffer,
	WriteString: (self: Malloc, address: number, value: string | any, offset: number?) -> (),
	ReadString: (self: Malloc, address: number, count: number?, offset: number?) -> string,
	Fill: (self: Malloc, address: number, value: any?, offset: number?, count: number?) -> (),
	Copy: (self: Malloc, destination: number, source: number, count: number?) -> (),

	SizeOf: (self: Malloc, address: number) -> number,
	CountOf: (self: Malloc, address: number) -> number,
	TypeOf: (self: Malloc, address: number) -> TypeDef?,
	IsAllocated: (self: Malloc, address: number) -> boolean,

	Capacity: (self: Malloc) -> number,
	Used: (self: Malloc) -> number,
	Available: (self: Malloc) -> number,
	LargestFree: (self: Malloc) -> number,
	Each: (self: Malloc, callback: (address: number, size: number, used: boolean, definition: TypeDef?) -> ()) -> (),
	Stats: (self: Malloc) -> Stats,
	Addresses: (self: Malloc) -> { number },
	Export: (self: Malloc) -> (buffer, buffer),

	Reset: (self: Malloc) -> (),
	Release: (self: Malloc) -> (),
}

local HEADER_SIZE = 8
local FOOTER_SIZE = 4
local CHUNK_OVERHEAD = HEADER_SIZE + FOOTER_SIZE
local ALIGNMENT = 4
local MIN_PAYLOAD = 8
local NULL_ADDRESS = 0
local FLAG_USED = 1
local BLOCK_MAGIC = 0x4D41
local MAX_TYPE_ID = 255

local HEADER_LENGTH = 0
local HEADER_FLAGS = 4
local HEADER_TYPE = 5
local HEADER_MAGIC = 6

local FREE_PREVIOUS = 0
local FREE_NEXT = 4

local CONTROL_FREE_HEAD = 0
local CONTROL_CAPACITY = 4
local CONTROL_USED_BYTES = 8
local CONTROL_LIVE_BLOCKS = 12
local CONTROL_PEAK_BYTES = 16
local CONTROL_ALLOC_COUNT = 20
local CONTROL_FREE_COUNT = 24
local CONTROL_SIZE = 32

local INV_SQRT2 = 0.7071067811865476
local QUAT_STEPS = 511
local QUAT_SCALE = QUAT_STEPS / INV_SQRT2
local QUAT_SIGN = 512
local QUAT_SPAN = 1024
local QUAT_MASK = 0x3FF

local EXPORT_MAGIC = "MLOC"
local EXPORT_VERSION = 1
local EXPORT_MAGIC_AT = 0
local EXPORT_VERSION_AT = 4
local EXPORT_CAPACITY_AT = 8
local EXPORT_IMAGE_AT = 12
local EXPORT_COUNT_AT = 16
local EXPORT_HEADER = 20
local EXPORT_ENTRY = 9

local typesById: { TypeDef } = {}
local typesByName: { [string]: TypeDef } = {}
local nextTypeId = 1

local NULL: any = setmetatable({}, {
	__tostring = function()
		return "Malloc.NULL"
	end,
})

table.freeze(NULL)

local function fail(message: string): never
	return error("[Malloc] " .. message, 3)
end

local function defineType(
	name: string,
	size: number,
	kind: string?,
	write: (target: buffer, offset: number, value: any) -> (),
	read: (target: buffer, offset: number) -> any
): TypeDef
	if nextTypeId > MAX_TYPE_ID then
		fail("exhausted the type table, only " .. MAX_TYPE_ID .. " types can exist")
	end

	local definition = table.freeze({
		id = nextTypeId,
		name = name,
		size = size,
		kind = kind,
		write = write,
		read = read,
	}) :: TypeDef

	typesById[nextTypeId] = definition
	typesByName[name] = definition
	nextTypeId += 1

	return definition
end

local function resolveTypeName(name: string): TypeDef?
	local direct = typesByName[name]

	if direct then
		return direct
	end

	local raw = string.match(name, "^Bytes(%d+)$")

	if raw then
		return Malloc.Types.Bytes(tonumber(raw) :: number)
	end

	local text = string.match(name, "^String(%d+)$")

	if text then
		return Malloc.Types.String(tonumber(text) :: number)
	end

	return nil
end

local function packQuaternion(x: number, y: number, z: number, w: number): number
	local length = math.sqrt(x * x + y * y + z * z + w * w)

	if length < 1e-6 then
		x, y, z, w = 0, 0, 0, 1
	else
		x, y, z, w = x / length, y / length, z / length, w / length
	end

	local components = { x, y, z, w }
	local largest = 4
	local best = math.abs(w)

	for index = 1, 3 do
		local magnitude = math.abs(components[index])

		if magnitude > best then
			largest = index
			best = magnitude
		end
	end

	if components[largest] < 0 then
		for index = 1, 4 do
			components[index] = -components[index]
		end
	end

	local packed = bit32.lshift(4 - largest, 30)
	local slot = 0

	for index = 1, 4 do
		if index ~= largest then
			local quantized = math.clamp(math.round(components[index] * QUAT_SCALE), -QUAT_STEPS, QUAT_STEPS)

			packed = bit32.bor(packed, bit32.lshift(bit32.band(quantized, QUAT_MASK), slot * 10))
			slot += 1
		end
	end

	return packed
end

local function unpackQuaternion(packed: number): (number, number, number, number)
	local largest = 4 - bit32.rshift(packed, 30)
	local components = { 0, 0, 0, 0 }
	local total = 0
	local slot = 0

	for index = 1, 4 do
		if index ~= largest then
			local quantized = bit32.band(bit32.rshift(packed, slot * 10), QUAT_MASK)

			if quantized >= QUAT_SIGN then
				quantized -= QUAT_SPAN
			end

			local component = quantized / QUAT_SCALE

			components[index] = component
			total += component * component
			slot += 1
		end
	end

	components[largest] = math.sqrt(math.max(0, 1 - total))

	return components[1], components[2], components[3], components[4]
end

local function assertValue(definition: TypeDef, value: any)
	local kind = definition.kind

	if kind ~= nil and typeof(value) ~= kind then
		fail(("%s values must be %s, got %s"):format(definition.name, kind, typeof(value)))
	end
end

local function alignUp(value: number): number
	return bit32.band(value + (ALIGNMENT - 1), bit32.bnot(ALIGNMENT - 1))
end

local function blockLength(data: buffer, address: number): number
	return buffer.readu32(data, address - HEADER_SIZE + HEADER_LENGTH)
end

local function blockTypeId(data: buffer, address: number): number
	return buffer.readu8(data, address - HEADER_SIZE + HEADER_TYPE)
end

local function isUsed(data: buffer, address: number): boolean
	return bit32.band(buffer.readu8(data, address - HEADER_SIZE + HEADER_FLAGS), FLAG_USED) ~= 0
end

local function writeBlock(data: buffer, address: number, size: number, used: boolean, typeId: number)
	local header = address - HEADER_SIZE

	buffer.writeu32(data, header + HEADER_LENGTH, size)
	buffer.writeu8(data, header + HEADER_FLAGS, if used then FLAG_USED else 0)
	buffer.writeu8(data, header + HEADER_TYPE, typeId)
	buffer.writeu16(data, header + HEADER_MAGIC, BLOCK_MAGIC)
	buffer.writeu32(data, address + size, size)
end

local function bump(control: buffer, field: number, delta: number)
	buffer.writeu32(control, field, buffer.readu32(control, field) + delta)
end

local function trackPeak(control: buffer)
	local used = buffer.readu32(control, CONTROL_USED_BYTES)

	if used > buffer.readu32(control, CONTROL_PEAK_BYTES) then
		buffer.writeu32(control, CONTROL_PEAK_BYTES, used)
	end
end

local function freeListRemove(data: buffer, control: buffer, address: number)
	local previous = buffer.readu32(data, address + FREE_PREVIOUS)
	local following = buffer.readu32(data, address + FREE_NEXT)

	if previous ~= NULL_ADDRESS then
		buffer.writeu32(data, previous + FREE_NEXT, following)
	else
		buffer.writeu32(control, CONTROL_FREE_HEAD, following)
	end

	if following ~= NULL_ADDRESS then
		buffer.writeu32(data, following + FREE_PREVIOUS, previous)
	end
end

local function freeListPush(data: buffer, control: buffer, address: number)
	local head = buffer.readu32(control, CONTROL_FREE_HEAD)

	buffer.writeu32(data, address + FREE_PREVIOUS, NULL_ADDRESS)
	buffer.writeu32(data, address + FREE_NEXT, head)

	if head ~= NULL_ADDRESS then
		buffer.writeu32(data, head + FREE_PREVIOUS, address)
	end

	buffer.writeu32(control, CONTROL_FREE_HEAD, address)
end

local function findFit(data: buffer, control: buffer, wanted: number): number
	local address = buffer.readu32(control, CONTROL_FREE_HEAD)
	local best = NULL_ADDRESS
	local bestSize = math.huge

	while address ~= NULL_ADDRESS do
		local size = blockLength(data, address)

		if size == wanted then
			return address
		end

		if size > wanted and size < bestSize then
			best = address
			bestSize = size
		end

		address = buffer.readu32(data, address + FREE_NEXT)
	end

	return best
end

local function coalesceForward(data: buffer, control: buffer, address: number): number
	local capacity = buffer.readu32(control, CONTROL_CAPACITY)
	local size = blockLength(data, address)
	local chunkEnd = address + size + FOOTER_SIZE

	if chunkEnd >= capacity then
		return size
	end

	local following = chunkEnd + HEADER_SIZE

	if isUsed(data, following) then
		return size
	end

	freeListRemove(data, control, following)
	size += blockLength(data, following) + CHUNK_OVERHEAD
	writeBlock(data, address, size, false, 0)

	return size
end

local function splitBlock(data: buffer, control: buffer, address: number, wanted: number, typeId: number): number
	local size = blockLength(data, address)

	if wanted >= size then
		writeBlock(data, address, size, true, typeId)
		return size
	end

	local leftover = size - wanted - CHUNK_OVERHEAD

	if leftover >= MIN_PAYLOAD then
		writeBlock(data, address, wanted, true, typeId)

		local remainder = address + wanted + CHUNK_OVERHEAD

		writeBlock(data, remainder, leftover, false, 0)
		coalesceForward(data, control, remainder)
		freeListPush(data, control, remainder)

		return wanted
	end

	local capacity = buffer.readu32(control, CONTROL_CAPACITY)
	local chunkEnd = address + size + FOOTER_SIZE

	if chunkEnd < capacity then
		local following = chunkEnd + HEADER_SIZE

		if not isUsed(data, following) then
			local donated = size - wanted
			local grown = blockLength(data, following) + donated

			freeListRemove(data, control, following)
			writeBlock(data, address, wanted, true, typeId)
			writeBlock(data, following - donated, grown, false, 0)
			freeListPush(data, control, following - donated)

			return wanted
		end
	end

	writeBlock(data, address, size, true, typeId)

	return size
end

local function releaseBlock(data: buffer, control: buffer, address: number)
	local size = blockLength(data, address)

	writeBlock(data, address, size, false, 0)
	size = coalesceForward(data, control, address)

	if address > HEADER_SIZE then
		local previousSize = buffer.readu32(data, address - HEADER_SIZE - FOOTER_SIZE)
		local previous = address - CHUNK_OVERHEAD - previousSize

		if not isUsed(data, previous) then
			freeListRemove(data, control, previous)
			size += previousSize + CHUNK_OVERHEAD
			address = previous
			writeBlock(data, address, size, false, 0)
		end
	end

	freeListPush(data, control, address)
end

local function initialise(data: buffer, control: buffer, capacity: number)
	buffer.fill(data, 0, 0, capacity)
	buffer.fill(control, 0, 0, CONTROL_SIZE)

	buffer.writeu32(control, CONTROL_CAPACITY, capacity)
	buffer.writeu32(control, CONTROL_FREE_HEAD, NULL_ADDRESS)

	writeBlock(data, HEADER_SIZE, capacity - CHUNK_OVERHEAD, false, 0)
	freeListPush(data, control, HEADER_SIZE)
end

local function resolveRequest(request: number | TypeDef, count: number?): (TypeDef?, number)
	local amount = if count ~= nil then math.floor(count) else 1

	if amount < 1 then
		fail("count must be at least 1")
	end

	if type(request) == "number" then
		local bytes = math.floor(request)

		if bytes < 1 then
			fail("size must be at least 1 byte")
		end

		return nil, math.max(alignUp(bytes * amount), MIN_PAYLOAD)
	end

	if type(request) ~= "table" or typesById[(request :: any).id] ~= request then
		fail("request must be a byte size or a Malloc.Types definition")
	end

	local definition = request :: TypeDef

	return definition, math.max(alignUp(definition.size * amount), MIN_PAYLOAD)
end

local function probe(self: Malloc, address: number): number?
	if self.released or type(address) ~= "number" or address % 1 ~= 0 then
		return nil
	end

	local data = self.data
	local capacity = buffer.readu32(self.control, CONTROL_CAPACITY)

	if address < HEADER_SIZE or address >= capacity then
		return nil
	end

	local header = address - HEADER_SIZE

	if buffer.readu16(data, header + HEADER_MAGIC) ~= BLOCK_MAGIC then
		return nil
	end

	local size = buffer.readu32(data, header + HEADER_LENGTH)

	if size < MIN_PAYLOAD or address + size + FOOTER_SIZE > capacity then
		return nil
	end

	if buffer.readu32(data, address + size) ~= size then
		return nil
	end

	if bit32.band(buffer.readu8(data, header + HEADER_FLAGS), FLAG_USED) == 0 then
		return nil
	end

	return size
end

local function assertAddress(self: Malloc, address: number): number
	if self.released then
		fail("this arena has been released")
	end

	local size = probe(self, address)

	if size then
		return size
	end

	return fail("address " .. tostring(address) .. " is not a live allocation")
end

local function assertDefinition(definition: TypeDef): TypeDef
	if type(definition) ~= "table" or typesById[(definition :: any).id] ~= definition then
		fail("expected a Malloc.Types definition")
	end

	return definition
end

local function resolveWindow(size: number, offset: number?, count: number?): (number, number)
	local start = if offset ~= nil then math.floor(offset) else 0
	local length = if count ~= nil then math.floor(count) else size - start

	if start < 0 or length < 0 or start + length > size then
		fail(("range [%d, %d) falls outside a block of %d bytes"):format(start, start + length, size))
	end

	return start, length
end

local arenaClass = {}
arenaClass.__index = arenaClass

function arenaClass.GenerateAddress(self: Malloc, request: number | TypeDef, count: number?): number?
	if self.released then
		fail("this arena has been released")
	end

	local definition, wanted = resolveRequest(request, count)
	local data, control = self.data, self.control
	local address = findFit(data, control, wanted)

	if address == NULL_ADDRESS then
		return nil
	end

	freeListRemove(data, control, address)

	local typeId = if definition then definition.id else 0
	local size = splitBlock(data, control, address, wanted, typeId)

	buffer.fill(data, address, 0, size)

	bump(control, CONTROL_USED_BYTES, size)
	bump(control, CONTROL_LIVE_BLOCKS, 1)
	bump(control, CONTROL_ALLOC_COUNT, 1)
	trackPeak(control)

	return address
end

function arenaClass.Free(self: Malloc, address: number)
	local size = assertAddress(self, address)
	local control = self.control

	releaseBlock(self.data, control, address)

	bump(control, CONTROL_USED_BYTES, -size)
	bump(control, CONTROL_LIVE_BLOCKS, -1)
	bump(control, CONTROL_FREE_COUNT, 1)
end

function arenaClass.Realloc(self: Malloc, address: number, request: number | TypeDef, count: number?): number?
	local size = assertAddress(self, address)
	local definition, wanted = resolveRequest(request, count)
	local data, control = self.data, self.control
	local typeId = if definition then definition.id else 0

	if wanted <= size then
		local final = splitBlock(data, control, address, wanted, typeId)

		bump(control, CONTROL_USED_BYTES, final - size)

		return address
	end

	local capacity = buffer.readu32(control, CONTROL_CAPACITY)
	local chunkEnd = address + size + FOOTER_SIZE

	if chunkEnd < capacity then
		local following = chunkEnd + HEADER_SIZE

		if not isUsed(data, following) then
			local merged = size + CHUNK_OVERHEAD + blockLength(data, following)

			if merged >= wanted then
				freeListRemove(data, control, following)
				writeBlock(data, address, merged, true, typeId)

				local final = splitBlock(data, control, address, wanted, typeId)

				buffer.fill(data, address + size, 0, final - size)
				bump(control, CONTROL_USED_BYTES, final - size)
				trackPeak(control)

				return address
			end
		end
	end

	local fresh = self:GenerateAddress(wanted)

	if fresh then
		buffer.copy(data, fresh, data, address, size)
		buffer.writeu8(data, fresh - HEADER_SIZE + HEADER_TYPE, typeId)
		self:Free(address)
	end

	return fresh
end

function arenaClass.Write(self: Malloc, address: number, value: any, index: number?)
	local size = assertAddress(self, address)
	local definition = typesById[blockTypeId(self.data, address)]

	if definition == nil then
		if value == NULL then
			buffer.fill(self.data, address, 0, size)
			return
		end

		fail("address " .. address .. " is untyped, use WriteAs or WriteBytes")
	end

	local slot = if index ~= nil then math.floor(index) else 0
	local offset = slot * definition.size

	if slot < 0 or offset + definition.size > size then
		fail(("index %d falls outside a block holding %d elements"):format(slot, size // definition.size))
	end

	if value == NULL then
		buffer.fill(self.data, address + offset, 0, definition.size)
		return
	end

	assertValue(definition, value)
	definition.write(self.data, address + offset, value)
end

function arenaClass.Read(self: Malloc, address: number, index: number?): any
	local size = assertAddress(self, address)
	local definition = typesById[blockTypeId(self.data, address)]

	if definition == nil then
		fail("address " .. address .. " is untyped, use ReadAs or ReadBytes")
	end

	local slot = if index ~= nil then math.floor(index) else 0
	local offset = slot * definition.size

	if slot < 0 or offset + definition.size > size then
		fail(("index %d falls outside a block holding %d elements"):format(slot, size // definition.size))
	end

	return definition.read(self.data, address + offset)
end

function arenaClass.WriteAs(self: Malloc, address: number, definition: TypeDef, value: any, offset: number?)
	local size = assertAddress(self, address)

	assertDefinition(definition)

	local start = resolveWindow(size, offset, definition.size)

	if value == NULL then
		buffer.fill(self.data, address + start, 0, definition.size)
		return
	end

	assertValue(definition, value)
	definition.write(self.data, address + start, value)
end

function arenaClass.ReadAs(self: Malloc, address: number, definition: TypeDef, offset: number?): any
	local size = assertAddress(self, address)

	assertDefinition(definition)

	local start = resolveWindow(size, offset, definition.size)

	return definition.read(self.data, address + start)
end

function arenaClass.WriteBytes(self: Malloc, address: number, source: buffer | string, offset: number?, count: number?)
	local size = assertAddress(self, address)

	if source == NULL then
		local start, length = resolveWindow(size, offset, count)

		buffer.fill(self.data, address + start, 0, length)

		return
	end

	local available = if type(source) == "string" then #source else buffer.len(source)
	local start, length = resolveWindow(size, offset, count or available)

	if length > available then
		fail(("source only holds %d of the %d requested bytes"):format(available, length))
	end

	if type(source) == "string" then
		buffer.writestring(self.data, address + start, source, length)
	else
		buffer.copy(self.data, address + start, source, 0, length)
	end
end

function arenaClass.ReadBytes(self: Malloc, address: number, offset: number?, count: number?): buffer
	local size = assertAddress(self, address)
	local start, length = resolveWindow(size, offset, count)
	local out = buffer.create(length)

	buffer.copy(out, 0, self.data, address + start, length)

	return out
end

function arenaClass.WriteString(self: Malloc, address: number, value: string, offset: number?)
	local size = assertAddress(self, address)

	if value == NULL then
		local empty = resolveWindow(size, offset, 2)

		buffer.writeu16(self.data, address + empty, 0)

		return
	end

	local start = resolveWindow(size, offset, #value + 2)

	buffer.writeu16(self.data, address + start, #value)
	buffer.writestring(self.data, address + start + 2, value)
end

function arenaClass.ReadString(self: Malloc, address: number, count: number?, offset: number?): string
	local size = assertAddress(self, address)
	local start = resolveWindow(size, offset, 2)
	local length = if count ~= nil then math.floor(count) else buffer.readu16(self.data, address + start)

	resolveWindow(size, start, length + 2)

	return buffer.readstring(self.data, address + start + 2, length)
end

function arenaClass.Fill(self: Malloc, address: number, value: any?, offset: number?, count: number?)
	local size = assertAddress(self, address)
	local start, length = resolveWindow(size, offset, count)

	buffer.fill(self.data, address + start, if value == nil or value == NULL then 0 else value, length)
end

function arenaClass.Copy(self: Malloc, destination: number, source: number, count: number?)
	local destinationSize = assertAddress(self, destination)
	local sourceSize = assertAddress(self, source)
	local length = if count ~= nil then math.floor(count) else math.min(destinationSize, sourceSize)

	if length < 0 or length > destinationSize or length > sourceSize then
		fail(("cannot copy %d bytes between blocks of %d and %d"):format(length, sourceSize, destinationSize))
	end

	buffer.copy(self.data, destination, self.data, source, length)
end

function arenaClass.SizeOf(self: Malloc, address: number): number
	return assertAddress(self, address)
end

function arenaClass.CountOf(self: Malloc, address: number): number
	local size = assertAddress(self, address)
	local definition = typesById[blockTypeId(self.data, address)]

	return if definition then size // definition.size else size
end

function arenaClass.TypeOf(self: Malloc, address: number): TypeDef?
	assertAddress(self, address)

	return typesById[blockTypeId(self.data, address)]
end

function arenaClass.IsAllocated(self: Malloc, address: number): boolean
	return probe(self, address) ~= nil
end

function arenaClass.Capacity(self: Malloc): number
	return if self.released then 0 else buffer.readu32(self.control, CONTROL_CAPACITY)
end

function arenaClass.Used(self: Malloc): number
	return if self.released then 0 else buffer.readu32(self.control, CONTROL_USED_BYTES)
end

function arenaClass.Available(self: Malloc): number
	if self.released then
		return 0
	end

	local data, control = self.data, self.control
	local address = buffer.readu32(control, CONTROL_FREE_HEAD)
	local total = 0

	while address ~= NULL_ADDRESS do
		total += blockLength(data, address)
		address = buffer.readu32(data, address + FREE_NEXT)
	end

	return total
end

function arenaClass.LargestFree(self: Malloc): number
	if self.released then
		return 0
	end

	local data, control = self.data, self.control
	local address = buffer.readu32(control, CONTROL_FREE_HEAD)
	local largest = 0

	while address ~= NULL_ADDRESS do
		local size = blockLength(data, address)

		if size > largest then
			largest = size
		end

		address = buffer.readu32(data, address + FREE_NEXT)
	end

	return largest
end

function arenaClass.Each(
	self: Malloc,
	callback: (address: number, size: number, used: boolean, definition: TypeDef?) -> ()
)
	if self.released then
		return
	end

	local data = self.data
	local capacity = buffer.readu32(self.control, CONTROL_CAPACITY)
	local address = HEADER_SIZE

	while address + FOOTER_SIZE <= capacity do
		local size = blockLength(data, address)

		callback(address, size, isUsed(data, address), typesById[blockTypeId(data, address)])

		address += size + CHUNK_OVERHEAD
	end
end

function arenaClass.Stats(self: Malloc): Stats
	local control = self.control
	local released = self.released
	local blocks = 0
	local fragments = 0

	self:Each(function(_, _, used)
		blocks += 1

		if not used then
			fragments += 1
		end
	end)

	return {
		capacity = self:Capacity(),
		used = self:Used(),
		free = self:Available(),
		overhead = blocks * CHUNK_OVERHEAD,
		blocks = blocks,
		fragments = fragments,
		largestFree = self:LargestFree(),
		allocations = if released then 0 else buffer.readu32(control, CONTROL_ALLOC_COUNT),
		frees = if released then 0 else buffer.readu32(control, CONTROL_FREE_COUNT),
		peak = if released then 0 else buffer.readu32(control, CONTROL_PEAK_BYTES),
	}
end

function arenaClass.Addresses(self: Malloc): { number }
	local list = {}

	self:Each(function(address: number, _size: number, used: boolean)
		if used then
			table.insert(list, address)
		end
	end)

	return list
end

function arenaClass.Export(self: Malloc): (buffer, buffer)
	if self.released then
		fail("this arena has been released")
	end

	local data = self.data
	local capacity = buffer.readu32(self.control, CONTROL_CAPACITY)
	local imageLength = 0
	local entries = 0
	local names = 0
	local address = HEADER_SIZE

	while address + FOOTER_SIZE <= capacity do
		local size = blockLength(data, address)

		if isUsed(data, address) then
			local definition = typesById[blockTypeId(data, address)]

			entries += 1
			names += if definition then #definition.name else 0
			imageLength = address + size + FOOTER_SIZE
		end

		address += size + CHUNK_OVERHEAD
	end

	local metadata = buffer.create(EXPORT_HEADER + entries * EXPORT_ENTRY + names)

	buffer.writestring(metadata, EXPORT_MAGIC_AT, EXPORT_MAGIC)
	buffer.writeu16(metadata, EXPORT_VERSION_AT, EXPORT_VERSION)
	buffer.writeu32(metadata, EXPORT_CAPACITY_AT, capacity)
	buffer.writeu32(metadata, EXPORT_IMAGE_AT, imageLength)
	buffer.writeu32(metadata, EXPORT_COUNT_AT, entries)

	local cursor = EXPORT_HEADER

	address = HEADER_SIZE

	while address + FOOTER_SIZE <= capacity do
		local size = blockLength(data, address)

		if isUsed(data, address) then
			local definition = typesById[blockTypeId(data, address)]
			local name = if definition then definition.name else ""

			buffer.writeu32(metadata, cursor, address)
			buffer.writeu32(metadata, cursor + 4, size)
			buffer.writeu8(metadata, cursor + 8, #name)
			buffer.writestring(metadata, cursor + EXPORT_ENTRY, name)

			cursor += EXPORT_ENTRY + #name
		end

		address += size + CHUNK_OVERHEAD
	end

	local image = buffer.create(imageLength)

	buffer.copy(image, 0, data, 0, imageLength)

	return metadata, image
end

function arenaClass.Reset(self: Malloc)
	if self.released then
		fail("this arena has been released")
	end

	initialise(self.data, self.control, buffer.readu32(self.control, CONTROL_CAPACITY))
end

function arenaClass.Release(self: Malloc)
	if self.released then
		return
	end

	self.released = true
	self.data = buffer.create(0)
	self.control = buffer.create(CONTROL_SIZE)
end

function arenaClass.__tostring(self: Malloc): string
	if self.released then
		return "Malloc(released)"
	end

	return ("Malloc(%d/%d bytes)"):format(self:Used(), self:Capacity())
end

function arenaClass.__len(self: Malloc): number
	return self:Capacity()
end

local bytesTypes: { [number]: TypeDef } = {}
local stringTypes: { [number]: TypeDef } = {}

local function writeRaw(target: buffer, offset: number, value: any, capacity: number)
	local kind = typeof(value)
	local length = 0

	if kind == "string" then
		length = math.min(#value, capacity)
		buffer.writestring(target, offset, value, length)
	elseif kind == "buffer" then
		length = math.min(buffer.len(value), capacity)
		buffer.copy(target, offset, value, 0, length)
	else
		fail("Bytes values must be a buffer or string, got " .. kind)
	end

	if length < capacity then
		buffer.fill(target, offset + length, 0, capacity - length)
	end
end

local function writeQuaternion(target: buffer, offset: number, value: any)
	local axis, angle = value:ToAxisAngle()
	local half = angle * 0.5
	local sine = math.sin(half)

	buffer.writeu32(target, offset, packQuaternion(axis.X * sine, axis.Y * sine, axis.Z * sine, math.cos(half)))
end

local scalarTypes = {
	Bool = defineType("Bool", 1, "boolean", function(target: buffer, offset: number, value: any)
		buffer.writeu8(target, offset, if value then 1 else 0)
	end, function(target: buffer, offset: number): any
		return buffer.readu8(target, offset) ~= 0
	end),

	U8 = defineType("U8", 1, "number", function(target: buffer, offset: number, value: any)
		buffer.writeu8(target, offset, value)
	end, function(target: buffer, offset: number): any
		return buffer.readu8(target, offset)
	end),

	I8 = defineType("I8", 1, "number", function(target: buffer, offset: number, value: any)
		buffer.writei8(target, offset, value)
	end, function(target: buffer, offset: number): any
		return buffer.readi8(target, offset)
	end),

	U16 = defineType("U16", 2, "number", function(target: buffer, offset: number, value: any)
		buffer.writeu16(target, offset, value)
	end, function(target: buffer, offset: number): any
		return buffer.readu16(target, offset)
	end),

	I16 = defineType("I16", 2, "number", function(target: buffer, offset: number, value: any)
		buffer.writei16(target, offset, value)
	end, function(target: buffer, offset: number): any
		return buffer.readi16(target, offset)
	end),

	U32 = defineType("U32", 4, "number", function(target: buffer, offset: number, value: any)
		buffer.writeu32(target, offset, value)
	end, function(target: buffer, offset: number): any
		return buffer.readu32(target, offset)
	end),

	I32 = defineType("I32", 4, "number", function(target: buffer, offset: number, value: any)
		buffer.writei32(target, offset, value)
	end, function(target: buffer, offset: number): any
		return buffer.readi32(target, offset)
	end),

	F32 = defineType("F32", 4, "number", function(target: buffer, offset: number, value: any)
		buffer.writef32(target, offset, value)
	end, function(target: buffer, offset: number): any
		return buffer.readf32(target, offset)
	end),

	F64 = defineType("F64", 8, "number", function(target: buffer, offset: number, value: any)
		buffer.writef64(target, offset, value)
	end, function(target: buffer, offset: number): any
		return buffer.readf64(target, offset)
	end),

	Address = defineType("Address", 4, "number", function(target: buffer, offset: number, value: any)
		buffer.writeu32(target, offset, value)
	end, function(target: buffer, offset: number): any
		return buffer.readu32(target, offset)
	end),
}

local colorType = defineType("Color3", 3, "Color3", function(target: buffer, offset: number, value: any)
	buffer.writeu8(target, offset, math.clamp(math.round(value.R * 255), 0, 255))
	buffer.writeu8(target, offset + 1, math.clamp(math.round(value.G * 255), 0, 255))
	buffer.writeu8(target, offset + 2, math.clamp(math.round(value.B * 255), 0, 255))
end, function(target: buffer, offset: number): any
	return Color3.fromRGB(
		buffer.readu8(target, offset),
		buffer.readu8(target, offset + 1),
		buffer.readu8(target, offset + 2)
	)
end)

Malloc.Types = table.freeze({
	Bool = scalarTypes.Bool,
	U8 = scalarTypes.U8,
	I8 = scalarTypes.I8,
	U16 = scalarTypes.U16,
	I16 = scalarTypes.I16,
	U32 = scalarTypes.U32,
	I32 = scalarTypes.I32,
	F32 = scalarTypes.F32,
	F64 = scalarTypes.F64,
	Address = scalarTypes.Address,

	Vector2 = defineType("Vector2", 8, "Vector2", function(target: buffer, offset: number, value: any)
		buffer.writef32(target, offset, value.X)
		buffer.writef32(target, offset + 4, value.Y)
	end, function(target: buffer, offset: number): any
		return Vector2.new(buffer.readf32(target, offset), buffer.readf32(target, offset + 4))
	end),

	Vector3 = defineType("Vector3", 12, "Vector3", function(target: buffer, offset: number, value: any)
		buffer.writef32(target, offset, value.X)
		buffer.writef32(target, offset + 4, value.Y)
		buffer.writef32(target, offset + 8, value.Z)
	end, function(target: buffer, offset: number): any
		return Vector3.new(
			buffer.readf32(target, offset),
			buffer.readf32(target, offset + 4),
			buffer.readf32(target, offset + 8)
		)
	end),

	Quaternion = defineType("Quaternion", 4, "CFrame", function(target: buffer, offset: number, value: any)
		writeQuaternion(target, offset, value)
	end, function(target: buffer, offset: number): any
		local x, y, z, w = unpackQuaternion(buffer.readu32(target, offset))

		return CFrame.new(0, 0, 0, x, y, z, w)
	end),

	CFrame = defineType("CFrame", 16, "CFrame", function(target: buffer, offset: number, value: any)
		local position = value.Position

		buffer.writef32(target, offset, position.X)
		buffer.writef32(target, offset + 4, position.Y)
		buffer.writef32(target, offset + 8, position.Z)
		writeQuaternion(target, offset + 12, value)
	end, function(target: buffer, offset: number): any
		local x, y, z, w = unpackQuaternion(buffer.readu32(target, offset + 12))

		return CFrame.new(
			buffer.readf32(target, offset),
			buffer.readf32(target, offset + 4),
			buffer.readf32(target, offset + 8),
			x,
			y,
			z,
			w
		)
	end),

	CFramePrecise = defineType("CFramePrecise", 28, "CFrame", function(target: buffer, offset: number, value: any)
		local position = value.Position
		local axis, angle = value:ToAxisAngle()
		local half = angle * 0.5
		local sine = math.sin(half)

		buffer.writef32(target, offset, position.X)
		buffer.writef32(target, offset + 4, position.Y)
		buffer.writef32(target, offset + 8, position.Z)
		buffer.writef32(target, offset + 12, axis.X * sine)
		buffer.writef32(target, offset + 16, axis.Y * sine)
		buffer.writef32(target, offset + 20, axis.Z * sine)
		buffer.writef32(target, offset + 24, math.cos(half))
	end, function(target: buffer, offset: number): any
		local qx = buffer.readf32(target, offset + 12)
		local qy = buffer.readf32(target, offset + 16)
		local qz = buffer.readf32(target, offset + 20)
		local qw = buffer.readf32(target, offset + 24)

		if qx == 0 and qy == 0 and qz == 0 and qw == 0 then
			qw = 1
		end

		return CFrame.new(
			buffer.readf32(target, offset),
			buffer.readf32(target, offset + 4),
			buffer.readf32(target, offset + 8),
			qx,
			qy,
			qz,
			qw
		)
	end),

	CFrameExact = defineType("CFrameExact", 48, "CFrame", function(target: buffer, offset: number, value: any)
		local components = { value:GetComponents() }

		for index = 1, 12 do
			buffer.writef32(target, offset + (index - 1) * 4, components[index])
		end
	end, function(target: buffer, offset: number): any
		local x = buffer.readf32(target, offset)
		local y = buffer.readf32(target, offset + 4)
		local z = buffer.readf32(target, offset + 8)
		local r00 = buffer.readf32(target, offset + 12)
		local r01 = buffer.readf32(target, offset + 16)
		local r02 = buffer.readf32(target, offset + 20)
		local r10 = buffer.readf32(target, offset + 24)
		local r11 = buffer.readf32(target, offset + 28)
		local r12 = buffer.readf32(target, offset + 32)
		local r20 = buffer.readf32(target, offset + 36)
		local r21 = buffer.readf32(target, offset + 40)
		local r22 = buffer.readf32(target, offset + 44)

		if
			r00 == 0 and r01 == 0 and r02 == 0
			and r10 == 0 and r11 == 0 and r12 == 0
			and r20 == 0 and r21 == 0 and r22 == 0
		then
			return CFrame.new(x, y, z)
		end

		return CFrame.new(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
	end),

	Color3 = colorType,
	Color3Bytes = colorType,

	Color3Float = defineType("Color3Float", 12, "Color3", function(target: buffer, offset: number, value: any)
		buffer.writef32(target, offset, value.R)
		buffer.writef32(target, offset + 4, value.G)
		buffer.writef32(target, offset + 8, value.B)
	end, function(target: buffer, offset: number): any
		return Color3.new(
			buffer.readf32(target, offset),
			buffer.readf32(target, offset + 4),
			buffer.readf32(target, offset + 8)
		)
	end),

	UDim = defineType("UDim", 8, "UDim", function(target: buffer, offset: number, value: any)
		buffer.writef32(target, offset, value.Scale)
		buffer.writei32(target, offset + 4, value.Offset)
	end, function(target: buffer, offset: number): any
		return UDim.new(buffer.readf32(target, offset), buffer.readi32(target, offset + 4))
	end),

	UDim2 = defineType("UDim2", 16, "UDim2", function(target: buffer, offset: number, value: any)
		buffer.writef32(target, offset, value.X.Scale)
		buffer.writei32(target, offset + 4, value.X.Offset)
		buffer.writef32(target, offset + 8, value.Y.Scale)
		buffer.writei32(target, offset + 12, value.Y.Offset)
	end, function(target: buffer, offset: number): any
		return UDim2.new(
			buffer.readf32(target, offset),
			buffer.readi32(target, offset + 4),
			buffer.readf32(target, offset + 8),
			buffer.readi32(target, offset + 12)
		)
	end),

	Rect = defineType("Rect", 16, "Rect", function(target: buffer, offset: number, value: any)
		buffer.writef32(target, offset, value.Min.X)
		buffer.writef32(target, offset + 4, value.Min.Y)
		buffer.writef32(target, offset + 8, value.Max.X)
		buffer.writef32(target, offset + 12, value.Max.Y)
	end, function(target: buffer, offset: number): any
		return Rect.new(
			buffer.readf32(target, offset),
			buffer.readf32(target, offset + 4),
			buffer.readf32(target, offset + 8),
			buffer.readf32(target, offset + 12)
		)
	end),

	NumberRange = defineType("NumberRange", 8, "NumberRange", function(target: buffer, offset: number, value: any)
		buffer.writef32(target, offset, value.Min)
		buffer.writef32(target, offset + 4, value.Max)
	end, function(target: buffer, offset: number): any
		return NumberRange.new(buffer.readf32(target, offset), buffer.readf32(target, offset + 4))
	end),

	Bytes = function(count: number): TypeDef
		local capacity = math.floor(count)

		if capacity < 1 then
			fail("Bytes needs a capacity of at least 1")
		end

		local cached = bytesTypes[capacity]

		if cached then
			return cached
		end

		local definition = defineType(
			"Bytes" .. capacity,
			capacity,
			nil,
			function(target: buffer, offset: number, value: any)
				writeRaw(target, offset, value, capacity)
			end,
			function(target: buffer, offset: number): any
				local out = buffer.create(capacity)

				buffer.copy(out, 0, target, offset, capacity)

				return out
			end
		)

		bytesTypes[capacity] = definition

		return definition
	end,

	String = function(count: number): TypeDef
		local capacity = math.floor(count)

		if capacity < 1 or capacity > 65535 then
			fail("String needs a capacity between 1 and 65535")
		end

		local cached = stringTypes[capacity]

		if cached then
			return cached
		end

		local definition = defineType(
			"String" .. capacity,
			capacity + 2,
			"string",
			function(target: buffer, offset: number, value: any)
				local length = math.min(#value, capacity)

				buffer.writeu16(target, offset, length)
				buffer.writestring(target, offset + 2, value, length)

				if length < capacity then
					buffer.fill(target, offset + 2 + length, 0, capacity - length)
				end
			end,
			function(target: buffer, offset: number): any
				return buffer.readstring(target, offset + 2, buffer.readu16(target, offset))
			end
		)

		stringTypes[capacity] = definition

		return definition
	end,
})

Malloc.NULL = NULL
Malloc.NULL_ADDRESS = NULL_ADDRESS
Malloc.Overhead = CHUNK_OVERHEAD

function Malloc.IsNull(value: any): boolean
	return value == nil or value == NULL or value == NULL_ADDRESS
end

function Malloc.Alloc(size: number): Malloc
	if type(size) ~= "number" or size ~= size or size < 1 then
		fail("Alloc needs a positive byte size, got " .. tostring(size))
	end

	local capacity = math.max(alignUp(math.floor(size)), MIN_PAYLOAD) + CHUNK_OVERHEAD
	local data = buffer.create(capacity)
	local control = buffer.create(CONTROL_SIZE)

	initialise(data, control, capacity)

	return (setmetatable({
		data = data,
		control = control,
		released = false,
	}, arenaClass) :: any) :: Malloc
end

function Malloc.Import(metadata: buffer, image: buffer): (Malloc, { number })
	if typeof(metadata) ~= "buffer" or typeof(image) ~= "buffer" then
		fail("Import needs the two buffers returned by Export")
	end

	local metaLength = buffer.len(metadata)

	if metaLength < EXPORT_HEADER or buffer.readstring(metadata, EXPORT_MAGIC_AT, 4) ~= EXPORT_MAGIC then
		fail("Import was not given a Malloc export")
	end

	local version = buffer.readu16(metadata, EXPORT_VERSION_AT)

	if version ~= EXPORT_VERSION then
		fail(("Import expected export version %d, got %d"):format(EXPORT_VERSION, version))
	end

	local capacity = buffer.readu32(metadata, EXPORT_CAPACITY_AT)
	local imageLength = buffer.readu32(metadata, EXPORT_IMAGE_AT)
	local count = buffer.readu32(metadata, EXPORT_COUNT_AT)

	if capacity < CHUNK_OVERHEAD + MIN_PAYLOAD or capacity % ALIGNMENT ~= 0 then
		fail("export declares an impossible capacity of " .. capacity)
	end

	if imageLength > capacity or imageLength % ALIGNMENT ~= 0 then
		fail("export declares an impossible image length of " .. imageLength)
	end

	if buffer.len(image) ~= imageLength then
		fail(("image holds %d bytes but the export declares %d"):format(buffer.len(image), imageLength))
	end

	local data = buffer.create(capacity)
	local control = buffer.create(CONTROL_SIZE)

	buffer.copy(data, 0, image, 0, imageLength)
	buffer.writeu32(control, CONTROL_CAPACITY, capacity)
	buffer.writeu32(control, CONTROL_FREE_HEAD, NULL_ADDRESS)

	if imageLength < capacity then
		writeBlock(data, imageLength + HEADER_SIZE, capacity - imageLength - CHUNK_OVERHEAD, false, 0)
	end

	local usedBytes = 0
	local live = 0
	local address = HEADER_SIZE

	while address + FOOTER_SIZE <= capacity do
		local header = address - HEADER_SIZE

		if buffer.readu16(data, header + HEADER_MAGIC) ~= BLOCK_MAGIC then
			fail("import image is corrupt: no block marker at " .. header)
		end

		local size = blockLength(data, address)

		if size < MIN_PAYLOAD or size % ALIGNMENT ~= 0 or address + size + FOOTER_SIZE > capacity then
			fail(("import image is corrupt: block at %d claims %d bytes"):format(address, size))
		end

		if buffer.readu32(data, address + size) ~= size then
			fail("import image is corrupt: footer mismatch at " .. address)
		end

		if isUsed(data, address) then
			usedBytes += size
			live += 1
		else
			freeListPush(data, control, address)
		end

		address += size + CHUNK_OVERHEAD
	end

	if address - HEADER_SIZE ~= capacity then
		fail("import image is corrupt: blocks do not tile the arena")
	end

	if count ~= live then
		fail(("export lists %d blocks but the image holds %d"):format(count, live))
	end

	local addresses = table.create(count, 0)
	local cursor = EXPORT_HEADER

	for index = 1, count do
		if cursor + EXPORT_ENTRY > metaLength then
			fail("export metadata is truncated")
		end

		local entryAddress = buffer.readu32(metadata, cursor)
		local entrySize = buffer.readu32(metadata, cursor + 4)
		local nameLength = buffer.readu8(metadata, cursor + 8)

		if cursor + EXPORT_ENTRY + nameLength > metaLength then
			fail("export metadata is truncated")
		end

		local name = if nameLength > 0 then buffer.readstring(metadata, cursor + EXPORT_ENTRY, nameLength) else ""

		cursor += EXPORT_ENTRY + nameLength

		if
			entryAddress < HEADER_SIZE
			or entryAddress + entrySize + FOOTER_SIZE > capacity
			or not isUsed(data, entryAddress)
			or blockLength(data, entryAddress) ~= entrySize
		then
			fail("export metadata does not match the image at " .. entryAddress)
		end

		local typeId = 0

		if nameLength > 0 then
			local definition = resolveTypeName(name)

			if definition then
				typeId = definition.id
			else
				fail(("Import does not know the type %q"):format(name))
			end
		end

		buffer.writeu8(data, entryAddress - HEADER_SIZE + HEADER_TYPE, typeId)

		addresses[index] = entryAddress
	end

	buffer.writeu32(control, CONTROL_USED_BYTES, usedBytes)
	buffer.writeu32(control, CONTROL_LIVE_BLOCKS, live)
	buffer.writeu32(control, CONTROL_PEAK_BYTES, usedBytes)
	buffer.writeu32(control, CONTROL_ALLOC_COUNT, live)

	local arena = (setmetatable({
		data = data,
		control = control,
		released = false,
	}, arenaClass) :: any) :: Malloc

	return arena, addresses
end

function Malloc.SizeOf(request: number | TypeDef, count: number?): number
	local _, wanted = resolveRequest(request, count)

	return wanted
end

function Malloc.Reserve(request: number | TypeDef, count: number?): number
	local _, wanted = resolveRequest(request, count)

	return wanted + CHUNK_OVERHEAD
end

function Malloc.Is(value: any): boolean
	return type(value) == "table" and getmetatable(value) == arenaClass
end

return Malloc
