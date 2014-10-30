--[[
	Firebird Schema Introspection and DDL Extraction

	LIMITATIONS:
	- there's no way to detect that a column was renamed rather than dropped/created again
	-

]]

module(...,require 'fbclient.module')

local oo = require 'loop.simple'
local sql = require 'fbclient.sql'
require 'fbclient.blob'

------------------------------------------------------------------------------
--[[
class fields:
	type = object type
	key = primary key
	foreign_keys = {key = lookup key}
	load_query(self, [keyval])
	ignore_keys = {key1 = true,...}
instance fields:
	foreigns = {key = foreign list}
]]
objects = oo.class()

function objects:__init(t)
	self = oo.rawnew(self, t)
	self:clear()
	if self.foreign_keys then
		self.foreigns = self.foreigns or {}
		for fk in pairs(self.foreigns) do
			assert(self.foreign_keys[fk])
		end
	end
	return self
end

function objects:clear(keyval)
	if keyval then
		self.elements[keyval] = nil
	else
		self.elements = {}
	end
end

function objects:lookup(e, lookup_key)
	lookup_key = lookup_key or self.key
	return self.elements[e[lookup_key]]
end

function objects:set(e)
	self.elements[e[self.key]] = e
	self:link(e)
end

function objects:link(e)
	if self.foreign_keys then
		for fk,foreign in pairs(self.foreigns) do
			local lookup_key = self.foreign_keys[fk]
			e[fk] = foreign:lookup(e, lookup_key)
		end
	end
end

function objects:load(tr, keyval)
	self:clear(keyval)
	for st in tr:exec(self:load_query(keyval)) do
		self:set(st:row())
	end
end

function objects:refresh(tr, e)
	self:load(tr, e[self.key])
end

local function deep_equal(new, old, ignore_keys, trace)
	local trace = trace or {}
	for k,newv in pairs(new) do
		if not ignore_keys or not ignore_keys[k] then
			local oldv = old[k]
			if type(newv) == 'table' and not trace[newv] then
				trace[newv] = true
				if not deep_equal(newv, oldv, ignore_keys, trace) then
					return false
				end
			elseif newv ~= oldv then
				return false
			end
		end
	end
	return true
end

function objects:compare(older)
	return coroutine.wrap(function()
		for k,e in pairs(self.elements) do
			local older_e = older:lookup(e)
			if older_e then
				if not deep_equal(e, older_e, self.ignore_keys) then
					coroutine.yield('update', e, older_e)
				end
			else
				coroutine.yield('insert', e)
			end
		end
		for k,e in pairs(older.elements) do
			if not self:lookup(e) then
				coroutine.yield('delete', nil, e)
			end
		end
	end)
end

function objects:diff(older)
	for action, new, old in self:compare(older) do
		self.queries[action](self, new, old)
	end
end

------------------------------------------------------------------------------
--[[
class fields:
	parent_key = parent lookup key
	children_key = childen list key
	children_class = children list class
instance fields:
	parent = parent list
]]
detail_objects = oo.class({}, objects)

function detail_objects:clear(parent_keyval)
	if parent_keyval then
		local parent = self.parent.elements[parent_keyval]
		parent[self.children_key] = self.children_class{parent = parent}
	else
		for _,e in pairs(self.parent.elements) do
			e[self.children_key]:clear()
		end
	end
end

function detail_objects:set(e)
	self:link(e)
	self.parent:lookup(e, self.parent_key)[self.children_key]:set(e)
end

local function cond(cond, iftrue, iffalse)
	if cond then return iftrue else return iffalse end
end

------------------------------------------------------------------------------
table_fields = oo.class({
	key = 'NAME',
	queries = {},
}, objects)

function table_fields.queries:insert(new)
	coroutine.yield(sql.parse_template('alter table :TABLE_NAME add :NAME :TYPE', new))
end

