local ffi = require "ffi"


local REFS = {}


local function castptr(cdata)
	return tonumber(ffi.cast("uintptr_t", cdata))
end


local Val_mt = {}
Val_mt.__index = Val_mt


function Val_mt:string()
	return ffi.string(self.mv_data, self.mv_size)
end


function Val_mt:__tostring()
	return ("MDB_val: %s"):format(self:string())
end


local MDBVal = ffi.metatype("MDB_val", Val_mt)


local Cursor_mt = {}
Cursor_mt.__index = Cursor_mt


function Cursor_mt:get(op, key)
	if not key then key = MDBVal() end
	local value = MDBVal()
	local rc = C.mdb_cursor_get(self, key, value, op)
	if rc == C.MDB_NOTFOUND then return end
	assert(rc == 0)
	return key, value
end


function Cursor_mt:first()
	return self:get(C.MDB_FIRST)
end


function Cursor_mt:next()
	return self:get(C.MDB_NEXT)
end


function Cursor_mt:seek(key)
	local key = MDBVal(#key, ffi.cast("void*", key))
	return self:get(C.MDB_SET_RANGE, key)
end


function Cursor_mt:__call()
	return self:next()
end


local MDBCursor = ffi.metatype("MDB_cursor", Cursor_mt)


local DB_mt = {}
DB_mt.__index = DB_mt


function DB_mt:put(key, value)
	self.txn:put(key, value, self.dbi)
end


function DB_mt:get(key)
	return self.txn:get(key, self.dbi)
end


local function DB(txn, dbi)
	local self = setmetatable({}, DB_mt)
	self.txn = txn
	self.dbi = dbi
	return self
end


local TXN_INITIAL = 0
local TXN_DONE = 1
local TXN_RESET = 2
local TXN_DIRTY = 3


local Txn_mt = {}


function Txn_mt:__index(name)
	if Txn_mt[name] then return Txn_mt[name] end
	return DB(self, self:dbi(name))
end


function Txn_mt:open(name, flags)
	flags = flags or C.MDB_CREATE
	local dbi = ffi.new("MDB_dbi[1]")
	local rc = C.mdb_dbi_open(self.txn, name, flags, dbi)
	assert(rc == 0)
	return dbi[0]
end


function Txn_mt:env()
	return C.mdb_txn_env(self.txn)
end


function Txn_mt:dbi(name)
	name = name or 0
	return REFS[castptr(self:env())][name]
end


function Txn_mt:cursor()
	local cursor = ffi.new("MDB_cursor *[1]");
	local rc = C.mdb_cursor_open(self.txn, self:dbi(), cursor)
	assert(rc == 0)
	cursor = cursor[0]
	if self.ro then
		ffi.gc(cursor, function(cursor)
			C.mdb_cursor_close(cursor)
		end)
	end
	return cursor
end


function Txn_mt:put(key, value, dbi)
	dbi = dbi or self:dbi()
	local key = MDBVal(#key, ffi.cast("void*", key))
	local value = MDBVal(#value, ffi.cast("void*", value))
	local rc = C.mdb_put(self.txn, dbi, key, value, 0)
	assert(rc == 0)
end


function Txn_mt:get(key, dbi)
	dbi = dbi or self:dbi()
	local key = MDBVal(#key, ffi.cast("void*", key))
	local value = MDBVal()
	local rc = C.mdb_get(self.txn, dbi, key, value)
	if rc == C.MDB_NOTFOUND then return end
	assert(rc == 0)
	return value
end


function Txn_mt:commit()
	assert(self.state ~= TXN_DONE)
	local rc = C.mdb_txn_commit(self.txn)
	assert(rc == 0)
	self.state = TXN_DONE
	return true
end


function Txn_mt:abort()
	if self.state == TXN_DONE then return end
	C.mdb_txn_abort(self.txn)
	self.state = TXN_DONE
end


function Txn_mt:__gc() self:abort() end


ffi.cdef([[
typedef struct {
	MDB_txn * txn;
	int state;
	bool ro;
} LeveeMDB_txn;
]])


local MDBTxn = ffi.metatype("LeveeMDB_txn", Txn_mt)


local function Txn(env, options)
	options = options or {}
	local self = MDBTxn()

	local flags = 0
	if options.read_only then
		flags = C.MDB_RDONLY
		self.ro = true
	end

	local txn = ffi.new("MDB_txn* [1]")
	local rc = C.mdb_txn_begin(env, nil, flags, txn)
	assert(rc == 0)
	self.txn = txn[0]
	return self
end


--
-- Env

local Env_mt = {}
Env_mt.__index = Env_mt


function Env_mt:info()
	local info = ffi.new("MDB_envinfo[1]")
	C.mdb_env_info(self, info)
	info = info[0]
	return {
		map_addr = info.me_mapaddr,
		map_size = tonumber(info.me_mapsize),
		last_pgno = tonumber(info.me_last_pgno),
		last_txnid = tonumber(info.me_last_txnid),
		max_readers = tonumber(info.me_maxreaders),
		num_readers = tonumber(info.me_numreaders)
	}
end


function Env_mt:w(f)
	local txn = self:txn()
	if not f then return txn end
	f(txn)
	txn:commit()
end


function Env_mt:r(f)
	local txn = self:txn({read_only=true})
	if not f then return txn end
	f(txn)
	txn:commit()
end


function Env_mt:txn(options)
	return Txn(self, options)
end


local MDBEnv = ffi.metatype("MDB_env", Env_mt)


local function Env(path, options)
	options = options or {}
	options.mode = options.mode or 0644

	local rc

	local env = ffi.new("MDB_env *[1]")
	local rc = C.mdb_env_create(env)
	assert(rc == 0)
	env = env[0]

	if options.names then
		rc = C.mdb_env_set_maxdbs(env, #options.names)
		assert(rc == 0)
	end

	rc = C.mdb_env_open(env, path, 0, tonumber(options.mode, 8))
	assert(rc == 0)

	ffi.gc(env, function(env)
		REFS[castptr(env)] = nil
		C.mdb_env_close(env)
	end)

	local txn = env:txn()
	REFS[castptr(env)] = {[0] = txn:open()}
	if options.names then
		for __, name in ipairs(options.names) do
			REFS[castptr(env)][name] = txn:open(name)
		end
	end
	txn:commit()

	return env
end


return {
	open = Env,
	REFS = REFS,
}
