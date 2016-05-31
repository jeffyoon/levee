local lmdb = require("lmdb")

local levee = require("levee")
local _ = levee._


return {
	test_core = function()
		local tmp = _.path.Path:tmpdir()
		defer(function() tmp:remove(true) end)

		local env = lmdb.open(tostring(tmp))

		env:w(function(txn)
			txn:put("foo", "bar")
			txn:put("bar", "foo")
			txn:put("abc", "123")
		end)

		env:r(function(txn)
			assert.equal(txn:get("foo"):string(), "bar")
		end)

		local txn = env:w()
		txn:put("abd", "nee")
		txn:abort()

		local txn = env:r()
		local c = txn:cursor()
		assert.equal(c:first():string(), "abc")
		local want = {"bar", "foo"}
		for key, value in c do
			assert.equal(key:string(), table.remove(want, 1))
		end
		assert.equal(c:seek("bar"):string(), "bar")
		txn:commit()

		env = nil
		collectgarbage("collect")
	end,
}
