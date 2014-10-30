--[=[
	Service Manager API, objectual interface based on service.lua

	connect([hostname],[username],[password],[timeout_sec],[libname|fbapi],[svc_class]) -> svo
	connect_ex([hostname],[spb_options_t],[libname|fbapi],[svc_class) -> svo

	service_class -> the LOOP class that svo objects inherit.

	svo.sv -> the status_vector object with which all calls are made.
	svo.fbapi -> the binding object onto which all calls are made.
	svo.timeout -> the timeout value against which all queries are made. you can change it between queries.

	svo:close()

	svo:lines() -> line_iterator -> line_num,line
	svo:chunks() -> chunk_iterator -> chunk_num,chunk

	svo:service_manager_version() -> n; currently 2
	svo:busy() -> boolean

	svo:server_version() -> s
	svo:server_implementation_string() -> s
	svo:server_capabilities() -> caps_t (pair() it out to see)
	svo:server_install_path() -> s
	svo:server_lock_path() -> s
	svo:server_msg_path() -> s
	svo:server_log() -> svo; use lines() or chunks() to get the output

	svo:attachment_num() -> n
	svo:db_num() -> n
	svo:db_names() -> name_t

	svo:db_stats(dbname,[options_t]) -> svo; use lines() or chunks() to get the output
	svo:db_backup(dbname,backup_file|backup_file_t,[options_t]) -> svo
	svo:db_restore(backup_file|backup_file_list,db_file,[options_t]) -> svo
	svo:db_repair(dbname,[options_t])
	svo:db_sweep(dbname)
	svo:db_mend(dbname)
	svo:db_nbackup(dbname,backup_file,[nbackup_level=0],[options_t]) --firebird 2.5+
	svo:db_nrestore(backup_file|backup_file_list,db_file,[options_t]) --firebird 2.5+

	svo:db_set_page_buffers(dbname,page_buffer_num)
	svo:db_set_sweep_interval(dbname,sweep_interval)
	svo:db_set_forced_writes(dbname,true|false)
	svo:db_set_space_reservation(dbname,true|false)
	svo:db_set_read_only(dbname,true|false)
	svo:db_set_dialect(dbname,dialect)

	svo:db_shutdown(dbname,timeout_sec,[force_mode],[shutdown_mode])
	svo:db_activate(dbname,[online_mode])
	svo:db_use_shadow(dbname)

	--user management API (user_db_file option is fb 2.5+)
	svo:user_db_file() -> s
	svo:user_list([user_db_file]) -> t[username] -> user_t
	svo:user_list(username,[user_db_file]) -> user_t
	svo:user_add(username,password,first_name,middle_name,last_name,[user_db_file])
	svo:user_update(username,password,first_name,middle_name,last_name,[user_db_file])
	svo:user_delete(username,[user_db_file])

	--trace API: firebird 2.5+
	svo:trace_start(trace_config_string,[trace_name]) -> svo; use lines() or chunks() to get the output
	svo:trace_list() -> trace_list_t
	svo:trace_suspend(trace_id)
	svo:trace_resume(trace_id)
	svo:trace_stop(trace_id)

	--enable/disable the RDB$ADMIN role for the appointed OS user for a service request to access security2.fdb.
	--firebird 2.5+
	svo:rdbadmin_set_mapping()
	svo:rdbadmin_drop_maping()

	USAGE/NOTES:
	- the functions db_backup() and db_restore() with verbose option on, as well as db_stats(),
	server_log(), trace_start(), do not return any output directly. instead you must use the lines()
	or chunks() iterators to get their output either line by line or chunk by chunk.

]=]

module(...,require 'fbclient.module')

local binding = require 'fbclient.binding'
local svapi = require 'fbclient.status_vector'
local api = require 'fbclient.service_wrapper'
local oo = require 'loop.base'

service_class = oo.class()

function connect(hostname, user, pass, timeout, fbapi, svc_class)
	local spb_opts = {
		isc_spb_user_name = user,
		isc_spb_password = pass,
	}
	return connect_ex(hostname, spb_opts, timeout, fbapi, svc_class)
end

function connect_ex(hostname, spb_opts, timeout, fbapi, svc_class)
	svc_class = svc_class or service_class
	fbapi = xtype(fbapi) == 'alien library' and fbapi or binding.new(fbapi or 'fbclient')
	local service_name = (hostname and hostname..':' or '')..'service_mgr'
	local sv = svapi.new()
	local svo = svc_class {
		fbapi = fbapi,
		sv = sv,
		timeout = timeout,
	}
	svo.handler = api.attach(fbapi, sv, service_name, spb_opts)
	return svo
end

function service_class:close()
	return api.detach(self.fbapi,self.sv,self.handler)
end

local function line_iterator(state,var)
	local info
	info,state.buf,state.buf_size =
		api.query(state.self.fbapi,state.self.sv,state.self.handler,{isc_info_svc_line=true},{isc_info_svc_timeout=state.self.timeout},state.buf,state.buf_size)
	if info.isc_info_svc_line == '' then
		return nil
	else
		return var+1,info.isc_info_svc_line
	end
end

function service_class:lines()
	return line_iterator,{self=self},0
end

local function chunk_iterator(state,var)
	local info
	info,state.buf,state.buf_size =
		api.query(state.self.fbapi,state.self.sv,state.self.handler,{isc_info_svc_to_eof=true},{isc_info_svc_timeout=state.self.timeout},state.buf,state.buf_size)
	if info.isc_info_svc_to_eof == '' then
		return nil
	else
		return var+1,info.isc_info_svc_to_eof
	end
end

function service_class:chunks()
	return chunk_iterator,{self=self},0
end

--about the service manager

function service_class:service_manager_version()
	local info = api.query(self.fbapi,self.sv,self.handler,{isc_info_svc_version=true},{isc_info_svc_timeout=self.timeout})
	return info.isc_info_svc_version
end

function service_class:busy()
	local info = api.query(self.fbapi,self.sv,self.handler,{isc_info_svc_running=true},{isc_info_svc_timeout=self.timeout})
	return info.isc_info_svc_running
end

--about the server

function service_class:server_version()
	local info = api.query(self.fbapi,self.sv,self.handler,{isc_info_svc_server_version=true},{isc_info_svc_timeout=self.timeout})
	return info.isc_info_svc_server_version
end

function service_class:server_implementation_string()
	local info = api.query(self.fbapi,self.sv,self.handler,{isc_info_svc_implementation=true},{isc_info_svc_timeout=self.timeout})
	return info.isc_info_svc_implementation
end

function service_class:server_capabilities()
	local info = api.query(self.fbapi,self.sv,self.handler,{isc_info_svc_capabilities=true},{isc_info_svc_timeout=self.timeout})
	return info.isc_info_svc_capabilities
end

function service_class:server_install_path()
	local info = api.query(self.fbapi,self.sv,self.handler,{isc_info_svc_get_env=true},{isc_info_svc_timeout=self.timeout})
	return info.isc_info_svc_get_env
end

function service_class:server_lock_path()
	local info = api.query(self.fbapi,self.sv,self.handler,{isc_info_svc_get_env_lock=true},{isc_info_svc_timeout=self.timeout})
	return info.isc_info_svc_get_env_lock
end

function service_class:server_msg_path()
	local info = api.query(self.fbapi,self.sv,self.handler,{isc_info_svc_get_env_msg=true},{isc_info_svc_timeout=self.timeout})
	return info.isc_info_svc_get_env_msg
end

function service_class:server_log()
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_get_fb_log')
	return self
end

--about databases

function service_class:attachment_num()
	local info = api.query(self.fbapi,self.sv,self.handler,{isc_info_svc_svr_db_info=true},{isc_info_svc_timeout=self.timeout})
	return info.isc_info_svc_svr_db_info.isc_spb_num_att[1]
end

function service_class:db_num()
	local info = api.query(self.fbapi,self.sv,self.handler,{isc_info_svc_svr_db_info=true},{isc_info_svc_timeout=self.timeout})
	return info.isc_info_svc_svr_db_info.isc_spb_num_db[1]
end

function service_class:db_names()
	local info = api.query(self.fbapi,self.sv,self.handler,{isc_info_svc_svr_db_info=true},{isc_info_svc_timeout=self.timeout})
	return info.isc_info_svc_svr_db_info.isc_spb_dbname --this is an array
end

function service_class:db_stats(db_name,opts)
	opts = opts or {}
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_db_stats', {
		isc_spb_dbname = db_name,
		isc_spb_options = {
			isc_spb_sts_hdr_pages		= opts.header_page_only, --this option is exclusive, unlike others
			isc_spb_sts_data_pages		= opts.data_pages,
			isc_spb_sts_idx_pages		= opts.index_pages,
			isc_spb_sts_record_versions	= opts.record_versions,
			isc_spb_sts_sys_relations	= opts.include_system_tables,
		},
	})
	return self
