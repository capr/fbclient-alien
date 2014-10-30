--[=[
	lgmp binding for gmp decimal number support

	df(lo,hi,scale) -> d; to be used with getdecimal()
	sdf(d,scale)	-> lo,hi; to be used with setdecimal()

	gmp_meta		-> the metatable of all gmp numbers
	isgmp(x)		-> true|false; the gmp library should provide this but since it doesn't...

	xsqlvar:getgmp() -> d
	xsqlvar:setgmp(d)

	xsqlvar:set(d), extended to support gmp-type integers and floats
	xsqlvar:get() -> d, extended to support gmp-type floats

	USAGE: just require this module if you have lgmp installed. call gmp.set_default_prec(x)
	first to set a minimum workable precision.

	LIMITATIONS:
	- assumes 2's complement signed int64 format (no byte order assumption though).

]=]

module(...,require 'fbclient.init')

local gmp = require 'gmp'
local xsqlvar_class = require('fbclient.xsqlvar').xsqlvar_class
local GMP_ZERO = lgmp.f(0)
gmp_meta = getmetatable(GMP_ZERO)

-- convert the lo,hi dword pairs of a 64bit integer into a decimal number and scale it down.
function df(lo,hi,scale)
	return (gmp.f(hi)*2^32+lo)*10^scale
end

-- scale up a decimal number and convert it into the corresponding lo,hi dword pairs of its int64 representation.
function sdf(d,scale)
	d:mul(10^-scale,d)
	local hi,lo = d / 2^32, d % 2^32
	if d < GMP_ZERO then
		hi = hi - 1
		lo = lo + 2^32
	end
	return gmp.tonumber(lo), gmp.tonumber(hi)
end

function xsqlvar_class:getgmp()
	return self:getdecimal(df)
end

function xsqlvar_class:setgmp(d)
	self:setdecimal(d,sdf)
end

function isgmp(x)
	return getmetatable(x) == gmp_meta
end

--the setter and getter must be module-bound so they won't get garbage-collected
xsqlvar_class:add_set_handler(
	function(self,p,typ,opt)
		if isgmp(p) and (typ == 'int16' or typ == 'int32' or typ == 'int64') then
			self:setgmp(p)
			return true
		end
	end
)

xsqlvar_class:add_get_handler(
	function(self,typ,opt)
		if typ == 'int16' or typ == 'int32' or typ == 'int64' then
			return true,self:getgmp()
		end
	end
)

