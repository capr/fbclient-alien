--[[
	Since you opened this file, you might want to know how modules work in fbclient.
	A typical fbclient module starts with the line:

		module(...,require'fbclient.module')

	This does two things:
		1) loads this module if it's not loaded already (so the initialization code only happens once)
		2) calls the value returned by require(), which is the return value of this module (chunk), which is
		the return value of pkg.new(globals), which is a function that initializes the module as
		described in package.lua.

	NOTE: don't interpret this module by Lua convention as the main module of fbclient, cuz there's no
	such thing as require'fbclient'. just coudln't find a better name for what this module does.

]]

local pkg = require 'fbclient.package'
local util = require 'fbclient.util'
local alien = require 'alien'
local struct = require 'alien.struct'

local globals = {
	--*** varargs
	select = select,
	unpack = unpack,
	--*** tables
	ipairs = ipairs,
	pairs = pairs,
	next = next,
	table = table,
	--*** types
	type = type,
	--*** numbers
	tonumber = tonumber,
	math = math,
	--*** strings
	tostring = tostring,
	string = string,
	--*** virtualization
	getmetatable = getmetatable,
	setmetatable = setmetatable,
	--rawequal = rawequal,
	--rawset = rawset,
	--rawget = rawget,
	--*** environments
	getfenv = getfenv,
	--setfenv = setfenv,
	--*** errors
	assert = assert,
	error = error,
	xpcall = xpcall,
	pcall = pcall,
	print = print,
	--*** coroutines
	coroutine = coroutine,
	--*** interpreter
	--load = load,
	--loadstring = loadstring,
	--loadfile = loadfile,
	--dofile = dofile,
	--*** modules
	require = require,
	--module = module,
	package = package,
	--*** clib
	--io = io,
	os = os,
	--*** gc
	--collectgarbage = collectgarbage,
	--gcinfo = gcinfo,
	--*** debug
	--debug = debug,
	--*** unsupported
	--newproxy = newproxy,
	--*** alien
	alien = alien,
	struct = struct,
	util = util, --in case you want to be explicit about it
}

--add all utils to the globals table
for k,v in pairs(util) do
	globals[k]=v
end

return pkg.new(globals)

