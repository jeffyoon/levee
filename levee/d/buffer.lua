local ffi = require('ffi')
local C = ffi.C


local errors = require("levee.errors")


local Buffer_mt = {}
Buffer_mt.__index = Buffer_mt


function Buffer_mt:__tostring()
	return string.format(
		"levee.d.Buffer: sav=%u, off=%u, len=%u, cap=%u",
		self.sav, self.off, self.len, self.cap)
end


function Buffer_mt:__len()
	return self.len
end


function Buffer_mt:truncate()
	if self.off > 0 then
		C.memmove(self.buf, self.buf+self.off, self.len)
		self.off = 0
	end
end


function Buffer_mt:ensure(hint)
	if not hint then
		-- ensure we have *some* space to read into
		hint = self.cap / 2 < 65536ULL and self.cap / 2 or 65536ULL
	end

	local cap = self.sav + self.len + hint

	if cap <= self.cap then
		-- already have enough space
		if self.len == 0 then
			-- can reclaim all space so reset offset
			self.off = 0
		elseif self:available() < hint then
			-- reclaim trimmed space and reset offset
			self:truncate()
		end
		return self
	end

	local buf

	-- find next capacity size
	if cap <= C.LEVEE_BUFFER_MIN_SIZE then
		cap = C.LEVEE_BUFFER_MIN_SIZE
	elseif cap >= C.LEVEE_BUFFER_MAX_BLOCK then
		-- grow to nearest LEVEE_BUFFER_MAX_BLOCK size with capacity to hold hint
		cap = (
			((cap - 1) / C.LEVEE_BUFFER_MAX_BLOCK) + 1) * C.LEVEE_BUFFER_MAX_BLOCK
	else
		-- grow to nearest power of 2
		cap = math.pow(2, math.ceil(math.log(cap)/math.log(2)))
	end

	local sav = self.sav
	if sav > 0 then self:thaw() end

	if self.off > 0 or cap < C.LEVEE_BUFFER_MAX_BLOCK then
		buf = C.malloc(cap)
		if buf == nil then error(tostring(errors.get(ffi.errno()))) end
		if self.len > 0 then
			-- only copy the subregion containing untrimmed data
			C.memcpy(buf, self.buf+self.off, self.len)
		end
		C.free(self.buf)
	else
		-- use realloc to take advantage of mremap
		buf = C.realloc(self.buf, cap)
		if buf == nil then error(tostring(errors.get(ffi.errno()))) end
	end

	-- always reset the offset back to 0
	self.buf = buf
	self.off = 0
	self.cap = cap

	if sav > 0 then self:freeze(sav) end

	return self
end


function Buffer_mt:available()
	return self.cap - (self.off + self.len + self.sav)
end


function Buffer_mt:trim(len)
	if not len or len >= self.len then
		local ret = self.len
		self.off = 0
		self.len = 0
		return ret
	end

	self.off = self.off + len
	self.len = self.len - len
	return len
end


function Buffer_mt:bump(len)
	self.len = self.len + len
end


function Buffer_mt:slice(len)
	return self.buf + self.off, len < self.len and len or self.len
end


function Buffer_mt:value()
	return self.buf + self.off, self.len
end


function Buffer_mt:copy(tgt, n)
	local buf, len = self:value()
	if len == 0 then return 0 end
	if n > len then n = len end
	C.memcpy(tgt, buf, n)
	return n
end


function Buffer_mt:move(tgt, n)
	local n = self:copy(tgt, n)
	if n > 0 then self:trim(n) end
	return n
end


function Buffer_mt:tail()
	return self.buf + self.off + self.len, self:available()
end


function Buffer_mt:freeze(len)
	assert(len <= self.len)
	assert(self.sav == 0)
	self:truncate()
	self.sav = len
	self.len = self.len - len
	self.buf = self.buf + len
end


function Buffer_mt:thaw()
	assert(self.sav > 0)
	self:truncate()
	self.len = self.len + self.sav
	self.buf = self.buf - self.sav
	self.sav = 0
end


function Buffer_mt:peek(len)
	if len then
		len = len < self.len and len or self.len
	else
		len = self.len
	end
	if len == 0ULL then return "" end
	return ffi.string(self.buf + self.off, len)
end


function Buffer_mt:take(len)
	local value = self:peek(len)
	self:trim(#value)
	return value
end


function Buffer_mt:push(s)
	self:ensure(#s)
	ffi.copy(self:tail(), s)
	self:bump(#s)
end


function Buffer_mt:writeinto_iovec(iov)
	iov:writeraw(self:value())
end


local function cleanup(buf)
	C.free(buf.buf)
	C.free(buf)
end


local mt = ffi.metatype("LeveeBuffer", Buffer_mt)


local M_mt = {}
M_mt.__index = M_mt


function M_mt.__call(M, hint)
	local buf = C.malloc(ffi.sizeof(mt))
	buf = ffi.cast("LeveeBuffer*", buf)
	buf = ffi.gc(buf, cleanup)
	buf.buf = nil
	buf.off = 0
	buf.len = 0
	buf.cap = 0
	buf.sav = 0
	buf:ensure(hint)
	return buf
end


function M_mt.from_ptr(M, buf)
	buf = ffi.cast("LeveeBuffer*", buf)
	buf = ffi.gc(buf, cleanup)
	return buf
end


return setmetatable({}, M_mt)
