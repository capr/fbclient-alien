--[[
	Packaging module. This is generic, so can be used for packages other than fbclient.
	Idea stolen and adapted from http://lua-users.org/wiki/ModuleDefinition, take #4.

	new(globals_t) -> init_f; function to pass to module() as discussed below.
	import(module_table | module_name) -> import a module's members into the caller's environment.

	Calling module(...,init_f) changes environment in which module() is called to a table which:
		- reads from table P, which in turn inherits table globals_t,
		- writes to both P and M,
	where M is the module's public interface table, and P is the module's private environment table.

	With this simple trick we get:
		- table globals_t gets inherited in the environments of the module, so just add any hard
		dependencies im this public table.
		- no access to the real global environment, so no worry about module() polluting it (*)
		- any assignment of a global variable goes into module's public interface table.
	(*) A side effect is that require('foo.bar') doesn't get you foo.bar in the environment, which
	is a good thing (it's how module() should behave anyway).

	LIMITATIONS:
	- the module's private environment is not directly reflexive anymore as it uses inheritance.
	- this scheme is arguably bloated, as each module needs:
		- 4 tables (including metatables)
		- one closure
		- duplicating all public elements in the private table
		- 1 indirection for accessing module symbols from inside the module
		- 2 indirections for accessing globals

]]

local function new(globals_t)
	local P_meta = {__index = globals_t}
	return function(M)
		local P = setmetatable({},P_meta)
		local M_env = setmetatable({},{__index=P, __newindex=function(t,k,v) M[k]=v; P[k]=v; end})
		setfenv(3, M_env)
		--import any module's public members (_M, _NAME, etc.) into the private namespace
		for k,v in pairs(M) do
			P[k] = v
		end
	end
end

local function import(M)
	if type(M) == 'string' then
		M = require(M)
	end
	local env = getfenv(2)
	for k,v in pairs(M) do
		env[k]=v
	end
end

return {
	new = new,
	import = import,
}

