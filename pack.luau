--!strict

debug.setmemorycategory('LIBPACK')

type int = number
type float = number
type map<K, V> = { [K]: V }
type array<V> = map<int, V>
type set<K> = map<K, true>

type Write<T> = (bytes: buffer, offset: int, value: T, count: int?) -> (int?)
type Read<T> = (bytes: buffer, offset: int, count: int?) -> (T, int?)
type Size<T> = (value: T) -> (int, int?)
type Assert<T> = (value: T) -> ()

export type Tagged<T> = {
	read format: Format<T>,
	read value: T
}

export type TypeFixed<T> = {
	read name: string,
	read size: int,
	read prefix: nil,
	read assert: Assert<T>,
	read write: Write<T>,
	read read: Read<T>
}

export type TypeSized<T> = {
	read name: string,
	read prefix: true?,
	read assert: Assert<T>,
	read size: Size<T>,
	read write: Write<T>,
	read read: Read<T>
}

export type Format<T> = TypeFixed<T> | TypeSized<T>

export type Schema<T> = Format<T> & {
	read encode: (value: T) -> buffer,
	read decode: (bytes: buffer) -> T
}

-- LIBRARY

local writeu8 = buffer.writeu8
local readu8 = buffer.readu8


local t = {}
local BUF = buffer.create(1 * 2^20) -- 1 MiB

@native
local function alloc(
	bytes: int
)
	BUF = buffer.create(bytes)
end

@native
local function tag<T>(
	format: Format<T>,
	value: T
)
	return table.freeze { format = format, value = value }
end

@native
local function encode<T>(
	format: Format<T>
)
	local fmtSize = format.size
	local fmtWrite = format.write

	return
		if type(fmtSize) == 'number' then
			@native function(
				value: T
			)
				local bytes = buffer.create(fmtSize)
				fmtWrite(bytes, 0, value)
				return bytes
			end
		else
			@native function(
				value: T
			): buffer
				local offset = fmtWrite(BUF, 0, value)
				-- offset should exist for composite types
				-- for stuff like string, buffer it would be nil
				offset = offset or fmtSize(value)
				local bytes = buffer.create(offset)
				buffer.copy(bytes, 0, BUF, 0, offset)
				return bytes
			end
end

@native
local function decode<T>(
	format: Format<T>
)
	local fmtRead = format.read

	return @native function(
		bytes: buffer
	): T
		return (fmtRead(bytes, 0))
	end
end

@native
local function schema<T>(
	format: Format<T>
): Schema<T>

	return table.freeze {
		name = format.name,
		size = format.size,
		assert = format.assert,
		write = format.write,
		read = format.read,
		prefix = (format :: TypeSized<T>).prefix,
		encode = encode(format),
		decode = decode(format)
	} :: Schema<T>
end

@native
local function getPrefixSize(
	length: int
)
	return ((length < 2^6 and 0)
		or (length < 2^14 and 1)
		or (length < 2^22 and 2) or 3) + 1
end