function table_fields.queries:update(new, old)
	local s = sql.parse_template('alter table :TABLE_NAME alter :NAME ', old)
	local new_domain = new.DOMAIN:find('^RDB%$') and new.domain.TYPE or sql.format_name(new.DOMAIN)
	local old_domain = old.DOMAIN:find('^RDB%$') and old.domain.TYPE or sql.format_name(old.DOMAIN)
	if new_domain ~= old_domain then
		s = s..'type '..new_domain
	end
	coroutine.yield(s)
end

function table_fields.queries:delete(_, old)
	coroutine.yield(sql.parse_template('alter table :TABLE_NAME drop :NAME', old))
end

table_fields_detail = oo.class({
	type = 'TABLE_FIELD',
	key = 'NAME',
	parent_key = 'TABLE_NAME',
	children_key = 'fields',
	children_class = table_fields,
	foreign_keys = {domain = 'DOMAIN'},
}, detail_objects)

function table_fields_detail:load_query(table_name)
	local system_flag = cond(not table_name, self.options.system_flag)
	return [[
		select
			rf.rdb$field_name as name,
			rf.rdb$relation_name as table_name,
			rf.rdb$field_source as domain,
			rf.rdb$base_field as base_field, --for views; table field or proc arg name
			rf.rdb$field_position as field_position,
			vr.rdb$relation_name as base_table, --for views; table or proc name
			rf.rdb$description as description,
			rf.rdb$default_value as default_value,
			rf.rdb$system_flag as system_flag,
			rf.rdb$security_class as security_class,
			rf.rdb$null_flag as null_flag,
			rf.rdb$default_source as default_source,
			rf.rdb$collation_id as collation_id
		from
			rdb$relation_fields rf
			inner join rdb$relations r on
				r.rdb$relation_name = rf.rdb$relation_name
			left join rdb$view_relations vr on
				vr.rdb$view_name = rf.rdb$relation_name
				and vr.rdb$view_context = rf.rdb$view_context
		where
			(r.rdb$system_flag = ? or ? is null)
			and (rf.rdb$relation_name = ? or ? is null)
		]], system_flag, system_flag, table_name, table_name
end

------------------------------------------------------------------------------
tables = oo.class({
	type = 'TABLE',
	key = 'NAME',
	queries = {},
}, objects)

function tables:load_query(name)
	local system_flag = cond(not name, self.options.system_flag)
	return [[
		select
			r.rdb$relation_name as name,
			t.rdb$type_name as table_type,
			case when ? is null then null else r.rdb$view_source end as view_source,
			r.rdb$description as description,
			r.rdb$system_flag as system_flag,
			r.rdb$dbkey_length as dbkey_length,
			r.rdb$security_class as security_class,
			r.rdb$external_file as external_file,
			r.rdb$external_description as external_description,
			r.rdb$owner_name as owner_name,
			r.rdb$default_class as default_class
		from
			rdb$relations r
			inner join rdb$types t on
				t.rdb$type = r.rdb$relation_type
				and t.rdb$field_name ='RDB$RELATION_TYPE'
		where
			(r.rdb$system_flag = ? or ? is null)
			and (r.rdb$relation_name = ? or ? is null)
		]], self.options.source_code, system_flag, system_flag, name, name
end

function tables:load(tr, name)
	objects.load(self, tr, name)
	if self.options.table_fields then
		self.fields:load(tr, name)
	end
end

