--[=[
	Fbclient procedural wrapper
	Based on Firebird's latest ibase.h with the help of the Interbase 6 API Guide.

	ib_version(fbapi) -> major,minor

	db_create(fbapi, sv, database, [dpb_options_t]) -> dbh
	db_create_sql(fbapi, sv, create_database_sql, dialect) -> dbh
	db_attach(fbapi, sv, database, [dpb_options_t]) -> dbh (see dpb.lua for options)
	db_detach(fbapi, sv, dbh)
	db_version(fbapi, sv, dbh) -> {line1,...}
	db_drop(fbapi, sv, dbh)
	db_info(fbapi, sv, dbh, options_t, [info_buf_len]) -> db_info_t (see db_info.lua for options)
	db_cancel_operation(fbapi, sv, dbh, ['fb_cancel_...']); see implementation below

	tr_start_multiple(fbapi, sv, {[dbh1]=tbp_options1_t|true,[dbh2]=tbp_options2_t|true,...}) -> trh
	tr_start(fbapi, sv, dbh, [tpb_options_t]) -> trh (see tpb.lua for options)
	tr_start_sql(fbapi, sv, dbh, set_transaction_sql, dialect) -> trh
	tr_commit_retaining(fbapi, sv, trh)
	tr_rollback_retaining(fbapi, sv, trh)
	tr_commit(fbapi, sv, trh)
	tr_rollback(fbapi, sv, trh)
	tr_info(fbapi, sv, trh, options_t, [info_buf_len]) -> tr_info_t (see tr_info.lua for options)

	dsql_execute_immediate(fbapi, sv, dbh, trh, sql, dialect)
	dsql_alloc_statement(fbapi, sv, dbh) -> sth
	dsql_free_statement(fbapi, sv, sth)
	dsql_set_cursor_name(fbapi, sv, sth, cursor_name)
	dsql_free_cursor(fbapi, sv, sth)
	dsql_prepare(fbapi, sv, dbh, trh, sth, sql, dialect, [in_xsqlda], [out_xsqlda], [xs_meta]) -> params_t, columns_t
	dsql_unprepare(fbapi, sv, sth)
	dsql_execute(fbapi, sv, trh, sth, [params_t])
	dsql_execute_returning(fbapi, sv, trh, sth, [params_t], columns_t)
	dsql_fetch(fbapi, sv, sth, out_state) -> true|false (true = OK, false = EOF)
	dsql_info(fbapi, sv, sth, options_t, [info_buf_len]) -> sql_info_t (see sql_info.lua for options)

	params_t[i] -> xsqlvar (see xsqlvar.lua); use set...() methods to set a param
	columns_t[i|column_alias_name] -> xsqlvar; use get...() methods to get the fetched value for a column

	columns_meta -> metatable of columns array returned by dsql_prepare()
	columns_meta.__type = 'fbclient columns'
	params_meta -> metatable of params array returned by dsql_prepare()
	params_meta.__type = 'fbclient params'

	USAGE/NOTES:
	- you might want to use class.lua, which is a higher level interface based on this wrapper.
	- all the functions here take a binding object (see binding.lua) as arg#1 to execute firebird API calls.
	- all attachments involved in a multi-database transaction should run on the same OS thread.
	- avoid sharing a connection between two threads, although fbclient itself is thread-safe from v2.5 on.
	against, and a status_vector buffer (see status_vector.lua) as arg#2 to report execution status (errors) on.
	- auxiliary wrapper functionality resides in other modules which you must require() yourself as needed:
		- binding.lua			creating fbclient alien binding objects (called fbapi objects)
		- status_vector.lua     creating status_vector buffers (abbreviated sv objects) and error handling API
		- blob.lua              blob procedural API and xsqlvar methods
		- decimal_*.lua         bignum procedural API and xsqlvar methods; depends on availability of bignum libraries
		- events.lua            events API
	- the following modules are loaded automatically when first needed:
		- db_info.lua           attachment info encoder & decoder
		- tr_info.lua           transaction info encoder & decoder
		- sql_info.lua          statement info encoder & decoder
		- blob_info.lua         blob info encoder & decoder
	- see test_wrapper.lua for complete coverage of all the functionality.

	LIMITATIONS:
	- db_create_sql() and dsql_execute_immediate() don't support input parameters,
	although the Firebird client API supports it.

]=]

