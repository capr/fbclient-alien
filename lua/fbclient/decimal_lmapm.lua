--[=[
	lmapm binding for mapm decimal number support

	df(lo,hi,scale) -> d; to be used with getdecimal()
	sdf(d,scale)	-> lo,hi; to be used with setdecimal()

	mapm_meta		-> the metatable of all mapm numbers
	ismapm(x)		-> true|false; the mapm library should provide this, but since it doesn't...

	xsqlvar:getmapm() -> d
	xsqlvar:setmapm(d)

	xsqlvar:set(d), extended to support mapm-type decimals
	xsqlvar:get() -> d, extended to support mapm-type decimals

	USAGE: just require this module if you have lmapm installed.

	LIMITATIONS:
	- the % operator doesn't have Lua semantics!
	- mapm is not thread-safe. it includes a lock-based thread-safe wrapper but you'll have to build it yourself.
	- assumes 2's complement signed int64 format (no byte order assumption though).

]=]

module(...,require 'fbclient.module')

local mapm = require 'mapm'
local xsqlvar_class = require('fbclient.xsqlvar').xsqlvar_class
local MAPM_ZERO = mapm.number(0)
mapm_meta = getmetatable(MAPM_ZERO)

-- convert the lo,hi dword pairs of a 64bit integer into a decimal number and scale it down.
function df(lo,hi,scale)
	return (mapm.number(hi) * 2^32 + lo) * 10^scale
end

-- scale up a decimal number and convert it into the corresponding lo,hi dword pairs of its int64 representation.
function sdf(d,scale)
	local hi,lo = mapm.idiv(d*10^-scale,2^32) --idiv returns quotient,remainder.
	if d < MAPM_ZERO then
		hi = hi - 1
		lo = lo + 2^32
	end
	return mapm.tonumber(lo), mapm.tonumber(hi)
end

function xsqlvar_class:getmapm()
	return self:getdecimal(df)
end

function xsqlvar_class:setmapm(d)
	self:setdecimal(d,sdf)
end

function ismapm(x)
	return getmetatable(x) == mapm_meta
end

xsqlvar_class:add_set_handler(
	function(self,p,typ,opt)
		if ismapm(p) and (typ == 'int16' or typ == 'int32' or typ == 'int64') then
			self:setmapm(p)
			return true
		end
	end
)

xsqlvar_class:add_get_handler(
	function(self,typ,opt)
		if typ == 'int16' or typ == 'int32' or typ == 'int64' then
			return true,self:getmapm()
		end
	end
)