@native
local function writeLength(
	bytes: buffer,
	offset: number,
	length: number
)
	local extra = getPrefixSize(length) - 1
	writeu8(bytes, offset, length * 4 + extra)
	offset += 1

	if extra == 0 then
		return offset
	end
	length //= 2^6

	for i = 1, extra do
		writeu8(bytes, offset, length // 2^(8*i))
		offset += 1
	end

	return offset
end

@native
local function readLength(
	bytes: buffer,
	offset: number
)
	local byte1 = readu8(bytes, offset)
	offset += 1

	local count = byte1 % 4
	local result = byte1 // 4

	if count == 0 then
		return result, offset
	end

	for i = 1, count do
		result += readu8(bytes, offset) * (2^(6 + (i - 1) * 8))
		offset += 1
	end

	return result, offset
end

@native
local function sizeof<V>(
	value: any,
	size: int | Size<V>,
	prefix: true?
): (int, int?)
	if type(size) == 'number' then
		return size, nil
	end

	local acc = 0
	local b, count = size(value)
	if prefix then
		count = count or b
		acc += getPrefixSize(count)
	end
	return acc + b, count
end

@native
local function writeItem<V>(
	bytes: buffer,
	offset: int,
	value: V,
	write: Write<V>,
	size: int | Size<V>,
	prefix: boolean?
)
	if size == 0 then
		return offset
	end

	if type(size) == 'number' then
		write(bytes, offset, value)
		return offset + size
	end

	local b, count = size(value)
	if prefix then
		count = count or b
		offset = writeLength(bytes, offset, count)
	end
	write(bytes, offset, value, count)
	return offset + b
end

@native
local function readItem<V>(
	bytes: buffer,
	offset: int,
	read: Read<V>,
	size: int | Size<V>,
	prefix: boolean?
): (V, int?)

	if type(size) == 'number' then
		return read(bytes, offset), offset + size
	end

	local value: V
	local count: int?

	if prefix then
		count, offset = readLength(bytes, offset)
	end

	local lastOffset = offset
	value, offset = read(bytes, offset, count)
	offset = offset or (lastOffset + size(value))

	return value, offset
end

local function assertPrimitive(
	typeName: string,
	symName: string?
)
	return function(
		value: any
	)
		if type(value) ~= typeName then
			error(`expected type '{typeName}' {symName and `({symName})` or ''}, got '{type(value)}'`, 0)
		end
	end
end

-- SIMPLE TYPES

t.literal = function<T>(
	value: T
)
	local name = `literal<{value}>`
	return table.freeze {

		name = name,
		size = 0,

		assert = function(
			v: any
		)
			if v ~= (value :: any) then
				error(`expected {name}, got {v}`, 0)
			end
		end,

		write = @native function(
			bytes: buffer,
			offset: int,
			value: T
		)
			return offset
		end,

		read = @native function(
			bytes: buffer,
			offset: int
		)
			return value, offset
		end

	} :: TypeFixed<T>
end

t.NIL = t.literal(nil) :: TypeFixed<nil>
t.FALSE = t.literal(false) :: TypeFixed<false>
t.TRUE = t.literal(true) :: TypeFixed<true>
t.ZERO = t.literal(0)
t.ONE = t.literal(1)

t.boolean = table.freeze {

	size = 1,

	name = 'boolean',

	assert = function(
		value: boolean
	)
		if type(value) ~= 'boolean' then
			error('not a boolean', 0)
		end
	end,

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

local function assertInt(
	byteSize: int,
	signed: boolean
)
	local name = `{signed and 'i' or 'u'}{byteSize * 8}`
	return function(
		value: int
	)
		assertPrimitive('number', name)(value)
		if value // 1 ~= value then
			error(`expected integer ({name}), got float`, 0)
		end
		if signed then
			if value < -2 ^ (byteSize * 8 - 1) or value >= 2 ^ (byteSize * 8 - 1) then
				error(`integer out of range ({name})`, 0)
			end
		else
			if value < 0 or value >= 2 ^ (byteSize * 8) then
				error(`integer out of range ({name})`, 0)
			end
		end
	end
end

t.u8 = table.freeze {
	name = 'u8',
	size = 1,
	assert = assertInt(1, false),
	write = writeu8,
	read = readu8
} :: TypeFixed<int>

t.i8 = table.freeze {
	name = 'i8',
	size = 1,
	assert = assertInt(1, true),
	write = buffer.writei8,
	read = buffer.readi8
} :: TypeFixed<int>

t.u16 = table.freeze {
	name = 'u16',
	size = 2,
	assert = assertInt(2, false),
	write = buffer.writeu16,
	read = buffer.readu16
} :: TypeFixed<int>

t.i16 = table.freeze {
	name = 'i16',
	size = 2,
	assert = assertInt(2, true),
	write = buffer.writei16,
	read = buffer.readi16
} :: TypeFixed<int>

t.u32 = table.freeze {
	name = 'u32',
	size = 4,
	assert = assertInt(4, false),
	write = buffer.writeu32,
	read = buffer.readu32
} :: TypeFixed<int>

t.i32 = table.freeze {
	name = 'i32',
	size = 4,
	assert = assertInt(4, true),
	write = buffer.writei32,
	read = buffer.readi32
} :: TypeFixed<int>

t.f32 = table.freeze {
	name = 'f32',
	size = 4,
	assert = function(
		value: float
	)
		assertPrimitive('number', 'f32')(value)
		if vector.create(value, 0, 0).x ~= value then
			error('not a float', 0)
		end
	end,
	write = buffer.writef32,
	read = buffer.readf32
} :: TypeFixed<float>

t.f64 = table.freeze {
	name = 'f64',
	size = 8,
	assert = assertPrimitive('number', 'f64'),
	write = buffer.writef64,
	read = buffer.readf64
} :: TypeFixed<float>

t.u24 = table.freeze {

	name = 'u24',

	size = 3,

	assert = assertInt(3, false),

	write = @native function(
		bytes: buffer,
		offset: int,
		value: int
	)
		writeu8(bytes, offset, value % 256)
		writeu8(bytes, offset + 1, (value // 256) % 256)
		writeu8(bytes, offset + 2, (value // 65536) % 256)
	end,

	read = @native function(
		bytes: buffer,
		offset: int
	)
		return
			readu8(bytes, offset) +
			readu8(bytes, offset + 1) * 256 +
			readu8(bytes, offset + 2) * 65536
	end

} :: TypeFixed<int>

t.i24 = table.freeze {

	name = 'i24',

	size = 3,

	assert = assertInt(3, true),

	write = @native function(
		bytes: buffer,
		offset: int,
		value: int
	)
		if value < 0 then
			value = 2 ^ 24 + value
		end
		buffer.writei8(bytes, offset, value % 256)
		buffer.writei8(bytes, offset + 1, (value // 256) % 256)
		buffer.writei8(bytes, offset + 2, (value // 65536) % 256)
	end,

	read = @native function(
		bytes: buffer,
		offset: int
	)
		local value = buffer.readi8(bytes, offset) +
			buffer.readi8(bytes, offset + 1) * 256 +
			buffer.readi8(bytes, offset + 2) * 65536
		if value >= 2 ^ 23 then
			value -= 2 ^ 24
		end
		return value
	end

} :: TypeFixed<int>

t.veci1 = table.freeze {

	name = 'veci1',
	size = 1,

	assert = function(
		value: vector
	)
		if type(value) ~= 'vector' then
			error('not a vector', 0)
		end
		for _, v in { value.x, value.y, value.z } do
			if v // 1 ~= v or math.abs(v) > 1 then
				error('Vector axis out of range', 0)
			end
		end
	end,

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
	prefix = true,
	size = string.len,
	assert = assertPrimitive('string'),
	write = buffer.writestring,
	read = buffer.readstring
} :: TypeSized<string>

local function str(
	prefix: Format<int>
)
	local byteSize = prefix.size :: int
	local bits = byteSize * 8
	local name = `str{bits}`

	return table.freeze {

		name = name,

		assert = function(
			value: string
		)
			assertPrimitive('string', name)(value)
			if #value >= 2^bits then
				error('string too long', 0)
			end
		end,

		size = @native function(
			value: string
		)
			return byteSize + #value
		end,

		write = @native function(
			bytes: buffer,
			offset: int,
			value: string
		)
			prefix.write(bytes, offset, #value)
			buffer.writestring(bytes, offset + byteSize, value, #value)
		end,

		read = @native function(
			bytes: buffer,
			offset: int
		)
			return buffer.readstring(bytes, offset + byteSize, (prefix.read(bytes, offset)))
		end

	} :: TypeSized<string>
end

t.str8 = str(t.u8)
t.str16 = str(t.u16)
t.str24 = str(t.u24)
t.str30 = str(t.u32)

t.buffer = table.freeze {
	name = 'buffer',
	prefix = true,
	assert = assertPrimitive('buffer'),
	size = buffer.len,

	write = @native function(
		bytes: buffer,
		offset: int,
		value: buffer,
		count: int
	)
		buffer.copy(bytes, offset, value, 0, count)
	end,

	read = @native function(
		bytes: buffer,
		offset: int,
		count: int
	)
		local sub = buffer.create(count)
		buffer.copy(sub, 0, bytes, offset, count)
		return sub
	end

} :: TypeSized<buffer>

-- COMPOSITE TYPES

local function vec2(
	numFormat: TypeFixed<number>
)
	local byteSize = numFormat.size :: number
	local write = numFormat.write
	local read = numFormat.read
	local name = `vec2<{numFormat.name}>`

	return table.freeze {

		name = name,
		size = 2 * byteSize,

		assert = function(
			value: vector
		)
			assertPrimitive('vector', name)(value)
			assert(value.x)
			assert(value.y)
		end,

		write = @native function(
			bytes: buffer,
			offset: int,
			value: vector
		)
			write(bytes, offset, value.x)
			write(bytes, offset + byteSize, value.y)
		end,

		read = @native function(
			bytes: buffer,
			offset: int
		)
			return vector.create(
				(read(bytes, offset)),
				(read(bytes, offset + byteSize)),
				(0)
			)
		end

	} :: TypeFixed<vector>
end

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
	local byteSize = numFormat.size :: number
	local write = numFormat.write
	local read = numFormat.read
	local assert = numFormat.assert
	local name = `vec3<{numFormat.name}>`

	return table.freeze {

		name = name,
		size = 3 * byteSize,

		assert = function(
			value: vector
		)
			assertPrimitive('vector', name)(value)
			assert(value.x)
			assert(value.y)
			assert(value.z)
		end,

		write = @native function(
			bytes: buffer,
			offset: int,
			value: vector
		)
			write(bytes, offset, value.x)
			write(bytes, offset + byteSize, value.y)
			write(bytes, offset + byteSize * 2, value.z)
		end,

		read = @native function(
			bytes: buffer,
			offset: int
		)
			return vector.create(
				(read(bytes, offset)),
				(read(bytes, offset + byteSize)),
				(read(bytes, offset + byteSize * 2))
			)
		end

	} :: TypeFixed<vector>
end

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
	local fmtSize = format.size
	local fmtWrite = format.write
	local fmtRead = format.read
	local fmtPrefix = format.prefix

	return table.freeze {

		name = `optional<{format.name}>`,

		assert = function(
			value: T?
		)
			if value ~= nil then
				format.assert(value)
			end
		end,

		size =
			if type(fmtSize) == 'number' then
				1 + fmtSize
			else
				@native function(
					value: T?
				): (int, int?)
					if value == nil then
						return 1, nil
					else
						local size, count = sizeof(value, fmtSize, fmtPrefix)
						return 1 + size, count
					end
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
				offset = writeItem(bytes, offset, value, fmtWrite, fmtSize, fmtPrefix)
			end
			return offset
		end,

		read = @native function(
			bytes: buffer,
			offset: int
		): (T?, int?)
			if readu8(bytes, offset) == 0 then
				return nil, offset + 1
			end
			return readItem(bytes, offset + 1, fmtRead, fmtSize, fmtPrefix)
		end

	} :: Format<T?>
end

t.array = function<V>(
	format: Format<V>,
	length: int?
)
	local fmtSize = format.size
	local fmtWrite = format.write
	local fmtRead = format.read
	local fmtPrefix = format.prefix

	return table.freeze {

		name = `array<{format.name}>`,

		prefix = not length or nil,

		assert = function(
			value: array<V>
		)
			for i = 1, (length or #value) do
				if (value :: any)[i] == nil then
					error(`missing key '{i}'`, 0)
				end
				local pass, err = pcall(format.assert, value[i])
				if not pass then
					error(`[ {i}: {err} ]`, 0)
				end
			end
		end,

		size =
			if length and type(format.size) == 'number' then
				format.size * length
			else
				@native function(
					value: array<V>
				)
					local size = 0
					for i = 1, (length or #value) do
						size += sizeof(value[i], fmtSize, fmtPrefix)
					end
					return size
				end,

		write = @native function(
			bytes: buffer,
			offset: int,
			value: array<V>
		)
			for i = 1, (length or #value) do
				offset = writeItem(bytes, offset, value[i], fmtWrite, fmtSize, fmtPrefix)
			end
			return offset
		end,

		read = @native function(
			bytes: buffer,
			offset: int,
			count: int?
		)
			local len = length or count :: int
			local result = table.create(len) :: array<V>
			for i = 1, len do
				result[i], offset = readItem(bytes, offset, fmtRead, fmtSize, fmtPrefix)
			end
			return result, offset
		end

	} :: Format<array<V>>
end

t.struct = function<V>(
	layout: V
)
	local fixedSize = 0
	local keysFixed = {} :: array<string>
	local keysDynamic = {} :: array<string>
	local pairs = {} :: array<string>

	type Layout = any

	for key, format in layout :: map<string, Format<any>> do
		if type(key) ~= 'string' then
			error(`struct key must be a string`, 0)
		end
		key = key :: string

		if type(format.size) == 'number' then
			fixedSize += format.size
			table.insert(keysFixed, key)
		else
			table.insert(keysDynamic, key)
		end

		table.insert(pairs, `({key}: {format.name})`)
	end

	table.sort(keysFixed)
	table.sort(keysDynamic)

	local staticCount = #keysFixed
	local dynamicCount = #keysDynamic
	local keys = table.create(staticCount + dynamicCount) :: array<string>
	table.move(keysFixed, 1, staticCount, #keys + 1, keys)
	table.move(keysDynamic, 1, dynamicCount, #keys + 1, keys)
	local keyCount = #keys

	local sizes = table.create(0) :: array<int>
	local writes = table.create(0) :: array<Write<any>>
	local reads = table.create(0) :: array<Read<any>>
	local prefixed = {} :: set<int>

	for i = 1, keyCount do
		local key = keys[i]
		local format = (layout :: any)[key]
		if format.prefix then
			prefixed[i] = true
		end
		table.insert(sizes, format.size)
		table.insert(writes, format.write)
		table.insert(reads, format.read)
	end

	return table.freeze {

		name = `struct<{table.concat(pairs, ', ')}>`,

		size =
			if dynamicCount == 0 then
				fixedSize
			else
				@native function(
					value: Layout
				)
					local dynSize = 0
					for i = staticCount + 1, keyCount do
						dynSize += sizeof(value[keys[i]], sizes[i], prefixed[i])
					end
					return fixedSize + dynSize
				end,

		assert = function(
			value: Layout
		)
			for i = 1, #keys do
				local key = keys[i]
				local item = value[key]
				local format = (layout :: any)[key]

				if item == nil and format ~= t.NIL then
					error(`missing key '{key}'`, 0)
				end

				local pass, err = pcall(format.assert, item)
				if not pass then
					error(`\{ [{key}]: {err} \}`, 0)
				end
			end
		end,

		write = @native function(
			bytes: buffer,
			offset: int,
			value: Layout
		)
			local keys, writes, sizes = keys, writes, sizes
			for i = 1, keyCount do
				offset = writeItem(bytes, offset, value[keys[i]], writes[i], sizes[i], i >= staticCount and prefixed[i])
			end
			return offset
		end,

		read = @native function(
			bytes: buffer,
			offset: int
		)
			local keys, reads, sizes = keys, reads, sizes
			local value = {}
			for i = 1, keyCount do
				value[keys[i]], offset = readItem(bytes, offset, reads[i], sizes[i], i >= staticCount and prefixed[i])
			end
			return value, offset
		end

	} :: Format<Layout>
end

t.map = function<K, V>(
	keyFormat: Format<K>,
	valueFormat: Format<V>
)
	local kfmtSize = keyFormat.size
	local vfmtSize = valueFormat.size
	local kfmtWrite = keyFormat.write
	local vfmtWrite = valueFormat.write
	local kfmtRead = keyFormat.read
	local vfmtRead = valueFormat.read
	local kfmtPrefix = keyFormat.prefix
	local vfmtPrefix = valueFormat.prefix

	return table.freeze {

		name = `map<{keyFormat.name}, {valueFormat.name}>`,

		prefix = true,

		assert = function(
			value: map<K, V>
		)
			for k, v in value :: any do
				keyFormat.assert(k)
				valueFormat.assert(v)
			end
		end,

		size = @native function(
			value: map<K, V>
		)
			local size = 0
			local count = 0
			for k, v in value :: any do
				size += sizeof(k, kfmtSize, kfmtPrefix)
				size += sizeof(v, vfmtSize, vfmtPrefix)
				count += 1
			end
			return size, count
		end,

		write = @native function(
			bytes: buffer,
			offset: int,
			value: map<K, V>
		)
			for k, v in value do
				offset = writeItem(bytes, offset, k, kfmtWrite, kfmtSize, kfmtPrefix)
				offset = writeItem(bytes, offset, v, vfmtWrite, vfmtSize, vfmtPrefix)
			end
			return offset
		end,

		read = @native function(
			bytes: buffer,
			offset: int,
			count: int
		)
			local result = table.create(count) :: map<K, V>
			local k: K, v: V
			for i = 1, count do
				k, offset = readItem(bytes, offset, kfmtRead, kfmtSize, kfmtPrefix)
				v, offset = readItem(bytes, offset, vfmtRead, vfmtSize, vfmtPrefix)
				result[k] = v
			end
			return result, offset
		end

	} :: Format<map<K, V>>
end

t.set = function<K>(
	keyFormat: Format<K>
)
	return t.map(keyFormat, t.TRUE)
end

-- explicit union
t.union = function(
	types: array<Format<any>>
)
	local names = {}
	local mapping = {}

	for i, format in types do
		table.insert(names, format.name)
		mapping[format.name] = i - 1
	end

	names = table.concat(names, ', ')

	return table.freeze {

		name = `union<{names}>`,

		assert = function(
			value: Tagged<any>
		)
			local format = value.format
			if not mapping[format.name] then
				error(`union<{names}> expected, got '{format.name}'`, 0)
			end
			format.assert(value.value)
		end,

		size = @native function(
			value: Tagged<any>
		)
			local format = value.format
			local size, count = sizeof(value.value, format.size, format.prefix)
			return 1 + size, count
		end,

		write = @native function(
			bytes: buffer,
			offset: int,
			value: Tagged<any>
		)
			local format = value.format
			writeu8(bytes, offset, mapping[format.name])
			return writeItem(bytes, offset + 1, value.value, format.write, format.size, format.prefix)
		end,

		read = @native function(
			bytes: buffer,
			offset: int
		)
			local format = types[readu8(bytes, offset) + 1]
			return readItem(bytes, offset + 1, format.read, format.size, format.prefix)
		end

	} :: Format<any>
end

-- tagged enum
t.tagged = function<T>(
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

	return table.freeze {

		name = `tagged<{names}>`,

		assert = function(
			value: any
		)
			local tag = value[field]
			local format = structs[tag]

			if not format then
				error(`tagged<{values}> expected, got {tag}`, 0)
			end
			format.assert(value)
		end,

		size = @native function(
			value: any
		)
			local tag = value[field]
			local format = structs[tag]
			local size, count = sizeof(value, format.size, format.prefix)
			return 1 + size, count
		end,

		write = @native function(
			bytes: buffer,
			offset: int,
			value: any
		)
			local tag = value[field]
			local format = structs[tag]
			writeu8(bytes, offset, mapping[tag])
			return writeItem(bytes, offset + 1, value, format.write, format.size, format.prefix)
		end,

		read = @native function(
			bytes: buffer,
			offset: int
		)
			local format = structs[inv[readu8(bytes, offset) + 1]]
			return readItem(bytes, offset + 1, format.read, format.size, format.prefix)
		end

	} :: Format<any>
end

return table.freeze {

	-- LIBRARY
	['version'] = 1, -- u32
	['alloc'] = alloc,
	['encode'] = encode,
	['decode'] = decode,
	['schema'] = schema,
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
