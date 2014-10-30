--[=[
	SQLDATA & SQLIND buffer encoding and decoding

	xsqlvar_class -> the table that xsqlvar objects inherit
	xsqlvar_meta -> the metatable of xsqlvar objects
	xsqlvar_meta.__index = xsqlvar_class
	xsqlvar_meta.__type = 'fbclient xsqlvar'

	wrap(xsqlvar_t, fbapi, sv, dbh, trh, [xsqlvar_meta]) -> xsqlvar

	xsqlvar:allownull() -> true|false
	xsqlvar:isnull() -> true|false
	xsqlvar:setnull()
	xsqlvar:setnotnull()
	xsqlvar:type() -> type[,subtype[,charset_id]]
		* subtype is scale for numbers, max_length for strings, subtype for blobs
		* charset_id is returned only for blobs (fb 2.1+)

	xsqlvar:gettime() -> time_t           for DATE, TIME, TIMESTAMP
	xsqlvar:settime(time_t)               for DATE, TIME, TIMESTAMP; see note (1)
	xsqlvar:getnumber() -> n              for FLOAT, DOUBLE PRECISION, SMALLINT, INTEGER, DECIMAL(1-15,0), BIGINT < -2^52 to 2^52-1
	xsqlvar:setnumber(n)                  for FLOAT, DOUBLE PRECISION, SMALLINT, INTEGER, DECIMAL(1-15,0), BIGINT < -2^52 to 2^52-1
	xsqlvar:getparts() -> parts_t         for SMALLINT, INTEGER, DECIMAL(1-15,0-15), BIGINT < -2^52 to 2^52-1; see note (2)
	xsqlvar:setparts(parts_t)             for SMALLINT, INTEGER, DECIMAL(1-15,0-15), BIGINT < -2^52 to 2^52-1
	xsqlvar:getdecimal(df) -> d           for SMALLINT, INTEGER, DECIMAL(1-18,0-18), BIGINT; see note (3)
	xsqlvar:setdecimal(d,sdf)             for SMALLINT, INTEGER, DECIMAL(1-18,0-18), BIGINT; see note (3)
	xsqlvar:getstring() -> s              for VARCHAR, CHAR
	xsqlvar:getstringlength() -> n        for VARCHAR, CHAR
	xsqlvar:setstring(s)                  for VARCHAR, CHAR
	xsqlvar:getunpadded(s)                for VARCHAR, CHAR (strips away any space padding from CHAR type)
	xsqlvar:setpadded(s)                  for VARCHAR, CHAR (adds necessary space padding for CHAR type)
	xsqlvar:getblobid() -> blob_id_buf    for BLOB
	xsqlvar:setblobid(blob_id_buf)        for BLOB

	parts_meta -> the metatable of parts_t objects (for numbers)
	mkparts(t) -> setmetatable(t, parts_meta)

	NOTES:
	(1) time_t is as per os.date(), but with the additional field sfrac, meaning fractions of a second,
	an integer in range 0-9999. it also has __tostring and __type on its metatable. see datetime.lua for details.
	(2) parts_t is {int,frac} and has __tostring and __type on its metatable.
	(3) the df and sdf arguments for getdecimal() and setdecimal() are functions implemented in decimal_*.lua.

	*** Polymorphic get() & set() ***

	xsqlvar:set(variant)           for all types: generic setter
	xsqlvar:get() -> variant       for all types: generic getter

	xsqlvar_class.set_handlers -> array of handler functions for set()
	xsqlvar_class.get_handlers -> array of handler functions for get()
	xsqlvar_class.add_set_handler(setf)
	xsqlvar_class.add_get_handler(getf)

	The polymorphic get() and set() are implemented and extendable with handler functions.
	checkout the handlers in this file and in decimal_*.lua and blob.lua for insight into the protocol
	for creating handlers to support more datatypes.

	Parameter value type mapping for set(p):

	param type					|	passed type		|	setter used				|	where setter is implemented
	----------------------------+-------------------+---------------------------+------------------------------
	any								null				setnull()					xsqlvar.lua
	is_null							any not null		setnotnull()				xsqlvar.lua
	time,date,timestamp				time_t				settime(t)					xsqlvar.lua
	all numerics					boolean				setnumber(b and 1 or 0)		xsqlvar.lua
	int16,int32,int64, scale = 0	number				setnumber(n)				xsqlvar.lua
	int16,int32,int64, scale >= 0	parts_t				setparts(parts_t)			xsqlvar.lua
	float,double					number				setnumber(n)				xsqlvar.lua
	varchar							string				setstring(s)				xsqlvar.lua
	char							string				setpadded(s)				xsqlvar.lua
	int16,int32,int64, any scale	decnumber number	setdecnumber(d)				decimal_ldecnumber.lua
	int16,int32,int64, any scale	mapm number			setmapm(d)					decimal_lmapm.lua
	int16,int32,int64, any scale	bc number			setbc(d)					decimal_lbc.lua
	blob							string				write(s)					blob.lua

	Column value type mapping for get():

	column type					|	returned type	|	getter used				|	where getter is implemented
	----------------------------+-------------------+---------------------------+------------------------------
	any, NULL value					nil					isnull()					xsqlvar.lua
	time,date,timestamp				time_t				gettime()					xsqlvar.lua
	int16,int32,int64 scale = 0		number				getnumber()					xsqlvar.lua
	int16,int32,int64 scale >= 0	parts_t				getparts()					xsqlvar.lua
	float,double					number				getnumber()					xsqlvar.lua
	varchar							string				getstring()					xsqlvar.lua
	char							string				getunpadded()				xsqlvar.lua
	int16,int32,int64, any scale	decnumber number    getdecnumber()				decimal_ldecnumber.lua
	int16,int32,int64, any scale	mapm number    		getmapm()					decimal_lmapm.lua
	int16,int32,int64, any scale	bc number    		getbc()						decimal_lbc.lua
	blob							string				concat(segments())			blob.lua

	TIP:
	- tostring(xs:get()) works for all data types.

	LIMITATIONS:
	- only works on a Lua compiler with LUA_NUMBER = double.

]=]