function tables.queries:insert(new)
	local col_defs = {}
	for name, field in pairs(new.fields.elements) do
		local col_type = field.DOMAIN:find'^RDB%$' and field.domain.TYPE or sql.format_name(field.DOMAIN)
		t[#t+1] = sql.format_name(field.NAME)..' '..col_type
	end



	sql.parse_template([=[CREATE TABLE :NAME [EXTERNAL FILE '%filespec']  ]=]
	(<col_def> [, <col_def> | <tconstraint> …]);

	coroutine.yield(sql.parse_template('create table :NAME (\n\t'..table.concat(col_defs, ',\n\t')..'\n)', new))
end

function tables.queries:update(new, old)
	new.fields:diff(old.fields)
end

function tables.queries:delete(_, old)
	coroutine.yield(sql.parse_template('drop table :NAME', old))
end


------------------------------------------------------------------------------
domains = oo.class({
	type = 'DOMAIN',
	key = 'NAME',
	queries = {},
}, objects)

function domains:load_query(name)
	local system_flag = cond(not name, self.options.system_flag)
	return [[
		select
			f.rdb$field_name as name,
			f.rdb$validation_source as validation_source,
			f.rdb$computed_source as computed_source,
			f.rdb$default_value as default_value,
			f.rdb$default_source as default_source,
			f.rdb$field_length as field_length,
			f.rdb$field_scale as field_scale,
			t.rdb$type_name as type,
			st.rdb$type_name as subtype,
			f.rdb$description as description,
			f.rdb$system_flag as system_flag,
			f.rdb$segment_length as segment_length,
			f.rdb$external_length as external_length,
			f.rdb$external_scale as external_scale,
			et.rdb$type_name as external_type,
			f.rdb$dimensions as dimensions,
			f.rdb$null_flag as null_flag,
			f.rdb$character_length as ch_length,
			f.rdb$collation_id as collation_id,
			f.rdb$character_set_id as charset_id,
			f.rdb$field_precision as field_precision
		from
			rdb$fields f
			inner join rdb$types t on
				t.rdb$field_name = 'RDB$FIELD_TYPE'
				and t.rdb$type = f.rdb$field_type
			left join rdb$types st on
				st.rdb$field_name = 'RDB$FIELD_SUB_TYPE'
				and st.rdb$type = f.rdb$field_sub_type
			left join rdb$types et on
				et.rdb$field_name = 'RDB$FIELD_TYPE'
				and et.rdb$type = f.rdb$external_type
		where
			(f.rdb$system_flag = ? or ? is null)
			and (f.rdb$field_name = ? or ? is null)
		]], system_flag, system_flag, name, name
end

function domains.queries:insert(new)
	return sql.parse_template('create domain :NAME', new)
end

function domains.queries:update(new, old)
	local t = {NAME = old.NAME}
	return sql.parse_template('alter domain :NAME', t)
end

function domains.queries:delete(_, old)
	return sql.parse_template('drop domain :NAME', old)
end

------------------------------------------------------------------------------


--[=[
do
	local function query(name)
		return [[
			select
				rdb$security_class as name,
				rdb$acl as acl,
				rdb$description as description
			from
				rdb$security_classes
			where
				rdb$security_class = ? or ? is null
			]], name, name
	end
	security_classes = oo.class({
		keys = {'NAME'},
		queries = {
			load = function() return query() end,
			update = function(e) return query(e.NAME) end,
		}
	}, objects)
end

do
	local function query(name, system_flag)
		system_flag = bool2int(system_flag)
		return [[
			select
				rdb$role_name as name,
				rdb$owner_name as owner,
				rdb$description as description,
				rdb$system_flag as system_flag
			from
				rdb$roles
			where
				(rdb$system_flag = ? or ? is null)
				and (rdb$role_name = ? or ? is null)
			]], system_flag, system_flag, name, name
	end
	roles = oo.class({
		keys = {'NAME'},
		queries = {
			load = function(self) return query(nil, self.system_flag) end,
			update = function(self, e) return query(e.NAME, true) end,
			describe = function(self, e) return format('comment on sequence $NAME is %DESCRIPTION', e) end,
		}
	}, objects)
end

do
	local function query(name, system_flag)
		system_flag = bool2int(system_flag)
		return [[
			select
				rdb$generator_id as id,
				rdb$generator_name as name,
				rdb$system_flag as system_flag,
				rdb$description as description
			from
				rdb$generators
			where
				(rdb$system_flag = ? or ? is null)
				and (rdb$generator_name = ? or ? is null)
			]], system_flag, system_flag, name, name
	end
	generators = oo.class({
		keys = {'ID', 'NAME'},
		queries = {
			load		= function(self) return query(nil, self.options.system_flag) end,
			update		= function(self, e) return query(e.NAME, true) end,
			describe	= 'comment on generator $NAME is %DESCRIPTION',
			create		= 'create sequence $NAME", e)',
			alter		= 'alter sequence $NAME restart with %VALUE',
		},
		refresh = function(self)
			objects.refersh(self)
			for name, e in pairs(self.by.NAME) do
				for st, value in self.transaction:exec(format('select gen_id($NAME,0) from rdb$database', name)) do
					e.VALUE = value
				end
			end
		end,
		load = function(self)
			objects.load(self, e)
			for st, value in self.transaction:exec(format('select gen_id($NAME,0) from rdb$database', e.NAME)) do
				e.VALUE = value
			end
		end,
	}, objects)
end

do
	local function query(name, system_flag)
		system_flag = bool2int(system_flag)
		return [[
			select
				rdb$exception_number as number,
				rdb$exception_name as name,
				rdb$message as message,
				rdb$description as description,
				rdb$system_flag as system_flag
			from
				rdb$exceptions
			where
				(rdb$system_flag = ? or ? is null)
				and (rdb$exception_name = ? or ? is null)
			]], system_flag, system_flag, name, name
	end

	function loaders.exceptions(tr, t,...)
		load(tr, newe, indexf(t, 'NUMBER', 'NAME'), query(...))
	end
end

do
	local function query(name, system_flag)
		system_flag = bool2int(system_flag)
		return [[
			select
				c.rdb$character_set_id as id,
				c.rdb$character_set_name as name,
				c.rdb$default_collate_name as default_collate
			from
				rdb$character_sets c
			where
				(c.rdb$system_flag = ? or ? is null)
				and (c.rdb$character_set_name = ? or ? is null)
			]], system_flag, system_flag, name, name
	end

	function charsets.load(tr, t, collations,...)
		local function add(e)
			index(e, t, 'ID', 'NAME')
			link(e, collations, 'default_collation', 'DEFAULT_COLLATE', 'NAME')
		end
		init_indices(t, 'ID', 'NAME')
		load(tr, new, add, query(...))
	end
end

do
	local function query(name, charset_id, system_flag)
		system_flag = bool2int(system_flag)
		return [[
			select
				c.rdb$collation_id as id,
				c.rdb$collation_name as name,
				c.rdb$character_set_id as charset_id,
			from
				rdb$collations c
			where
				(c.rdb$system_flag = ? or ? is null)
				and (c.rdb$collation_name = ? or ? is null)
				and (c.rdb$character_set_id = ? or ? is null)
		]], system_flag, system_flag, name, name, charset_id, charset_id
	end

	function loaders.collations(tr, t, charsets,...)
		local function add(e)
			index(e, t, 'NAME')
			route(e, charsets, 'CHARSET_ID', 'ID', 'collations', 'charset', 'NAME')
		end
		init_indices(t, 'NAME')
		init_routes(charsets, 'ID', 'collations')
		load(tr, newe, add, query(...))
	end
end

function queries.collations.create(e)
	return format_sql("create collation %NAME for charset %CHARSET_NAME from external ('%EXTNAME')",
		function(key) return e[key] or e.charset.NAME end)
end

do
	local function query(name, system_flag)
		system_flag = bool2int(system_flag)
		return [[
			select
				f.rdb$function_name as name,
				f.rdb$description as description,
				f.rdb$module_name as library,
				f.rdb$entrypoint as entry_point,
				f.rdb$return_argument as return_argument_position,
				f.rdb$system_flag as system_flag
			from
				rdb$functions f
			where
				(f.rdb$system_flag = ? or ? is null)
				and (f.rdb$function_name = ? or ? is null)
			]], system_flag, system_flag, name, name
	end

	function loaders.functions(tr, t,...)
		load(tr, newe, indexf(t, 'NAME'), query(...))
	end
end

do
	local function query(function_name, system_flag)
		system_flag = bool2int(system_flag)
		return [[
			select
				a.rdb$function_name as function_name,
				a.rdb$argument_position as position,
				tm.rdb$type_name as mechanism,
				tt.rdb$type_name as field_type,
				a.rdb$field_scale as field_scale,
				a.rdb$field_length as field_length,
				a.rdb$field_sub_type as subtype,
				a.rdb$character_set_id as charset_id,
				a.rdb$field_precision as field_precision,
				a.rdb$character_length as ch_length
			from
				rdb$function_arguments a
				inner join rdb$functions f on
					f.rdb$function_name = a.rdb$function_name
				left join rdb$types tm on
					tm.rdb$field_name = 'RDB$MECHANISM'
					and tm.rdb$type = a.rdb$mechanism
				inner join rdb$types tt on
					tt.rdb$field_name = 'RDB$FIELD_TYPE'
					and tt.rdb$type = a.rdb$field_type
			where
				(f.rdb$system_flag = ? or ? is null)
				and (a.rdb$function_name = ? or ? is null)
			]], system_flag, system_flag, name, name
	end

	function loaders.function_args(tr, functions,...)
		local add = routef(functions, 'FUNCTION_NAME', 'NAME', 'args', 'function', 'NAME')
		load(tr, newe, add, query(...))
	end
end

do
	local function query(name, with_source, system_flag)
		system_flag = bool2int(system_flag)
		return [[
			select
				p.rdb$procedure_id as id,
				p.rdb$procedure_name as name,
				p.rdb$description as description,
				case when ? is null then null else p.rdb$procedure_source end as source
			from
				rdb$procedures p
			where
				(p.rdb$system_flag = ? or ? is null)
				and (p.rdb$procedure_name = ? or ? is null)
			]], with_source, system_flag, system_flag, name, name
	end

	function loaders.procedures(tr, t,...)
		load(tr, newe, indexf(t, 'ID', 'NAME'), query(...))
	end
end

do
	local function query(name, system_flag)
		system_flag = bool2int(system_flag)
		return [[
			select
				i.rdb$index_name,
				i.rdb$relation_name,
				i.rdb$unique_flag,
				i.rdb$description,
				i.rdb$segment_count,
				i.rdb$index_inactive,
				i.rdb$foreign_key,
				i.rdb$system_flag,
				i.rdb$expression_source,
				i.rdb$statistics
			from
				rdb$indices i
		]]
	end

	function loaders.indices(tr,t,...)
		load(tr, newe, indexf(t, 'NAME'), query(...))
	end
end

do
	local function query(name)
		return [[
			select
			i.rdb$index_name,
			i.rdb$relation_name,
			i.rdb$unique_flag,
			i.rdb$description,
			i.rdb$segment_count,
			i.rdb$index_inactive,
			i.rdb$foreign_key,
			i.rdb$system_flag,
			i.rdb$expression_source,
			i.rdb$statistics
		from
			rdb$
		]]
	end

	function loaders.foreign_keys(tr,t,...)
		load(tr, newe, indexf(t, 'NAME'), query(...))
	end
end

function load(tr, opts)
	loaders.security_classes()

]=]

schema = oo.class()

function schema:__init(t)
	local self = oo.rawnew(self, t)
	self.domains = domains{options = self.options}
	self.tables = tables{options = self.options}
	self.table_fields = table_fields_detail{parent = self.tables, options = self.options}
	self.table_fields.foreigns.domain = self.domains
	self.tables.fields = self.table_fields
	return self
end

function schema:load(tr)
	for i,list in ipairs{
		self.domains,
		self.tables,
		self.table_fields,
	} do
		list:load(tr)
	end
end

function schema:compare(older)
	return coroutine.wrap(function()
		for i,list_name in ipairs{
			'domains',
			'tables',
		} do
			for action, old_e, new_e in self[list_name]:compare(older[list_name]) do
				coroutine.yield(action, old_e, new_e)
			end
		end
	end)
end

function schema:diff(older)
	return coroutine.wrap(function()
		for i,list_name in ipairs{
			'domains',
			'tables',
		} do
			self[list_name]:diff(older[list_name])
		end
	end)
end

return schema

