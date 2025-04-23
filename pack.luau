--!strict

debug.setmemorycategory('LIBPACK')

type int = number
type float = number
type map<K, V> = { [K]: V }
type array<V> = map<int, V>
type set<K> = map<K, true>
type unpack<T...> = (array<any>, int, int) -> (T...)

type WriteFixed<T...> = (bytes: buffer, offset: int, T...) -> ()
type WriteDynamic<T...> = (bytes: buffer, offset: int, T...) -> (int)
type Write<T...> = WriteFixed<T...> | WriteDynamic<T...>

type ReadFixed<T...> = (bytes: buffer, offset: int) -> (T...)
type ReadDynamic<T...> = (bytes: buffer, offset: int) -> (int, T...)
type Read<T...> = ReadFixed<T...> | ReadDynamic<T...>

type SizeFixed = int
type SizeDynamic<T...> = (T...) -> int
type Size<T...> = SizeFixed | SizeDynamic<T...>

type Check<T...> = (T...) -> ()

export type Tagged<T> = {
	read format: Format<T>,
	read value: T
}

export type TypeFixed<T...> = {
	read name: string,
	read fixed: true,
	read size: SizeFixed,
	read write: WriteFixed<T...>,
	read read: ReadFixed<T...>
}

export type TypeDynamic<T...> = {
	read name: string,
	read fixed: false,
	read size: SizeDynamic<T...>,
	read write: WriteDynamic<T...>,
	read read: ReadDynamic<T...>
}

export type Format<T...> = TypeFixed<T...> | TypeDynamic<T...>

export type Schema<T...> = Format<T...> & {
	read encode: (T...) -> buffer,
	read decode: (bytes: buffer) -> T...
}

-- LIBRARY

local writeu8 = buffer.writeu8
local readu8 = buffer.readu8
local writeu16 = buffer.writeu16
local readu16 = buffer.readu16
local writeu32 = buffer.writeu32
local readu32 = buffer.readu32

-- maybe keep this
local BUF = buffer.create(10 * 2^10) -- 10 KiB

local t = {}

local weakvals = table.freeze { __mode = 'v' }
local cache_data = setmetatable({}, weakvals) :: map<string, Format<any>>
local cache_state = {} :: array<boolean>

local cache = table.freeze {

	push = function(
		enabled: boolean
	)
		table.insert(cache_state, enabled)
	end,

	pop = function()
		table.remove(cache_state)
	end,

	stats = function()
		local count = 0
		for _ in cache_data do
			count += 1
		end
		return table.freeze {
			count = count,
			enabled = if #cache_state == 0 then 'default' else cache_state[#cache_state]
		}
	end

}

local function get<T>(
	name: string
)
	return cache_data[name] :: Format<T>?
end

