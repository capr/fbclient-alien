--[[
	Setting up a testing environment for testing the fbclient package

	Supported combinations of fbclient, fbembed and fbserver versions are in the tables below.

	***** Unit Testing API: *****

	init([verbose=true]) -> initializes the following globals:
		OS
		tmpdir
		setup_lib(libname, version)
		deps { depname = module, ... } -> available dependencies
	combinations([included_combinations],[excluded_combinations]) ->
			-> combinations_t -> [i] -> test_combination = {lib=,ver=,server=,server_ver=}
	setup(test_combination) -> test_env; test_env = {database=,username=,password=,...,lots of fields,see code}
	unwrap(script,test_combination)
	wrap(f,cmdline_args)
	run(f_or_script_name,[included_combinations],[excluded_combinations],
												[cmdline_arg1,...]) -> total_ok_num,total_fail_num
		* if ... then call wrap(f,...)
		* if test_combination is missing, iterate through all combinations in combinations() table
		* if f is a script name, calls unwrap(f,setup(test_combination))
		* if f is a function, calls f(setup(test_combination))
		* f() can return ok_num,fail_num; 0,0 is implied if it doesn't
	test_env:create_test_db() -> attachment; creates the main test db and returns the attachment object
	test_env:create_test_db2() -> attachment; creates the secondary test db and returns the attachment object

	***** Prerequisites: *****

	- ./lua/modules/<dependent pure-lua modules>
	- ./<OS>/lua/modules/<dependent binary lua modules>
	- ./<OS>/lua/<lua interpreter executable>
	- firebird servers listening on specified ports on localhost

	Limitations:

	- uses current directory to form a full path for finding the firebird binaries,
	which means you have to run the test suite from the directory of this file.

	- run() is designed to either run a lua script in a sub-process or alua function in the same process
	for each test combination; currently though, only running a lua script is supported because:
		1) a bug in alien 0.5 which prevents having lib1.func1 and lib2.func1 in the same process space;
		2) a limitation of ldd.so which doesn't re-read LD_LIBRARY_PATH on every dlopen() call.

]]

module(...,package.seeall)

--start config section

lua_cmdline = nil
package_dir = './..'
fbclient_versions = {'2.5.0','2.1.3','2.0.6'}
fbembed_versions = fbclient_versions
servers = {
	{'localhost/3250','2.5.0'},
	{'localhost/3213','2.1.3'},
	{'localhost/3206','2.0.6'},
}
excluded_combinations = {}
dependencies = {'mapm', 'ldecNumber', 'bc'}

--end config section