module(...,require 'fbclient.module')

local datetime = require 'fbclient.datetime'

xsqlvar_class = {}

xsqlvar_meta = {
	__index = xsqlvar_class,
	__type = 'fbclient xsqlvar'
}

function wrap(xs, fbapi, sv, dbh, trh, xs_meta)
	xs.fbapi = fbapi --needed for time and blob funcs
	xs.sv = sv --needed for blob funcs
	xs.dbh = dbh --needed for blob funcs
	xs.trh = trh --needed for blob funcs
	return setmetatable(xs, xs_meta or xsqlvar_meta)
end

function xsqlvar_class:allownull()
	return self.allow_null
end

function xsqlvar_class:isnull()
	return self.sqlind_buf:get(1,'int')==-1
end

function xsqlvar_class:setnull()
	assert(self.allow_null, 'NULL not allowed')
	if self.buflen > 0 then
		alien.memset(self.sqldata_buf,0,self.buflen) --important!
	end
	self.sqlind_buf:set(1,-1,'int')
end

function xsqlvar_class:setnotnull() --only for SQL_NULL type introduced in Firebird 2.5 (see relnotes)
	asserts(self.sqltype == 'SQL_NULL', 'incompatible data type %s', self:type())
	self.sqlind_buf:set(1,0,'int')
end

do
	local sqltypes = {
		SQL_TYPE_TIME='time',		--TIME
		SQL_TYPE_DATE='date',		--DATE
		SQL_TIMESTAMP='timestamp',	--TIMESTAMP
		SQL_SHORT='int16',			--SMALLINT and DECIMAL(1-4,0-4)
		SQL_LONG='int32',			--INTEGER and DECIMAL(5-9,0-9)
		SQL_INT64='int64',			--BIGINT and DECIMAL(10-18,0-18)
		SQL_FLOAT='float',			--FLOAT
		SQL_DOUBLE='double',		--DOUBLE PRECISION
		SQL_TEXT='char',			--CHAR
		SQL_VARYING='varchar',		--VARCHAR
		SQL_BLOB='blob',			--BLOB
		SQL_ARRAY='array',			--ARRAY
		SQL_NULL='is_null',			--`? IS NULL` construct (Firebird 2.5)
	}

	function xsqlvar_class:type()
		local typ = assert(sqltypes[self.sqltype])
		if typ == 'int16' or typ == 'int32' or typ == 'int64' then
			return typ, 0-self.sqlscale --because in FP 0-0 == +0
		elseif typ == 'varchar' or typ == 'char' then
			return typ, self.sqllen
		elseif type == 'blob' then
			return typ, self.subtype, self.sqlscale --sqlscale represents charset_id for blobs
		else
			return typ
		end
	end
