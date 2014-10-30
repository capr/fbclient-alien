#!/usr/bin/lua
--[[

	Testing unit for service_class.lua

	TODO: more test cases are needed:
	- test assertions and error conditions
	- list & repair of limbo transactions
	- test tracer with OS threads
	- bind & test fb_shutdown() (fbembed 2.5+)

]]

local config = require 'test_config'

function test_everything(env)
	require 'fbclient.error_codes'
	local service_class = require 'fbclient.service_class'
	local service_wrapper = require 'fbclient.service_wrapper'
	local util = require 'fbclient.util'
	local dump = util.dump
	local timeout = 2

	env:create_test_db():close()

	local svc = service_class.connect(env.server, env.username, env.password, timeout, env.libname)
	print(string.format('connect(%s, %s, %s, %s, %s)', env.server or '(embedded)', env.username, env.password, timeout, env.libname))

	local function dump_lines()
		for line_num,line in svc:lines() do
			print(line_num,line)
		end
	end

	local function dump_chunks()
		for i,chunk in svc:chunks() do
			io.write(chunk)
		end
	end

	local function test_server_info()
		--server methods without parameters
		local t = {
			'service_manager_version',
			'server_version',
			'server_implementation_string',
			'server_capabilities',
			'server_install_path',
			'server_lock_path',
			'server_msg_path',
		}
		if not config.OS:find'^linux' or (not env.server_ver:find'^2%.0' and not env.server_ver:find'^2%.1') then
			table.insert(t,'attachment_num')
			table.insert(t,'db_num')
		end
		for i,method in ipairs(t) do
			print(string.format('%s()',method),svc[method](svc))
			while svc:busy() do end
		end
		if not config.OS:find'^linux' or (not env.server_ver:find'^2%.0' and not env.server_ver:find'^2%.1') then
			print('db_names()'); dump(svc:db_names())
		end
	end

	local function test_get_fb_log()
		if config.OS:find'^linux' and (env.server_ver:find'^2%.0' or env.server_ver:find'^2%.1') then return end
		print('server_log()'); svc:server_log()
		dump_lines()
		while svc:busy() do end
	end

	local function test_backup()
		print(string.format('db_backup(%s,{%s,%d,%s})',env.database_file,env.backup_file1,env.backup_file_length,env.backup_file2))
		local bk = {env.backup_file1,env.backup_file_length,env.backup_file2}
		svc:db_backup(env.database_file,bk,{
				verbose=true,
				ignore_checksums=true,
				ignore_limbo=true,
				metadata_only=nil,
				no_garbage_collect=true,
				include_external_tables=nil,
			});
		dump_lines()

		print(string.format('db_restore({%s,%s},%s)',env.backup_file1,env.backup_file2,env.database_file))
		local bk = {env.backup_file1,env.backup_file2}
		svc:db_restore(bk,env.database_file,{
				verbose=true,
				page_buffers=100,
				page_size=1024*16,
				commit_each_table=true,
				force=true,
			});
		dump_lines()
	end

	local function test_repair()
		print(string.format('db_repair(%s)',env.database_file))
		svc:db_repair(env.database_file,{
				dont_fix=true,
				ignore_checksums=true,
				kill_shadows=true,
				full=true,
			}); dump_lines()
	end

	local function test_db_actions()
		--database methods with or without parameters
		for i,t in ipairs{
			{'db_stats'},
			{'db_sweep'},
			{'db_mend'},
			{'db_set_read_only',false},
			{'db_set_page_buffers',123},
			{'db_set_sweep_interval',1234},
			{'db_set_forced_writes',true},
			{'db_set_space_reservation',true},
			{'db_set_dialect',3},
			{'db_use_shadow'},
		} do
			local method = t[1]
			print(
				string.format('%s(%s)',method,env.database_file),
				svc[method](svc,env.database_file,select(2,unpack(t)))
			)
			dump_lines()
			while svc:busy() do end
		end
	end

	local function test_shutdown()
		if env.server_ver:find('^2%.1') then return end
		if env.server_ver:find('^2%.0') then return end

		svc:db_shutdown(env.database_file,30,'full','full')
		dump_lines(); while svc:busy() do end

		svc:db_activate(env.database_file,'normal')
		dump_lines(); while svc:busy() do end
	end

	local function test_user_actions()
		print('user_db_file()',svc:user_db_file())
		while svc:busy() do end

		if env.lib == 'fbembed' then return end

		pcall(function()
			svc:user_delete('test_user')
		end)
		pcall(function() while svc:busy() do end end)
		pcall(dump_lines)
		
		print('user_add()'); svc:user_add('test_user','123','Test','W','Foo')
		while svc:busy() do end
		print('user_update()'); svc:user_update('test_user','321','Test2','W2','Foo2')
		while svc:busy() do end

		print('user_list()');
		if env.server_ver:find('^2%.1') or env.server_ver:find('^2%.0') then
			for _ in svc:lines() do end --a bug in fb 2.0/2.1 needs this
		end
		dump(svc:user_list())
		while svc:busy() do end

		print('user_delete()'); svc:user_delete('test_user')
		while svc:busy() do end
	end

	local function test_rdb_mapping()
		if env.lib == 'fbembed' then return end
		if env.server_ver:find('^2%.1') then return end
		if env.server_ver:find('^2%.0') then return end

		print('rdbadmin_set_mapping()',svc:rdbadmin_set_mapping())
		while svc:busy() do end
		print('rdbadmin_drop_mapping()',svc:rdbadmin_drop_mapping())
		while svc:busy() do end
	end

	local function test_nbackup()
		if env.server_ver:find('^2%.1') then return end
		if env.server_ver:find('^2%.0') then return end

		print(string.format('db_nbackup(%s,%s,%d)',env.database_file,env.nbackup_file0,0))
		os.remove(env.nbackup_file0) --nbackup fails if backup file exists
		svc:db_nbackup(env.database_file,env.nbackup_file0,0,{
				no_triggers = true,
			}); dump_lines()

		print(string.format('db_nbackup(%s,%s,%d)',env.database_file,env.nbackup_file1,1))
		os.remove(env.nbackup_file1) --nbackup fails if backup file exists
		svc:db_nbackup(env.database_file,env.nbackup_file1,1,{
				no_triggers = true,
			}); dump_lines()

		print(string.format('db_nrestore({%s,%s},%s)',env.nbackup_file0,env.nbackup_file1,env.database_file))
		os.remove(env.database_file) --nbackup fails if database file exists
		svc:db_nrestore({env.nbackup_file0,env.nbackup_file1},env.database_file,{
				no_triggers = true,
			}); dump_lines()
	end

	--TODO: make a multi-threaded test case for this
	function test_trace()
		if env.server_ver:find('^2%.1') then return end
		if env.server_ver:find('^2%.0') then return end

		print('trace_start()'); svc:trace_start([[
		<database>
			enabled true
			log_connections true
			log_transactions true
			log_statement_prepare true
			log_statement_free true
			log_statement_start true
			log_statement_finish true
			log_procedure_start true
			log_procedure_finish true
			log_trigger_start true
			log_trigger_finish true
			log_context true
			print_plan true
			print_perf true
			log_dyn_requests true
			print_dyn true
			time_threshold 100
			max_sql_length 65535
			max_dyn_length 65535
			max_arg_length 65535
			max_arg_count 1000
		</database>
		<services>
			enabled true
			log_services true
		#note: the combination of log_services and log_service_query causes infinite loop (CORE-2733)
		#	log_service_query true
		</services>
		]],'my trace')
		print('trace_list()'); dump(svc:trace_list())
		print('trace_suspend()'); svc:trace_suspend(trace_id)
		print('trace_resume()'); svc:trace_resume(trace_id)
		print('trace_stop()'); svc:trace_stop(trace_id)
	end

	test_server_info()
	test_get_fb_log()
	test_backup()
	test_repair()
	test_db_actions()
	test_shutdown()
	test_user_actions()
	test_rdb_mapping()
	test_nbackup()
	--this blocks indefinitely: make some traffic on the test database if you wanna see any tracing info.
	--test_trace()

	svc:close()

	return 1,0
end

--local comb = {{lib='fbembed',ver='2.1.3'}}
config.run(test_everything,comb,nil,...)