local function keys(t)
	local r = {}
	for k in pairs(t) do r[#r+1] = k end
	return r
end

OS = nil
tmpdir = nil
pkgver = nil
deps = nil
setup_lib = nil

local original_package_cpath = package.cpath
local original_package_path = package.path

local function read(cmd)
	local f = io.popen(cmd)
	local s = f:read('*a')
	f:close()
	if string.sub(s,-1)=='\n' then
		s = string.sub(s,1,-2) --remove terminating newline
	end
	return s
end

function init(verbose)
	local _print=print; local function print(...) if verbose ~= false then _print(...) end end

	if OS then return end

	--setup require() to load binary libraries from ./win32/lua/modules first
	package.cpath = [[.\win32\lua\modules\?.dll;]]..original_package_cpath
	require 'alien.core'

	--detect OS
	local function DetectOS() --stolen from Asko Kauppi's hamster
		local plat = alien.core.platform
		if plat == 'windows' then
			return 'win32'
		elseif plat == 'linux' then
			local s = read('uname -m')
			if s:find'^x86_64' then
				return 'linux64'
			else
				return 'linux32'
			end
		else
			error('Unsupported platform '..plat)
		end
	end
	OS = DetectOS()
	print('Detected OS: '..OS)

	if OS == 'win32' then
		--on windows we setup require() to load dependent lua modules from .\lua\modules
		package.path = [[lua\modules\?.lua;]]..original_package_path
	end

	require 'alien'
	require 'alien.struct'
	require 'ex' --for os.setenv()

	--setup require() to load fbclient from package_dir
	--TODO: make this bit work again with luarocks 2.0 which doesn't need luarocks.require anymore !
	if package.loaded['luarocks.require'] then
		if pcall(require,'fbclient.version') then
			error('Cannot load fbclient package from '..package_dir..': fbclient is also installed on LuaRocks and luarocks.require was loaded.')
		end
	end
	package.path = package.path..';'..package_dir..'/lua/?.lua'

	--detect temp dir
	if OS == 'win32' then
		tmpdir = assert(os.getenv('TEMP'), 'Cannot set up a working directory: env. var %TEMP% is not set.')..'\\'
	elseif OS:find'^linux' then
		tmpdir = '/tmp/'
	end
	print('Detected temp dir: '..tmpdir)

	--setup lua command line for executing test scripts
	if OS == 'win32' then
		lua_cmdline = [[.\win32\lua\lua.exe -e "io.stdout:setvbuf 'no'"]]
	elseif OS:find'^linux' then
		lua_cmdline = [[lua -e "io.stdout:setvbuf 'no'"]]
	end
	print('Using lua command: '..lua_cmdline)

	--test require by getting fbclient version module
	pkgver = require 'fbclient.version'
	print('Detected fbclient package: fbclient v'..table.concat(pkgver, '.')..' at '..package_dir..'/lua/fbclient')

	--make setup_lib() function which prepares a specific version of fbclient.dll/.so and returns the libname to bind to
	if OS == 'win32' then
		--bind SetDllDirectory from kernel32.dll (available in WinXP SP1+ and Vista)
		--it's the official way in Windows to load a bunch of related dlls from a directory of your chosing.
		local kernel32 = alien.load('kernel32')
		local what = 'Cannot arrange loading of fbclient.dll from a specified path.\n'
		local ok,err = xpcall(function()
			kernel32.SetDllDirectoryA:types{ABI='stdcall',ret='int','string'}
		end, debug.traceback)
		if not ok then
			error(what..'A kernel32.dll with SetDllDirectoryA() (WinXP SP1+ or Vista) is needed.\n'..err)
		end

		--get current directory: SetDllDirectoryA needs an absolute path
		local cd = read('cd')
		cd = assert(cd,'Cannot detect current directory: `cd` command failed')

		function setup_lib(libname, version)
			path = cd..'\\win32\\'..(libname == 'fbembed' and 'fbembed' or 'firebird')..'-'..version
			binpath = path..(libname == 'fbembed' and '' or '\\bin')

			assert(kernel32.SetDllDirectoryA(nil) ~= 0, what..'SetDllDirectoryA() error')
			assert(kernel32.SetDllDirectoryA(binpath) ~= 0, what..'SetDllDirectoryA() error')

			os.setenv('FIREBIRD',path)
			assert(os.getenv('FIREBIRD')==path)

			return binpath..'\\'..libname..'.dll'
		end
	else
		function setup_lib(libname, version)
			local pwd = '.'
			local path = pwd..'/'..OS..'/'..'firebird'..'-'..version
			local libpath = path..'/lib'
			local libfilepath = libpath..'/lib'..libname..'.so.'..version

			os.setenv('FIREBIRD',path)
			assert(os.getenv('FIREBIRD')==path)

			return libfilepath
		end
	end

	--load optional dependencies
	deps = {}
	for i,depname in ipairs(dependencies) do
		local dep = pcall(require,depname)
		if not dep then
			print('NOTE: Optional dependent lua package '..depname..' not installed.')
		else
			deps[depname] = dep
		end
	end
	if (next(deps)) then
		print('Dependent modules loaded: '..table.concat(keys(deps), ', '))
	end
end

function combinations(included_comb,excluded_comb)
	local function combination_in(comb_array,lib,ver,server,server_ver)
		if not comb_array then
			return false
		end
		for i,c in ipairs(comb_array) do
			if (not c.lib or lib == c.lib)
				and (not c.ver or ver == c.ver)
				and (not c.server or server == c.server)
				and (not c.server_ver or server_ver == c.server_ver)
			then
				return true
			end
		end
	end
	included_comb = included_comb or {{}}
	local t = {}
	for i, ver in ipairs(fbclient_versions) do
		for j, st in ipairs(servers) do
			local server,server_ver = unpack(st)
			if combination_in(included_comb,'fbclient',ver,server,server_ver)
				and not combination_in(excluded_combinations,'fbclient',ver,server,server_ver)
				and not combination_in(excluded_comb,'fbclient',ver,server,server_ver)
			then
				t[#t+1] = {lib = 'fbclient', ver = ver, server = server, server_ver = server_ver}
			end
		end
	end
	for i, ver in ipairs(fbembed_versions) do
		if combination_in(included_comb,'fbembed',ver,nil,ver)
			and not combination_in(excluded_combinations,'fbembed',ver,nil,ver)
			and not combination_in(excluded_comb,'fbembed',ver,nil,ver)
		then
			t[#t+1] = {lib = 'fbembed', ver = ver, server = nil, server_ver = ver}
		end
	end
	return t
end

function setup_subprocess(comb)
	if OS:find'^linux' then
		local pwd = '.'
		local path = pwd..'/'..OS..'/'..'firebird'..'-'..comb.ver
		local libpath = path..'/lib'
		--this has no effect for loading a library in the current process, for which ldd.so
		--already read LD_LIBRARY_PATH and won't read it again on the next call to dlopen().
		--so we have to set LD_LIBRARY_PATH in the parent process and it gets inherited.
		os.setenv('LD_LIBRARY_PATH',libpath)
		assert(os.getenv('LD_LIBRARY_PATH')==libpath)
	end
end

test_env_class = {}
test_env_meta = {__index = test_env_class}

--prepare a testing environment and return it
function setup(comb)
	local libname = setup_lib(comb.lib, comb.ver)
	local database_file = tmpdir..'fbclient_test.fdb'
	local database2_file = tmpdir..'fbclient_test2.fdb'
	local database = (comb.server and comb.server..':' or '')..database_file
	local database2 = (comb.server and comb.server..':' or '')..database2_file
	local env = setmetatable({
		deps = deps,
		firebird_dir = os.getenv('FIREBIRD'),
		lib = comb.lib,
		libname = libname,
		ver = comb.ver,
		database = database,
		database2 = database2,
		database_file = database_file,
		database2_file = database2_file,
		server = comb.server,
		server_ver = comb.server_ver,
		username = 'SYSDBA',
		password = 'masterkey',
		dialect = 3,
		--gbak options
		backup_file1 = tmpdir..'test-backup.fbk01',
		backup_file2 = tmpdir..'test-backup.fbk02',
		backup_file_length = 1024*1024*3,
		--nbackup options
		nbackup_file0 = tmpdir..'test-nbackup.level0',
		nbackup_file1 = tmpdir..'test-nbackup.level1',
	}, test_env_meta)

		print(([[

Test environemnt for %s v%s%s:

	FIREBIRD:       %s
	libname:        %s
	database_file:  %s
	database2_file: %s
	database:       %s
	database2:      %s
	server:         %s
	username:       %s
	password:       %s
	dialect:        %d
	backup_file1:   %s
	backup_file2:   %s
	backup_file_length: %d
	nbackup_file0:  %s
	nbackup_file1:  %s

		]]):format(
			env.lib, env.ver, env.server and ' against '..env.server..' (v'..env.server_ver..')' or '',
			env.firebird_dir or '',
			env.libname,
			env.database_file,
			env.database2_file,
			env.database,
			env.database2,
			env.server or '',
			env.username,
			env.password,
			env.dialect,
			env.backup_file1,
			env.backup_file2,
			env.backup_file_length,
			env.nbackup_file0,
			env.nbackup_file1
		))

	return env
end

function wrap(f,...)
	if select('#',...) < 4 then
		print('Cmdline args expected: lib ver server server_ver.')
		print('Best to run this with config.unwrap() or config.run().')
		return
	end

	init(false)

	local env = setup({
		lib = select(1,...),
		ver = select(2,...),
		server = select(3,...) ~= '-' and select(3,...) or nil,
		server_ver = select(4,...)
	})
	local k,ok_num,fail_num = xpcall(function() return f(env) end,debug.traceback)
	if k then
		print('@@@ COUNTS',ok_num,fail_num)
	else
		print(ok_num)
		print('@@@ ERROR')
	end
end

function unwrap(script,comb)
	comb.server = comb.server or '-'
	local f = io.popen(lua_cmdline..' '..script..' '..comb.lib..' '..comb.ver..' '
									..comb.server..' '..comb.server_ver)
	local ok_num,fail_num = 0,0
	for s in f:lines() do
		if s:find('^@@@ COUNTS') then
			ok_num,fail_num = s:match('^@@@ COUNTS%s(%-?%d+)%s(%-?%d+)')
		elseif s:find('^@@@ ERROR') then
			f:close()
			error(s:match('^@@@ ERROR%s(.*)'))
		else
			print(s)
		end
	end
	f:close()
	return ok_num,fail_num
end

local function _run(f,comb)
	local ok_num,fail_num
	if type(f) == 'string' then --we have to run a lua test script
		setup_subprocess(comb)
		ok_num,fail_num = unwrap(f,comb)
	else -- we have to run a lua test function
		local env = setup(comb)
		ok_num,fail_num = f(env)
	end
	print(('Test summary: %d ok, %d failed'):format(ok_num or 0,fail_num or 0))
	return ok_num,fail_num
end

function run(f,included_comb,excluded_comb,...)
	if select('#',...) > 0 then
		wrap(f,...)
	else
		init(true)
		print('Testing combinations:')
		for i,c in ipairs(combinations(included_comb,excluded_comb)) do
			print('\t'..tostring(i)..' '..c.lib..' v'..c.ver..
					(c.server and ' against '..c.server..' (v'..c.server_ver..')' or ''))
		end

		local total_ok_num,total_fail_num = 0,0
		for i,comb in ipairs(combinations(included_comb,excluded_comb)) do
			local ok_num,fail_num = _run(f,comb)
			total_ok_num = total_ok_num + (ok_num or 0)
			total_fail_num = total_fail_num + (fail_num or 0)
		end
		print(('Total for all tests: %d ok, %d failed'):format(total_ok_num,total_fail_num))
		return total_ok_num,total_fail_num
	end
end

--test_env methods

function test_env_class:create_test_db(db, dbfile)
	local fb = require 'fbclient.class'
	db = db or self.database
	dbfile = dbfile or self.database_file

	--silently drop the test database in case it's still hanging around
	pcall(function()
		local db = fb.attach(db, self.username, self.password, nil, nil, nil, self.libname)
		db:drop()
	end)
	--just in case the attachment and/or drop fails for unrelated reasons...
	os.remove(dbfile)
	return fb.create_database(db, self.username, self.password, nil, nil, nil, nil, nil, self.libname)
end

function test_env_class:create_test_db2()
	return self:create_test_db(self.database2, self.database2_file)
end

