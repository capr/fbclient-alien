#!/usr/bin/lua
--[[
	Test unit for xsqlvar.lua and decimal_*.lua

	NOTE: blobs are not tested here.

]]

local config = require 'test_config'

function test_everything(env)
	local fb = require 'fbclient.class'

	if config.deps.mapm then require 'fbclient.decimal_lmapm' end
	if config.deps.ldecNumber then require 'fbclient.decimal_ldecnumber' end
	if config.deps.bc then require 'fbclient.decimal_lbc' end

	--lua numbers
	local NAN = 1e300000/1e300000
	local MINF = -1e300000
	local PINF = 1e300000
	local floats = {NAN,MINF,-0,0,1/2,PINF} -- NOTE: only 1/2^x values have the same precision in single and double floats!
	local doubles = {NAN,MINF,-0,0,0.4,1/2,PINF}
	local smallints = {-2^15,-0,1234,2^15-1}
	local integers = {-2^31,-0,123456789,2^31-1}
	local bigints = {-2^52,-0,123456789012345,2^52-1}
	local short_decimals = {-9999,-0,0,9999}
	local integer_decimals = {-999999999,-0,0,999999999}
	local bigint_decimals = {-999999999999999,-0,0,999999999999999}
	--number parts
	local P = (require 'fbclient.xsqlvar').mkparts
	local smallint_parts = {P{-9999,0},P{-0,-0},P{9999,0}}
	local integer_parts = {P{-999999999,0},P{-0,-0},P{999999999,0}}
	local bigint_parts = {P{-999999999999999,0},P{-0,-0},P{999999999999999,0}}
	local short_decimal_parts = {P{-99,99},P{-0,-0},P{99,99}}
	local integer_decimal_parts = {P{-9999,99999},P{-0,-0},P{9999,99999}}
	local bigint_decimal_parts = {P{-99999,9999999999},P{-0,-0},P{99999,9999999999}}
	--strings
	local function gen_s(len)
		local t = {}
		for i=1,len do
			t[#t+1] = string.char(math.random(('a'):byte(), ('z'):byte()))
		end
		return table.concat(t)
	end
	--date/times
	local T = (require 'fbclient.datetime').mktime
	local TS = (require 'fbclient.datetime').mktimestamp
	local D = (require 'fbclient.datetime').mkdate
	local timestamps = {TS{year=2009,month=12,day=31,hour=12,min=34,sec=56,sfrac=7895}}
	local dates = {D{year=2009,month=12,day=31}}
	local times = {T{hour=12,min=34,sec=56,sfrac=7895}}
	local var_strings = {gen_s(256),gen_s(128),'','x'}
	local fixed_strings = {gen_s(256),gen_s(256)}
	--bignums

	local bignum_support = (env.deps.mapm or env.deps.ldecNumber or env.deps.bc) and true or false

	local decnumbers = {}
	if _G['decNumber'] then
		decnumbers = {
			decNumber.tonumber('-999999999.999999999'),
			decNumber.tonumber('-123456789.123456789'),
			decNumber.tonumber(-0),
			decNumber.tonumber(0),
			decNumber.tonumber('123456789.123456789'),
			decNumber.tonumber('999999999.999999999')
		}
	end
	local mapm_numbers = {}
	if _G['mapm'] then
		mapm_numbers = {
			mapm.number('-999999999.999999999'),
			mapm.number('-123456789.123456789'),
			mapm.number('-0.000000001'),
			mapm.number(0),
			mapm.number('123456789.123456789'),
			mapm.number('999999999.999999999')
		}
	end
	local bc_numbers = {}
	if _G['bc'] then
		--WATCH OUT: unlike mapm, bc.digits() actually sets the decimal precision on which all library computations are made!
		bc.digits(9)
		bc_numbers = {
			bc.number('-999999999.999999999'),
			bc.number('-123456789.123456789'),
			bc.number('-0.000000001'),
			bc.number(0),
			bc.number('123456789.123456789'),
			bc.number('999999999.999999999')
		}
	end

	local function eq(x,y) return x ~= x and y ~= y or x == y end --eq() differs from `==` in that eq(NAN,NAN) is true
	local function stringeq(sval,pval,column) return sval == pval and column:getstringlength() == #pval end

	local tests = {
		{sql_type='integer',setter='setnull',getter='isnull',values={true}},
		{sql_type='integer',setter='set',getter='get',values={nil,n=1}},

		{sql_type='float',setter='setnumber',getter='getnumber',values=floats},
		{sql_type='float',setter='set',getter='get',values=floats},
		{sql_type='double precision',setter='setnumber',getter='getnumber',values=doubles},
		{sql_type='double precision',setter='set',getter='get',values=doubles},
		{sql_type='smallint',setter='setnumber',getter='getnumber',values=smallints},
		{sql_type='smallint',setter='set',getter='get',values=smallints},
		{sql_type='integer',setter='setnumber',getter='getnumber',values=integers},
		{sql_type='integer',setter='set',getter='get',values=integers},
		{sql_type='bigint',setter='setnumber',getter='getnumber',values=bigints},
		{sql_type='bigint',setter='set',getter='get',values=bigints},
		{sql_type='decimal(4,0)',setter='setnumber',getter='getnumber',values=short_decimals},
		{sql_type='decimal(9,0)',setter='setnumber',getter='getnumber',values=integer_decimals},
		{sql_type='decimal(15,0)',setter='setnumber',getter='getnumber',values=bigint_decimals},

		{sql_type='smallint',setter='setparts',getter='getparts',values=smallint_parts},
		{sql_type='integer',setter='setparts',getter='getparts',values=integer_parts},
		{sql_type='bigint',setter='setparts',getter='getparts',values=bigint_parts},
		{sql_type='decimal(4,2)',setter='setparts',getter='getparts',values=short_decimal_parts},
		{sql_type='decimal(9,5)',setter='setparts',getter='getparts',values=integer_decimal_parts},
		{sql_type='decimal(15,10)',setter='setparts',getter='getparts',values=bigint_decimal_parts},

		{sql_type='varchar(256)',setter='setstring',getter='getstring',values=var_strings,tester=stringeq},
		{sql_type='char(256)',setter='setstring',getter='getstring',values=fixed_strings,tester=stringeq},
		{sql_type='char(256)',setter='setpadded',getter='getunpadded',values=var_strings},
		{sql_type='timestamp',setter='settime',getter='gettime',values=timestamps},
		{sql_type='date',setter='settime',getter='gettime',values=dates},
		{sql_type='time',setter='settime',getter='gettime',values=times},

		{sql_type='decimal(18,9)',setter='setdecnumber',getter='getdecnumber',values=decnumbers},
		{sql_type='decimal(18,9)',setter='setmapm',getter='getmapm',values=mapm_numbers},
		{sql_type='decimal(18,9)',setter='setbc',getter='getbc',values=bc_numbers},
	}


	local at = env:create_test_db()
	print(at)

	local ok,fail=0,0

	for _,test in ipairs(tests) do
		pcall(function() at:exec_immediate('drop table test') end)
		local q = 'create table test(c '..test.sql_type..')'
		print(q)
		at:exec_immediate(q)
		local tr = at:start_transaction_ex()
		for i=1,test.values.n or #test.values do
			local pval = test.values[i]
			tr:exec('delete from test')
			local st = tr:prepare('insert into test (c) values (?) returning c')
			st.params[1][test.setter](st.params[1],pval)
			st:run()
			assert(st:fetch())
			local sval = st.columns[1][test.getter](st.columns[1])
			local tester = test.tester or eq
			local k = tester(pval,sval,st.columns[1])
			if k then ok=ok+1 else fail=fail+1 end
			print('test for type '..test.sql_type..' using '..test.getter..'/'..test.setter..': '
					..(k and 'ok, "'..tostring(sval)..'" == "'..tostring(pval)..'"'
							or 'failed, "'..tostring(sval)..'" ~= "'..tostring(pval)..'"'))
			assert(not st:fetch())
		end
		at:commit_all()
	end

	if
		not env.server_ver:find'^2%.0'
		and not env.server_ver:find'^2%.1'
		and not env.ver:find'^2%.0'
		and not env.ver:find'^2%.1'
	then
		--test SQL_NULL type (fbclient and fbserver 2.5+)
		at:exec_immediate('create table test_sql_null(c integer)')
		at:exec_immediate('insert into test_sql_null(c) values (1)')
		local tr = at:start_transaction('read')
		local st = tr:prepare('select c from test_sql_null where ? is null or c = ?')
		for i, c in st:exec(2,2) do assert(false) end
		assert(st:setparams(1,1):run():fetch())
		assert(st:setparams():run():fetch())
		tr:commit()
		ok=ok+1
	end

	at:close()
	at = nil
	collectgarbage('collect')
	assert(not next(fb.attachment_class.attachments))
	return ok,fail
end

--local comb = {{lib='fbembed',ver='2.1.3'}}
config.run(test_everything,comb,nil,...)