end

--operations on a database

function service_class:db_backup(db_name,backup_file,opts)
	opts = opts or {}
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_backup', {
		isc_spb_dbname = db_name,
		isc_spb_bkp_file = backup_file,
		isc_spb_verbose = opts.verbose,
		isc_spb_options = {
			isc_spb_bkp_ignore_checksums     = opts.ignore_checksums,
			isc_spb_bkp_ignore_limbo         = opts.ignore_limbo,
			isc_spb_bkp_metadata_only        = opts.metadata_only,
			isc_spb_bkp_no_garbage_collect   = opts.no_garbage_collect,
			isc_spb_bkp_old_descriptions     = opts.old_descriptions,		--don't use this option
			isc_spb_bkp_non_transportable    = opts.non_transportable,		--don't use this option
			isc_spb_bkp_convert              = opts.include_external_tables,
		},
	})
	return self
end

function service_class:db_restore(backup_file,db_file,opts)
	opts = opts or {}
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_restore', {
		isc_spb_bkp_file		= backup_file,
		isc_spb_dbname			= db_file,
		isc_spb_verbose			= opts.verbose,
		isc_spb_res_buffers		= opts.page_buffers,
		isc_spb_res_page_size	= opts.page_size,
		isc_spb_res_access_mode = opts.read_only and 'isc_spb_prp_am_readonly'
									or opts.read_only == false and 'isc_spb_prp_am_readwrite'
										or nil,
		isc_spb_options = {
			isc_spb_res_deactivate_idx	= opts.dont_build_indexes,
			isc_spb_res_no_shadow		= opts.dont_recreate_shadow_files,
			isc_spb_res_no_validity		= opts.dont_validate,
			isc_spb_res_one_at_a_time	= opts.commit_each_table,
			isc_spb_res_replace			= opts.force,
			isc_spb_res_create			= not opts.force or nil,
			isc_spb_res_use_all_space	= opts.no_space_reservation,
		},
	})
	return self
