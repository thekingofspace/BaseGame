--!strict
--!optimize 2

--[[
	Malloc

	A memory allocator that keeps everything inside Luau buffers.

	You ask it for one big block of bytes up front. After that you hand out
	small pieces of that block, write values into them, and give them back
	when you are done. Nothing is stored in Luau tables, so the garbage
	collector never has to look at any of it. There is one table per arena
	and that is all.

	Every piece you hand out is called a block, and you refer to it by its
	address, which is just a number. Numbers cost nothing to pass around,
	copy, or store inside another block.


	GETTING STARTED

		local Malloc = require(ReplicatedStorage.Shared.Malloc)

		local arena = Malloc.Alloc(4096)

		local spot = arena:GenerateAddress(Malloc.Types.Vector3)
		arena:Write(spot, Vector3.new(1, 2, 3))
		print(arena:Read(spot))

		arena:Free(spot)


	HOW THE MEMORY IS LAID OUT

	The arena is one buffer. It is cut into chunks that sit right next to
	each other with no gaps. Every chunk looks like this.

		8 bytes of header
		the payload, which is what you actually use
		4 bytes of footer

	The header holds the payload size, a flags byte, the type id, and a
	two byte marker used to spot damaged memory. The footer holds the same
	size again. Keeping the size at both ends is what lets a block find the
	chunk in front of it in one step, which matters when freeing.

	So a block costs 12 bytes on top of whatever you asked for. The
	smallest payload is 8 bytes, because free blocks store two links inside
	their own payload.

	Free blocks are joined together in a chain. When you free a block it
	checks the chunks on either side, and if they are free too it merges
	with them into one larger free block. This means two free blocks can
	never sit next to each other, and an empty arena always collapses back
	into a single free block.

	When you ask for memory the allocator walks the free chain and picks the
	block that fits with the least waste left over. If the leftover is big
	enough to become its own chunk it is split off. If it is too small to
	stand alone and the next chunk is free, the leftover is handed to that
	neighbour instead of being wasted.


	ADDRESSES

	An address is the byte offset of a payload inside the arena buffer.
	Address 0 never happens, so 0 doubles as the null address. If a request
	cannot be met you get nil back instead of an error, the same way malloc
	returns null in C. Always check the result.

		local spot = arena:GenerateAddress(64)

		if spot == nil then
			warn("out of room")
			return
		end

	Addresses stay valid until you free the block or resize it. Growing a
	block can move it, so use the address that Realloc or Resize gives back.


	TYPES

	Malloc.Types holds the value types you can store. Each one knows its
	size and how to turn a value into bytes and back.

		Bool  U8  I8  U16  I16  U32  I32  F32  F64  Address
		Vector2  Vector3  Rect  NumberRange  UDim  UDim2
		Color3  Color3Float
		CFrame  CFramePrecise  CFrameExact  Quaternion

	Two of them are built at the moment you ask for them, so that you can
	pick the size.

		Malloc.Types.Bytes(16)    raw bytes, holds a buffer or a string
		Malloc.Types.String(16)   text up to 16 characters

	The rotation types are worth knowing about because they trade accuracy
	for space.

		CFrame          16 bytes, position plus a squeezed rotation
		CFramePrecise   28 bytes, position plus a full rotation
		CFrameExact     48 bytes, every number kept exactly as it was
		Quaternion       4 bytes, rotation only, no position

	The squeezed rotation in CFrame is accurate to about a sixteenth of a
	degree, which is plenty for most game work. If you need it perfect, use
	CFramePrecise or CFrameExact.

	Colors are three bytes by default, one per channel, which is how colors
	are normally written anyway. Use Color3Float if you need the full range.

	A block remembers its own type, so Write and Read only need the value.

		local spot = arena:GenerateAddress(Malloc.Types.U32, 4)

		arena:Write(spot, 100, 0)
		arena:Write(spot, 200, 1)
		print(arena:Read(spot, 1))

	The last number is the slot, counting from 0. You can also ignore the
	block type and read or write any type at any byte offset with WriteAs
	and ReadAs.


	MALLOC.NULL

	Malloc.NULL is a value you can write anywhere. It wipes the bytes it is
	written to and leaves the address alone. Use it when you want to empty
	something without giving the memory back.

		arena:Write(spot, Malloc.NULL)

	Because all zero bytes are a valid reading of every type, a wiped block
	reads back as an empty value. Numbers read 0, flags read false, text
	reads empty, vectors read zero, and rotations read as no rotation.

	Malloc.NULL_ADDRESS is the separate thing, the number 0, which is what
	a stored pointer holds when it points at nothing. Malloc.IsNull covers
	both of those plus nil.


	ARRAYS

	An array is a block that also tracks how many items you have put in it.
	It costs 4 extra bytes and nothing more.

		local list = arena:GenerateArray(Malloc.Types.Vector3, 64)

		arena:Push(list, Vector3.new(1, 2, 3))
		arena:Push(list, Vector3.new(4, 5, 6))

		print(arena:Get(list, 0))
		print(arena:Length(list))

		arena:Iterate(list, function(index, value)
			print(index, value)
		end)

	Slots count from 0. Length is how many items are in it right now and
	CountOf is how many it can hold. Push returns nil when it is full.
	Remove takes an item out and slides the rest down. Pop takes the last
	one off.


	DICTIONARIES

	A dictionary maps keys to values. Both the key and the value are normal
	Malloc types, so the whole thing lives in bytes.

		local map = arena:GenerateDictionary(
			Malloc.Types.String(16),
			Malloc.Types.F32,
			100
		)

		arena:Set(map, "health", 100)
		print(arena:Get(map, "health"))
		print(arena:Has(map, "health"))

		arena:Remove(map, "health")

	Inside, it is a table of slots. A key is turned into a number and that
	number picks a starting slot. If the slot is taken it walks forward
	until it finds a free one. Deleting slides the following keys back so
	no dead markers are left behind, which keeps the table small and fast.

	It asks for a few more slots than you need so that it never fills up
	completely, since a completely full table of this kind gets very slow.
	Three quarters full is the limit. Set returns false once it is full,
	though it will still overwrite keys that are already there.

	Keys match on their bytes. Two keys are the same key when they write
	the same bytes. Worth keeping in mind for decimal number keys, where
	negative zero and positive zero write differently.

	Slot order is not the order you added things in, and it changes as you
	add and remove. Do not rely on it.


	RESIZING

	Resize changes how much a collection can hold, in either direction.

		list = arena:Resize(list, 128)
		map = arena:Resize(map, 500)

	Arrays usually stay where they are. Shrinking an array below what it
	holds drops the items off the end.

	Dictionaries always move, because the slot count is part of how keys
	find their slot, so everything has to be placed again. The new address
	is what Resize hands back. If you stored the old address somewhere,
	write the new one over it. Shrinking a dictionary below what it holds
	is refused, since there is no sensible answer for which entries to
	throw away.

	Grow does the same thing but refuses to drop array items, so use it
	when losing data should be an error.


	SENDING AN ARENA SOMEWHERE ELSE

	Export gives you two buffers. One is a short description of everything
	stored, and the other is the memory itself, cut off after the last
	block in use. Import turns them back into an arena.

		local metadata, image = arena:Export()

		local restored, addresses = Malloc.Import(metadata, image)

	Import also hands back a list of every address in the arena, in order,
	so the other side knows what it received without being told.

	Addresses are kept exactly as they were. That is what makes it safe to
	store addresses inside blocks. You can keep one block full of addresses
	that point at all the others, send the pair of buffers across, and the
	pointers still work on the far side.

	Types travel by name rather than by number, because the numbers depend
	on which types each side happened to ask for first. Import reads the
	names and looks them up again, and builds sized types like String16
	back from scratch if it has to.

	Import does not trust what it is given. It walks every chunk, checks
	the markers, the sizes, and the footers, and makes sure the chunks fill
	the arena exactly before handing anything back. Anything bent gets a
	clear error instead of a broken arena.


	SIZING AN ARENA

	KB, MB, and GB turn a friendly number into a byte count, so you do not
	have to write the zeros out.

		local arena = Malloc.Alloc(Malloc.MB(4))

	They use 1024 to the step, the way memory is normally counted, so one
	MB is 1048576 bytes and not a flat million.

	If you want an arena that is exactly big enough instead, add up what
	you plan to put in it. These give the full cost including the 12 byte
	overhead.

		Malloc.Reserve(Malloc.Types.Vector3, 10)
		Malloc.ReserveArray(Malloc.Types.Vector3, 64)
		Malloc.ReserveDictionary(Malloc.Types.String(16), Malloc.Types.F32, 100)

	Format turns a byte count back into something you can read.

		print(Malloc.Format(4194304))    4 MB
		print(Malloc.Format(4000000))    3.81 MB
		print(Malloc.Format(512))        512 B

	It picks the unit for you and drops trailing zeros. Pass a second
	number if you want a set number of decimal places.


	CHECKING ON AN ARENA

	Summary prints a readable report of where the memory went.

		print(arena:Summary())

		Malloc arena
		  capacity       4 MB
		  used           11.72 KB (0.3%)
		  free           3.99 MB
		  largest free   3.99 MB
		  fragmentation  0.0%
		  overhead       24 B across 2 chunks
		  free chunks    1
		  peak used      11.72 KB
		  allocations    4
		  frees          3

	Usage is how full the arena is, from 0 to 1.

	Fragmentation is how broken up the free space is, from 0 to 1. Zero
	means all the free space is in one piece, so the largest thing you can
	ask for is everything that is free. A high number means the free space
	is scattered in small holes, and a big request will fail even though
	the total looks like it should fit.


	EVERYTHING YOU CAN CALL

	On the module

		Malloc.Alloc(bytes)                        make an arena
		Malloc.Import(metadata, image)             rebuild a sent arena
		Malloc.Is(value)                           is this an arena
		Malloc.IsNull(value)                       nil, NULL, or address 0
		Malloc.SizeOf(type, count)                 payload bytes needed
		Malloc.Reserve(type, count)                payload plus overhead
		Malloc.ReserveArray(type, capacity)        cost of an array
		Malloc.ReserveDictionary(key, value, n)    cost of a dictionary
		Malloc.KB(count)                           count times 1024
		Malloc.MB(count)                           count times 1048576
		Malloc.GB(count)                           count times 1073741824
		Malloc.Format(bytes, decimals)             "3.81 MB"
		Malloc.Types                               the value types
		Malloc.NULL                                the wipe value
		Malloc.NULL_ADDRESS                        the number 0
		Malloc.Overhead                            12

	Blocks

		arena:GenerateAddress(type or bytes, count)
		arena:Free(address)
		arena:Realloc(address, type or bytes, count)

	Reading and writing

		arena:Write(address, value, slot)
		arena:Read(address, slot)
		arena:WriteAs(address, type, value, offset)
		arena:ReadAs(address, type, offset)
		arena:WriteBytes(address, buffer or string, offset, count)
		arena:ReadBytes(address, offset, count)
		arena:WriteString(address, text, offset)
		arena:ReadString(address, count, offset)
		arena:Fill(address, byte, offset, count)
		arena:Copy(destination, source, count)

	Asking about a block

		arena:SizeOf(address)        payload bytes
		arena:CountOf(address)       how many it can hold
		arena:TypeOf(address)        its type
		arena:KindOf(address)        plain, array, or dictionary
		arena:IsAllocated(address)   is it alive

	Arrays and dictionaries

		arena:GenerateArray(type, capacity)
		arena:GenerateDictionary(key, value, entries)
		arena:Push(address, value)
		arena:Pop(address)
		arena:Get(address, slot or key)
		arena:Set(address, slot or key, value)
		arena:Has(address, key)
		arena:Remove(address, slot or key)
		arena:Length(address)
		arena:Clear(address)
		arena:Iterate(address, callback)
		arena:Resize(address, capacity)
		arena:Grow(address, capacity)

	The arena as a whole

		arena:Capacity()       total bytes
		arena:Used()           bytes handed out
		arena:Available()      bytes free
		arena:LargestFree()    biggest single free block
		arena:Addresses()      every live address
		arena:Each(callback)   walk every chunk, free ones included
		arena:Stats()          a table of numbers
		arena:Summary()        the same thing as readable text
		arena:Usage()          how full it is, 0 to 1
		arena:Fragmentation()  how broken up the free space is, 0 to 1
		arena:Export()         metadata and memory buffers
		arena:Reset()          free everything, keep the arena
		arena:Release()        free everything and drop the memory


	THINGS THAT WILL CATCH YOU OUT

	Slots count from 0, not 1.

	GenerateAddress and friends return nil when they cannot fit the
	request. If you pass that nil along you get an error further down
	saying no address was given.

	Write and Read only work on plain blocks. Arrays and dictionaries use
	Get, Set, and Push. The error message will tell you which to use.

	Realloc works on plain blocks and Resize works on collections.

	Do not add to or remove from a collection while Iterate is running.
	Collect what you want to change and do it after the loop ends.

	Release throws the memory away. Every address from that arena stops
	working. Reset keeps the arena but empties it.
]]

