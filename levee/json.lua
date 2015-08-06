local ffi = require("ffi")
local C = ffi.C

local errno = require("levee.errno")


local Json_mt = {}
Json_mt.__index = Json_mt


function Json_mt:__new()
	return ffi.new(self):init()
end


function Json_mt:__tostring()
	return string.format("levee.json: %p", self)
end


function Json_mt:init()
	C.sp_json_init(self)
	return self
end


function Json_mt:reset()
	C.sp_json_reset(self)
end


function Json_mt:is_done()
	return C.sp_json_is_done(self)
end


function Json_mt:next(eof, buf, len)
	return C.sp_json_next(self, buf, len, eof)
end


function Json_mt:stream_next(stream)
	local n = self:next(false, stream:value())
	if n < 0 then
		return false, ffi.string(C.sp_strerror(n))
	end

	if n > 0 then
		stream:trim(n)
		-- need to read more if SP_JSON_NONE
		if self.type ~= C.SP_JSON_NONE then
			return true
		end
	end

	local n, err = stream:readin()
	if n <= 0 then
		-- connection died
		return false, errno:message(err)
	end

	return self:stream_next(stream)
end


function Json_mt:stream_value(stream)
	local ok, err = self:stream_next(stream)
	if not ok then return ok, err end

	if self.type == C.SP_JSON_OBJECT then
		local ob = {}
		while true do
			local ok, key = self:stream_value(stream)
			if not ok then return ok, key end
			if key == C.SP_JSON_OBJECT_END then
				return true, ob
			end
			local ok, value = self:stream_value(stream)
			if not ok then return ok, value end
			ob[key] = value
		end

	elseif self.type == C.SP_JSON_ARRAY then
		local arr = {}
		while true do
			local ok, item = self:stream_value(stream)
			if not ok then return ok, item end
			if item == C.SP_JSON_ARRAY_END then
				return true, arr
			end
			table.insert(arr, item)
		end

	elseif self.type == C.SP_JSON_NUMBER then
		return true, self.number

	elseif self.type == C.SP_JSON_STRING then
		return true, ffi.string(self.utf8.buf, self.utf8.len)

	elseif self.type == C.SP_JSON_TRUE then
		return true, true

	elseif self.type == C.SP_JSON_FALSE then
		return true, false

	elseif self.type == C.SP_JSON_NULL then
		return true, nil

	else
		-- should only be SP_JSON_OBJECT_END and SP_JSON_ARRAY_END
		return true, self.type
	end
end


function Json_mt:stream_consume(stream)
	-- stream methods:
	--	:readin()
	--	:value() -> returns char*, len (could return eof?)
	--	:trim(n)

	local ok, value = self:stream_value(stream)
	if not ok then return ok, value end
	assert(self:is_done())
	self:reset()
	return true, value
end


--
-- Poor man's encode - just awful, please replace

local function encode(data)
	if type(data) == "table" then
		local ret = {}
		table.insert(ret, "{")
		if next(data) then
			for key, value in pairs(data) do
				assert(type(key) == "string")
				table.insert(ret, '"'..key..'"')
				table.insert(ret, ": ")
				table.insert(ret, encode(value))
				table.insert(ret, ", ")
			end
			table.remove(ret)  -- pop trailing ','
		end
		table.insert(ret, "}")
		return table.concat(ret)

	elseif type(data) == "string" then
		return '"'..data..'"'

	elseif type(data) == "number" then
		return tostring(data)

	else
		print(type(data))
		assert(false)
	end
end


return {
	decoder = ffi.metatype("SpJson", Json_mt),
	encode = encode,
}