end

function service_class:db_nbackup(db_name,backup_file,nbackup_level,opts) --firebird 2.5+
	nbackup_level = nbackup_level or 0
	opts = opts or {}
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_nbak',{
		isc_spb_dbname		= db_name,
		isc_spb_nbk_file	= backup_file,
		isc_spb_nbk_level	= nbackup_level,
		isc_spb_options = {
			isc_spb_nbk_no_triggers = opts.no_triggers,
		},
	})
end

function service_class:db_nrestore(backup_file_list,db_file,opts) --firebird 2.5+
	if type(backup_file_list) == 'string' then
		backup_file_list = {backup_file_list}
	end
	opts = opts or {}
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_nrest', {
		isc_spb_nbk_file	= backup_file_list,
		isc_spb_dbname		= db_file,
		isc_spb_options = {
			isc_spb_nbk_no_triggers = opts.no_triggers,
		},
	})
end

function service_class:db_repair(db_name,opts)
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_repair', {
		isc_spb_dbname = db_name,
		isc_spb_options = {
			isc_spb_rpr_validate_db		= true,
			isc_spb_rpr_check_db		= opts.dont_fix,
			isc_spb_rpr_ignore_checksum	= opts.ignore_checksums,
			isc_spb_rpr_kill_shadows	= opts.kill_shadows,
			isc_spb_rpr_full			= opts.full,
		},
	})
