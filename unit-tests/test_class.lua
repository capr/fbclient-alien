#!/usr/bin/lua

--[[
	Test unit for class.lua

]]

local config = require 'test_config'

local function map(t,f)
	local tt = {}
	for i=1,#t do
		tt[#tt+1] = f(t[i])
	end
	return tt
end

local function asserteq(a,b,s)
	assert(a==b,s or string.format('%s ~= %s', tostring(a), tostring(b)))
end

local function test_everything(env)

	local api = require 'fbclient.class'
	local util = require 'fbclient.util'
	require 'fbclient.blob' --blob support is not loaded automatically
	require 'fbclient.error_codes' --error codes are not loaded automatically
	local count = util.count
	local dump = util.dump

	local function db_diag(db)
		print('  attachment id', db:id())
		print('  version'); dump(db:database_version())
		print('  server version', db:server_version())
		if env.lib ~= 'fbembed' and env.server_ver:find'^2%.5' then
			for st, s in db:exec("select rdb$get_context('SYSTEM','ENGINE_VERSION') from rdb$database") do
				print('  engine version', s)
			end
		end
	end

	local function db_info(db)
		print('  page counts'); dump(db:page_counts())
		print('  page size', db:page_size())
		print('  page count', db:page_count())
		print('  buffer count', db:buffer_count())
		print('  memory', db:memory())
		print('  max memory', db:max_memory())
		print('  sweep interval', db:sweep_interval())
		print('  no reserve', db:no_reserve())
		print('  ods version', table.concat(db:ods_version(),'.'))
		print('  forced writes', db:forced_writes())
		print('  connected users', unpack(db:connected_users()))
		print('  read only', db:read_only())
		print('  creation date', db:creation_date())
		print('  page contents(1)', pcall(function() db:page_contents(1) end))
		print('  table counts'); dump(db:table_counts())
	end

	local function test_db()
		env:create_test_db():drop()

		local db = api.create_database_sql(
				string.format("create database '%s' user '%s' password '%s'",
								env.database, env.username, env.password), env.libname)
		print('db/create/sql', db); db_diag(db); db_info(db)
		db:drop(); print('  dropped', db)
		asserteq(count(db.attachments), 0)

		local db = api.create_database(env.database, env.username, env.password,
										nil, nil, nil, nil, nil, env.libname)
		print('db/create/dpb', db)
		asserteq(count(db.attachments), 1)
		db:close(); print('  closed', db)
		asserteq(count(db.attachments), 0)

		local db = api.attach(env.database, env.username, env.password, nil, nil, nil, env.libname)
		print('db/attach', db)
		local db2 = db:clone()
		print('db/clone', db2)
		asserteq(count(db2.attachments), 2)

		db:close(); print('db/close', db)
		asserteq(count(db2.attachments), 1)
		db2:drop(); print('db2/drop', db2)
		asserteq(count(db.attachments), 0)
	end

	local function tr_diag(tr)
		print('  transaction id', tr:id())
	end

	local function test_tr()
		local db = env:create_test_db()
		local db2 = env:create_test_db2()
		asserteq(count(db.attachments), 2)

		local tr = db:start_transaction_sql('SET TRANSACTION')
		print('tr/start/sql', tr); tr_diag(tr)
		asserteq(count(tr.attachments), 1)
		asserteq(next(tr.attachments), db)
		asserteq(count(db.transactions), 1)

		tr:commit_retaining()
		asserteq(count(db.transactions), 1)
		tr:commit()
		asserteq(count(tr.attachments), 0)
		asserteq(count(db.transactions), 0)

		local tr = api.start_transaction_ex{
			[db] = {isc_tpb_read = true},
			[db2] = {isc_tpb_write = true},
		}
		print('tr/start/multi-database', tr); tr_diag(tr)
		asserteq(count(tr.attachments), 2)
		asserteq(count(db.transactions), 1)
		asserteq(count(db2.transactions), 1)

		tr:rollback_retaining()
		asserteq(count(db.transactions), 1)
		asserteq(count(db2.transactions), 1)

		db:rollback_all()
		asserteq(count(tr.attachments), 0)
		asserteq(count(db.transactions), 0)
		asserteq(count(db2.transactions), 0)

		db:close_all()
		asserteq(count(db.attachments), 0)
	end

	local function test_exec()
		local db = env:create_test_db()

		local q = 'create table t(id integer primary key, name blob)'
		db:exec_immediate(q)
		print('exec/immediate', q)

		local tr = db:start_transaction('write', 'consistency', 10)

		local q = 'insert into t values (?,?) returning id, name'
		print('exec/returning', q, 1, 'hello')
		for st,id,name in tr:exec(q, 1, 'hello') do
			print('exec/fetch', id, name)
			asserteq(id, 1)
			asserteq(name, 'hello')
		end
		asserteq(count(tr.statements), 0)

		local q = 'insert into t values (?,?)'
		for st in tr:exec(q, 2, 'hello again') do assert(false,'shouldn\'t fetch') end
		print('exec/insert', q, 2, 'hello again')
		asserteq(count(tr.statements), 0)

		local q = 'select * from t for update of name'
		print('exec/select', q)
		for st, id, name in tr:exec(q) do
			st:set_cursor_name('cr')
			local q, p = 'update t set name = ? where current of cr', name..' updated'
			asserteq(count(tr.statements), 1)
			tr:exec(q, p)
			asserteq(count(tr.statements), 1)
			print('exec/cursor update', q, p)
		end
		asserteq(count(tr.statements), 0)

		tr:commit()
		local tr = db:start_transaction('read', 'read commited', 0)

		local q, p = 'select * from t where name like ?', '%updated'
		local st = tr:prepare(q)
		print('st/prepare', q, '->', st)
		asserteq(count(tr.statements), 1)
		st:setparams(p):run()
		print('st/run', p)
		print('  statement type', st:type())
		print('  execution plan', st:plan())
		print('  affected rows'); dump(st:affected_rows())

		print('st/fields',unpack(map(st.columns,function(c) return c.column_alias_name end)))
		local i=0
		while st:fetch() do
			print('st/fetch', st:values())
			local id,name = st:values()
			local name2,id2 = st:values('NAME','ID')
			local row = st:row()
			asserteq(id2, id); asserteq(name2, name)
			asserteq(id, st.values.ID); asserteq(name, st.values.NAME)
			asserteq(id, st:values('ID')); asserteq(name, st:values('NAME'))
			asserteq(id, row.ID); asserteq(name, row.NAME)
			asserteq(id, st.columns.ID:get()); asserteq(name, st.columns.NAME:get())
			assert(name:find'^hello.-updated$')
			i=i+1
		end
		asserteq(i, 2)
		asserteq(st.cursor_open, nil)

		p = 'hello again updated'
		st:setparams(p):run()
		i=0
		while st:fetch() do
			asserteq(st.values.NAME, p)
			i=i+1
		end
		asserteq(i, 1)
		asserteq(st.cursor_open, nil)

		db:close_all(); print('db/close_all')
		asserteq(count(tr.statements), 0)
		asserteq(count(tr.attachments), 0)
		asserteq(count(db.transactions), 0)
		asserteq(count(db.attachments), 0)
	end

	test_db()
	test_tr()
	test_exec()

	return 1,0
end

--local comb = {{lib='fbclient',ver='2.5.0',server_ver='2.5.0'}}
config.run(test_everything,comb,nil,...)

