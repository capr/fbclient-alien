
module(...,require 'fbclient.module')

local sql = require 'fbclient.sql'

--[==[ --source: LangRef.pdf
CREATE TABLE table [EXTERNAL [FILE] ’filespec’]
	(<col_def> [, <col_def> | <tconstraint> …]);
<col_def> = col {<datatype> | COMPUTED [BY] (<expr>) | domain}
	[DEFAULT {literal | NULL | USER}]
	[NOT NULL]
	[<col_constraint>]
	[COLLATE collation]
<datatype> =
	{SMALLINT | INTEGER | FLOAT | DOUBLE PRECISION}[<array_dim>]
	| (DATE | TIME | TIMESTAMP}[<array_dim>]
	| {DECIMAL | NUMERIC} [(precision [, scale])] [<array_dim>]
	| {CHAR | CHARACTER | CHARACTER VARYING | VARCHAR} [(int)]
	[<array_dim>] [CHARACTER SET charname]
	| {NCHAR | NATIONAL CHARACTER | NATIONAL CHAR}
	[VARYING] [(int)] [<array_dim>]
	| BLOB [SUB_TYPE {int | subtype_name}] [SEGMENT SIZE int]
	[CHARACTER SET charname]
	| BLOB [(seglen [, subtype])]<array_dim> = [[x:]y [, [x:]y …]]
<expr> = A valid SQL expression that results in a single value.
<col_constraint> = [CONSTRAINT constraint]
	{ UNIQUE
	| PRIMARY KEY
	| REFERENCES other_table [(other_col [, other_col …])]
	[ON DELETE {NO ACTION|CASCADE|SET DEFAULT|SET NULL}]
	[ON UPDATE {NO ACTION|CASCADE|SET DEFAULT|SET NULL}]
	| CHECK (<search_condition>)}
<tconstraint> = [CONSTRAINT constraint]
	{{PRIMARY KEY | UNIQUE} (col [, col …])
	| FOREIGN KEY (col [, col …]) REFERENCES other_table
	[ON DELETE {NO ACTION|CASCADE|SET DEFAULT|SET NULL}]
	[ON UPDATE {NO ACTION|CASCADE|SET DEFAULT|SET NULL}]
	| CHECK (<search_condition>)}
<search_condition> = <val> <operator> {<val> | (<select_one>)}
	| <val> [NOT] BETWEEN <val> AND <val>
	| <val> [NOT] LIKE <val> [ESCAPE <val>]
	| <val> [NOT] IN (<val> [, <val> …] | <select_list>)
	| <val> IS [NOT] NULL
	| <val> {>= | <=}
	| <val> [NOT] {= | < | >}
	| {ALL | SOME | ANY} (<select_list>)
	| EXISTS (<select_expr>)
	| SINGULAR (<select_expr>)
	| <val> [NOT] CONTAINING <val>
	| <val> [NOT] STARTING [WITH] <val>
	| (<search_condition>)
	| NOT <search_condition>
	| <search_condition> OR <search_condition>
	| <search_condition> AND <search_condition>
<val> = { col [<array_dim>] | :variable
	| <constant> | <expr> | <function>
	| udf ([<val> [, <val> …]])
	| NULL | USER | RDB$DB_KEY | ? }
	[COLLATE collation]
<constant> = num | 'string' | charsetname 'string'
<function> = COUNT (* | [ALL] <val> | DISTINCT <val>)
	| SUM ([ALL] <val> | DISTINCT <val>)
	| AVG ([ALL] <val> | DISTINCT <val>)
	| MAX ([ALL] <val> | DISTINCT <val>)
	| MIN ([ALL] <val> | DISTINCT <val>)
	| CAST (<val> AS <datatype>)
	| UPPER (<val>)
	| GEN_ID (generator, <val>)
<operator> = {= | < | > | <= | >= | !< | !> | <> | !=}
<select_one> = SELECT on a single column; returns exactly one value.
<select_list> = SELECT on a single column; returns zero or more values.
<select_expr> = SELECT on a list of values; returns zero or more values.
]==]
function create_table(tab)
	--[[
	<col_def> = col {<datatype> | COMPUTED [BY] (<expr>) | domain}
		[DEFAULT {literal | NULL | USER}]
		[NOT NULL]
		[<col_constraint>]
		[COLLATE collation]
	]]
	local function col_def(name, field)
		local function col_type() --{<datatype> | COMPUTED [BY] (<expr>) | domain}
			return
				K(field.type) or
				C(K'COMPUTED BY (', E(field.computed_by_expr), ')') or
				(field.domain and

			or computed_by() or field.domain
		end
		--[[
		<col_constraint> = [CONSTRAINT constraint]
			{ UNIQUE
			| PRIMARY KEY
			| REFERENCES other_table [(other_col [, other_col …])]
			[ON DELETE {NO ACTION|CASCADE|SET DEFAULT|SET NULL}]
			[ON UPDATE {NO ACTION|CASCADE|SET DEFAULT|SET NULL}]
			| CHECK (<search_condition>)}
		]]
		local function constraint()
			return --
		end
		return C(' ', N(name), col_type(),
			CO(' ',
				C(' ', K'DEFAULT', E(field.default)), --TODO: field.default -> K'USER'
				C(' ', field.not_null, K'NOT NULL')
				constraint(),
				C(' ', K'COLLATE', N(field.collate))
			)
		)
	end
	return sql.run(function()
		return C(' ', K'CREATE TABLE', N(tab.name), '(\n\t', I(col_def, tab.fields, ',\n\t'), '\n)')
	end)
end

function create_table_ast()
	local constraint = CO(
		K'CONSTRAINT'..N'constraint',

		--[[
		<col_constraint> = [CONSTRAINT constraint]
			{ UNIQUE
			| PRIMARY KEY
			| REFERENCES other_table [(other_col [, other_col …])]
			[ON DELETE {NO ACTION|CASCADE|SET DEFAULT|SET NULL}]
			[ON UPDATE {NO ACTION|CASCADE|SET DEFAULT|SET NULL}]
			| CHECK (<search_condition>)}
		]]

	local col_type = KV'type' / K'COMPUTED BY ('..E'computed_by_expr'..')' / N'domain'
			)
	local col_def = N'name'..col_type..
				O(K'DEFAULT'..E'default').. --TODO: field.default -> K'USER'
				O(B'not_null'..K'NOT NULL')..
				O(constraint)..
				O(K'COLLATE'..N'collate')
	return sql.ast(function()
		return K'CREATE TABLE'..N'name'..'(\n\t'..I(col_def, 'fields', ',\n\t')..'\n)'
	end)
end