end

function service_class:db_sweep(db_name)
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_repair', {
		isc_spb_dbname = db_name,
		isc_spb_options = {isc_spb_rpr_sweep_db = true},
	})
end

function service_class:db_mend(db_name,opts)
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_repair', {
		isc_spb_dbname = db_name,
		isc_spb_options = {isc_spb_rpr_mend_db = true},
	})
end

function service_class:db_set_page_buffers(db_name,page_buffers)
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_properties', {
		isc_spb_dbname				= db_name,
		isc_spb_prp_page_buffers	= page_buffers,
	})
end

function service_class:db_set_sweep_interval(db_name,sweep_interval)
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_properties', {
		isc_spb_dbname				= db_name,
		isc_spb_prp_sweep_interval	= sweep_interval,
	})
end

function service_class:db_set_forced_writes(db_name,enable_forced_writes)
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_properties', {
		isc_spb_dbname				= db_name,
		isc_spb_prp_write_mode		= enable_forced_writes and 'isc_spb_prp_wm_sync' or 'isc_spb_prp_wm_async',
	})
end

function service_class:db_set_space_reservation(db_name,enable_reservation)
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_properties', {
		isc_spb_dbname				= db_name,
		isc_spb_prp_reserve_space	= enable_reservation and 'isc_spb_prp_res' or 'isc_spb_prp_res_use_full',
	})
end

function service_class:db_set_read_only(db_name,enable_read_only)
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_properties', {
		isc_spb_dbname				= db_name,
		isc_spb_prp_access_mode		= enable_read_only and 'isc_spb_prp_am_readonly' or 'isc_spb_prp_am_readwrite',
	})
end

function service_class:db_set_dialect(db_name,dialect)
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_properties', {
		isc_spb_dbname				= db_name,
		isc_spb_prp_set_sql_dialect	= dialect,
	})
end

local shutdown_modes = {
	normal = 'isc_spb_prp_sm_normal',
	multi  = 'isc_spb_prp_sm_multi',
	single = 'isc_spb_prp_sm_single',
	full   = 'isc_spb_prp_sm_full',
}

--force_mode = full|transactions|connections; shutdown_mode = normal|multi|single|full
function service_class:db_shutdown(db_name,timeout,force_mode,shutdown_mode)
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_properties', {
		isc_spb_dbname = db_name,
		isc_spb_prp_shutdown_db				= (force_mode or 'full') == 'full' and timeout or nil, --force
		isc_spb_prp_deny_new_attachments	= force_mode == 'transactions' and timeout or nil, --let transactions finish
		isc_spb_prp_deny_new_transactions	= force_mode == 'connections' and timeout or nil, --let attachments finish
		isc_spb_prp_shutdown_mode			= asserts(shutdown_modes[shutdown_mode or 'multi'], 'invalid shutdown mode %s', shutdown_mode),
	})
end

function service_class:db_activate(db_name,online_mode)
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_properties', {
		isc_spb_dbname = db_name,
		isc_spb_prp_online_mode	= asserts(shutdown_modes[online_mode or 'normal'], 'invalid online mode %s', online_mode),
		isc_spb_options = {
			isc_spb_prp_db_online	= true,
		},
	})
end

function service_class:db_use_shadow(db_name)
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_properties', {
		isc_spb_dbname = db_name,
		isc_spb_options = {isc_spb_prp_activate = true},
	})
end

--operations on the security database

function service_class:user_db_file()
	local info = api.query(self.fbapi,self.sv,self.handler,{isc_info_svc_user_dbpath=true},{isc_info_svc_timeout=self.timeout})
	return info.isc_info_svc_user_dbpath
end

