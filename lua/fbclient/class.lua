--[=[
	Fbclient objectual wrapper
	Based on wrapper.lua and friends.

	*** ATTACHMENTS ***
	attach(database,[username],[password],[client_charset],[role_name],[dpb_options_t],[fbapi_object | libname],[at_class]) -> attachment
	attach_ex(database,[dpb_options_t],[fbapi_object | libname],[at_class]) -> attachment
	create_database(database,[username],[password],[client_charset],[role_name],[db_charset],[page_size],
					[dpb_options_t],[fbapi_object | libname],[at_class]) -> attachmenet
	create_database_ex(database,[dpb_options_t],[fbapi_object | libname],[at_class]) -> attachmenet
	create_database_sql(create_database_sql,[fbapi_object | libname],[at_class]) -> attachmenet
	attachment:clone() -> new attachment on the same fbapi object
	attachment:close()
	attachment:close_all()
	attachment:closed() -> true|false
	attachment:drop()
	attachment:cancel_operation(cancel_opt_s='fb_cancel_raise')

	*** ATTACHMENT INFO ***
	attachment:database_version() -> {line1,...}
	attachment:info(options_t,[info_buf_len]) -> db_info_t
	attachment:id() -> n
	attachment:page_counts() -> {reads=n,writes=n,fetches=n,marks=n}
	attachment:server_version() -> s
	attachment:page_size() -> n
	attachment:page_count() -> n
	attachment:buffer_count() -> n
	attachment:memory() -> n
	attachment:max_memory() -> n
	attachment:sweep_interval() -> n
	attachment:no_reserve() -> n
	attachment:ods_version() -> {maj,min}
	attachment:forced_writes() -> true|false
	attachment:connected_users() -> {username1,...}
	attachment:read_only() -> true|false
	attachment:creation_date() -> time_t
	attachment:page_contents(page_number) -> s; fb 2.5+
	attachment:table_counts() -> {[table_id]={read_seq_count=n,read_idx_count=n,...}}

	*** TRANSACTIONS ***
	start_transaction_ex({[attachment1]={tbp_options_t} | true],...},[tr_class]) -> transaction
	attachment:start_transaction([access],[isolation],[lock_timeout],[tpb_opts],[tr_class]) -> transaction
	attachment:start_transaction_ex([tpb_options_t],[tr_class]) -> transaction
	attachment:start_transaction_sql(set_transaction_sql,[tr_class]) -> transaction
	transaction:commit()
	transaction:rollback()
	transaction:commit_retaining()
	transaction:rollback_retaining()
	transaction:closed() -> true|false
	attachment:commit_all()
	attachment:rollback_all()

	*** TRANSACTION INFO ***
	transaction:info(options_t,[info_buf_len]) -> tr_info_t
	transaction:id() -> n

	*** UNPREPARED STATEMENTS ***
	trasaction:exec_immediate(sql)
	trasaction:exec_immediate_on(attachment,sql)

	*** PREPARED STATEMENTS ***
	transaction:prepare_on(attachment, sql, [st_class]) -> statement
	transaction:prepare(sql, [st_class]) -> statement
	statement:close()
	statement:closed() -> true|false
	statement:run() -> statement (returned for convenience)
	statement:fetch() -> true|false; true = OK, false = EOF.
	statement:set_cursor_name(name); can only be called after each statement:run()
	statement:close_cursor()
	transaction:close_all_statements()
	attachment:close_all_statements()
	statement:close_all_blobs()

	*** STATEMENT INFO ***
	statement:info(options_t,[info_buf_len]) -> st_info_t
	statement:type() -> type_s
	statement:plan() -> plan_s
	statement:affected_rows() -> {selected=,inserted=,updated=,deleted=}

	*** XSQLVARS ***
	statement.params -> params_t; params_t[i] -> xsqlvar (xsqlvar methods in xsqlvar.lua and friends)
	statement.columns -> columns_t; columns_t[col_num|col_name] -> xsqlvar

	*** SUGAR COATING ***
	attachment:exec(sql,p1,p2,...) -> row_iterator() -> st,v1,v2,...
	attachment:exec_immediate(sql)
	transaction:exec_on(attachment,sql,p1,p2,...) -> row_iterator() -> st,v1,v2,...
	transaction:exec(sql,p1,p2,...) -> row_iterator() -> st,v1,v2,...
	statement:exec(p1,p2,...) -> row_iterator() -> col_num,v1,v2,...
	statement:setparams(p1,p2,...) -> statement (returned for convenience)
	statement:getvalues() -> v1,v2,...,vlast
	statement:getvalues([col_num|col_name,...]) -> vi,vj,...
	statement.values[col_num|col_name] -> statement.columns[col_num]:get()
	statement:values(...) -> statement:getvalues(...)
	statement:row() -> { col_name = val,... }

	*** ERROR HANDLING ***
	attachment:sqlcode() -> n; deprecated in favor of sqlstate() in fb 2.5+
	attachment:sqlstate() -> s; SQL-2003 compliant SQLSTATE code; fbclient 2.5+ firebird 2.5+
	attachment:sqlerror() -> sql error message based on sqlcode()
	attachment:errors() -> {err_msg1,...}
	attachment:full_status() -> s;

	*** OBJECT STATE ***
	attachment.fbapi -> fbclient binding object, as returned by fbclient.binding.new(libname)
	attachment.sv -> status_vector object, as returned by fbclient.status_vector.new()
	transaction.fbapi -> fbclient binding object (the fbapi of one of the attachments)
	transaction.sv -> status_vector object (the status vector of one of the attachments)
	statement.fbapi -> fbclient binding object (attachment's fbapi)
	statement.sv -> status_vector object (attachment's sv)

	attachment.attachments -> hash of all active attachments
	attachment.transactions -> hash of active transactions on this attachment
	attachment.statements -> hash of active statements on this attachment
	transaction.attachments -> hash of attachments this transaction spans
	transaction.statements -> hash of active statements on this transaction
	statement.attachment -> the attachment this statement executes on
	statement.transaction -> the transaction this statement executes on
	xsqlvar.statement -> statement this xsqlvar object belongs to

	*** CLASS OBJECTS ***
	attachment_class -> table inherited by attachment objects
	transaction_class -> table inherited by transaction objects
	statement_class -> table inherited by statement objects

	*** USAGE NOTES ***
	- auxiliary functionality resides in other modules which are NOT require()'d automatically:
		- blob.lua              xsqlvar methods for blob support
	- see test_class.lua for complete coverage of all the functionality.
	- tostring(statement:values.COL_NAME) works for all data types.

	*** LIMITATIONS ***
	- dialect support is burried, and only dialect 3 databases are supported.
	- st.values is only callable and indexable (cant' do #, pairs(), or ipairs() on it)

]=]

module(...,require 'fbclient.module')

local api = require 'fbclient.wrapper' --this module is based on the procedural wrapper
local oo = require 'loop.base' --we use LOOP for classes so you can extend them if you want
local binding = require 'fbclient.binding' --using the wrapper requires a binding object
local svapi = require 'fbclient.status_vector' --using the wrapper requires a status_vector object
local xsqlda = require 'fbclient.xsqlda' --for preallocating xsqlda buffers
require 'fbclient.sql_info' --st:run() calls api.dsql_info()

attachment_class = oo.class {
	attachments = {},
	prealloc_param_count = 6, --pre-allocate xsqlda on prepare() to avoid a second isc_describe_bind() API call
	prealloc_column_count = 20, --pre-allocate xsqlda on prepare() to avoid a second isc_describe() API call
	statement_handle_pool_limit = 0, --in fb 2.5+ statement handles can be recycled, so you can increase/remove this
	cache_prepared_statements = true, --reuse prepared statements that have exactly the same sql text
	__type = 'fbclient attachment',
	__tostring = function(at) return xtype(at)..(at.database and ' to '..at.database or '') end,
}

transaction_class = oo.class {
	__type = 'fbclient transaction',
	__tostring = function(tr) return xtype(tr) end,
}

statement_class = oo.class {
	__type = 'fbclient statement',
	__tostring = function(st) return xtype(st) end,
}

local function create_attachment_object(fbapi, at_class)
	at_class = at_class or attachment_class
	fbapi = xtype(fbapi) == 'alien library' and fbapi or binding.new(fbapi or 'fbclient')
	local at = at_class {
		fbapi = fbapi,
		sv = svapi.new(),
		statement_handle_pool = {},
		transactions = {}, --transactions spanning this attachment
		statements = {}, --statements made against this attachment
	}
	return at
end

function attach(database, user, pass, client_charset, role, opts, fbapi, at_class)
	opts = opts or {}
	opts.isc_dpb_user_name = user
	opts.isc_dpb_password = pass
	opts.isc_dpb_lc_ctype = client_charset
	opts.isc_dpb_sql_role_name = role
	return attach_ex(database, opts, fbapi, at_class)
end

function attach_ex(database, opts, fbapi, at_class)
	local at = create_attachment_object(fbapi, at_class)
	at.handle = api.db_attach(at.fbapi, at.sv, database, opts)
	at.attachments[at] = true
	at.database = database --for cloning and __tostring
	at.dpb_options = deep_copy(opts) --for cloning
	at.allow_cloning = true
	return at
end

--start a new connection reusing the fbapi object of the source connection.
function attachment_class:clone()
	assert(self.handle, 'attachment closed')
	assert(self.allow_cloning, 'cloning not available on this attachment\n'..
								'only attachments made with attach() family of functions can be cloned')
	local at = create_attachment_object(self.fbapi)
	at.database = self.database
	at.dpb_options = deep_copy(self.dpb_options)
	at.allow_cloning = true
	at.handle = api.db_attach(at.fbapi, at.sv, at.database, at.dpb_options)
	at.attachments[at] = true
	return at
end

function create_database(database, user, pass, client_charset, role, db_charset, page_size, opts, fbapi, at_class)
	opts = opts or {}
	opts.isc_dpb_user_name = user
	opts.isc_dpb_password = pass
	opts.isc_dpb_lc_ctype = client_charset
	opts.isc_dpb_sql_role_name = role
	opts.isc_dpb_sql_dialect = 3
	opts.isc_dpb_set_db_charset = db_charset
	opts.isc_dpb_page_size = page_size
	return create_database_ex(database, opts, fbapi, at_class)
end

function create_database_ex(database, opts, fbapi, at_class)
	local at = create_attachment_object(fbapi, at_class)
	at.handle = api.db_create(at.fbapi, at.sv, database, opts)
	at.attachments[at] = true
	at.database = database --for __tostring
	return at
end

function create_database_sql(sql, fbapi, at_class)
	asserts(type(sql)=='string', 'arg#1 string expected, got %s',type(sql))
	local at = create_attachment_object(fbapi, at_class)
	at.handle = api.db_create_sql(at.fbapi, at.sv, sql, 3)
	at.attachments[at] = true
	return at
end

function attachment_class:close()
	assert(self.handle, 'attachment already closed')
	self:rollback_all()
	api.db_detach(self.fbapi, self.sv, self.handle)
	self.handle = nil
	self.attachments[self] = nil
end

function attachment_class:close_all()
	while next(self.attachments) do
		next(self.attachments):close()
	end
end

function attachment_class:drop()
	assert(self.handle, 'attachment closed')
	self:rollback_all()
	api.db_drop(self.fbapi, self.sv, self.handle)
	self.handle = nil
	self.attachments[self] = nil
end

function attachment_class:sqlcode()
	return svapi.sqlcode(self.fbapi, self.sv)
end

function attachment_class:sqlstate()
	return svapi.sqlstate(self.fbapi, self.sv)
end

function attachment_class:sqlerror()
	return svapi.sqlerror(self.fbapi, self:sqlcode())
end

function attachment_class:errors()
	return svapi.full_status(self.fbapi, self.sv)
end

function attachment_class:full_status()
	return svapi.full_status(self.fbapi, self.sv)
end


function attachment_class:cancel_operation(opt)
	assert(self.handle, 'attachment closed')
	opt = opt or 'fb_cancel_raise'
	api.db_cancel_operation(self.fbapi, self.sv, self.handle, opt)
end

function attachment_class:database_version()
	assert(self.handle, 'attachment closed')
	return api.db_version(self.fbapi, self.handle)
end

function attachment_class:info(opts, info_buf_len)
	assert(self.handle, 'attachment closed')
	return api.db_info(self.fbapi, self.sv, self.handle, opts, info_buf_len)
end

function attachment_class:id()
	return self:info({isc_info_attachment_id=true}).isc_info_attachment_id
end

function attachment_class:page_counts()
	local t = self:info{
		isc_info_reads = true,
		isc_info_writes = true,
		isc_info_fetches = true,
		isc_info_marks = true,
	}
	return {
		reads = t.isc_info_reads,
		writes = t.isc_info_writes,
		fetches = t.isc_info_fetches,
		marks = t.isc_info_marks,
	}
end

function attachment_class:server_version()
	return self:info{isc_info_isc_version=true}.isc_info_isc_version
end

function attachment_class:page_size()
	return self:info{isc_info_page_size=true}.isc_info_page_size
end

function attachment_class:page_count()
	return self:info{isc_info_allocation=true}.isc_info_allocation
end

function attachment_class:buffer_count()
	return self:info{isc_info_num_buffers=true}.isc_info_num_buffers
end

function attachment_class:memory()
	return self:info{isc_info_current_memory=true}.isc_info_current_memory
end

function attachment_class:max_memory()
	return self:info{isc_info_max_memory=true}.isc_info_max_memory
end

function attachment_class:sweep_interval()
	return self:info{isc_info_sweep_interval=true}.isc_info_sweep_interval
end

function attachment_class:no_reserve()
	return self:info{isc_info_no_reserve=true}.isc_info_no_reserve
end

function attachment_class:ods_version()
	local t = self:info{
		isc_info_ods_version=true,
		isc_info_ods_minor_version=true,
	}
	return {t.isc_info_ods_version, t.isc_info_ods_minor_version}
end

function attachment_class:forced_writes()
	return self:info{isc_info_forced_writes=true}.isc_info_forced_writes
end

function attachment_class:connected_users()
	return self:info{isc_info_user_names=true}.isc_info_user_names
end

function attachment_class:read_only()
	return self:info{isc_info_db_read_only=true}.isc_info_db_read_only
end

function attachment_class:creation_date()
	return self:info{isc_info_creation_date=true}.isc_info_creation_date
end

function attachment_class:page_contents(page_number)
	return self:info{fb_info_page_contents=page_number}.fb_info_page_contents
end

--returns {[table_id]={read_seq_count=,read_idx_count=,...},...}
function attachment_class:table_counts()
	local qt = {
		isc_info_read_seq_count = true,
		isc_info_read_idx_count = true,
		isc_info_insert_count = true,
		isc_info_update_count = true,
		isc_info_delete_count = true,
		isc_info_backout_count = true,
		isc_info_purge_count = true,
		isc_info_expunge_count = true,
	}
	local t = self:info(qt)
	local rt = {}
	for k in pairs(qt) do
		local kk = k:sub(#'isc_info_'+1)
		for table_id,count in pairs(t[k]) do
			if not rt[table_id] then
				rt[table_id] = {}
			end
			rt[table_id][kk] = count
		end
	end
	return rt
end

function start_transaction_ex(opts, tr_class)
	tr_class = tr_class or transaction_class
	assert(next(opts), 'at least one attachment is necessary to start a transaction')
	local attachments, tpb_opts = {}, {}
	for at,opt in pairs(opts) do
		assert(at.handle, 'attachment closed')
		attachments[at] = true
		tpb_opts[at.handle] = opt
	end
	local tr = tr_class {
		fbapi = next(attachments).fbapi, --use the fbapi of one of the attachments
		sv = next(attachments).sv, --use the sv of one of the attachments
		attachments = attachments,
		statements = {},
	}
	tr.handle = api.tr_start_multiple(tr.fbapi, tr.sv, tpb_opts)
	for at in pairs(attachments) do
		at.transactions[tr] = true
	end
	return tr
end

function attachment_class:start_transaction_ex(tpb_opts, tr_class)
	return start_transaction_ex({[self]=tpb_opts or true}, tr_class)
end

function attachment_class:start_transaction_sql(sql, tr_class)
	assert(self.handle, 'attachment closed')
	tr_class = tr_class or transaction_class
	local tr = tr_class {
		fbapi = self.fbapi,
		sv = self.sv,
		attachments = {[self] = true},
		statements = {},
	}
	tr.handle = api.tr_start_sql(tr.fbapi, tr.sv, self.handle, sql, 3)
	self.transactions[tr] = true
	return tr
end

function attachment_class:start_transaction(access, isolation, lock_timeout, tpb_opts, tr_class)
	local tpb_opts = tpb_opts or {}
	asserts(not access
				or access == 'read'
				or access == 'write',
					'arg#1 "read" or "write" expected, got "%s"',access)
	asserts(not isolation
				or isolation == 'consistency'
				or isolation == 'concurrency'
				or isolation == 'read commited'
				or isolation == 'read commited, no record version',
					'arg#2 "consistency", "concurrency", "read commited" or "read commited, no record version" expected, got "%s"', isolation)
	tpb_opts.isc_tpb_read = access == 'read' or nil
	tpb_opts.isc_tpb_write = access == 'write' or nil
	tpb_opts.isc_tpb_consistency = isolation == 'consistency' or nil
	tpb_opts.isc_tpb_concurrency = isolation == 'concurrency' or nil
	tpb_opts.isc_tpb_read_committed = isolation == 'read commited' or isolation == 'read commited, no record version' or nil
	tpb_opts.isc_tpb_rec_version = isolation == 'read commited' or nil
	tpb_opts.isc_tpb_wait = lock_timeout and lock_timeout > 0 or nil
	tpb_opts.isc_tpb_nowait = lock_timeout == 0 or nil
	tpb_opts.isc_tpb_lock_timeout = lock_timeout and lock_timeout > 0 and lock_timeout or nil
	return self:start_transaction_ex(tpb_opts, tr_class)
end

function attachment_class:commit_all()
	while next(self.transactions) do
		next(self.transactions):commit()
	end
end

function attachment_class:rollback_all()
	while next(self.transactions) do
		next(self.transactions):rollback()
	end
end

function transaction_class:close(action)
	local action = action or 'commit'
	assert(self.handle, 'transaction closed')
	self:close_all_statements()
	if action == 'commit' then
		api.tr_commit(self.fbapi, self.sv, self.handle)
	elseif action == 'rollback' then
		api.tr_rollback(self.fbapi, self.sv, self.handle)
	else
		asserts(false, 'arg#1 "commit" or "rollback" expected, got %s', action)
	end
	local at = next(self.attachments)
	while at do
		at.transactions[self] = nil
		self.attachments[at] = nil
		at = next(self.attachments)
	end
	self.handle = nil
end

function transaction_class:commit()
	self:close('commit')
end

function transaction_class:rollback()
	self:close('rollback')
end

function transaction_class:commit_retaining()
	assert(self.handle, 'transaction closed')
	api.tr_commit_retaining(self.fbapi, self.sv, self.handle)
end

function transaction_class:rollback_retaining()
	assert(self.handle, 'transaction closed')
	api.tr_rollback_retaining(self.fbapi, self.sv, self.handle)
end

function transaction_class:info(opts, info_buf_len)
	assert(self.handle, 'transaction closed')
	return api.tr_info(self.fbapi, self.sv, self.handle, opts, info_buf_len)
end

function transaction_class:id()
	return self:info({isc_info_tra_id=true}).isc_info_tra_id
end

function transaction_class:exec_immediate_on(attachment, sql)
	api.dsql_execute_immediate(self.fbapi, self.sv, attachment.handle, self.handle, sql, 3)
end

function transaction_class:exec_immediate(sql)
	assert(count(self.attachments,2) == 1, 'use exec_immediate_on() on multi-database transactions')
	return self:exec_immediate_on(next(self.attachments), sql)
end

function transaction_class:prepare_on(attachment, sql, st_class)
	assert(self.handle, 'transaction closed')
	st_class = st_class or statement_class
	local st = st_class {
		fbapi = attachment.fbapi,
		sv = attachment.sv,
		transaction = self,
		attachment = attachment,
	}

	--grab a handle from the statement handle pool of the attachment, or make a new one.
	local spool = attachment.statement_handle_pool
	if next(spool) then
		st.handle = next(spool)
		spool[st.handle] = nil
	else
		st.handle = api.dsql_alloc_statement(st.fbapi, st.sv, attachment.handle)
	end

	st.params, st.columns =
		api.dsql_prepare(self.fbapi, self.sv, attachment.handle, self.handle, st.handle, sql, 3,
						xsqlda.new(attachment.prealloc_param_count),
						xsqlda.new(attachment.prealloc_column_count))

	st.values = setmetatable({}, {
		__index = function(t,k) return st.columns[k]:get() end,
		__call = function(t,self,...) return self:getvalues(...) end,
	})

	attachment.statements[st] = true
	self.statements[st] = true

	--make and record the decision on how the statement should be executed and results be fetched.
	--NOTE: there's no official way to do this, I just did what made sense, it may be wrong.
	st.expect_output = #st.columns > 0
	st.expect_cursor = false
	if st.expect_output then
		st.expect_cursor = ({
			isc_info_sql_stmt_select = true,
			isc_info_sql_stmt_select_for_upd = true
		})[st:type()]
	end

	return st
end

function transaction_class:prepare(sql, st_class)
	assert(count(self.attachments,2) == 1, 'use prepare_on() on multi-database transactions')
	return self:prepare_on(next(self.attachments), sql, st_class)
end

--NOTE: this function works (does nothing) even if the blob module isn't loaded!
function statement_class:close_all_blobs()
	for i,xs in ipairs(self.params) do
		if xs.blob_handle then
			xs:close()
		end
	end
	for i,xs in ipairs(self.columns) do
		if xs.blob_handle then
			xs:close()
		end
	end
end

function statement_class:close()
	assert(self.handle, 'statement already closed')
	self:close_all_blobs()
	self:close_cursor()

	--try unpreparing the statement handle instead of freeing it, and drop it into the handle pool.
	local spool = self.attachment.statement_handle_pool
	local limit = self.attachment.statement_handle_pool_limit
	if not limit or count(spool, limit) < limit then
		api.dsql_unprepare(self.fbapi, self.sv, self.handle)
		spool[self.handle] = true
	else
		api.dsql_free_statement(self.fbapi, self.sv, self.handle)
	end

	self.expect_output = nil
	self.expect_cursor = nil
	self.already_fetched = nil
	self.attachment.statements[self] = nil
	self.transaction.statements[self] = nil
	self.handle = nil
	self.transaction = nil
	self.attachment = nil
end

function attachment_class:close_all_statements()
	while next(self.statements) do
		next(self.statements):close()
	end
end

function transaction_class:close_all_statements()
	while next(self.statements) do
		next(self.statements):close()
	end
end

function statement_class:run()
	assert(self.handle, 'statement closed')
	self:close_all_blobs()
	self:close_cursor()
	if self.expect_output and not self.expect_cursor then
		api.dsql_execute_returning(self.fbapi, self.sv, self.transaction.handle, self.handle, self.params, self.columns)
		self.already_fetched = true
	else
		api.dsql_execute(self.fbapi, self.sv, self.transaction.handle, self.handle, self.params)
		self.cursor_open = self.expect_cursor
	end
	return self
end

function statement_class:set_cursor_name(name)
	api.dsql_set_cursor_name(self.fbapi, self.sv, self.handle, name)
end

function statement_class:fetch()
	assert(self.handle, 'statement closed')
	self:close_all_blobs()
	local fetched = self.already_fetched or false
	if fetched then
		self.already_fetched = nil
	elseif self.cursor_open then
		fetched = api.dsql_fetch(self.fbapi, self.sv, self.handle, self.columns)
		if not fetched then
			self:close_cursor()
		end
	end
	return fetched
end

function statement_class:close_cursor()
	if self.cursor_open then
		api.dsql_free_cursor(self.fbapi, self.sv, self.handle)
		self.cursor_open = nil
	end
end

function statement_class:info(opts, info_buf_len)
	assert(self.handle, 'statement closed')
	return api.dsql_info(self.fbapi, self.sv, self.handle, opts, info_buf_len)
end

function statement_class:type()
	return self:info({isc_info_sql_stmt_type=true}).isc_info_sql_stmt_type[1]
end

function statement_class:plan()
	return self:info({isc_info_sql_get_plan=true}).isc_info_sql_get_plan
end

local affected_rows_codes = {
	isc_info_req_select_count = 'selects',
	isc_info_req_insert_count = 'inserts',
	isc_info_req_update_count = 'updates',
	isc_info_req_delete_count = 'deletes',
}

function statement_class:affected_rows()
	local t, codes = {}, self:info({isc_info_sql_records=true}).isc_info_sql_records
	for k,v in pairs(codes) do
		t[affected_rows_codes[k]] = v
	end
	return t
end

function statement_class:setparams(...)
	for i,p in ipairs(self.params) do
		p:set(select(i,...))
	end
	return self
end

function statement_class:getvalues(...)
	if select('#',...) == 0 then
		local t = {}
		for i,col in ipairs(self.columns) do
			t[i] = col:get()
		end
		return unpack(t,1,#self.columns)
	else
		local t,n = {},select('#',...)
		for i=1,n do
			t[i] = self.columns[select(i,...)]:get()
		end
		return unpack(t,1,n)
	end
end

function statement_class:row()
	local t = {}
	for i,col in ipairs(self.columns) do
		local name = asserts(col.column_alias_name,'column %d does not have an alias name',i)
		local val = col:get()
		t[name] = val
	end
	return t
end

local function statement_exec_iter(st,i)
	if st:fetch() then
		return i+1, st:values()
	end
end

function statement_class:exec(...)
	self:setparams(...)
	self:run()
	return statement_exec_iter,self,0
end

local function transaction_exec_iter(st)
	if st:fetch() then
		return st, st:values()
	else
		st:close()
	end
end

local function null_iter() end

function transaction_class:exec_on(at,sql,...)
	local st = self:prepare_on(at,sql)
	st:setparams(...)
	st:run()
	if st.expect_output then
		return transaction_exec_iter,st
	else
		st:close()
		return null_iter
	end
end

function transaction_class:exec(sql,...)
	return self:exec_on(next(self.attachments),sql,...)
end

local function attachment_exec_iter(st)
	if st:fetch() then
		return st, st:values()
	else
		st.transaction:commit() --commit() closes all statements automatically
	end
end

--ATTN: if you break the iteration before fetching all the result rows the
--transaction, statement and fetch cursor all remain open until you close the attachment!
function attachment_class:exec(sql,...)
	local tr = self:start_transaction_ex()
	local st = tr:prepare_on(self,sql)
	st:setparams(...)
	st:run()
	if st.expect_output then
		return attachment_exec_iter,st
	else
		st.transaction:commit()
	end
end

function attachment_class:exec_immediate(sql)
	local tr = self:start_transaction_ex()
	tr:exec_immediate_on(self,sql)
	tr:commit()
end

local function object_closed(self)
	return self.handle == nil
end

attachment_class.closed = object_closed
transaction_class.closed = object_closed
statement_class.closed = object_closed