end

function xsqlvar_class:gettime(t) --t is optional so you can reuse a time_t between calls
	assert(not self:isnull(), 'NULL value')
	local typ = self.sqltype
	if typ == 'SQL_TYPE_TIME' then
		t, self.tm_buf = datetime.decode_time(self.sqldata_buf, self.fbapi, t, self.tm_buf)
	elseif typ == 'SQL_TYPE_DATE' then
		t, self.tm_buf = datetime.decode_date(self.sqldata_buf, self.fbapi, t, self.tm_buf)
	elseif typ == 'SQL_TIMESTAMP' then
		t, self.tm_buf = datetime.decode_timestamp(self.sqldata_buf, self.fbapi, t, self.tm_buf)
	else
		asserts(false, 'incompatible data type %s', self:type())
	end
	return t
end

function xsqlvar_class:settime(t)
	local typ = self.sqltype
	if typ == 'SQL_TYPE_TIME' then
		datetime.encode_time(t, self.sqldata_buf, self.fbapi)
	elseif typ == 'SQL_TYPE_DATE' then
		datetime.encode_date(t, self.sqldata_buf, self.fbapi)
	elseif typ == 'SQL_TIMESTAMP' then
		datetime.encode_timestamp(t, self.sqldata_buf, self.fbapi)
	else
		asserts(false, 'incompatible data type %s', self:type())
	end
	self.sqlind_buf:set(1,0,'int')
end

function xsqlvar_class:getnumber()
	assert(not self:isnull(), 'NULL value')
	local typ,scale,styp = self.sqltype, self.sqlscale, self:type()
	if typ == 'SQL_FLOAT' then --FLOAT
		return self.sqldata_buf:get(1,'float')
	elseif typ == 'SQL_DOUBLE' or typ == 'SQL_D_FLOAT' then --DOUBLE PRECISION
		return self.sqldata_buf:get(1,'double')
	elseif typ == 'SQL_SHORT' then --SMALLINT
		asserts(scale == 0, 'decimal type %s scale %d (only integers and scale 0 decimals allowed)', styp, scale)
		return self.sqldata_buf:get(1,'short')
	elseif typ == 'SQL_LONG' then --INTEGER
		asserts(scale == 0, 'decimal type %s scale %d (only integers and scale 0 decimals allowed)', styp, scale)
		return self.sqldata_buf:get(1,'int')
	elseif typ == 'SQL_INT64' then --BIGINT
		asserts(scale == 0, 'decimal type %s scale %d (only integers and scale 0 decimals allowed)', styp, scale)
		local lo,hi = struct.unpack('Ii', self.sqldata_buf, self.buflen)
		local n = hi * 2^32 + lo --overflowing results in +/- INF
		--we consider it an error to be able to read a number out of the range of setnumber()
		asserts(n >= MIN_LUAINT and n <= MAX_LUAINT, 'number out of range (range is %d to %d)',MIN_LUAINT,MAX_LUAINT)
		return n
	end
	asserts(false, 'incompatible data type %s', styp)
end

