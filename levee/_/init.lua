local ret = {}

for k, v in pairs(require("levee._.path")) do ret[k] = v end
for k, v in pairs(require("levee._.syscalls")) do ret[k] = v end

return ret