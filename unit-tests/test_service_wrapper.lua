#!/usr/bin/lua
--[[

	Testing unit for service_wrapper.lua

	TODO: more test cases are needed:
	- test assertions and error conditions
	- make test cases for each combination of options that can be combined together (is this feasible?)
	- test list & repair of limbo transactions
	- test tracer with OS threads
	- bind & test fb_shutdown() (fbembed 2.5+)

]]

local config = require 'test_config'

function test_everything(env)
	local api = require 'fbclient.service_wrapper'
	require 'fbclient.error_codes'
	require 'fbclient.binding'
	require 'fbclient.status_vector'
	local util = require 'fbclient.util'
	local dump = util.dump
	local asserts = util.asserts

	local fbapi
	local sv

	local function attach()
		local spb_opts = {
			isc_spb_user_name = env.username,
			isc_spb_password = env.password,
		}
		-- NOTE: 'service_mgr' is just a required magic word that is part of the syntax
		local svh = api.attach(fbapi,sv,(env.server and env.server..':' or '')..'service_mgr',spb_opts)
		print('**** attached ****')
		return svh
	end

	local function detach(svh)
		api.detach(fbapi,sv,svh)
		print('**** detatched ****')
	end

	local function test_attachment(svh)

		local function wait()
			while true do
				local info = api.query(fbapi,sv,svh,{isc_info_svc_running=true},{isc_info_svc_timeout=5})
				if not info.isc_info_svc_running then break end
			end
		end

		-- query the response one line at a time
		local function query_action()
			local t,buf,buf_size
			while true do
				t,buf,buf_size = api.query(fbapi,sv,svh,{isc_info_svc_line=true},nil,buf,buf_size)
				if t.isc_info_svc_line == '' then
					break
				end
				print(t.isc_info_svc_line)
			end
		end

		-- query the response one buffer at a time
		local function query_action_faster()
			local t,buf,buf_size
			while true do
				t,buf,buf_size = api.query(fbapi,sv,svh,{isc_info_svc_to_eof=true},nil,buf,buf_size)
				if t.isc_info_svc_to_eof == '' then
					break
				end
				io.write(t.isc_info_svc_to_eof)
			end
		end

		local function test_info()
			print('**** test_info ****')
			dump(api.query(fbapi,sv,svh,{
				isc_info_svc_svr_db_info		= not config.OS:find'^linux' or (not env.server_ver:find'^2%.1' and not env.server_ver:find'^2%.0') or nil, --ok
				--isc_info_svc_get_license		= true, --not supported on firebird
				--isc_info_svc_get_license_mask	= true, --not supported on firebird
				isc_info_svc_get_config			= true, --nothing on firebird (marked TODO in jrd/svc.cpp)
				isc_info_svc_version			= true, --ok
				isc_info_svc_server_version		= true, --ok
				isc_info_svc_implementation		= true, --ok
				isc_info_svc_capabilities		= true, --ok
				isc_info_svc_user_dbpath		= true, --ok
				isc_info_svc_get_env			= true, --ok
				isc_info_svc_get_env_lock		= true, --ok
				isc_info_svc_get_env_msg		= true, --ok
				isc_info_svc_line				= nil,	--only in response to an action, so not now
				isc_info_svc_to_eof				= nil,	--only in response to an action, so not now
				--isc_info_svc_get_licensed_users	= true, --not supported on firebird
				isc_info_svc_limbo_trans		= nil,	--only in response to isc_action_svc_repair+isc_spb_rpr_list_limbo_trans
				isc_info_svc_running			= true, --ok
				isc_info_svc_get_users			= nil,	--only in response to isc_action_svc_display_user, so not now
			}, {isc_info_svc_timeout = 5}))

		end

		local function test_get_fb_log()
			if config.OS:find'^linux' and (env.server_ver:find'^2%.0' or env.server_ver:find'^2%.1') then return end
			print('**** test_get_fb_log ****')
			api.start(fbapi,sv,svh,'isc_action_svc_get_fb_log')
			query_action_faster()
		end

		local function test_backup()
			print('**** test_backup ****')
			api.start(fbapi,sv,svh,'isc_action_svc_backup', {
				isc_spb_dbname = env.database_file,
				isc_spb_bkp_file = {env.backup_file1, env.backup_file_length, env.backup_file2},
				isc_spb_verbose = true,
				isc_spb_bkp_factor = nil,-- blocking size for tape drives, whatever that means
				isc_spb_options = {
					isc_spb_bkp_ignore_checksums     = true,
					isc_spb_bkp_ignore_limbo         = true,
					isc_spb_bkp_metadata_only        = nil,
					isc_spb_bkp_no_garbage_collect   = true,
					isc_spb_bkp_old_descriptions     = nil,
					isc_spb_bkp_non_transportable    = nil,
					isc_spb_bkp_convert              = nil,
					isc_spb_bkp_expand               = nil, -- undocumented and unimplemented in firebird!
				},
			})
			query_action_faster()

			print('**** test_restore ****')
			api.start(fbapi,sv,svh,'isc_action_svc_restore', {
				isc_spb_bkp_file = {env.backup_file1, env.backup_file2},
				isc_spb_dbname = env.database_file,
				isc_spb_verbose = true,
				isc_spb_res_length = nil, -- TODO: what does this option do?
				isc_spb_res_buffers		= 128,
				isc_spb_res_page_size	= 1024*16,
				isc_spb_res_access_mode	= 'isc_spb_res_am_readwrite',
				isc_spb_options = {
					isc_spb_res_deactivate_idx	= nil,
					isc_spb_res_no_shadow		= nil,
					isc_spb_res_no_validity		= true,
					isc_spb_res_one_at_a_time	= true,
					isc_spb_res_replace			= true,
					isc_spb_res_create			= true,
					isc_spb_res_use_all_space	= nil,
				},
			})
			query_action_faster()
		end

		local function test_repair()
			print('**** test_repair ****')
			api.start(fbapi,sv,svh,'isc_action_svc_repair', {
				isc_spb_dbname = env.database_file,
				isc_spb_options = {
					isc_spb_rpr_validate_db			= true,
					isc_spb_rpr_sweep_db			= nil,
					isc_spb_rpr_mend_db				= nil,
					isc_spb_rpr_check_db			= true,
					isc_spb_rpr_ignore_checksum		= true,
					isc_spb_rpr_kill_shadows		= true,
					isc_spb_rpr_full				= true,
				},
			})
			query_action()
		end

		local function test_limbo_transactions()
			print('**** test_limbo_transactions ****')
			api.start(fbapi,sv,svh,'isc_action_svc_repair', {
				isc_spb_dbname = env.database_file,
				isc_spb_options = {isc_spb_rpr_list_limbo_trans=true},
			})

			query_action()
			dump(api.query(fbapi,sv,svh,{isc_info_svc_limbo_trans=true}))

			-- TODO: finish this: we need a way to generate some limbo transactions!
			do return end
			api.start(fbapi,sv,svh,'isc_action_svc_repair', {
				isc_spb_dbname					= env.database_file,
				isc_spb_rpr_commit_trans		= nil,
				isc_spb_rpr_rollback_trans		= true,
				isc_spb_rpr_recover_two_phase	= nil,
				isc_spb_tra_id					= 123,
			})
			query_action()
		end

		local function test_user_actions()
			if env.lib == 'fbembed' then return end --user actions not available on embedded server

			local user_db_file = api.query(fbapi,sv,svh,{isc_info_svc_user_dbpath=true}).isc_info_svc_user_dbpath

			pcall(function()
				api.start(fbapi,sv,svh,'isc_action_svc_delete_user',{isc_spb_sec_username='test_user'})
			end)
			pcall(function() wait() end)
			pcall(function() query_action() end)

			print('**** test_user_actions/add_user ****')
			api.start(fbapi,sv,svh,'isc_action_svc_add_user',{
				isc_spb_sec_username    = 'TEST_USER',
				isc_spb_sec_password    = '1234',
				isc_spb_sec_firstname   = 'Test',
				isc_spb_sec_middlename  = 'W',
				isc_spb_sec_lastname    = 'User',
				isc_spb_dbname          = user_db_file,
			})
			wait()

			local function test_display_all_users()
				print('**** test_user_actions/display_users (all) ****')
				query_action()--a bug in firebird 2.0/2.1 needs this so the output buffer gets cleared!
				api.start(fbapi,sv,svh,'isc_action_svc_display_user',{isc_spb_dbname=user_db_file})
				dump(api.query(fbapi,sv,svh,{isc_info_svc_get_users=true}))
				wait()
			end

			test_display_all_users()

			print('**** test_user_actions/modify_user ****')
			api.start(fbapi,sv,svh,'isc_action_svc_modify_user',{
				isc_spb_sec_username	= 'test_user',
				isc_spb_sec_password	= '12345',
				isc_spb_sec_firstname	= 'Test2',
				isc_spb_sec_middlename	= 'W2',
				isc_spb_sec_lastname	= 'User2',
				isc_spb_dbname          = user_db_file,
			})
			wait()

			local function test_display_user(user)
				print('**** test_user_actions/display_users (only for '..user..') ****')
				api.start(fbapi,sv,svh,'isc_action_svc_display_user',{
					isc_spb_sec_username = user,
					isc_spb_dbname       = user_db_file,
				})
				dump(api.query(fbapi,sv,svh,{isc_info_svc_get_users=true}))
				wait()
			end

			test_display_user('wrong_user')
			test_display_user('test_user')

			print('**** test_user_actions/del_user ****')
			api.start(fbapi,sv,svh,'isc_action_svc_delete_user',{
				isc_spb_sec_username = 'test_user',
				isc_spb_dbname       = user_db_file,
			})
			wait()
			query_action()
		end

		local function test_set_db_properties()
			print('**** test_set_db_properties ****')
			api.start(fbapi,sv,svh,'isc_action_svc_properties', {
				isc_spb_dbname						= env.database_file,
				isc_spb_prp_page_buffers			= 100,
				isc_spb_prp_sweep_interval			= 3600*24,
				isc_spb_prp_reserve_space			= 'isc_spb_prp_res',
				--isc_spb_prp_write_mode				= 'isc_spb_prp_wm_sync',
				--isc_spb_prp_access_mode				= 'isc_spb_prp_am_readwrite',
				--isc_spb_prp_set_sql_dialect			= 3,
				--isc_spb_options = {
				--	isc_spb_prp_activate  = true,
				--	isc_spb_prp_db_online = true,
				--},
			})
			query_action()
		end

		local function test_shutdown()
			if env.server_ver:find('^2%.1') then return end
			if env.server_ver:find('^2%.0') then return end

			print('**** test_shutdown/shutdown ****')
			api.start(fbapi,sv,svh,'isc_action_svc_properties', {
				isc_spb_dbname						= env.database_file,
				isc_spb_prp_shutdown_db				= 30, -- shutdown after all attachments close or after timeout
				--isc_spb_prp_deny_new_attachments	= 30, -- shutdown if no transactions till timeout; deny new attachments in the meantime
				--isc_spb_prp_deny_new_transactions	= 30, -- shutdown if no transactions till timeout; deny new transactions in the meantime
				isc_spb_prp_shutdown_mode			= 'isc_spb_prp_sm_full',
			})
			query_action()

			print('**** test_shutdown/online ****')
			api.start(fbapi,sv,svh,'isc_action_svc_properties', {
				isc_spb_dbname						= env.database_file,
				isc_spb_prp_online_mode				= 'isc_spb_prp_sm_normal',
			})
			query_action()
		end

		local function test_db_stats()
			print('**** test_db_stats ****')
			api.start(fbapi,sv,svh,'isc_action_svc_db_stats', {
				isc_spb_dbname = env.database_file,
				isc_spb_options = {
					isc_spb_sts_data_pages		= true,
					isc_spb_sts_hdr_pages		= nil,
					isc_spb_sts_idx_pages		= true,
					isc_spb_sts_sys_relations	= true,
					isc_spb_sts_record_versions	= true,
					isc_spb_sts_table			= nil,
					isc_spb_sts_nocreation		= nil,
				},
			})
			query_action()
		end

		local function test_trace()
			if env.server_ver:find('^2%.1') then return end
			if env.server_ver:find('^2%.0') then return end

			print('**** start_trace ****')
			api.start(fbapi,sv,svh,'isc_action_svc_trace_start',{
				isc_spb_trc_name = 'test trace session',
				isc_spb_trc_cfg  = [[
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
		]],
			})
			query_action()

			--TODO: never reaching this line. find a (multithreaded) way to finish this test automatically.
			print('**** test_trace/suspend ****')
			api.start(fbapi,sv,svh,'isc_action_svc_trace_suspend',{isc_spb_trc_id=trace_id})
			query_action()

			print('**** test_trace/resume ****')
			api.start(fbapi,sv,svh,'isc_action_svc_trace_resume',{isc_spb_trc_id=trace_id})
			query_action()

			print('**** test_trace/list ****')
			api.start(fbapi,sv,svh,'isc_action_svc_trace_list')
			query_action()

			print('**** test_trace/stop ****')
			api.start(fbapi,sv,svh,'isc_action_svc_trace_stop',{isc_spb_trc_id=trace_id})
			query_action()
		end

		local function test_rdb_mapping()
			if env.server_ver:find('^2%.1') then return end
			if env.server_ver:find('^2%.0') then return end
			if env.lib == 'fbembed' then return end

			print('**** test_rdb_mapping/set ****')
			api.start(fbapi,sv,svh,'isc_action_svc_set_mapping')
			query_action()

			print('**** test_rdb_mapping/drop ****')
			api.start(fbapi,sv,svh,'isc_action_svc_drop_mapping')
			query_action()
		end

		local function test_nbackup()
			if env.server_ver:find('^2%.1') then return end
			if env.server_ver:find('^2%.0') then return end
			if env.lib == 'fbembed' then return end

			print('**** test_nbackup/level0 ****')
			os.remove(env.nbackup_file0) --nbackup fails if backup file exists
			api.start(fbapi,sv,svh,'isc_action_svc_nbak', {
				isc_spb_dbname		= env.database_file,
				isc_spb_nbk_file	= env.nbackup_file0,
				isc_spb_nbk_level	= 0,
				isc_spb_options = {
					isc_spb_nbk_no_triggers = true,
				},
			})
			query_action()

			print('**** test_nbackup/level1 ****')
			os.remove(env.nbackup_file1) --nbackup fails if backup file exists
			api.start(fbapi,sv,svh,'isc_action_svc_nbak', {
				isc_spb_dbname		= env.database_file,
				isc_spb_nbk_file	= env.nbackup_file1,
				isc_spb_nbk_level	= 1,
				isc_spb_options = {
					isc_spb_nbk_no_triggers = true,
				},
			})
			query_action()

			print('**** test_nrestore ****')
			os.remove(env.database_file) --nbackup fails if database file exists
			api.start(fbapi,sv,svh,'isc_action_svc_nrest', {
				isc_spb_nbk_file	= {env.nbackup_file0, env.nbackup_file1},
				isc_spb_dbname		= env.database_file,
				isc_spb_options = {
					isc_spb_nbk_no_triggers = true,
				},
			})
			query_action()
		end

		test_info()
		test_get_fb_log()
		test_backup()
		test_repair()
		test_limbo_transactions()
		test_user_actions()
		test_set_db_properties()
		test_shutdown()
		test_db_stats()
		test_rdb_mapping()
		test_nbackup()
		--this blocks indefinitely: make some traffic on the test database if you wanna see any tracing info.
		--test_trace()
	end

	fbapi = fbclient.binding.new(env.libname)
	sv = fbclient.status_vector.new()

	env:create_test_db():close()

	svh = attach()
	test_attachment(svh)
	detach(svh)

	return 1,0
end

--local comb = {{lib='fbembed',ver='2.5.0'}}
--local comb = {{lib='fbclient',ver='2.0.5',server_ver='2.5.0'}}
config.run(test_everything,comb,nil,...)