module(...,require 'fbclient.module')

local svapi   = require 'fbclient.status_vector'
local dpb     = require 'fbclient.dpb'
local tpb     = require 'fbclient.tpb'
local xsqlda  = require 'fbclient.xsqlda'
local xsqlvar = require 'fbclient.xsqlvar'

local fbtry = svapi.try

function ib_version(fbapi) --returns major, minor
	checktype(fbapi,'alien library',1)

	return fbapi.isc_get_client_major_version(), fbapi.isc_get_client_minor_version()
end

function db_attach(fbapi, sv, dbname, opts)
	local dbh = alien.buffer(POINTER_SIZE)
	dbh:set(1,nil,'pointer') --important!
	local dpb_s = dpb.encode(opts)
	fbtry(fbapi, sv, 'isc_attach_database', #dbname, dbname, dbh, dpb_s and #dpb_s or 0, dpb_s)
	return dbh
end

function db_detach(fbapi, sv, dbh)
	fbtry(fbapi, sv, 'isc_detach_database', dbh)
end

function db_version(fbapi, dbh)
	checktype(fbapi,'alien library',1)
	ver={}
	local function helper(p,s)
		ver[#ver+1]=s
	end
	local cb = alien.callback(helper,'void','pointer','string')
	assert(fbapi.isc_version(dbh,cb,nil)==0,'isc_version() error')
	return ver
end

--returns a connected dbh just like db_attach().
function db_create(fbapi, sv, dbname, opts)
	checktype(dbname,'string',1)

	local dbh = alien.buffer(POINTER_SIZE)
	dbh:set(1,nil,'pointer') --important!
	local dpb_s = dpb.encode(opts)
	fbtry(fbapi, sv, 'isc_create_database', #dbname, dbname, dbh, dpb_s and #dpb_s or 0, dpb_s, 0)
	return dbh
end

--wrap around dsql_execute_immediate() for the CREATE DATABASE statement. returns a connected dbh.
--NOTE: you could make this support input parameters, but it doesn't worth the trouble.
function db_create_sql(fbapi, sv, sql, dialect)
	checktype(sql,'string',1)

	local dbh = alien.buffer(POINTER_SIZE)
	dbh:set(1,nil,'pointer') --important!
	fbtry(fbapi, sv, 'isc_dsql_execute_immediate', dbh, nil, #sql, sql, dialect, nil)
	return dbh
end

function db_drop(fbapi, sv, dbh)
	fbtry(fbapi, sv, 'isc_drop_database', dbh)
end

function db_info(fbapi, sv, dbh, opts, info_buf_len)
	local info = require 'fbclient.db_info' --this is a runtime dependency so as to not bloat the library!
	local opts, max_len = info.encode(opts)
	info_buf_len = math.min(MAX_SHORT, info_buf_len or max_len)
	local info_buf = alien.buffer(info_buf_len)
	fbtry(fbapi, sv, 'isc_database_info', dbh, #opts, opts, info_buf_len, info_buf)
	return info.decode(info_buf, info_buf_len, fbapi)
end

local fb_cancel_operation_enum = {
	fb_cancel_disable = 1, --disable any pending fb_cancel_raise
	fb_cancel_enable  = 2, --enable any pending fb_cancel_raise
	fb_cancel_raise   = 3, --cancel any request on db_handle ASAP (at the next rescheduling point), and return an error in the status_vector.
	fb_cancel_abort   = 4,
}

--ATTN: don't call this from the main thread (where the signal handler is registered)!
function db_cancel_operation(fbapi, sv, dbh, opt)
	asserts(type(sql)=='string', 'arg#1 string expected, got %s',type(sql))
	opts = asserts(fb_cancel_operation_enum[opts or 'fb_cancel_raise'], 'invalid option %s', opt)
	fbtry(fbapi, sv, 'fb_cancel_operation', dbh, opts)
end

local TEB = 'pip' --Transaction Existence Block: dbh*,#TPB,TPB*

--when no options are provided, {isc_tpb_write=true,isc_tpb_concurrency=true,isc_tpb_wait=true} is assumed by Firebird!
function tr_start_multiple(fbapi, sv, t)
	local n,a = 0,{}
	for dbh,opts in pairs(t) do
		if opts == true then opts = nil end
		a[#a+1] = dbh
		local tpb_str = tpb.encode(opts)
		a[#a+1] = tpb_str and #tpb_str or 0
		a[#a+1] = tpb_str and alien.buffer(tpb_str) or nil --we make a buffer to fixate tbp_str's address
		n=n+1
	end

	local TEB_ARRAY = '!4'..string.rep(TEB,n)
	local teb_buf = alien.buffer(struct.size(TEB_ARRAY))
	alien.memcpy(teb_buf, struct.pack(TEB_ARRAY, unpack(a)))

	local trh = alien.buffer(POINTER_SIZE)
	trh:set(1,nil,'pointer') --important!
	fbtry(fbapi, sv, 'isc_start_multiple', trh, n, teb_buf)
	return trh
end

function tr_start(fbapi, sv, dbh, opts)
	return tr_start_multiple(fbapi, sv, {[dbh]=opts or true})
end

--wrap around dsql_execute_immediate() for the SET TRANSACTION statement. returns a new transaction handle.
--there's no way to start transactions spanning multiple attachments with this one.
--NOTE: you could make this support input parameters, but it doesn't worth the trouble.
function tr_start_sql(fbapi, sv, dbh, sql, dialect)
	local trh = alien.buffer(POINTER_SIZE)
	trh:set(1,nil,'pointer') --important!
	fbtry(fbapi, sv, 'isc_dsql_execute_immediate', dbh, trh, #sql, sql, dialect, nil)
	return trh
end

function tr_commit_retaining(fbapi, sv, trh) fbtry(fbapi, sv, 'isc_commit_retaining', trh) end
function tr_rollback_retaining(fbapi, sv, trh) fbtry(fbapi, sv, 'isc_rollback_retaining', trh) end
function tr_commit(fbapi, sv, trh) fbtry(fbapi, sv, 'isc_commit_transaction', trh) end
function tr_rollback(fbapi, sv, trh) fbtry(fbapi, sv, 'isc_rollback_transaction', trh) end

function tr_info(fbapi, sv, trh, opts, info_buf_len)
	local info = require 'fbclient.tr_info' --this is a runtime dependency so as to not bloat the library!
	local opts, max_len = info.encode(opts)
	info_buf_len = math.min(MAX_SHORT, info_buf_len or max_len)
	local info_buf = alien.buffer(info_buf_len)
	fbtry(fbapi, sv, 'isc_transaction_info', trh, #opts, opts, info_buf_len, info_buf)
	return info.decode(info_buf, info_buf_len)
end

--NOTE: this can be made to support input parameters and result values.
function dsql_execute_immediate(fbapi, sv, dbh, trh, sql, dialect)
	fbtry(fbapi, sv, 'isc_dsql_execute_immediate', dbh, trh, #sql, sql, dialect, nil)
end

--use this to prepare and execute prepared queries against dbh.
function dsql_alloc_statement(fbapi, sv, dbh)
	local sth = alien.buffer(POINTER_SIZE)
	sth:set(1,nil,'pointer')
	fbtry(fbapi, sv, 'isc_dsql_alloc_statement2', dbh, sth)
	return sth
end

--frees a statement allocated with dsql_alloc_statement()
function dsql_free_statement(fbapi, sv, sth)
	fbtry(fbapi, sv, 'isc_dsql_free_statement', sth, 2)
end

columns_meta = {__type = 'fbclient columns'}
params_meta = {__type = 'fbclient params'}

local XSQLDA = {}

--returns in_t,out_t which are arrays of xsqlvar: in_t is for parameters and out_t for returned values.
--additionally you can use out_t[alias_name] to access a column by alias.
--you might wanna pre-allocate the in_xsqlda and out_xsqlda for lil'less library calls (one xsqlvar
--is 152 bytes), or you can give back the ones returned in in_t/out_t by a previous call to dsql_prepare().
function dsql_prepare(fbapi, sv, dbh, trh, sth, sql, dialect, in_xsqlda, out_xsqlda, xs_meta)

	--prepare statement, getting the number of output columns, and eventually filling the xsqlvars
	out_xsqlda = out_xsqlda or xsqlda.new(0)
	fbtry(fbapi, sv, 'isc_dsql_prepare', trh, sth, #sql, sql, dialect, out_xsqlda)
	--see if the xsqlda is long enough to keep all columns, and if not, reallocate and re-describe.
	local alloc,used = xsqlda.decode(out_xsqlda)
	if alloc < used then
		out_xsqlda = xsqlda.new(used)
		fbtry(fbapi, sv, 'isc_dsql_describe', sth, 1, out_xsqlda)
	end

	--allocate sqldata buffers for each output column, according to the xsqlvar description.
	local out_t = {}
	for i=1,used do
		local xsqlvar_ptr = xsqlda.xsqlvar_get(out_xsqlda,i)
		local xs = xsqlda.xsqlvar_alloc(xsqlvar_ptr)
		xs = xsqlvar.wrap(xs, fbapi, sv, dbh, trh, xs_meta)
		out_t[i] = xs
		if xs.column_alias_name then
			out_t[xs.column_alias_name] = xs
		end
	end
	out_t[XSQLDA] = out_xsqlda --pin it so it won't get garbage-collected
	setmetatable(out_t, columns_meta)

	--describe parameter placeholders, getting the number of parameters, and eventually filling the xsqlvars.
	in_xsqlda = in_xsqlda or xsqlda.new(0)
	fbtry(fbapi, sv, 'isc_dsql_describe_bind', sth, 1, in_xsqlda)

	--see if the xsqlda is long enough to keep all parameters, and if not, reallocate and re-describe.
	local alloc,used = xsqlda.decode(in_xsqlda)
	if alloc < used then
		in_xsqlda = xsqlda.new(used)
		fbtry(fbapi, sv, 'isc_dsql_describe_bind', sth, 1, in_xsqlda)
	end

	--allocate sqldata buffers for each parameter, according to the xsqlvar description.
	local in_t = {}
	for i=1,used do
		local xsqlvar_ptr = xsqlda.xsqlvar_get(in_xsqlda,i)
		local xs = xsqlda.xsqlvar_alloc(xsqlvar_ptr)
		xs = xsqlvar.wrap(xs, fbapi, sv, dbh, trh, xs_meta)
		in_t[i] = xs
	end
	in_t[XSQLDA] = in_xsqlda --pin it so it won't get garbage-collected
	setmetatable(in_t, params_meta)

	return in_t, out_t
end

--unprepares a statement without free'ing the statement handle; fb 2.5+
function dsql_unprepare(fbapi, sv, sth)
	fbtry(fbapi, sv, 'isc_dsql_free_statement', sth, 4)
end

--call it on a prepared statement.
function dsql_set_cursor_name(fbapi, sv, sth, cursor_name)
	fbtry(fbapi, sv, 'isc_dsql_set_cursor_name', sth, cursor_name, 0)
end

--frees a cursor created by dsql_set_cursor_name()
function dsql_free_cursor(fbapi, sv, sth)
	fbtry(fbapi, sv, 'isc_dsql_free_statement', sth, 1)
end

--call it on a prepared statement. set in_t[i] values first, if any.
function dsql_execute(fbapi, sv, trh, sth, in_t)
	fbtry(fbapi, sv, 'isc_dsql_execute', trh, sth, 1, in_t and in_t[XSQLDA])
end

--call it on a prepared statement. set in_t[i] values before, if any. read out_t[i|alias] values after.
function dsql_execute_returning(fbapi, sv, trh, sth, in_t, out_t)
	fbtry(fbapi, sv, 'isc_dsql_execute2', trh, sth, 1, in_t and in_t[XSQLDA], out_t[XSQLDA])
end

--call this on an executed statement. then read the out_t[i] values.
--note that only select statements return a cursor to fetch from!
function dsql_fetch(fbapi, sv, sth, out_t)
	local status = fbtry(fbapi, sv, 'isc_dsql_fetch', sth, 1, out_t[XSQLDA])
	assert(status == 0 or status == 100)
	return status == 0
end

function dsql_info(fbapi, sv, sth, opts, info_buf_len)
	local info = require 'fbclient.sql_info' --this is a runtime dependency so as to not bloat the library!
	local opts, max_len = info.encode(opts)
	info_buf_len = math.min(MAX_SHORT, info_buf_len or max_len)
	local info_buf = alien.buffer(info_buf_len)
	fbtry(fbapi, sv, 'isc_dsql_sql_info', sth, #opts, opts, info_buf_len, info_buf)
	return info.decode(info_buf, info_buf_len)
end

