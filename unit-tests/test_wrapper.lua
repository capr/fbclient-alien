#!/usr/bin/lua
--[[
	Test unit for wrapper.lua

]]

local config = require 'test_config'

local function asserteq(a,b,s)
	assert(a==b,s or string.format('%s ~= %s', tostring(a), tostring(b)))
end

function test_everything(env)

	require 'fbclient.error_codes'
	local fbclient = {
		svapi			= require 'fbclient.status_vector',
		binding			= require 'fbclient.binding',
		wrapper 		= require 'fbclient.wrapper',
		error_codes		= require 'fbclient.error_codes',
		event 			= require 'fbclient.event',
		blob			= require 'fbclient.blob',
		util			= require 'fbclient.util',
		db_info			= require 'fbclient.db_info',
		tr_info			= require 'fbclient.tr_info',
		sql_info		= require 'fbclient.sql_info',
		blob_info		= require 'fbclient.blob_info',
		alien			= require 'alien',
	}
	local api = fbclient.wrapper
	local dump = fbclient.util.dump
	local asserts = fbclient.util.asserts
	local post20 = not env.server_ver:find'^2%.0'
	local post21 = post20 and not env.server_ver:find'^2%.1'

	local db_opts = {
		isc_dpb_user_name = env.username,
		isc_dpb_password = env.password,
	}

	local fbapi = fbclient.binding.new(env.libname)
	local sv = fbclient.svapi.new()

	--upvalues from here on: fbapi, sv

	local function ib_version()
		print(string.format('INTERBASE compatibility version: %d.%d',api.ib_version(fbapi)))
	end

	local function create(dbname)
		--note: param substitution is not available with db_create(), hence the string.format() thing!
		local dbh = api.db_create_sql(fbapi, sv,
										string.format("create database '%s' user '%s' password '%s'",
														dbname, env.username, env.password),
										env.dialect)
		print('CREATED '..dbname)
		return dbh
	end

	local function attach(dbname)
		local dbh = api.db_attach(fbapi,sv,dbname,db_opts)
		print('ATTACHED '..dbname)
		return dbh
	end

	local function drop(dbh)
		api.db_drop(fbapi,sv,dbh)
		print('DROPPED')
	end

	local function detatch(dbh)
		api.db_detatch(fbapi,sv,dbh)
	end

	local function test_attachment(dbh)

		--upvalues from here on: fbapi, sv, dbh

		local function db_version()
			print'DB VERSION:'; dump(api.db_version(fbapi, dbh),'\n')
		end

		local function test_events()
			do return end -- not finished yet!!

			local event = fbclient.event
			local e = event.new('STUFF')
			event.wait(sv, dbh, e)
			local called = false
			local eh = event.listen(sv, dbh, e, function(...) called = true; print('event counts: ',...) end)
			query(sv, dbh, 'execute procedure test_events')
			while not called do print('.') end
			event.cancel(sv, dbh, eh)
		end

		local function test_tpb()
			local trh = api.tr_start(fbapi, sv, dbh)
			api.dsql_execute_immediate(fbapi, sv, dbh, trh, 'create table test_tr1(id integer)')
			api.dsql_execute_immediate(fbapi, sv, dbh, trh, 'create table test_tr2(id integer)')
			api.tr_commit(fbapi, sv, trh)

			local tpb = {
				isc_tpb_write=true,
				isc_tpb_read_committed=true,
				isc_tpb_wait=true,
				isc_tpb_no_rec_version=true,
				isc_tpb_lock_timeout=10,
				{'isc_tpb_shared', 'isc_tpb_lock_write', 'TEST_TR1'},
				{'isc_tpb_protected', 'isc_tpb_lock_read', 'TEST_TR2'},
			}
			local trh = api.tr_start(fbapi, sv, dbh, tpb)
			print'TRANSACTION started (with table reservation options)'
			--TODO: how to test if table reservation options are in effect? they were accepted alright.
			api.tr_commit_retaining(fbapi, sv, trh)
			print'TRANSACTION commit-retained'
			api.tr_rollback_retaining(fbapi, sv, trh)
			print'TRANSACTION rollback-retained'
			api.tr_rollback(fbapi, sv, trh)
			print'TRANSACTION rolled back'
		end

		local function test_db_info()
			local tr1 = api.tr_start(fbapi, sv, dbh)
			local tr2 = api.tr_start(fbapi, sv, dbh)

			local t = {
				isc_info_db_id=true,
				isc_info_reads=true,
				isc_info_writes=true,
				isc_info_fetches=true,
				isc_info_marks=true,
				isc_info_implementation=true,
				isc_info_isc_version=true,
				isc_info_base_level=true,
				isc_info_page_size=true,
				isc_info_num_buffers=true,
				--TODO: isc_info_limbo=true,
				isc_info_current_memory=true,
				isc_info_max_memory=true,
				--error (expected): isc_info_window_turns=true,
				--error (expected): isc_info_license=true,
				isc_info_allocation=true,
				isc_info_attachment_id=true,
				isc_info_read_seq_count=true,
				isc_info_read_idx_count=true,
				isc_info_insert_count=true,
				isc_info_update_count=true,
				isc_info_delete_count=true,
				isc_info_backout_count=true,
				isc_info_purge_count=true,
				isc_info_expunge_count=true,
				isc_info_sweep_interval=true,
				isc_info_ods_version=true,
				isc_info_ods_minor_version=true,
				isc_info_no_reserve=true,
				isc_info_forced_writes=true,
				isc_info_user_names=true,
				isc_info_page_errors=true,
				isc_info_record_errors=true,
				isc_info_bpage_errors=true,
				isc_info_dpage_errors=true,
				isc_info_ipage_errors=true,
				isc_info_ppage_errors=true,
				isc_info_tpage_errors=true,
				isc_info_set_page_buffers=true,
				isc_info_db_sql_dialect=true,
				isc_info_db_read_only=true,
				isc_info_db_size_in_pages=true,
				frb_info_att_charset=true,
				isc_info_db_class=true,
				isc_info_firebird_version=true,
				isc_info_oldest_transaction=true,
				isc_info_oldest_active=true,
				isc_info_oldest_snapshot=true,
				isc_info_next_transaction=true,
				isc_info_db_provider=true,
				isc_info_active_transactions=true,
				isc_info_active_tran_count=post20 or nil,
				isc_info_creation_date=post20 or nil,
				isc_info_db_file_size=post20 or nil,
				fb_info_page_contents = post21 and 1 or nil,
			}
			local info = api.db_info(fbapi, sv, dbh, t)
			print'DB info:'; dump(info)
			if post21 then
				asserteq(#info.fb_info_page_contents, info.isc_info_page_size)
			end
			if post20 then
				asserteq(info.isc_info_active_tran_count, 2)
			end
			--TODO: how to assert that all this info is accurate?
			api.tr_commit(fbapi, sv, tr1)
			api.tr_commit(fbapi, sv, tr2)
		end

		local function test_tr_info()
			local trh = api.tr_start(fbapi, sv, dbh, {
				isc_tpb_write=true,
				isc_tpb_read_committed=true,
				isc_tpb_wait=true,
				isc_tpb_no_rec_version=true,
				isc_tpb_lock_timeout=10,
			})
			local t = {
				isc_info_tra_id=true,
				isc_info_tra_oldest_interesting=post20 or nil,
				isc_info_tra_oldest_snapshot=post20 or nil,
				isc_info_tra_oldest_active=post20 or nil,
				isc_info_tra_isolation=post20 or nil,
				isc_info_tra_access=post20 or nil,
				isc_info_tra_lock_timeout=post20 or nil,
			}
			local info = api.tr_info(fbapi, sv, trh, t)
			print'TRANSACTION info:'; dump(info)
			if post20 then
				asserteq(info.isc_info_tra_isolation[1],'isc_info_tra_read_committed')
				asserteq(info.isc_info_tra_isolation[2],'isc_info_tra_no_rec_version')
				asserteq(info.isc_info_tra_access,'isc_info_tra_readwrite')
				asserteq(info.isc_info_tra_lock_timeout,10)
			end
			--TODO: how to assert that all this info is accurate?
			api.tr_commit(fbapi, sv, trh)
		end

		local function test_sql_info()
			local trh = api.tr_start(fbapi, sv, dbh)
			local sth = api.dsql_alloc_statement(fbapi, sv, dbh)
			local params,columns = api.dsql_prepare(fbapi, sv, dbh, trh, sth, 'select rdb$relation_id from rdb$database where rdb$relation_id = ?', env.dialect)

			local info = api.dsql_info(fbapi, sv, sth, {
				--isc_info_sql_select=true, --TODO
				--isc_info_sql_bind=true, --TODO
				isc_info_sql_stmt_type=true,
				isc_info_sql_get_plan=true,
				isc_info_sql_records=true,
				isc_info_sql_batch_fetch=true,
			})

			print'SQL info:'; dump(info)

			--api.dsql_free_cursor(fbapi, sv, sth)
			api.dsql_free_statement(fbapi, sv, sth)
			api.tr_commit(fbapi, sv, trh)
		end

		local function test_dpb()
			--TODO
		end

		--perform the actual testing on the attachment
		db_version()
		test_events()
		test_tpb()
		test_db_info()
		test_tr_info()
		test_sql_info()
		test_dpb()

	end --test_attachment()

	--perform the actual testing on the library
	ib_version()

	-- in case the database is still alive from a previous failed test, drop it.
	pcall(function() dbh = attach(env.database); drop(dbh) end)
	--alternative drop method without attachment :)
	os.remove(env.database_file)

	local dbh = create(env.database)
	test_attachment(dbh)
	drop(dbh)

	return 1,0
end

--local comb = {{lib='fbembed',ver='2.5.0'}}
config.run(test_everything,comb,nil,...)