function xsqlvar_class:setnumber(n)
	local typ,scale,styp = self.sqltype, self.sqlscale, self:type()
	if typ == 'SQL_FLOAT' then
		--TODO: replace this ugly (but safe and efficient, aren't they all) hack to check
		--loss of precision in conversion from double to float
		local oldn = self.sqldata_buf:get(1,'float')
		self.sqldata_buf:set(1,n,'float')
		local p = self.sqldata_buf:get(1,'float')
		if not (n ~= n and p ~= p or n == p) then
			self.sqldata_buf:set(1,oldn,'float')
			assert(false, 'arg#1 number out of precision')
		end
	elseif typ == 'SQL_DOUBLE' or typ == 'SQL_D_FLOAT' then
		self.sqldata_buf:set(1,n,'double')
	elseif typ == 'SQL_SHORT' or typ == 'SQL_LONG' or typ == 'SQL_INT64' then
		asserts(scale == 0, 'decimal type %s scale %d (only integers and scale 0 decimals allowed)', styp, scale)
		assert(n%1==0, 'arg#1 integer expected, got float')
		local range_error = 'arg#1 number out of range (range is %d to %d)'
		if typ == 'SQL_SHORT' then
			asserts(n >= MIN_SHORT and n <= MAX_SHORT, range_error, MIN_SHORT, MAX_SHORT)
			self.sqldata_buf:set(1,n,'short')
		elseif typ == 'SQL_LONG' then
			asserts(n >= MIN_INT and n <= MAX_INT, range_error, MIN_INT, MAX_INT)
			self.sqldata_buf:set(1,n,'int')
		elseif typ == 'SQL_INT64' then
			asserts(n >= MIN_LUAINT and n <= MAX_LUAINT, range_error, MIN_LUAINT, MAX_LUAINT)
			local lo,hi = n % 2^32, math.floor(n / 2^32)
			self.sqldata_buf:set(1,lo,'uint')
			self.sqldata_buf:set(1+INT_SIZE,hi,'int')
		end
	else
		asserts(false, 'incompatible data type %s', styp)
	end
	self.sqlind_buf:set(1,0,'int')
end

parts_meta = {__type = 'fbclient parts'}

do
	local DECIMAL_DOT_SYMBOL = ('%1.1f'):format(3.14):sub(2,2)
	assert(#DECIMAL_DOT_SYMBOL==1)
	function parts_meta:__tostring()
		return ('%d%s%d'):format(self[1],DECIMAL_DOT_SYMBOL,self[2])
	end
end

function parts_meta:__eq(other)
	return self[1] == other[1] and self[2] == other[2]
end

function mkparts(t) return setmetatable(t, parts_meta) end

--this doesn't work with FLOAT or DOUBLE because decimal fractions can't be accurately represented in floats.
function xsqlvar_class:getparts(t) --t is optional so you can reuse the table in a tight loop
	t = t or {0,0}
	assert(not self:isnull(), 'NULL value')
	local typ, scale = self.sqltype, self.sqlscale
	local n
	if typ == 'SQL_SHORT' then --SMALLINT or DECIMAL(1-4,0-4)
		n = self.sqldata_buf:get(1,'short')
	elseif typ == 'SQL_LONG' then --INTEGER or DECIMAL(5-9,0-9)
		n = self.sqldata_buf:get(1,'int')
	elseif typ == 'SQL_INT64' then --BIGINT or DECIMAL(10-18,0-18)
		local lo,hi = struct.unpack('Ii', self.sqldata_buf, self.buflen)
		n = hi * 2^32 + lo --overflowing results in +/- INF
		--we see it as an error to be able to getparts() a number that is out of the range of setparts()
		asserts(n >= MIN_LUAINT and n <= MAX_LUAINT, 'number out of range (range is %d to %d)', MIN_LUAINT, MAX_LUAINT)
	else
		asserts(false, 'incompatible data type %s', self:type())
	end
	if scale == 0 then
		t[1] = n
		t[2] = 0
	else
		t[1] = math.floor(n*10^scale)
		t[2] = n%10^-scale
	end
	return mkparts(t)
end

--this doesn't work with FLOAT or DOUBLE because decimal fractions can't be accurately represented in floats.
function xsqlvar_class:setparts(t)
	local int,frac = unpack(t)
	assert(int%1==0, 'arg#1[1] integer expected, got float')
	assert(frac%1==0, 'arg#1[2] integer expected, got float')
	local range_error = 'arg#1[%d] out of range (range is %d to %d)'
	local factor = 10^-self.sqlscale
	asserts(frac <= factor-1, range_error, 2, 0, factor-1)
	local n = int*factor+frac
	local typ = self.sqltype
	if typ == 'SQL_SHORT' then
		asserts(n >= MIN_SHORT and n <= MAX_SHORT, range_error, 1, MIN_SHORT, MAX_SHORT)
		self.sqldata_buf:set(1,n,'short')
	elseif typ == 'SQL_LONG' then
		asserts(n >= MIN_INT and n <= MAX_INT, range_error, 1, MIN_INT, MAX_INT)
		self.sqldata_buf:set(1,n,'int')
	elseif typ == 'SQL_INT64' then
		asserts(n >= MIN_LUAINT and n <= MAX_LUAINT, range_error, 1, MIN_LUAINT, MAX_LUAINT)
		local lo,hi = n % 2^32, math.floor(n / 2^32)
		self.sqldata_buf:set(1,lo,'uint')
		self.sqldata_buf:set(1+INT_SIZE,hi,'int')
	else
		asserts(false, 'incompatible data type %s', self:type())
	end
	self.sqlind_buf:set(1,0,'int')
end

function xsqlvar_class:getdecimal(df)
	assert(not self:isnull(), 'NULL value')
	local typ = self.sqltype
	if typ == 'SQL_SHORT' then --SMALLINT or DECIMAL(1-4,0-4)
		return df(self.sqldata_buf:get(1,'short'), 0, self.sqlscale)
	elseif typ == 'SQL_LONG' then --INTEGER or DECIMAL(5-9,0-9)
		return df(self.sqldata_buf:get(1,'int'), 0, self.sqlscale)
	elseif typ == 'SQL_INT64' then --BIGINT or DECIMAL(10-18,0-18)
		local lo,hi = struct.unpack('Ii', self.sqldata_buf, self.buflen)
		return df(lo, hi, self.sqlscale)
	end
	asserts(false, 'incompatible data type %s', self:type())
end

function xsqlvar_class:setdecimal(d,sdf)
	local typ = self.sqltype
	local lo,hi
	local range_error = 'arg#1 number out of range (range is %d to %d)'
	if typ == 'SQL_SHORT' then
		asserts(lo >= MIN_SHORT and lo <= MAX_SHORT, range_error, MIN_SHORT, MAX_SHORT)
		lo,hi = sdf(d, self.sqlscale)
		self.sqldata_buf:set(1,lo,'short')
	elseif typ == 'SQL_LONG' then
		asserts(lo >= MIN_INT and lo <= MAX_INT, range_error, MIN_INT, MAX_INT)
		lo,hi = sdf(d, self.sqlscale)
		self.sqldata_buf:set(1,lo,'int')
	elseif typ == 'SQL_INT64' then
		lo,hi = sdf(d, self.sqlscale)
		assert(lo >= 0 and lo <= MAX_UINT and hi >= MIN_INT and hi <= MAX_INT, 'arg#1 number out of range')
		self.sqldata_buf:set(1,lo,'uint')
		self.sqldata_buf:set(1+INT_SIZE,hi,'int')
	else
		asserts(false, 'incompatible data type %s', self:type())
	end
	self.sqlind_buf:set(1,0,'int')
end

function xsqlvar_class:getstring()
	assert(not self:isnull(), 'NULL value')
	local typ = self.sqltype
	if typ == 'SQL_TEXT' then
		return self.sqldata_buf:tostring(self.sqllen) --CHAR type, space padded
	elseif typ == 'SQL_VARYING' then
		return struct.unpack('hc0', self.sqldata_buf, self.buflen) --VARCHAR type
	else
		asserts(false, 'incompatible data type %s',self:type())
	end
end

function xsqlvar_class:getstringlength()
	assert(not self:isnull(), 'NULL value')
	local typ = self.sqltype
	if typ == 'SQL_TEXT' then
		return self.sqllen
	elseif typ == 'SQL_VARYING' then
		return struct.unpack('h', self.sqldata_buf, self.buflen)
	else
		asserts(false, 'incompatible data type %s',self:type())
	end
end

function xsqlvar_class:setstring(s)
	local typ = self.sqltype
	if typ == 'SQL_TEXT' then
		asserts(#s == self.sqllen, 'expected string of exactly %d bytes', self.sqllen)
		alien.memcpy(self.sqldata_buf, s)
	elseif typ == 'SQL_VARYING' then
		local buf = self.sqldata_buf
		asserts(#s <= self.sqllen, 'expected string of max. %d bytes', self.sqllen)
		buf:set(1,#s,'short')
		alien.memcpy(buf:topointer(1+SHORT_SIZE), s)
	else
		asserts(false, 'incompatible data type %s',self:type())
	end
	self.sqlind_buf:set(1,0,'int')
end

function xsqlvar_class:setpadded(s)
	if self.sqltype == 'SQL_TEXT' then
		self:setstring(s..(' '):rep(select(2,self:type())-#s))
	else
		self:setstring(s)
	end
end

function xsqlvar_class:getunpadded()
	if self.sqltype == 'SQL_TEXT' then
		return (self:getstring():gsub(' *$',''))
	else
		self:getstring()
	end
end

function xsqlvar_class:getblobid()
	asserts(self.sqltype == 'SQL_BLOB', 'incompatible data type %s', self:type())
	return self.sqldata_buf
end

function xsqlvar_class:setblobid(blob_id_buf)
	asserts(self.sqltype == 'SQL_BLOB', 'incompatible data type %s', self:type())
	if self.sqldata_buf ~= blob_id_buf then --this could be a newly created blob_id_buf
		alien.memcpy(self.sqldata_buf, blob_id_buf, self.buflen)
	end
	self.sqlind_buf:set(1,0,'int')
end

function xsqlvar_class:set(p)
	for _,f in ipairs(self.set_handlers) do
		if f(self,p,self:type()) then
			return
		end
	end
	asserts(false, 'set(%s) not available for type %s',xtype(p),self:type())
end

function xsqlvar_class:get()
	for _,f in ipairs(self.get_handlers) do
		local ok,x = f(self,self:type())
		if ok then
			return x
		end
	end
	asserts(false, 'get() not available for type %s',self:type())
end

function xsqlvar_class:add_get_handler(f)
	self.get_handlers[#self.get_handlers+1] = f
end

function xsqlvar_class:add_set_handler(f)
	self.set_handlers[#self.set_handlers+1] = f
end

xsqlvar_class.set_handlers = {}
xsqlvar_class.get_handlers = {}

xsqlvar_class:add_set_handler(
	function(self,p,typ,opt) --nil -> NULL
		if p == nil then
			self:setnull(p)
			return true
		end
	end
)

xsqlvar_class:add_set_handler(
	function(self,p,typ,opt) --indexable for time|date|timestamp -> settime()
		if (typ == 'time' or typ == 'date' or typ == 'timestamp')
			and applicable(p,'__index')
		then
			self:settime(p)
			return true
		end
	end
)

xsqlvar_class:add_set_handler(
	function(self,p,typ,opt) --indexable for all integers -> setparts({int,frac})
		if (typ == 'int16' or typ == 'int32' or typ == 'int64')
			and applicable(p,'__index')
		then
			self:setparts(p)
			return true
		end
	end
)

xsqlvar_class:add_set_handler(
	function(self,p,typ,opt) --number for all integers w/scale=0 -> setnumber()
		if (typ == 'float' or typ == 'double' or
				((typ == 'int16' or typ == 'int32' or typ == 'int64') and opt == 0))
			and type(p) == 'number' --no auto-coercion for numbers
		then
			self:setnumber(p)
			return true
		end
	end
)

xsqlvar_class:add_set_handler(
	function(self,p,typ,opt) --string for varchars
		if typ == 'varchar' and type(p) == 'string' then --no auto-coercion for strings
			self:setstring(p)
			return true
		end
	end
)

xsqlvar_class:add_set_handler(
	function(self,p,typ,opt) --string for chars
		if typ == 'char' and type(p) == 'string' then --no auto-coercion for strings
			self:setpadded(p)
			return true
		end
	end
)

xsqlvar_class:add_set_handler(
	function(self,p,typ,opt) --non-nil for SQL_NULL
		if typ == 'is_null' then
			if p == nil then
				self:setnull()
			else
				self:setnotnull()
			end
			return true
		end
	end
)

xsqlvar_class:add_set_handler(
	function(self,p,typ,opt) --boolean for all numeric types: true -> 1, false -> 0
		if type(p) == 'boolean' and
			(typ == 'float' or typ == 'double'
			or typ == 'int16' or typ == 'int32' or typ == 'int64')
		then
			self:setnumber(p and 1 or 0)
			return true
		end
	end
)

xsqlvar_class:add_get_handler(
	function(self,typ,opt)
		if self:isnull() then
			return true,nil
		end
	end
)

xsqlvar_class:add_get_handler(
	function(self,typ,opt)
		if typ == 'time' or typ == 'date' or typ == 'timestamp' then
			return true,self:gettime()
		end
	end
)

xsqlvar_class:add_get_handler(
	function(self,typ,opt)
		if typ == 'float' or typ == 'double' or
			((typ == 'int16' or typ == 'int32' or typ == 'int64') and opt == 0) then
			return true,self:getnumber()
		end
	end
)

xsqlvar_class:add_get_handler(
	function(self,typ,opt)
		if (typ == 'int16' or typ == 'int32' or typ == 'int64') and opt ~= 0 then
			return true,self:getparts()
		end
	end
)

xsqlvar_class:add_get_handler(
	function(self,typ,opt)
		if typ == 'varchar' then
			return true,self:getstring()
		end
	end
)

xsqlvar_class:add_get_handler(
	function(self,typ,opt)
		if typ == 'char' then
			return true,self:getunpadded()
		end
	end
)

xsqlvar_class:add_get_handler(
	function(self,typ,opt)
		if typ == 'is_null' then
			return true,not self:isnull() or nil
		end
	end
)

