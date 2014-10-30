--[[
	STATUS_VECTOR structure: encapsulate error reporting for all firebird functions

	new() -> sv

	status(sv) -> true|nil,errcode
	full_status(fbapi, sv) -> true|nil,full_error_message
	errors(fbapi, sv) -> {err_msg1,...}
	sqlcode(fbapi, sv) -> n; deprecated in favor of sqlstate() in firebird 2.5+
	sqlstate(fbapi, sv) -> s; SQL-2003 compliant SQLSTATE code; fbclient 2.5+ firebird 2.5+
	sqlerror(fbapi, sqlcode) -> sql_error_message

	pcall(fbapi, sv, fname, ...) -> true,status|false,full_error_message
	try(fbapi, sv, fname, ...) -> status; breaks on errors with full_error_message

	USAGE:
	use new() to get you a new status_vector, then you can use any Firebird API function
	with it (arg#1). then check out status() to see if the function failed, and if so, call errors(), etc.
	to grab the errors. alternatively, use pcall() with any firebird function, which follows
	the lua protocol for failing, or use try() to make them break directly.
	on success, the status code returned by the function is returned (rarely used).

	TODO:
	- error_codes(b, sv) -> {errtype=errcode|errmsg,...}

]]

module(...,require 'fbclient.module')

local binding = require 'fbclient.binding'

--to be used by error_codes()
local codes = {
	isc_arg_end			= 0,	-- end of argument list
	isc_arg_gds			= 1,	-- generic DSRI (means Interbase) status value
	isc_arg_string		= 2,	-- string argument
	isc_arg_cstring		= 3,	-- count & string argument
	isc_arg_number		= 4,	-- numeric argument (long)
	isc_arg_interpreted	= 5,	-- interpreted status code (string)
	isc_arg_vms			= 6,	-- VAX/VMS status code (long)
	isc_arg_unix		= 7,	-- UNIX error code
	isc_arg_domain		= 8,	-- Apollo/Domain error code
	isc_arg_dos			= 9,	-- MSDOS/OS2 error code
	isc_arg_mpexl		= 10,	-- HP MPE/XL error code
	isc_arg_mpexl_ipc	= 11,	-- HP MPE/XL IPC error code
	isc_arg_next_mach	= 15,	-- NeXT/Mach error code
	isc_arg_netware		= 16,	-- NetWare error code
	isc_arg_win32		= 17,	-- Win32 error code
	isc_arg_warning		= 18,	-- warning argument
}

function new()
	return alien.buffer(struct.size('i')*20)
end

-- this function is made so you can do assert(status(sv)) after each firebird call.
function status(sv)
	--checktype(sv,'alien buffer',1)

	s0, s1 = struct.unpack('ii', sv, struct.size('ii'))
	return not (s0 == 1 and s1 ~= 0), s1
end

-- use this only if status() returns false.
function errors(fbapi, sv)
	checktype(fbapi,'alien library',1)
	--checktype(sv,'alien buffer',2)

	local errlist = {}
	local msg = alien.buffer(2048)
	local psv = alien.buffer(POINTER_SIZE)
	psv:set(1, sv:topointer(), 'pointer')
	while fbapi.fb_interpret(msg, 2048, psv) ~= 0 do
		errlist[#errlist+1] = msg:tostring()
	end
	return errlist
end

-- use this if status() returns false.
function sqlcode(fbapi, sv)
	return fbapi.isc_sqlcode(sv)
end

-- use this if status() returns false.
function sqlstate(fbapi, sv)
	checktype(fbapi,'alien library',1)
	--checktype(sv,'alien buffer',2)

	local sqlstate_buf = alien.buffer(6)
	fbapi.fb_sqlstate(sqlstate_buf, sv)
	return sqlstate_buf:tostring(5)
end

-- use this if status() returns false.
function sqlerror(fbapi, sqlcode)
	checktype(fbapi,'alien library',1)

	local msg = alien.buffer(2048)
	fbapi.isc_sql_interprete(sqlcode, msg, 2048)
	return msg:tostring()
end

function full_status(fbapi, sv)
	checktype(fbapi,'alien library',1)
	--checktype(sv,'alien buffer',2)

	local ok,err = status(sv)
	if not ok then
		local errcodes = package.loaded['fbclient.error_codes']
		if errcodes then
			local err_name = errcodes[err]
			if err_name then
				err = err_name..' ['..err..']'
			end
		end
		local errlist = errors(fbapi, sv)
		local sqlcod = sqlcode(fbapi, sv)
		--TODO: include sqlstate() only if supported in the client library: local sqlstat = sqlstate(fbapi, sv)
		local sqlerr = sqlerror(fbapi, sqlcod)
		err = 'error '..err..': '..table.concat(errlist,'\n')..
				'\nSQLCODE = '..(sqlcod or '<none>')..(sqlerr and ', '..sqlerr or '')
	end
	return ok,err
end

-- calls fname (which is the name of a firebird API function) in "protected mode",
-- following the return protocol of lua's pcall
function pcall(fbapi, sv, fname,...)
	checktype(fbapi,'alien library',1)
	--checktype(sv,'alien buffer',2)
	checktype(fname,'string',3)

	local status = fbapi[fname](sv,...)
	ok,err = full_status(fbapi, sv)
	if ok then
		return true,status
	else
		return false,fname..'() '..err
	end
end

function try(fbapi, sv, fname,...)
	local ok,result = pcall(fbapi, sv, fname,...)
	if ok then
		return result
	else
		error(result, 3)
	end
end

