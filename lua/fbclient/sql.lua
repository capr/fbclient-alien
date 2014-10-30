--[[
	Firebird-specific SQL formatting specific

]]

module(...,require 'fbclient.module')

local keywords = require 'fbclient.sql_keywords'

function S(s) --string, subject to quoting of apostrophes
	return s
end

function K(s) --keywords, subject to case change
	return s
end

function N(s) --name, subject to un-double-quoting of non-reserved keywords and double-quoting of reserved keywords
	s = s:match('^%"([%u_]-)"$') or s --de-quote all-uppercase-and-no-spaces names
	return (not quoting_mode or keywords[quoting_mode][s]) and '"'..s..'"' or s
end

function L(s) --literal
	return s
end

function E(s) --expression
	return s
end

--Concatenate arguments; a nil or false argument results in a nil expression; true arguments are ignored
function C(sep,...)
	--
end

--Concatenate Optional arguments; a nil or false argument ignores the argument; true arguments are ignored
function CO(sep,...)
	--
end

function I(f, t, sep) --concatenate the results of mapping f over t
	local ts = {}
	for k,v in pairs(t) do
		ts[#ts+1] = f(k,v)
	end
	return table.concat(ts, sep)
end

function run(f,...)
	local fenv = getfenv(f)
	local function helper(...)
		setfenv(f, fenv)
		return ...
	end
	local newfenv = setmetatable({}, {__index = function(t,k) return _M[k] or fenv end})
	setfenv(f, newfenv)
	return helper(f(...))
end

