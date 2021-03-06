local ffi = require('ffi')
local C = ffi.C

local function crc32(val, len)
	return C.sp_crc32(0ULL, val, len or #val)
end

local function crc32c(val, len)
	return C.sp_crc32c(0ULL, val, len or #val)
end

local function metro(val, len, seed)
	return C.sp_metrohash64(val, len or #val, seed or C.SP_SEED_DEFAULT)
end

local function sip(val, len, seed)
	return C.sp_siphash(val, len or #val, seed or C.SP_SEED_DEFAULT)
end

local function sipcase(val, len, seed)
	return C.sp_siphash_case(val, len or #val, seed or C.SP_SEED_DEFAULT)
end

return {
	seed = {
		default = C.SP_SEED_DEFAULT,
		random = C.SP_SEED_RANDOM
	},
	crc32 = crc32,
	crc32c = crc32c,
	metro = metro,
	sip = sip,
	sipcase = sipcase
}