function service_class:user_list(username,user_db_file)
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_display_user',{
		isc_spb_sec_username = username,
		isc_spb_dbname       = user_db_file,
	})
	local info = api.query(self.fbapi,self.sv,self.handler,{isc_info_svc_get_users=true},{isc_info_svc_timeout=self.timeout})
	if username then
		local a = info.isc_info_svc_get_users
		assert(#a == 1,'user not found')
		return {
			first_name=a.isc_spb_sec_firstname[1],
			middle_name=a.isc_spb_sec_middlename[1],
			last_name=a.isc_spb_sec_lastname[1]
		}
	else
		local t = {}
		for i,username in ipairs(info.isc_info_svc_get_users.isc_spb_sec_username) do
			t[username] = {
				first_name=info.isc_info_svc_get_users.isc_spb_sec_firstname[i],
				middle_name=info.isc_info_svc_get_users.isc_spb_sec_middlename[i],
				last_name=info.isc_info_svc_get_users.isc_spb_sec_lastname[i],
			}
		end
		return t
	end
end

function service_class:user_add(username,password,first_name,middle_name,last_name,user_db_file)
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_add_user',{
		isc_spb_sec_username    = username,
		isc_spb_sec_password    = password,
		isc_spb_sec_firstname   = first_name,
		isc_spb_sec_middlename  = middle_name,
		isc_spb_sec_lastname    = last_name,
		isc_spb_dbname          = user_db_file,
	})
end

function service_class:user_update(username,password,first_name,middle_name,last_name,user_db_file)
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_modify_user',{
		isc_spb_sec_username	= username,
		isc_spb_sec_password	= password,
		isc_spb_sec_firstname	= first_name,
		isc_spb_sec_middlename	= middle_name,
		isc_spb_sec_lastname	= last_name,
		isc_spb_dbname          = user_db_file,
	})
end

function service_class:user_delete(username,user_db_file)
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_delete_user',{
		isc_spb_sec_username = username,
		isc_spb_dbname       = user_db_file,
	})
end

--tracing API (firebird 2.5+)

local function check_trace_action_result(s)
	assert(not s:find('not found') and not s:find('No permission'),s)
end

function service_class:trace_list()
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_trace_list')

	local function decode_timestamp(y,m,d,h,m,s)
		return {year=y,month=m,day=d,hour=h,min=m,sec=s}
	end

	local function decode_flags(s)
		local t = {}
		s:gsub('([^,]*)', function(c) t[trim(c)]=true; end)
		return t
	end

	local t,s = {}

	local function tryadd(patt,field,decoder)
		local from,to,c1,c2,c3,c4,c5,c6 = s:find(patt)
		if from then t[field] = decoder(c1,c2,c3,c4,c5,c6) end
	end

	for i,s in self:lines() do
		tryadd('^Session ID: (%d+)','id',tonumber)
		tryadd('^  name: (%.+)','name',tostring)
		tryadd('^  user: (%.+)','user',tostring)
		tryadd('^  date: (%d%d%d%d)-(%d%d)-(%d%d) (%d%d):(%d%d):(%d%d)','date',decode_timestamp)
		tryadd('^  flags: (%.+)','flags',decode_flags)
	end
	return t
end

function service_class:trace_start(trace_config_string,trace_name)
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_trace_start',{
		isc_spb_trc_name = trace_name,
		isc_spb_trc_cfg  = trace_config_string,
	})
	return self
end

function service_class:trace_suspend(trace_id)
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_trace_suspend',{isc_spb_trc_id=trace_id})
	for i,line in self:lines() do
		return check_trace_action_result(line)
	end
end

function service_class:trace_resume(trace_id)
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_trace_resume',{isc_spb_trc_id=trace_id})
	for i,line in self:lines() do
		return check_trace_action_result(line)
	end
end

function service_class:trace_stop(trace_id)
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_trace_stop',{isc_spb_trc_id=trace_id})
	for i,line in self:lines() do
		return check_trace_action_result(line)
	end
end

--RDB$ADMIN mapping (firebird 2.5+)

function service_class:rdbadmin_set_mapping()
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_set_mapping')
end

function service_class:rdbadmin_drop_mapping()
	api.start(self.fbapi,self.sv,self.handler,'isc_action_svc_drop_mapping')
end