local function declare<T>(
	default: boolean,
	name: string,
	value: T
)
	(table.freeze :: (T) -> T)(value)
	if (#cache_state == 0 and default) or cache_state[#cache_state] then
		cache_data[name] = value
	end
	return value
end

@native
local function tag<T>(
	format: Format<T>,
	value: T
)
	return table.freeze { format = format, value = value }
end

@native
local function vlqPrefix(
	length: int
)
	return
		if length < 2^6 then 1
			elseif length < 2^14 then 2
			elseif length < 2^22 then 3
			else 4
end

@native
local function writeLength(
	bytes: buffer,
	offset: number,
	length: number
)
	if length < 2^6 then
		writeu8(bytes, offset, 4 * length)
		return offset + 1
	elseif length < 2^14 then
		writeu16(bytes, offset, 1 + 4 * length)
		return offset + 2
	elseif length < 2^22 then
		length = 3 + 4 * length
		writeu8(bytes, offset, length % 2^8)
		writeu16(bytes, offset + 1, length // 2^8)
		return offset + 3
	else
		writeu32(bytes, offset, 3 + 4 * length)
		return offset + 4
	end
end

@native
local function readLength(
	bytes: buffer,
	offset: number
)
	local first = readu8(bytes, offset)
	local count = first % 4

	if count == 0 then
		return offset + 1, first // 4
	elseif count == 1 then
		return offset + 2, readu16(bytes, offset) // 4
	elseif count == 2 then
		return offset + 3, (first + readu16(bytes, offset + 1) * 2^6) // 4
	else
		return offset + 4, readu32(bytes, offset) // 4
	end
end

local function encoder<T...>(
	format: Format<T...>,
	check: Check<T...>?
)
	if type(format.size) == 'number' then

		local fmtWrite = format.write :: WriteFixed<T...>
		local fmtSize = format.size :: int

		if check then
			return @native function(
				...: T...
			)
				check(...)
				local bytes = buffer.create(fmtSize)
				fmtWrite(bytes, 0, ...)
				return bytes
			end
		else
			return @native function(
				...: T...
			)
				local bytes = buffer.create(fmtSize)
				fmtWrite(bytes, 0, ...)
				return bytes
			end
		end

	else

		local fmtWrite = format.write :: WriteDynamic<T...>
		-- local fmtSize = format.size :: SizeDynamic<T...>

		if check then
			return @native function(
				...: T...
			)
				check(...)
				local offset = fmtWrite(BUF, 0, ...)
				local bytes = buffer.create(offset)
				buffer.copy(bytes, 0, BUF, 0, offset)
				return bytes
			end
		else
			return @native function(
				...: T...
			)
				-- local bytes = buffer.create(fmtSize(...))
				-- fmtWrite(bytes, 0, ...)
				-- return bytes
				local offset = fmtWrite(BUF, 0, ...)
				local bytes = buffer.create(offset)
				buffer.copy(bytes, 0, BUF, 0, offset)
				return bytes
			end
		end

	end
end

local function decoder<T...>(
	format: Format<T...>
)
	local fmtRead = format.read :: ReadDynamic<T...>

	return @native function(
		bytes: buffer
	)
		return select(2, fmtRead(bytes, 0))
	end
end

@native
local function schema<T...>(
	format: Format<T...>,
	check: Check<T...>?
): Schema<T...>

	return table.freeze {
		name = format.name,
		fixed = format.fixed,
		size = format.size,
		write = format.write,
		read = format.read,
		encode = encoder(format, check),
		decode = decoder(format)
	} :: Schema<T...>
end

@native
local function sizeof<T...>(
	format: Format<T...>,
	...: T...
)
	if format.fixed then
		return format.size
	else
		return format.size(...)
	end
end

-- SIMPLE TYPES

local function writeNOP(
	bytes: buffer,
	offset: int,
	value: nil
)
	return offset
end

function t.value<T>(
	value: T
)
	local name = `value<{value}>`

	local cached = get(name)
	if cached then
		return cached :: TypeFixed<T>
	end

	return declare(true, name, {

		name = name,

		fixed = true,
		size = 0, -- implies literal

		write = writeNOP,

		read = @native function(
			bytes: buffer,
			offset: int
		)
			return value
		end

	} :: TypeFixed<T>)
end

-- common
t.NIL = t.value(nil) :: TypeFixed<nil>
t.FALSE = t.value(false) :: TypeFixed<false>
t.TRUE = t.value(true) :: TypeFixed<true>
t.ZERO = t.value(0) :: TypeFixed<int>
t.ONE = t.value(1) :: TypeFixed<int>
t.EMPTY = t.value({}) :: TypeFixed<{}>

t.boolean = table.freeze {

	name = 'boolean',

	fixed = true,
	size = 1,

	write = function(
		bytes: buffer,
		offset: int,
		value: boolean
	)
		writeu8(bytes, offset, value and 255 or 0)
	end,

	read = function(
		bytes: buffer,
		offset: int
	)
		return readu8(bytes, offset) == 255
	end

} :: TypeFixed<boolean>

t.u8 = table.freeze {
	name = 'u8',
	fixed = true,
	size = 1,
	write = writeu8,
	read = readu8
} :: TypeFixed<int>

t.i8 = table.freeze {
	name = 'i8',
	fixed = true,
	size = 1,
	write = buffer.writei8,
	read = buffer.readi8
} :: TypeFixed<int>

t.u16 = table.freeze {
	name = 'u16',
	fixed = true,
	size = 2,
	write = buffer.writeu16,
	read = buffer.readu16
} :: TypeFixed<int>

t.i16 = table.freeze {
	name = 'i16',
	fixed = true,
	size = 2,
	write = buffer.writei16,
	read = buffer.readi16
} :: TypeFixed<int>

t.u32 = table.freeze {
	name = 'u32',
	fixed = true,
	size = 4,
	write = buffer.writeu32,
	read = buffer.readu32
} :: TypeFixed<int>

t.i32 = table.freeze {
	name = 'i32',
	fixed = true,
	size = 4,
	write = buffer.writei32,
	read = buffer.readi32
} :: TypeFixed<int>

t.f32 = table.freeze {
	name = 'f32',
	fixed = true,
	size = 4,
	write = buffer.writef32,
	read = buffer.readf32
} :: TypeFixed<float>

t.f64 = table.freeze {
	name = 'f64',
	fixed = true,
	size = 8,
	write = buffer.writef64,
	read = buffer.readf64
} :: TypeFixed<float>

@native
local function writeu24(
	bytes: buffer,
	offset: int,
	value: int
)
	writeu16(bytes, offset, value % 2^16)
	writeu8(bytes, offset + 2, value // 2^16)
end

@native
local function readu24(
	bytes: buffer,
	offset: int
)
	return readu16(bytes, offset) + readu8(bytes, offset + 2) * 2^16
end

t.u24 = table.freeze {
	name = 'u24',
	fixed = true,
	size = 3,
	write = writeu24,
	read = readu24
} :: TypeFixed<int>

t.i24 = table.freeze {

	name = 'i24',

	fixed = true,
	size = 3,

	write = @native function(
		bytes: buffer,
		offset: int,
		value: int
	)
		writeu24(bytes, offset, if value < 0 then value + 2^24 else value)
	end,

	read = @native function(
		bytes: buffer,
		offset: int
	)
		local n = readu24(bytes, offset)
		return if n >= 2^23 then n - 2^24 else n
	end

} :: TypeFixed<int>

t.vec3t = table.freeze {

	name = 'vec3t',

	fixed = true,
	size = 1,

	write = @native function(
		bytes: buffer,
		offset: int,
		value: vector
	)
		writeu8(bytes, offset,
			(value.x + 1) + (value.y + 1) * 3 + (value.z + 1) * 9)
	end,

	read = @native function(
		bytes: buffer,
		offset: int
	)
		local num = readu8(bytes, offset)
		return vector.create(
			num % 3 - 1, (num // 3) % 3 - 1, (num // 9) % 3 - 1)
	end

} :: TypeFixed<vector>

t.string = table.freeze {

	name = 'string',

	fixed = false,

	size = @native function(
		value: string
	)
		local length = #value
		return vlqPrefix(length) + length, length
	end,

	write = @native function(
		bytes: buffer,
		offset: int,
		value: string
	)
		local length = #value
		offset = writeLength(bytes, offset, length)
		buffer.writestring(bytes, offset, value, length)
		return offset + length
	end,

	read = @native function(
		bytes: buffer,
		offset: int
	)
		local length: int
		offset, length = readLength(bytes, offset)
		return offset + length, buffer.readstring(bytes, offset, length)
	end

} :: TypeDynamic<string>

local function str(
	prefix: TypeFixed<int>
)
	--[[
		No need to cache here, this is a private function and the possible
			cases are defined below this function.
	]]
	local fixedSize = prefix.size
	local prefixWrite = prefix.write
	local prefixRead = prefix.read

	return table.freeze {

		name = `str{fixedSize * 8}`,

		fixed = false,

		size = @native function(
			value: string
		)
			return fixedSize + #value, #value
		end,

		write = @native function(
			bytes: buffer,
			offset: int,
			value: string
		)
			prefixWrite(bytes, offset, #value)
			buffer.writestring(bytes, offset + fixedSize, value, #value)
			return offset + fixedSize + #value
		end,

		read = @native function(
			bytes: buffer,
			offset: int
		)
			local length = prefixRead(bytes, offset)
			return offset + fixedSize + length, buffer.readstring(bytes, offset + fixedSize, length)
		end

	} :: TypeDynamic<string>
end

-- possible
t.str8 = str(t.u8)
t.str16 = str(t.u16)
t.str24 = str(t.u24)
t.str30 = str(t.u32)

t.buffer = table.freeze {

	name = 'buffer',

	fixed = false,

	size = @native function(
		value: buffer
	)
		local len = buffer.len(value)
		return vlqPrefix(len) + len, len
	end,

	write = @native function(
		bytes: buffer,
		offset: int,
		value: buffer
	)
		local length = buffer.len(value)
		offset = writeLength(bytes, offset, length)
		buffer.copy(bytes, offset, value, 0, length)
		return offset + length
	end,

	read = @native function(
		bytes: buffer,
		offset: int
	)
		local length: int
		offset, length = readLength(bytes, offset)
		local sub = buffer.create(length)
		buffer.copy(sub, 0, bytes, offset, length)
		return offset + length, sub
	end

} :: TypeDynamic<buffer>

local function buf(
	prefix: TypeFixed<int>
)
	--[[
		No need to cache here, this is a private function and the possible
			cases are defined below this function.
	]]
	local fixedSize = prefix.size
	local prefixWrite = prefix.write
	local prefixRead = prefix.read

	return table.freeze {

		name = `buf{fixedSize * 8}`,

		fixed = false,

		size = @native function(
			value: buffer
		)
			return fixedSize + buffer.len(value)
		end,

		write = @native function(
			bytes: buffer,
			offset: int,
			value: buffer
		)
			local length = buffer.len(value)
			prefixWrite(bytes, offset, length)
			offset += fixedSize
			buffer.copy(bytes, offset, value, 0, length)
			return offset + length
		end,

		read = @native function(
			bytes: buffer,
			offset: int
		)
			local length = (prefixRead(bytes, offset))
			offset += fixedSize
			local sub = buffer.create(length)
			buffer.copy(sub, 0, bytes, offset, length)
			return offset + length, sub
		end

	} :: TypeDynamic<buffer>
end

-- possible
t.buf8 = buf(t.u8)
t.buf16 = buf(t.u16)
t.buf24 = buf(t.u24)
t.buf30 = buf(t.u32)

-- COMPOSITE TYPES

local function vec2(
	numFormat: TypeFixed<number>
)
	local fixedSize = numFormat.size
	local write = numFormat.write
	local read = numFormat.read
	local name = `vec2<{numFormat.name}>`

	return table.freeze {

		name = name,

		fixed = true,
		size = 2 * fixedSize,

		write = @native function(
			bytes: buffer,
			offset: int,
			value: vector
		)
			write(bytes, offset, value.x)
			write(bytes, offset + fixedSize, value.y)
		end,

		read = @native function(
			bytes: buffer,
			offset: int
		)
			return vector.create(
				(read(bytes, offset)),
				(read(bytes, offset + fixedSize)),
				(0)
			)
		end

	} :: TypeFixed<vector>
end

-- possible
t.vec2u8 = vec2(t.u8)
t.vec2i8 = vec2(t.i8)
t.vec2u16 = vec2(t.u16)
t.vec2i16 = vec2(t.i16)
t.vec2u32 = vec2(t.u32)
t.vec2i32 = vec2(t.i32)
t.vec2 = vec2(t.f32)

local function vec3(
	numFormat: TypeFixed<number>
)
	local fixedSize = numFormat.size
	local write = numFormat.write
	local read = numFormat.read
	local name = `vec3<{numFormat.name}>`

	return table.freeze {

		name = name,

		fixed = true,
		size = 3 * fixedSize,

		write = @native function(
			bytes: buffer,
			offset: int,
			value: vector
		)
			write(bytes, offset, value.x)
			write(bytes, offset + fixedSize, value.y)
			write(bytes, offset + fixedSize * 2, value.z)
		end,

		read = @native function(
			bytes: buffer,
			offset: int
		)
			return vector.create(
				(read(bytes, offset)),
				(read(bytes, offset + fixedSize)),
				(read(bytes, offset + fixedSize * 2))
			)
		end

	} :: TypeFixed<vector>
end

-- possible
t.vec3u8 = vec3(t.u8)
t.vec3i8 = vec3(t.i8)
t.vec3u16 = vec3(t.u16)
t.vec3i16 = vec3(t.i16)
t.vec3u32 = vec3(t.u32)
t.vec3i32 = vec3(t.i32)
t.vec3 = vec3(t.f32)

function t.optional<T>(
	format: Format<T>
)
	local name = `optional<{format.name}>`

	local cached = get(name)
	if cached then
		return cached :: Format<T?>
	end

	if format.fixed then

		local fmtSize = format.size :: int
		local fmtWrite = format.write :: WriteFixed<T>
		local fmtRead = format.read :: ReadFixed<T>

		return declare(true, name, {

			name = name,

			fixed = false,

			size = @native function(
				value: T?
			)
				return 1 + (if value == nil then 0 else fmtSize)
			end,

			write = @native function(
				bytes: buffer,
				offset: int,
				value: T?
			)
				local exists = value ~= nil
				writeu8(bytes, offset, exists and 255 or 0)
				offset += 1
				if exists then
					fmtWrite(bytes, offset, value)
					offset += fmtSize
				end
				return offset
			end,

			read = @native function(
				bytes: buffer,
				offset: int
			)
				local exists = readu8(bytes, offset) == 255
				offset += 1
				if not exists then
					return offset, nil
				end
				return offset + fmtSize, fmtRead(bytes, offset)
			end

		} :: Format<T?>)

	else

		local fmtSize = format.size :: SizeDynamic<T>
		local fmtWrite = format.write :: WriteDynamic<T>
		local fmtRead = format.read :: ReadDynamic<T>

		return declare(true, name, {

			name = name,

			fixed = false,

			size = @native function(
				value: T?
			)
				return 1 + (if value == nil then 0 else fmtSize(value))
			end,

			write = @native function(
				bytes: buffer,
				offset: int,
				value: T?
			)
				local exists = value ~= nil
				writeu8(bytes, offset, exists and 255 or 0)
				offset += 1
				if exists then
					offset = fmtWrite(bytes, offset, value)
				end
				return offset
			end,

			read = @native function(
				bytes: buffer,
				offset: int
			)
				local exists = readu8(bytes, offset) == 255
				offset += 1
				if not exists then
					return offset, nil
				end
				return fmtRead(bytes, offset)
			end

		} :: Format<T?>)

	end
end

function t.array<V>(
	format: Format<V>,
	length: int?
): Format<array<V>>

	local fmtSize = format.size
	local fmtWrite = format.write
	local fmtRead = format.read
	local isFixed = format.fixed

	local name = `array<{format.name}>`

	local cached = get(name)
	if cached then
		return cached :: Format<array<V>>
	end

	if length then
		if isFixed then
			return declare(true, name, {

				name = name,

				fixed = true,
				size = (fmtSize :: int) * length,

				write = @native function(
					bytes: buffer,
					offset: int,
					value: array<V>
				)
					for i = 1, length do
						(fmtWrite :: WriteFixed<V>)(bytes, offset, value[i])
						offset += fmtSize :: int
					end
					return offset
				end,

				read = @native function(
					bytes: buffer,
					offset: int
				)
					local result = table.create(length) :: array<V>
					for i = 1, length do
						result[i] = (fmtRead :: ReadFixed<V>)(bytes, offset)
						offset += fmtSize :: int
					end
					return offset, result
				end

			} :: TypeFixed<array<V>>)
		else
			return declare(true, name, {

				name = name,

				fixed = false,
				size = @native function(
					value: array<V>
				)
					local size, length = 0, #value
					for i = 1, length do
						size += (fmtSize :: SizeDynamic<V>)(value[i])
					end
					return vlqPrefix(length) + size, length
				end,

				write = @native function(
					bytes: buffer,
					offset: int,
					value: array<V>
				)
					for i = 1, length do
						offset = (fmtWrite :: WriteDynamic<V>)(bytes, offset, value[i])
					end
					return offset
				end,

				read = @native function(
					bytes: buffer,
					offset: int
				)
					local result = table.create(length) :: array<V>
					for i = 1, length do
						offset, result[i] = (fmtRead :: ReadDynamic<V>)(bytes, offset)
					end
					return offset, result
				end

			} :: TypeDynamic<array<V>>)
		end
	else
		if isFixed then
			return declare(true, name, {

				name = name,

				fixed = false,

				size = @native function(
					value: array<V>
				)
					local length = #value
					return vlqPrefix(length) + (fmtSize :: int) * length, length
				end,

				write = @native function(
					bytes: buffer,
					offset: int,
					value: array<V>
				)
					local length = #value
					offset = writeLength(bytes, offset, length)
					for i = 1, length do
						(fmtWrite :: WriteFixed<V>)(bytes, offset, value[i])
						offset += fmtSize :: int
					end
					return offset
				end,

				read = @native function(
					bytes: buffer,
					offset: int
				)
					local length: int
					offset, length = readLength(bytes, offset)
					local result = table.create(length) :: array<V>
					for i = 1, length do
						result[i] = (fmtRead :: ReadFixed<V>)(bytes, offset)
						offset += fmtSize :: int
					end
					return offset, result
				end

			} :: TypeDynamic<array<V>>)
		else
			return declare(true, name, {

				name = name,

				fixed = false,

				size = @native function(
					value: array<V>
				)
					local size, length = 0, #value
					for i = 1, length do
						size += (fmtSize :: SizeDynamic<V>)(value[i])
					end
					return vlqPrefix(length) + size, length
				end,

				write = @native function(
					bytes: buffer,
					offset: int,
					value: array<V>
				)
					local length = #value
					offset = writeLength(bytes, offset, length)
					for i = 1, length do
						offset = (fmtWrite :: WriteDynamic<V>)(bytes, offset, value[i])
					end
					return offset
				end,

				read = @native function(
					bytes: buffer,
					offset: int
				)
					local result = {} :: array<V>
					local length: int
					offset, length = readLength(bytes, offset)
					for i = 1, length do
						offset, result[i] = (fmtRead :: ReadDynamic<V>)(bytes, offset)
					end
					return offset, result
				end

			} :: TypeDynamic<array<V>>)
		end
	end
end

function t.struct<T, S>(
	layout: T
): S

	local fixedSize = 0
	local keysFixed = {} :: array<string>
	local keysDynamic = {} :: array<string>

	type Layout = any

	for key, format in layout :: map<string, Format<any>> do
		if type(key) ~= 'string' then
			error(`struct key must be a string`, 0)
		end

		if format.fixed then
			fixedSize += (format.size :: int)
			table.insert(keysFixed, key)
		else
			table.insert(keysDynamic, key)
		end
	end

	table.sort(keysFixed)
	table.sort(keysDynamic)

	local fixedCount = #keysFixed
	local dynamicCount = #keysDynamic
	local keyCount = fixedCount + dynamicCount

	if keyCount == 0 then
		return t.EMPTY
	end

	local keys = table.create(keyCount) :: array<string>
	table.move(keysFixed, 1, fixedCount, #keys + 1, keys)
	table.move(keysDynamic, 1, dynamicCount, #keys + 1, keys)

	local writes = table.create(keyCount) :: array<Write<any>>
	local reads = table.create(keyCount) :: array<Read<any>>
	local sizes = table.create(keyCount) :: array<Size<any>>
	local pairs = table.create(keyCount) :: array<string>

	for i = 1, keyCount do
		local key = keys[i]
		local format = (layout :: any)[key]
		writes[i]	= format.write
		reads[i] = format.read
		sizes[i] = format.size
		table.insert(pairs, `({key}: {format.name})`)
	end

	local name = `struct\{ {table.concat(pairs, ', ')} \}`

	local cached = get(name)
	if cached then
		return cached :: Format<Layout>
	end

	if dynamicCount == 0 then
		return declare(true, name, {

			name = name,

			fixed = true,
			size = fixedSize,

			write = @native function(
				bytes: buffer,
				offset: int,
				value: Layout
			)
				for i = 1, fixedCount do
					(writes[i] :: WriteFixed<any>)(bytes, offset, value[keys[i]])
					offset += sizes[i] :: int
				end
				return offset
			end,

			read = @native function(
				bytes: buffer,
				offset: int
			)
				local result = table.clone(layout) :: Layout
				for i = 1, fixedCount do
					result[keys[i]] = (reads[i] :: ReadFixed<any>)(bytes, offset)
					offset += sizes[i] :: int
				end
				return offset, result
			end

		} :: TypeFixed<Layout>)
	else
		return declare(true, name, {

			name = name,

			fixed = false,

			size = @native function(
				value: Layout
			)
				local size = fixedSize
				for i = fixedCount + 1, keyCount do
					size += ((sizes[i] :: SizeDynamic<any>)(value[keys[i]]))
				end
				return size
			end,

			write = @native function(
				bytes: buffer,
				offset: int,
				value: Layout
			)
				for i = 1, fixedCount do
					(writes[i] :: WriteFixed<any>)(bytes, offset, value[keys[i]])
					offset += sizes[i] :: int
				end
				for i = fixedCount + 1, keyCount do
					offset = (writes[i] :: WriteDynamic<any>)(bytes, offset, value[keys[i]])
				end
				return offset
			end,

			read = @native function(
				bytes: buffer,
				offset: int
			)
				local result = table.clone(layout) :: Layout
				for i = 1, fixedCount do
					result[keys[i]] = (reads[i] :: ReadFixed<any>)(bytes, offset)
					offset += sizes[i] :: int
				end
				for i = fixedCount + 1, keyCount do
					offset, result[keys[i]] = (reads[i] :: ReadDynamic<any>)(bytes, offset)
				end
				return offset, result
			end

		} :: Format<Layout>)
	end
end

function t.partial<V>(
	layout: V
): Format<V>

	local newLayout = {}
	for key, format in layout :: map<string, Format<any>> do
		newLayout[key] = t.optional(format)
	end
	return t.struct(newLayout) :: Format<V>
end

@native
local function mapLength<K, V>(
	value: map<K, V>
)
	local length = 0
	for _ in value do
		length += 1
	end
	return length
end

function t.map<K, V>(
	keyFormat: Format<K>,
	valueFormat: Format<V>
)
	local name = `map<{keyFormat.name}, {valueFormat.name}>`

	local cached = get(name)
	if cached then
		return cached :: Format<map<K, V>>
	end

	if keyFormat.fixed and valueFormat.fixed then

		local kfmtSize = keyFormat.size :: int
		local vfmtSize = valueFormat.size :: int
		local kfmtWrite = keyFormat.write :: WriteFixed<K>
		local vfmtWrite = valueFormat.write :: WriteFixed<V>
		local kfmtRead = keyFormat.read :: ReadFixed<K>
		local vfmtRead = valueFormat.read :: ReadFixed<V>

		local sizeEntry = kfmtSize + vfmtSize

		return declare(true, name, {

			name = name,

			fixed = false,

			size = @native function(
				value: map<K, V>
			)
				local length = mapLength(value)
				return vlqPrefix(length) + length * sizeEntry, length
			end,

			write = @native function(
				bytes: buffer,
				offset: int,
				value: map<K, V>
			)
				local length = mapLength(value)
				offset = writeLength(bytes, offset, length)
				for k, v in value do
					kfmtWrite(bytes, offset, k)
					vfmtWrite(bytes, offset + kfmtSize, v)
					offset += sizeEntry
				end
				return offset
			end,

			read = @native function(
				bytes: buffer,
				offset: int
			)
				local length: int
				offset, length = readLength(bytes, offset)
				local result = {} :: map<K, V>
				for i = 1, length do
					result[kfmtRead(bytes, offset)] = vfmtRead(bytes, offset + kfmtSize)
					offset += sizeEntry
				end
				return offset, result
			end

		} :: TypeDynamic<map<K, V>>)

	elseif keyFormat.fixed and not valueFormat.fixed then

		local kfmtSize = keyFormat.size :: int
		local vfmtSize = valueFormat.size :: SizeDynamic<V>
		local kfmtWrite = keyFormat.write :: WriteFixed<K>
		local vfmtWrite = valueFormat.write :: WriteDynamic<V>
		local kfmtRead = keyFormat.read :: ReadFixed<K>
		local vfmtRead = valueFormat.read :: ReadDynamic<V>

		return declare(true, name, {

			name = name,

			fixed = false,

			size = @native function(
				value: map<K, V>
			)
				local size, length = 0, mapLength(value)
				for _, v in value do
					size += vfmtSize(v)
				end
				return vlqPrefix(length) + length * kfmtSize + size, length
			end,

			write = @native function(
				bytes: buffer,
				offset: int,
				value: map<K, V>
			)
				local length = mapLength(value)
				offset = writeLength(bytes, offset, length)
				for k, v in value do
					kfmtWrite(bytes, offset, k)
					offset = vfmtWrite(bytes, offset + kfmtSize, v)
				end
				return offset
			end,

			read = @native function(
				bytes: buffer,
				offset: int
			)
				local length: int, k: K, v: V
				offset, length = readLength(bytes, offset)
				local result = {} :: map<K, V>
				for i = 1, length do
					k = kfmtRead(bytes, offset)
					offset, v = vfmtRead(bytes, offset + kfmtSize)
					result[k] = v
				end
				return offset, result
			end

		} :: TypeDynamic<map<K, V>>)

	elseif not keyFormat.fixed and valueFormat.fixed then

		local kfmtSize = keyFormat.size :: SizeDynamic<K>
		local vfmtSize = valueFormat.size :: int
		local kfmtWrite = keyFormat.write :: WriteDynamic<K>
		local vfmtWrite = valueFormat.write :: WriteFixed<V>
		local kfmtRead = keyFormat.read :: ReadDynamic<K>
		local vfmtRead = valueFormat.read :: ReadFixed<V>

		return declare(true, name, {

			name = name,

			fixed = false,

			size = @native function(
				value: map<K, V>
			)
				local size, length = 0, mapLength(value)
				for k in value do
					size += kfmtSize(k)
				end
				return vlqPrefix(length) + length * vfmtSize + size, length
			end,

			write = @native function(
				bytes: buffer,
				offset: int,
				value: map<K, V>
			)
				local length = mapLength(value)
				offset = writeLength(bytes, offset, length)
				for k, v in value do
					offset = kfmtWrite(bytes, offset, k)
					vfmtWrite(bytes, offset, v)
					offset += vfmtSize
				end
				return offset
			end,

			read = @native function(
				bytes: buffer,
				offset: int
			)
				local length: int
				offset, length = readLength(bytes, offset)
				local result = {} :: map<K, V>
				local k: K, v: V
				for i = 1, length do
					offset, k = kfmtRead(bytes, offset)
					v = vfmtRead(bytes, offset)
					offset += vfmtSize
					result[k] = v
				end
				return offset, result
			end

		} :: TypeDynamic<map<K, V>>)

	else

		local kfmtSize = keyFormat.size :: SizeDynamic<K>
		local vfmtSize = valueFormat.size :: SizeDynamic<V>
		local kfmtWrite = keyFormat.write :: WriteDynamic<K>
		local vfmtWrite = valueFormat.write :: WriteDynamic<V>
		local kfmtRead = keyFormat.read :: ReadDynamic<K>
		local vfmtRead = valueFormat.read :: ReadDynamic<V>

		return declare(true, name, {

			name = name,

			fixed = false,

			size = @native function(
				value: map<K, V>
			)
				local size, length = 0, mapLength(value)
				for k, v in value do
					size += kfmtSize(k)
					size += vfmtSize(v)
				end
				return vlqPrefix(length) + size, length
			end,

			write = @native function(
				bytes: buffer,
				offset: int,
				value: map<K, V>
			)
				local length = mapLength(value)
				offset = writeLength(bytes, offset, length)
				for k, v in value do
					offset = kfmtWrite(bytes, offset, k)
					offset = vfmtWrite(bytes, offset, v)
				end
				return offset
			end,

			read = @native function(
				bytes: buffer,
				offset: int
			)
				local length: int
				offset, length = readLength(bytes, offset)
				local result = {} :: map<K, V>
				local k: K, v: V
				for i = 1, length do
					offset, k = kfmtRead(bytes, offset)
					offset, v = vfmtRead(bytes, offset)
					result[k] = v
				end
				return offset, result
			end

		} :: TypeDynamic<map<K, V>>)

	end
end

function t.set<K>(
	keyFormat: Format<K>
)
	return t.map(keyFormat, t.TRUE)
end

-- tagged union (explicit)
function t.union(
	types: array<Format<any>>
)
	local names = {}
	local mapping = {}

	for i, format in types do
		table.insert(names, format.name)
		mapping[format.name] = i - 1
	end

	names = table.concat(names, ', ')

	local name = `union<{names}>`

	local cached = get(name)
	if cached then
		return cached :: Format<any>
	end

	return declare(false, name, {

		name = name,

		fixed = false,

		size = @native function(
			value: Tagged<any>
		)
			local format = assert(value.format)
			return 1 + (if format.fixed then format.size :: int else ((format.size :: SizeDynamic<any>)(value.value))), nil
		end,

		write = @native function(
			bytes: buffer,
			offset: int,
			value: Tagged<any>
		)
			local format = assert(value.format)
			writeu8(bytes, offset, mapping[format.name])
			if format.fixed then
				(format.write :: WriteFixed<any>)(bytes, offset + 1, value.value)
				return offset + 1 + (format.size :: int)
			else
				return (format.write :: WriteDynamic<any>)(bytes, offset + 1, value.value)
			end
		end,

		read = @native function(
			bytes: buffer,
			offset: int
		)
			local format = types[readu8(bytes, offset) + 1]
			if format.fixed then
				return offset + 1 + (format.size :: int), (format.read :: ReadFixed<any>)(bytes, offset + 1)
			else
				return (format.read :: ReadDynamic<any>)(bytes, offset + 1)
			end
		end

	} :: Format<any>)
end

-- tagged enum
function t.tagged<T>(
	field: T,
	structs: map<T, Format<any>>
)
	local mapping = {} :: map<T, int>
	local inv = {} :: map<int, T>
	local names = {}
	local values = {} :: array<string>

	for k, v in structs do
		if mapping[k] then
			error(`duplicate enum value '{k}'`, 0)
		end
		mapping[k] = #names
		inv[#names + 1] = k
		table.insert(names, v.name)
		table.insert(values, k)
	end

	names = table.concat(names, ', ')
	values = table.concat(values, ', ')

	local name = `tagged<{names}>`

	local cached = get(name)
	if cached then
		return cached :: Format<any>
	end

	return declare(false, name, {

		name = name,

		size = @native function(
			value: any
		)
			local tag = value[field]
			local format = structs[tag]
			return 1 + (if format.fixed then format.size :: int else (format.size :: SizeDynamic<any>)(value))
		end,

		write = @native function(
			bytes: buffer,
			offset: int,
			value: any
		)
			local tag = value[field]
			local format = structs[tag]
			writeu8(bytes, offset, mapping[tag])
			if format.fixed then
				(format.write :: WriteFixed<any>)(bytes, offset + 1, value)
				return offset + 1 + (format.size :: int)
			else
				return (format.write :: WriteDynamic<any>)(bytes, offset + 1, value)
			end
		end,

		read = @native function(
			bytes: buffer,
			offset: int
		)
			local format = structs[inv[readu8(bytes, offset) + 1]]
			if format.fixed then
				return offset + 1 + (format.size :: int), (format.read :: ReadFixed<any>)(bytes, offset + 1)
			else
				return (format.read :: ReadDynamic<any>)(bytes, offset + 1)
			end
		end

	} :: Format<any>)
end

-- identifier enum
function t.enum<T>(
	options: { T }
)
	local mapping = {} :: map<T, int>
	local names = table.create(#options) :: array<string>

	for i, v in options do
		mapping[v] = i - 1
		names[i] = `{v}`
	end

	local name = `enum<{table.concat(names, ', ')}>`

	local cached = get(name)
	if cached then
		return cached :: TypeFixed<T>
	end

	return declare(false, name, {

		name = name,

		fixed = true,
		size = 1,

		write = @native function(
			bytes: buffer,
			offset: int,
			value: T
		)
			writeu8(bytes, offset, mapping[value])
		end,

		read = @native function(
			bytes: buffer,
			offset: int
		)
			return options[readu8(bytes, offset) + 1]
		end

	} :: TypeFixed<T>)
end

function t.tuple<T...>(
	types: array<Format<any>>
): Format<T...>

	local typeCount = #types
	local fixedSize = 0
	local fixedMapping = table.create(typeCount) :: array<int>
	local dynamicMapping = table.create(typeCount) :: array<int>
	local tempArray = table.create(typeCount) :: array<any>
	local names = table.create(typeCount) :: array<string>

	for i, format in types do
		if format.name:find('tuple') then
			error(`tuple types cannot be nested`, 0)
		end
		if format.fixed then
			fixedSize += (format.size :: int)
			table.insert(fixedMapping, i)
		else
			table.insert(dynamicMapping, i)
		end
		names[i] = format.name
	end

	local name = `tuple({table.concat(names, ', ')})`
	local fixedCount = #fixedMapping
	local dynamicCount = #dynamicMapping

	if dynamicCount == 0 then

		local sizes = table.create(fixedCount) :: array<SizeFixed>
		local writes = table.create(fixedCount) :: array<WriteFixed<any>>
		local reads = table.create(fixedCount) :: array<ReadFixed<any>>

		for i = 1, fixedCount do
			sizes[i] = types[i].size :: SizeFixed
			writes[i] = types[i].write :: WriteFixed<any>
			reads[i] = types[i].read :: ReadFixed<any>
		end

		return declare(false, name, {

			name = name,

			fixed = true,
			size = fixedSize,

			write = @native function(
				bytes: buffer,
				offset: int,
				...: T...
			)
				local data = {...}
				for i = 1, fixedCount do
					writes[i](bytes, offset, data[i])
					offset += sizes[i]
				end
				return offset
			end,

			read = @native function(
				bytes: buffer,
				offset: int
			)
				for i = 1, fixedCount do
					tempArray[i] = reads[i](bytes, offset)
					offset += sizes[i]
				end
				return offset, (table.unpack :: unpack<T...>)(tempArray, 1, fixedCount)
			end

		} :: TypeFixed<T...>)
	else

		local inverse = table.create(typeCount) :: array<int>
		table.move(fixedMapping, 1, fixedCount, #inverse + 1, inverse)
		table.move(dynamicMapping, 1, dynamicCount, #inverse + 1, inverse)

		local sizes = table.create(typeCount) :: array<Size<any>>
		local writes = table.create(typeCount) :: array<Write<any>>
		local reads = table.create(typeCount) :: array<Read<any>>

		for i = 1, typeCount do
			sizes[i] = types[inverse[i]].size
			writes[i] = types[inverse[i]].write
			reads[i] = types[inverse[i]].read
		end

		return declare(false, name, {

			name = name,

			fixed = false,

			size = @native function(
				...: T...
			)
				local data = { ... }
				local size = fixedSize
				for i = fixedCount + 1, typeCount do
					size += (sizes[i] :: SizeDynamic<any>)(data[inverse[i]])
				end
				return size
			end,

			write = @native function(
				bytes: buffer,
				offset: int,
				...: T...
			)
				local data = { ... }
				for i = 1, fixedCount do
					(writes[i] :: WriteFixed<T...>)(bytes, offset, data[inverse[i]])
					offset += (sizes[i] :: int)
				end
				for i = fixedCount + 1, typeCount do
					offset = (writes[i] :: WriteDynamic<any>)(bytes, offset, data[inverse[i]])
				end
				return offset
			end,

			read = @native function(
				bytes: buffer,
				offset: int
			)
				for i = 1, fixedCount do
					tempArray[inverse[i]] = (reads[i] :: ReadFixed<T...>)(bytes, offset)
					offset += (sizes[i] :: int)
				end
				for i = fixedCount + 1, typeCount do
					offset, tempArray[inverse[i]] = (reads[i] :: ReadDynamic<any>)(bytes, offset)
				end
				return offset, (table.unpack :: unpack<T...>)(tempArray, 1, typeCount)
			end

		} :: TypeDynamic<T...>)
	end
end

return table.freeze {

	-- LIBRARY
	['version'] = 1, -- u32
	['cache'] = cache,
	['encoder'] = encoder,
	['decoder'] = decoder,
	['schema'] = schema,
	['sizeof'] = sizeof,
	['tag'] = tag,

	-- FORMATS
	t = table.freeze(t)

}

--[[

	MIT License

	Copyright (c) 2025 jonbyte

	Permission is hereby granted, free of charge, to any person obtaining a copy
	of this software and associated documentation files (the "Software"), to deal
	in the Software without restriction, including without limitation the rights
	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
	copies of the Software, and to permit persons to whom the Software is
	furnished to do so, subject to the following conditions:

	The above copyright notice and this permission notice shall be included in all
	copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
	SOFTWARE.

]]
