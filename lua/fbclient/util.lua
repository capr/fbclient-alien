--[[
	Utility functions
	keep this list as short as possible as to not make the language too alien.
	these functions are registerd in the environment inherited by all other modules (see init.lua).

	Table utils:

	index(t) -> {t.v1=t.k1,...}
	keys(t) -> {t.k1,t.k2,...}
	deep_copy(t,[target={}]) -> target
	count(t,[upto=math.huge]) -> n; counts table keys upto a limit

	Platform constants:

	INT_SIZE, SHORT_SIZE, LONG_SIZE, POINTER_SIZE
	MIN_INT, MAX_INT, MAX_UINT, MIN_SHORT, MAX_SHORT, MAX_USHORT, MAX_BYTE, MIN_SCHAR, MAX_SCHAR,
	MIN_LUAINT, MAX_LUAINT

	Type checking:

	asserts(v,s,...)
	xtype(x) -> getmetatable(x).__type or type(x)
	applicable(x,metamethod_name) -> tells if a metamethod is applicable to an object

	isint(v) -> true|false
	isuint(v) -> true|false
	isshort(v) -> true|false
	isushort(v) -> true|false
	isbyte(v) -> true|false
	isschar(v) -> true|false

	Debug utils:

	dump(v)

]]

local error = error
local pairs = pairs
local getmetatable = getmetatable
local setmetatable = setmetatable
local math = math
local next = next
local assert = assert
local type = type
local unpack = unpack
local tostring = tostring
local print = print
local select = select
local alien = require 'alien'

module(...) --require'fbclient.module' on this module would create a circular dependency

--enumerate a table's keys into an array in no particular order
function index(t)
	newt={}
	for k,v in pairs(t) do
		newt[v]=k
	end
	return newt
end

--return an unsorted array of keys of t
function keys(t)
	newt={}
	for k,v in pairs(t) do
		newt[#newt+1]=k
	end
	return newt
end

--simple deep copy function without cycle detection.
--uses assignment to copy objects (except tables), so userdata and thread types are not supported.
--the metatable is not copied, just referenced, except if it's the source object itself, then it's reassigned.
function deep_copy(t,target)
	if not t then return target end
	target = target or {}
	for k,v in pairs(t) do
		target[k] = applicable(v,'__pairs') and deep_copy(v,target[k]) or v
	end
	local mt = getmetatable(t)
	return setmetatable(target, mt == t and target or mt)
end

--count the elements in t (optionally upto some number)
function count(t,upto)
	upto = upto or math.huge
	local i,k = 0,next(t)
	while k and i < upto do
		i = i+1
		k = next(t,k)
	end
	return i
end

--garbageless assert with string formatting
function asserts(v,s,...)
	if v then
		return v,s,...
	else
		error(s:format(select(1,...)), 2)
	end
end

function checktype(val,typ,argname)
	if type(typ)=='string' then
		if type(argname)=='number' then
			asserts(xtype(val)==typ,'arg #%d type %s expected, got %s',argname,typ,xtype(val))
		else
			asserts(xtype(val)==typ,'arg %s type %s expected, got %s',argname,typ,xtype(val))
		end
	else
		if type(argname)=='number' then
			asserts(typ(val),'arg #%d expected, got %s',argname,typ,xtype(val))
		else
			asserts(typ(val),'arg %s expected, got %s',argname,typ,xtype(val))
		end
	end
end

function xtype(x)
	local mt = getmetatable(x)
	return mt and mt.__type or type(x)
end

local applicable_prims = {
	__call = 'function',
	__index = 'table', __newindex = 'table', __mode = 'table',
	__pairs = 'table', __ipairs = 'table', __len = 'table',
	__tonumber = 'number',
		__add = 'number', __sub = 'number', __mul = 'number', __div = 'number', __mod = 'number',
		__pow = 'number', __unm = 'number',
	__tostring = 'string', __concat = 'string',
}

function applicable(x,mm)
	if applicable_prims[mm] == type(x) then
		return true
	elseif mm == '__tostring' and type(x) == 'number' then
		return true
	else
		local mt = getmetatable(x)
		return mt and mt[mm] or false
	end
end

INT_SIZE	= alien.sizeof('int')
SHORT_SIZE	= alien.sizeof('short')
LONG_SIZE	= alien.sizeof('long')
POINTER_SIZE= alien.sizeof('pointer')
MIN_INT		= -2^(8*INT_SIZE-1)
MAX_INT		=  2^(8*INT_SIZE-1)-1
MAX_UINT	=  2^(8*INT_SIZE)-1
MIN_SHORT	= -2^(8*SHORT_SIZE-1)
MAX_SHORT	=  2^(8*SHORT_SIZE-1)-1
MAX_USHORT	=  2^(8*SHORT_SIZE)-1
MAX_BYTE	=  2^8-1
MIN_SCHAR	= -2^7
MAX_SCHAR	=  2^7-1
MIN_LUAINT	= -2^52
MAX_LUAINT	=  2^52-1

function isint(v) return v%1 == 0 and v >= MIN_INT and v <= MAX_INT end
function isuint(v) return v%1 == 0 and v >= 0 and v <= MAX_UINT end
function isshort(v) return v%1 == 0 and v >= MIN_SHORT and v <= MAX_SHORT end
function isushort(v) return v%1 == 0 and v >= 0 and v <= MAX_USHORT end
function isbyte(v) return v%1 == 0 and v >= 0 and v <= MAX_BYTE end
function isschar(v) return v%1 == 0 and v >= MIN_SCHAR and v <= MAX_SCHAR end

function dump_buffer(buf,size)
	local s = buf:tostring(size)
	print('alien buffer',size,s)
	for i=1,#s do
		local c = s:sub(i,i)
		local b = c:byte()
		print(b,c)
	end
end

--debugging functions
local function dump_recursive(v,k,i,trace,level)
	i = i or 0
	local indent = 2
	if level and i > level then return end
	if applicable(v,'__pairs') and not applicable(v, '__tostring') then
		local typ = type(v) == 'table' and '['..tostring(v)..']' or type(v)
		if trace[v] then
			print((' '):rep(i*indent)..(k and '['..tostring(k)..'] => ' or '')..'<traced> '..typ)
		else
			trace[v] = true
			print((' '):rep(i*indent)..(k and '['..tostring(k)..'] => ' or '')..typ)
			for kk,vv in pairs(v) do
				kk = applicable(kk,'__tostring') and kk or '('..type(kk)..')'
				dump_recursive(vv,kk,i+1,trace,level)
			end
		end
	else
		print((' '):rep(i*indent)..(k and '['..tostring(k)..'] => ' or '')..tostring(v))
	end
end

--table dump for debugging purposes
function dump(...)
	for i=1,select('#',...) do
		dump_recursive(select(i,...),nil,nil,{})
	end
	return ...
end