local Malloc = {}

export type TypeDef = {
	id: number,
	name: string,
	size: number,
	kind: string?,
	key: TypeDef?,
	value: TypeDef?,
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
	Usage: (self: Malloc) -> number,
	Fragmentation: (self: Malloc) -> number,
	Summary: (self: Malloc) -> string,
	Addresses: (self: Malloc) -> { number },
	Export: (self: Malloc) -> (buffer, buffer),

	GenerateArray: (self: Malloc, element: TypeDef, capacity: number) -> number?,
	GenerateDictionary: (self: Malloc, key: TypeDef, value: TypeDef, entries: number) -> number?,
	KindOf: (self: Malloc, address: number) -> string,
	Length: (self: Malloc, address: number) -> number,
	Push: (self: Malloc, address: number, value: any) -> number?,
	Pop: (self: Malloc, address: number) -> any,
	Get: (self: Malloc, address: number, at: any) -> any,
	Set: (self: Malloc, address: number, at: any, value: any) -> boolean,
	Has: (self: Malloc, address: number, key: any) -> boolean,
	Remove: (self: Malloc, address: number, at: any) -> any,
	Clear: (self: Malloc, address: number) -> (),
	Iterate: (self: Malloc, address: number, callback: (any, any) -> ()) -> (),
	Resize: (self: Malloc, address: number, capacity: number) -> number?,
	Grow: (self: Malloc, address: number, capacity: number) -> number?,

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
local KIND_MASK = 6
local KIND_PLAIN = 0
local KIND_ARRAY = 2
local KIND_DICT = 4

local ARRAY_LENGTH_AT = 0
local ARRAY_HEADER = 4

local DICT_COUNT_AT = 0
local DICT_CAPACITY_AT = 4
local DICT_HEADER = 8
local DICT_LOAD = 0.75
local DICT_MIN_SLOTS = 4
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
	read: (target: buffer, offset: number) -> any,
	pair: { key: TypeDef, value: TypeDef }?
): TypeDef
	if nextTypeId > MAX_TYPE_ID then
		fail("exhausted the type table, only " .. MAX_TYPE_ID .. " types can exist")
	end

	local definition = table.freeze({
		id = nextTypeId,
		name = name,
		size = size,
		kind = kind,
		key = if pair then pair.key else nil,
		value = if pair then pair.value else nil,
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

	local mapKey, mapValue = string.match(name, "^Map<(.+),(.+)>$")

	if mapKey and mapValue then
		local resolvedKey = resolveTypeName(mapKey)
		local resolvedValue = resolveTypeName(mapValue)

		if resolvedKey and resolvedValue then
			return Malloc.Types.Map(resolvedKey, resolvedValue)
		end
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

	if address == nil then
		fail("no address was given, which usually means an allocation did not fit and returned nil")
	end

	if address == NULL then
		fail("Malloc.NULL is a value used to clear a slot, not an address")
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

local function nextPowerOfTwo(value: number): number
	local size = 1

	while size < value do
		size *= 2
	end

	return size
end

local function bitmapBytes(slots: number): number
	return (slots + 7) // 8
end

local function dictSlots(entries: number): number
	return math.max(DICT_MIN_SLOTS, math.ceil(entries / DICT_LOAD))
end

local function dictLimit(slots: number): number
	return math.floor(slots * DICT_LOAD)
end

local function describeKind(kind: number): string
	if kind == KIND_ARRAY then
		return "an array"
	elseif kind == KIND_DICT then
		return "a dictionary"
	end

	return "a plain block"
end

local function blockKind(data: buffer, address: number): number
	return bit32.band(buffer.readu8(data, address - HEADER_SIZE + HEADER_FLAGS), KIND_MASK)
end

local function markKind(data: buffer, address: number, kind: number, typeId: number)
	local header = address - HEADER_SIZE

	buffer.writeu8(data, header + HEADER_FLAGS, FLAG_USED + kind)
	buffer.writeu8(data, header + HEADER_TYPE, typeId)
end

local function hashBytes(source: buffer, offset: number, length: number): number
	local hash = 0

	for index = 0, length - 1 do
		hash = bit32.band(hash + buffer.readu8(source, offset + index), 0xFFFFFFFF)
		hash = bit32.band(hash + bit32.lshift(hash, 10), 0xFFFFFFFF)
		hash = bit32.bxor(hash, bit32.rshift(hash, 6))
	end

	hash = bit32.band(hash + bit32.lshift(hash, 3), 0xFFFFFFFF)
	hash = bit32.bxor(hash, bit32.rshift(hash, 11))

	return bit32.band(hash + bit32.lshift(hash, 15), 0xFFFFFFFF)
end

local function sameBytes(left: buffer, leftAt: number, right: buffer, rightAt: number, length: number): boolean
	local index = 0

	while index + 4 <= length do
		if buffer.readu32(left, leftAt + index) ~= buffer.readu32(right, rightAt + index) then
			return false
		end

		index += 4
	end

	while index < length do
		if buffer.readu8(left, leftAt + index) ~= buffer.readu8(right, rightAt + index) then
			return false
		end

		index += 1
	end

	return true
end

local scratch = buffer.create(64)

local function encodeKey(definition: TypeDef, value: any): buffer
	if buffer.len(scratch) < definition.size then
		scratch = buffer.create(nextPowerOfTwo(definition.size))
	end

	buffer.fill(scratch, 0, 0, definition.size)
	assertValue(definition, value)
	definition.write(scratch, 0, value)

	return scratch
end

local function slotTaken(data: buffer, bitmapAt: number, slot: number): boolean
	return bit32.band(bit32.rshift(buffer.readu8(data, bitmapAt + slot // 8), slot % 8), 1) == 1
end

local function setSlot(data: buffer, bitmapAt: number, slot: number, taken: boolean)
	local at = bitmapAt + slot // 8
	local bit = bit32.lshift(1, slot % 8)
	local byte = buffer.readu8(data, at)

	buffer.writeu8(data, at, if taken then bit32.bor(byte, bit) else bit32.band(byte, bit32.bxor(0xFF, bit)))
end

local function arrayElement(data: buffer, address: number): TypeDef
	local element = typesById[blockTypeId(data, address)]

	if element == nil then
		return fail("address " .. address .. " is an array with no element type")
	end

	return element
end

local function arrayCapacity(size: number, element: TypeDef): number
	return (size - ARRAY_HEADER) // element.size
end

local function dictDefinition(data: buffer, address: number): TypeDef
	local definition = typesById[blockTypeId(data, address)]

	if definition and definition.key and definition.value then
		return definition
	end

	return fail("address " .. address .. " is a dictionary with no key and value types")
end

local function dictLayout(data: buffer, address: number): (TypeDef, TypeDef, number, number, number, number)
	local definition = dictDefinition(data, address)
	local key = definition.key :: TypeDef
	local value = definition.value :: TypeDef
	local capacity = buffer.readu32(data, address + DICT_CAPACITY_AT)
	local bitmapAt = address + DICT_HEADER
	local keysAt = bitmapAt + bitmapBytes(capacity)

	return key, value, capacity, bitmapAt, keysAt, keysAt + capacity * key.size
end

local function findSlot(
	data: buffer,
	bitmapAt: number,
	keysAt: number,
	capacity: number,
	keySize: number,
	probe: buffer
): (number, boolean)
	local slot = hashBytes(probe, 0, keySize) % capacity

	for _ = 1, capacity do
		if not slotTaken(data, bitmapAt, slot) then
			return slot, false
		end

		if sameBytes(data, keysAt + slot * keySize, probe, 0, keySize) then
			return slot, true
		end

		slot = (slot + 1) % capacity
	end

	return -1, false
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

	if blockKind(self.data, address) ~= KIND_PLAIN then
		fail(("address %d is %s, use Grow"):format(address, describeKind(blockKind(self.data, address))))
	end
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

	if blockKind(self.data, address) ~= KIND_PLAIN then
		fail(("address %d is %s, use Set or Push"):format(address, describeKind(blockKind(self.data, address))))
	end

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

	if blockKind(self.data, address) ~= KIND_PLAIN then
		fail(("address %d is %s, use Get"):format(address, describeKind(blockKind(self.data, address))))
	end

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
	local data = self.data
	local kind = blockKind(data, address)

	if kind == KIND_ARRAY then
		return arrayCapacity(size, arrayElement(data, address))
	end

	if kind == KIND_DICT then
		return dictLimit(buffer.readu32(data, address + DICT_CAPACITY_AT))
	end

	local definition = typesById[blockTypeId(data, address)]

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

local function assertKind(self: Malloc, address: number, wanted: number): number
	local size = assertAddress(self, address)
	local kind = blockKind(self.data, address)

	if kind ~= wanted then
		fail(("address %d is %s, not %s"):format(address, describeKind(kind), describeKind(wanted)))
	end

	return size
end

local function arraySlot(data: buffer, address: number, element: TypeDef, index: number, length: number): number
	local slot = math.floor(index)

	if slot < 0 or slot >= length then
		fail(("index %d falls outside an array of %d elements"):format(slot, length))
	end

	return address + ARRAY_HEADER + slot * element.size
end

local function dictSet(self: Malloc, address: number, key: any, value: any): boolean
	local data = self.data
	local keyType, valueType, capacity, bitmapAt, keysAt, valuesAt = dictLayout(data, address)
	local probe = encodeKey(keyType, key)
	local slot, found = findSlot(data, bitmapAt, keysAt, capacity, keyType.size, probe)

	if slot < 0 then
		return false
	end

	if not found then
		local count = buffer.readu32(data, address + DICT_COUNT_AT)

		if count >= dictLimit(capacity) then
			return false
		end

		buffer.copy(data, keysAt + slot * keyType.size, probe, 0, keyType.size)
		setSlot(data, bitmapAt, slot, true)
		buffer.writeu32(data, address + DICT_COUNT_AT, count + 1)
	end

	local at = valuesAt + slot * valueType.size

	if value == NULL then
		buffer.fill(data, at, 0, valueType.size)
	else
		assertValue(valueType, value)
		valueType.write(data, at, value)
	end

	return true
end

local function dictFind(self: Malloc, address: number, key: any): (number, boolean)
	local data = self.data
	local keyType, _valueType, capacity, bitmapAt, keysAt = dictLayout(data, address)

	return findSlot(data, bitmapAt, keysAt, capacity, keyType.size, encodeKey(keyType, key))
end

local function dictRemove(self: Malloc, address: number, key: any): any
	local data = self.data
	local keyType, valueType, capacity, bitmapAt, keysAt, valuesAt = dictLayout(data, address)
	local slot, found = findSlot(data, bitmapAt, keysAt, capacity, keyType.size, encodeKey(keyType, key))

	if not found then
		return nil
	end

	local keySize = keyType.size
	local valueSize = valueType.size
	local removed = valueType.read(data, valuesAt + slot * valueSize)
	local hole = slot
	local cursor = slot

	for _ = 1, capacity do
		cursor = (cursor + 1) % capacity

		if not slotTaken(data, bitmapAt, cursor) then
			break
		end

		local ideal = hashBytes(data, keysAt + cursor * keySize, keySize) % capacity
		local movable

		if cursor > hole then
			movable = ideal <= hole or ideal > cursor
		else
			movable = ideal <= hole and ideal > cursor
		end

		if movable then
			buffer.copy(data, keysAt + hole * keySize, data, keysAt + cursor * keySize, keySize)
			buffer.copy(data, valuesAt + hole * valueSize, data, valuesAt + cursor * valueSize, valueSize)
			hole = cursor
		end
	end

	setSlot(data, bitmapAt, hole, false)
	buffer.fill(data, keysAt + hole * keySize, 0, keySize)
	buffer.fill(data, valuesAt + hole * valueSize, 0, valueSize)
	buffer.writeu32(data, address + DICT_COUNT_AT, buffer.readu32(data, address + DICT_COUNT_AT) - 1)

	return removed
end

function arenaClass.GenerateArray(self: Malloc, element: TypeDef, capacity: number): number?
	assertDefinition(element)

	local slots = math.floor(capacity)

	if slots < 1 then
		fail("an array needs room for at least one element")
	end

	local address = self:GenerateAddress(ARRAY_HEADER + slots * element.size)

	if address then
		markKind(self.data, address, KIND_ARRAY, element.id)
	end

	return address
end

function arenaClass.GenerateDictionary(self: Malloc, key: TypeDef, value: TypeDef, entries: number): number?
	local definition = Malloc.Types.Map(key, value)
	local wanted = math.floor(entries)

	if wanted < 1 then
		fail("a dictionary needs room for at least one entry")
	end

	local slots = dictSlots(wanted)
	local address = self:GenerateAddress(DICT_HEADER + bitmapBytes(slots) + slots * definition.size)

	if address then
		markKind(self.data, address, KIND_DICT, definition.id)
		buffer.writeu32(self.data, address + DICT_CAPACITY_AT, slots)
	end

	return address
end

function arenaClass.KindOf(self: Malloc, address: number): string
	assertAddress(self, address)

	local kind = blockKind(self.data, address)

	return if kind == KIND_ARRAY then "array" elseif kind == KIND_DICT then "dictionary" else "plain"
end

function arenaClass.Length(self: Malloc, address: number): number
	assertAddress(self, address)

	local data = self.data
	local kind = blockKind(data, address)

	if kind == KIND_ARRAY then
		return buffer.readu32(data, address + ARRAY_LENGTH_AT)
	end

	if kind == KIND_DICT then
		return buffer.readu32(data, address + DICT_COUNT_AT)
	end

	return fail("address " .. address .. " is a plain block, use CountOf")
end

function arenaClass.Push(self: Malloc, address: number, value: any): number?
	local size = assertKind(self, address, KIND_ARRAY)
	local data = self.data
	local element = arrayElement(data, address)
	local length = buffer.readu32(data, address + ARRAY_LENGTH_AT)

	if length >= arrayCapacity(size, element) then
		return nil
	end

	local at = address + ARRAY_HEADER + length * element.size

	if value == NULL then
		buffer.fill(data, at, 0, element.size)
	else
		assertValue(element, value)
		element.write(data, at, value)
	end

	buffer.writeu32(data, address + ARRAY_LENGTH_AT, length + 1)

	return length
end

function arenaClass.Pop(self: Malloc, address: number): any
	assertKind(self, address, KIND_ARRAY)

	local data = self.data
	local element = arrayElement(data, address)
	local length = buffer.readu32(data, address + ARRAY_LENGTH_AT)

	if length == 0 then
		return nil
	end

	local at = address + ARRAY_HEADER + (length - 1) * element.size
	local value = element.read(data, at)

	buffer.fill(data, at, 0, element.size)
	buffer.writeu32(data, address + ARRAY_LENGTH_AT, length - 1)

	return value
end

function arenaClass.Get(self: Malloc, address: number, at: any): any
	assertAddress(self, address)

	local data = self.data
	local kind = blockKind(data, address)

	if kind == KIND_ARRAY then
		local element = arrayElement(data, address)
		local length = buffer.readu32(data, address + ARRAY_LENGTH_AT)

		return element.read(data, arraySlot(data, address, element, at, length))
	end

	if kind == KIND_DICT then
		local _keyType, valueType, _capacity, _bitmapAt, _keysAt, valuesAt = dictLayout(data, address)
		local slot, found = dictFind(self, address, at)

		if not found then
			return nil
		end

		return valueType.read(data, valuesAt + slot * valueType.size)
	end

	return fail("address " .. address .. " is a plain block, use Read")
end

function arenaClass.Set(self: Malloc, address: number, at: any, value: any): boolean
	assertAddress(self, address)

	local data = self.data
	local kind = blockKind(data, address)

	if kind == KIND_ARRAY then
		local element = arrayElement(data, address)
		local length = buffer.readu32(data, address + ARRAY_LENGTH_AT)
		local target = arraySlot(data, address, element, at, length)

		if value == NULL then
			buffer.fill(data, target, 0, element.size)
		else
			assertValue(element, value)
			element.write(data, target, value)
		end

		return true
	end

	if kind == KIND_DICT then
		return dictSet(self, address, at, value)
	end

	return fail("address " .. address .. " is a plain block, use Write")
end

function arenaClass.Has(self: Malloc, address: number, key: any): boolean
	assertKind(self, address, KIND_DICT)

	local _slot, found = dictFind(self, address, key)

	return found
end

function arenaClass.Remove(self: Malloc, address: number, at: any): any
	assertAddress(self, address)

	local data = self.data
	local kind = blockKind(data, address)

	if kind == KIND_DICT then
		return dictRemove(self, address, at)
	end

	if kind ~= KIND_ARRAY then
		return fail("address " .. address .. " is a plain block, use Free")
	end

	local element = arrayElement(data, address)
	local length = buffer.readu32(data, address + ARRAY_LENGTH_AT)
	local target = arraySlot(data, address, element, at, length)
	local removed = element.read(data, target)
	local tail = address + ARRAY_HEADER + (length - 1) * element.size

	if target < tail then
		buffer.copy(data, target, data, target + element.size, tail - target)
	end

	buffer.fill(data, tail, 0, element.size)
	buffer.writeu32(data, address + ARRAY_LENGTH_AT, length - 1)

	return removed
end

function arenaClass.Clear(self: Malloc, address: number)
	local size = assertAddress(self, address)
	local data = self.data
	local kind = blockKind(data, address)

	if kind == KIND_ARRAY then
		buffer.fill(data, address, 0, size)
		return
	end

	if kind == KIND_DICT then
		buffer.fill(data, address + DICT_HEADER, 0, size - DICT_HEADER)
		buffer.writeu32(data, address + DICT_COUNT_AT, 0)

		return
	end

	buffer.fill(data, address, 0, size)
end

function arenaClass.Iterate(self: Malloc, address: number, callback: (any, any) -> ())
	assertAddress(self, address)

	local data = self.data
	local kind = blockKind(data, address)

	if kind == KIND_ARRAY then
		local element = arrayElement(data, address)
		local length = buffer.readu32(data, address + ARRAY_LENGTH_AT)

		for index = 0, length - 1 do
			callback(index, element.read(data, address + ARRAY_HEADER + index * element.size))
		end

		return
	end

	if kind == KIND_DICT then
		local keyType, valueType, capacity, bitmapAt, keysAt, valuesAt = dictLayout(data, address)

		for slot = 0, capacity - 1 do
			if slotTaken(data, bitmapAt, slot) then
				callback(
					keyType.read(data, keysAt + slot * keyType.size),
					valueType.read(data, valuesAt + slot * valueType.size)
				)
			end
		end

		return
	end

	fail("address " .. address .. " is a plain block, use Read")
end

function arenaClass.Resize(self: Malloc, address: number, capacity: number): number?
	assertAddress(self, address)

	local data = self.data
	local kind = blockKind(data, address)
	local wanted = math.floor(capacity)

	if kind == KIND_ARRAY then
		if wanted < 1 then
			fail("an array needs room for at least one element")
		end

		local element = arrayElement(data, address)
		local length = buffer.readu32(data, address + ARRAY_LENGTH_AT)

		if wanted < length then
			buffer.fill(data, address + ARRAY_HEADER + wanted * element.size, 0, (length - wanted) * element.size)
			buffer.writeu32(data, address + ARRAY_LENGTH_AT, wanted)
		end

		buffer.writeu8(data, address - HEADER_SIZE + HEADER_FLAGS, FLAG_USED)

		local moved = self:Realloc(address, ARRAY_HEADER + wanted * element.size)

		if moved == nil then
			markKind(data, address, KIND_ARRAY, element.id)
			return nil
		end

		markKind(data, moved, KIND_ARRAY, element.id)

		return moved
	end

	if kind ~= KIND_DICT then
		return fail("address " .. address .. " is a plain block, use Realloc")
	end

	if wanted < 1 then
		fail("a dictionary needs room for at least one entry")
	end

	local keyType, valueType, oldCapacity, bitmapAt, keysAt, valuesAt = dictLayout(data, address)
	local count = buffer.readu32(data, address + DICT_COUNT_AT)

	if wanted < count then
		fail(("cannot resize a dictionary holding %d entries down to %d, remove entries first"):format(count, wanted))
	end

	if dictSlots(wanted) == oldCapacity then
		return address
	end

	local fresh = self:GenerateDictionary(keyType, valueType, wanted)

	if fresh == nil then
		return nil
	end

	for slot = 0, oldCapacity - 1 do
		if slotTaken(data, bitmapAt, slot) then
			dictSet(
				self,
				fresh,
				keyType.read(data, keysAt + slot * keyType.size),
				valueType.read(data, valuesAt + slot * valueType.size)
			)
		end
	end

	self:Free(address)

	return fresh
end

function arenaClass.Grow(self: Malloc, address: number, capacity: number): number?
	assertAddress(self, address)

	local data = self.data
	local kind = blockKind(data, address)
	local wanted = math.floor(capacity)

	if kind == KIND_ARRAY then
		local length = buffer.readu32(data, address + ARRAY_LENGTH_AT)

		if wanted < length then
			fail(("Grow will not drop %d of %d array elements, use Resize"):format(length - wanted, length))
		end
	end

	return self:Resize(address, capacity)
end

function arenaClass.Usage(self: Malloc): number
	local capacity = self:Capacity()

	if capacity == 0 then
		return 0
	end

	return self:Used() / capacity
end

function arenaClass.Fragmentation(self: Malloc): number
	local free = self:Available()

	if free == 0 then
		return 0
	end

	return 1 - self:LargestFree() / free
end

function arenaClass.Summary(self: Malloc): string
	if self.released then
		return "Malloc arena (released)"
	end

	local stats = self:Stats()
	local lines = {
		"Malloc arena",
		("  capacity       %s"):format(Malloc.Format(stats.capacity)),
		("  used           %s (%.1f%%)"):format(Malloc.Format(stats.used), self:Usage() * 100),
		("  free           %s"):format(Malloc.Format(stats.free)),
		("  largest free   %s"):format(Malloc.Format(stats.largestFree)),
		("  fragmentation  %.1f%%"):format(self:Fragmentation() * 100),
		("  overhead       %s across %d chunks"):format(Malloc.Format(stats.overhead), stats.blocks),
		("  free chunks    %d"):format(stats.fragments),
		("  peak used      %s"):format(Malloc.Format(stats.peak)),
		("  allocations    %d"):format(stats.allocations),
		("  frees          %d"):format(stats.frees),
	}

	return table.concat(lines, "\n")
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

	Map = function(key: TypeDef, value: TypeDef): TypeDef
		assertDefinition(key)
		assertDefinition(value)

		local name = "Map<" .. key.name .. "," .. value.name .. ">"
		local cached = typesByName[name]

		if cached then
			return cached
		end

		return defineType(
			name,
			key.size + value.size,
			nil,
			function(_target: buffer, _offset: number, _value: any)
				fail("a dictionary is written through Set, not Write")
			end,
			function(_target: buffer, _offset: number): any
				return fail("a dictionary is read through Get, not Read")
			end,
			{ key = key, value = value }
		)
	end,

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

local SIZE_UNITS = { "B", "KB", "MB", "GB", "TB" }

local function sizeArgument(count: number, unit: string): number
	if type(count) ~= "number" or count ~= count or count < 0 then
		fail(unit .. " needs a count of zero or more, got " .. tostring(count))
	end

	return count
end

function Malloc.KB(count: number): number
	return math.floor(sizeArgument(count, "KB") * 1024)
end

function Malloc.MB(count: number): number
	return math.floor(sizeArgument(count, "MB") * 1048576)
end

function Malloc.GB(count: number): number
	return math.floor(sizeArgument(count, "GB") * 1073741824)
end

function Malloc.Format(bytes: number, decimals: number?): string
	if type(bytes) ~= "number" or bytes ~= bytes then
		fail("Format needs a number of bytes, got " .. tostring(bytes))
	end

	local places = if decimals ~= nil then math.clamp(math.floor(decimals), 0, 6) else 2
	local amount = math.abs(bytes)
	local unit = 1

	while amount >= 1024 and unit < #SIZE_UNITS do
		amount /= 1024
		unit += 1
	end

	if unit == 1 then
		return ("%d %s"):format(math.floor(bytes), SIZE_UNITS[1])
	end

	local text = ("%." .. places .. "f"):format(if bytes < 0 then -amount else amount)

	if string.find(text, "%.", 1, false) then
		text = string.gsub(text, "0+$", "")
		text = string.gsub(text, "%.$", "")
	end

	return text .. " " .. SIZE_UNITS[unit]
end

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
			local kind = bit32.band(buffer.readu8(data, header + HEADER_FLAGS), KIND_MASK)

			if kind ~= KIND_PLAIN and kind ~= KIND_ARRAY and kind ~= KIND_DICT then
				fail("import image is corrupt: unknown block kind at " .. address)
			end

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

function Malloc.ReserveArray(element: TypeDef, capacity: number): number
	assertDefinition(element)

	local slots = math.floor(capacity)

	if slots < 1 then
		fail("an array needs room for at least one element")
	end

	return math.max(alignUp(ARRAY_HEADER + slots * element.size), MIN_PAYLOAD) + CHUNK_OVERHEAD
end

function Malloc.ReserveDictionary(key: TypeDef, value: TypeDef, entries: number): number
	assertDefinition(key)
	assertDefinition(value)

	local wanted = math.floor(entries)

	if wanted < 1 then
		fail("a dictionary needs room for at least one entry")
	end

	local slots = dictSlots(wanted)
	local payload = DICT_HEADER + bitmapBytes(slots) + slots * (key.size + value.size)

	return math.max(alignUp(payload), MIN_PAYLOAD) + CHUNK_OVERHEAD
end

function Malloc.Is(value: any): boolean
	return type(value) == "table" and getmetatable(value) == arenaClass
end

return Malloc
