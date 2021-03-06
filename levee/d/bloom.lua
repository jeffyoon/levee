local ffi = require("ffi")
local C = ffi.C

local rand = require('levee._.rand')

local bloom_seed = rand.integer()


local Bloom_mt = {}
Bloom_mt.__index = Bloom_mt


function Bloom_mt:__tostring()
	return string.format("levee.Bloom: %p", self)
end


function Bloom_mt:is_capable(hint, fpp)
	return C.sp_bloom_is_capable(self, hint, fpp or self.fpp)
end


-- TODO: support more types
function Bloom_mt:hash(val, len)
	return C.sp_bloom_hash(val, len or #val)
end


function Bloom_mt:put(val, len)
	return self:put_hash(self:hash(val, len))
end


function Bloom_mt:put_hash(hash)
	C.sp_bloom_put_hash(self, hash)
	return self
end


function Bloom_mt:maybe(val, len)
	return self:maybe_hash(self:hash(val, len))
end


function Bloom_mt:maybe_hash(hash)
	return C.sp_bloom_maybe_hash(self, hash)
end


function Bloom_mt:clear()
	C.sp_bloom_clear(self)
end


function Bloom_mt:copy()
	return ffi.gc(C.sp_bloom_copy(self), C.sp_bloom_free)
end


ffi.metatype("SpBloom", Bloom_mt)


local function Bloom(hint, fpp)
	local self = C.sp_bloom_new(hint or 0, fpp or 0.01)
	return ffi.gc(self, C.sp_bloom_free)
end


return Bloom
