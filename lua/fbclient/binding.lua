--[[
	Alien binding of the fbclient shared library

	Based on the latest jrd/ibase.h located at:
		http://firebird.cvs.sourceforge.net/viewvc/*checkout*/firebird/firebird2/src/jrd/ibase.h

	new(libname) -> fbapi
	is_library(fbapi) -> true|false
	has_symbol(fbapi,symbol) -> true if symbol is present in fbapi
	isc_que_events_callback(f); f = function(result_buf, bufsize, updated_buf)

	fbapi.<isc_function_name>(<args>) -> result

	Notes:

	- most API calls are commented --s,s*,... meaning they return int STATUS_VECTOR, and their
	first argument is an int STATUS_VECTOR[20].
	- dbh*,trh*,sth*,bh* (db, transaction, statement, blob, etc. handle) is a pointer to a buffer
	of sizeof(pointer) that you have to allocate yourself and initialize to NULL.

	Missing functions: (don't worry, they aren't needed)

	isc_print_*() -- we don't print stuff with database APIs in this country
	isc_interprete() --deprecated in fb 2.0 as dangerous and replaced by fb_interpret().
	isc_start_transaction() -- same as isc_start_multiple(), but with varargs instead of a TEB array
	isc_dsql_finish:types{abi=FBABI,ret=i,p} --status,dbh*; said to have no purpose and do nothing
	isc_dsql_insert:types{abi=FBABI,ret=i,p,p,H,p} --s,s*,sth*,H,xsqlda*; --not documented
	isc_prepare_transaction() and isc_prepare_transaction2()
		-- why in Satan's Glorious Name would we ever want to break ACID of a two-phase commit?
	isc_dsql_allocate_statement:types{abi=FBABI,ret=i,p,p,p} --s,s*,dbh*,sth*
		-- we instead use isc_dsql_allocate_statement2() which frees all statements automatically
		upon database detatchment (no biggie).
	isc_dsql_exec_immed2:types{abi=FBABI,ret=i,p,p,p,H,s,H,p,p} --s,s*,dbh*,trh*,#query,query,dialect,in_xsqlda*,out_xsqlda*
		-- *can be* used for statements returning a single row of data directly in an XSQLDA.
		-- you can't use this if you don't know the types and max. sizes of returned values in advance,
		rendering this function pretty useless.
	isc_expand_dpb() -- only for tube computers.
	isc_modify_dpb:types{abi=FBABI,ret=p,p,H,s,h} --char**,h*,H,s,h --undocumented
	isc_free:types{abi=FBABI,ret=i,s} --undocumented
	isc_vax_integer() -- we use the '<' flag of alien.struct to enforce byte order in structs instead.
	isc_create_blob{abi=FBABI,ret=i,p,p,p,p,p} --s,s*,dbh*,trh*,bh*,blob_id* (old version, we use isc_create_blob2())
	isc_event_block_a() -- non-vararg variant of isc_event_block() but not exported in linux
	BLOB_*() --lots of phantoms in the attic we have no use for

]]

module(...,require 'fbclient.module')

local FBABI = 'stdcall'
--NOTE: "char" is unsigned in alien; the signed byte is called "byte". joy.
local v,c,i,I,h,H,l,L,p,s,cb =
	'void','char','int','uint','short','ushort','long','ulong','pointer','string','callback'

function has_symbol(lib,sym)
	--TODO: replace this ugly hack with a nice alien built-in symbol test function.
	return (pcall(function() local _ = lib[sym] end))
end

local alien_library_meta

function is_library(lib)
	--TODO: replace this hack with a nice alien built-in library test function.
	return getmetatable(lib) == alien_library_meta
end

function new(libname)
	local lib = alien.load(libname)
	alien_library_meta = getmetatable(lib)
	alien_library_meta.__type = 'alien library'

	--library info: this only gets you the interbase compatibility version, not the client library version!
	lib.isc_get_client_version:types{abi=FBABI,ret=v,s}
	lib.isc_get_client_major_version:types{abi=FBABI,ret=i}
	lib.isc_get_client_minor_version:types{abi=FBABI,ret=i}
	--error reporting
	lib.fb_interpret:types{abi=FBABI,ret=i,p,I,p} --more?,msg,#msg,s**
	lib.isc_sqlcode:types{abi=FBABI,ret=i,p} --sqlcode,s*; deprecated in favor of fb_sqlstate()
	lib.isc_sql_interprete:types{abi=FBABI,ret=v,h,s,h} --sqlcode,msgbuf,#msgbuf; deprecated in firebird 2.5 in favor of fb_sqlstate().
	if has_symbol(lib,'fb_sqlstate') then -- fbclient v2.5+
		lib.fb_sqlstate:types{abi=FBABI,ret=v,p,p} --sqlstate_buf*,s*; firebird 2.5+
	end
	--databases
	lib.isc_attach_database:types{abi=FBABI,ret=i,p,h,s,p,h,s} --s,s*,#db_name,db_name,dbh*,#DPB,DPB*; means connect
	lib.isc_detach_database:types{abi=FBABI,ret=i,p,p} --s,s*,dbh*; means disconnect
	lib.isc_create_database:types{abi=FBABI,ret=i,p,h,s,p,h,s,h} --s,s*,#db_name,db_name,dbh*,#DPB,DPB*,db_type=0
	lib.isc_drop_database:types{abi=FBABI,ret=i,p,p} --s,s*,dbh*
	lib.isc_database_info:types{abi=FBABI,ret=i,p,p,h,s,h,p} --s,s*,dbh*,#opts,opts*,#info_buf,info_buf*
	lib.isc_version:types{abi=FBABI,ret=i,p,cb,p} --version,dbh*,callback,calback_arg1
	if has_symbol(lib,'fb_cancel_operation') then -- fbclient 2.5+
		lib.fb_cancel_operation:types{abi=FBABI,ret=i,p,p,H} --s,s*,dbh*,option; firebird 2.5+
	end
	--transactions
	lib.isc_start_multiple:types{abi=FBABI,ret=i,p,p,h,p} --s,s*,trh*,db_count,TEB* (TEB=array of {dbh*,#TPB,TPB*})
	lib.isc_commit_transaction:types{abi=FBABI,ret=i,p,p} --s,s*,trh* (also closes trh)
	lib.isc_commit_retaining:types{abi=FBABI,ret=i,p,p} --s,s*,trh*
	lib.isc_rollback_transaction:types{abi=FBABI,ret=i,p,p} --s,s*,trh* (also closes trh)
	lib.isc_rollback_retaining:types{abi=FBABI,ret=i,p,p} --s,s*,trh*
	lib.isc_transaction_info:types{abi=FBABI,ret=i,p,p,h,s,h,p} --s,s*,trh*,#opts,opts*,#info_buf,info_buf*
	--unprepared statements
	lib.isc_dsql_execute_immediate:types{abi=FBABI,ret=i,p,p,p,H,s,H,p} --s,s*,dhb*,trh*,#query,query,dialect,out_xsqlda*
	--prepared statements
	lib.isc_dsql_alloc_statement2:types{abi=FBABI,ret=i,p,p,p} --s,s*,dbh*,sth*
	lib.isc_dsql_free_statement:types{abi=FBABI,ret=i,p,p,H} --s,s*,sth*,DSQL_close|DSQL_drop
	lib.isc_dsql_prepare:types{abi=FBABI,ret=i,p,p,p,H,s,H,p} --s,s*,trh*,sth*,#query,query,dialect,out_xsqlda*
	lib.isc_dsql_sql_info:types{abi=FBABI,ret=i,p,p,h,s,h,p} --s,s*,sth*,#opts,opts*,#info_buf,info_buf*
	lib.isc_dsql_set_cursor_name:types{abi=FBABI,ret=i,p,p,s,H} --s,s*,sth*,name,0
	lib.isc_dsql_describe:types{abi=FBABI,ret=i,p,p,H,p} --s,s*,sth*,1,out_xsqlda*
	lib.isc_dsql_describe_bind:types{abi=FBABI,ret=i,p,p,H,p} --s,s*,sth*,1,in_xsqlda*
	lib.isc_dsql_execute:types{abi=FBABI,ret=i,p,p,p,H,p} --s,s*,trh*,sth*,1,in_xsqlda*
	lib.isc_dsql_execute2:types{abi=FBABI,ret=i,p,p,p,H,p,p} --s,s*,trh*,sth*,1,in_xsqlda*,out_xsqlda*
	lib.isc_dsql_fetch:types{abi=FBABI,ret=i,p,p,H,p} --s,s*,sth*,1,out_xsqlda*
	--encoding/decoding data
	lib.isc_encode_timestamp:types{abi=FBABI,ret=v,s,p} --struct_tm*,isc_timestamp*
	lib.isc_decode_timestamp:types{abi=FBABI,ret=v,p,p} --isc_timestamp*,struct_tm*
	lib.isc_encode_sql_date:types{abi=FBABI,ret=v,s,p} --struct_tm*,isc_date*
	lib.isc_decode_sql_date:types{abi=FBABI,ret=v,p,p} --isc_date*,struct_tm*
	lib.isc_encode_sql_time:types{abi=FBABI,ret=v,s,p} --struct_tm*,isc_time*
	lib.isc_decode_sql_time:types{abi=FBABI,ret=v,p,p} --isc_time*,struct_tm*
	--segmented blobs
	lib.isc_open_blob2:types{abi=FBABI,ret=i,p,p,p,p,p,H,s} --s,s*,dbh*,trh*,blob_id*,#bpb,bpb*
	lib.isc_create_blob2:types{abi=FBABI,ret=i,p,p,p,p,p,h,s} --s,s*,dbh*,trh*,bh*,blob_id*,#bpb,bpb*
	lib.isc_cancel_blob:types{abi=FBABI,ret=i,p,p} --s,s*,bh*
	lib.isc_close_blob:types{abi=FBABI,ret=i,p,p} --s,s*,bh*
	lib.isc_get_segment:types{abi=FBABI,ret=i,p,p,p,H,p} --s,s*,bh*,#bytes_read*,#buf,buf
	lib.isc_put_segment:types{abi=FBABI,ret=i,p,p,H,s} --s,s*,bh*,#data,data
	lib.isc_blob_info:types{abi=FBABI,ret=i,p,p,h,s,h,p} --s,s*,bh*,#opts,opts,#info_buf,info_buf
	--stream blobs
	lib.isc_seek_blob:types{abi=FBABI,ret=i,p,p,h,l,p} --s,s*,blob_id*,mode,offset,result_offset*
	--blob filters: not used!
	lib.isc_blob_default_desc:types{abi=FBABI,ret=v,p,p,p} --v,ISC_BLOB_DESC*,table_name*,col_name*
	lib.isc_blob_lookup_desc:types{abi=FBABI,ret=i,p,p,p,s,s,p,s} --s,s*,dbh*,trh*,s?,s?,ISC_BLOB_DESC*,s?
	lib.isc_blob_gen_bpb:types{abi=FBABI,ret=i,p,p,p,H,H,s,p} --s,s*,ISC_BLOB_DESC*,ISC_BLOB_DESC*,?,?,s?,H*?
	lib.isc_blob_set_desc:types{abi=FBABI,ret=i,p,s,s,h,h,h,p} --s,s*,s?,s?,h?,h?,h?,ISC_BLOB_DESC*
	--services
	lib.isc_service_attach:types{abi=FBABI,ret=i,p,H,s,p,H,s} --s,s*,slen,service*,svh*,#spb,spb
	lib.isc_service_detach:types{abi=FBABI,ret=i,p,p} --s,s*,svh*
	lib.isc_service_query:types{abi=FBABI,ret=i,p,p,p,H,s,H,s,H,p} --s,s*,svh*,nil,#spb,spb,#req,req,#result,result
	lib.isc_service_start:types{abi=FBABI,ret=i,p,p,p,H,s} --s,s*,svh*,nil,#rb,rb
	--events
	lib.isc_wait_for_event:types{abi=FBABI,ret=i,p,p,h,p,p} --s,s*,dbh*,bufsize,event_buf*,result_buf*
	lib.isc_que_events:types{abi=FBABI,ret=i,p,p,p,h,p,cb,p} --s,s*,dbh*,event_id*,bufsize,event_buf*,event_cb,cb_arg*
	lib.isc_event_counts:types{abi=FBABI,ret=v,p,h,p,p} --s*,bufsize,event_buf*,result_buf*
	lib.isc_cancel_events:types{abi=FBABI,ret=i,p,p,p} --s,s*,dbh*,event_id*
	--needed to do what isc_event_block (which is a vararg function which therefore we can't use) should do
	lib.gds__alloc:types{abi=FBABI,ret=p,l} --block*,size
	--[[
	--events: two problem functions: the first is a vararg function so not supported by alien, the second is not available in Linux.
	lib.isc_event_block:types{abi='cdecl',ret=l,p,p,H,s,s,s,s,s,s,s,s,s,s,s,s,s,s,s} --bufsize,event_buffer*,result_buffer*,count,name1,name2,...,name15
	lib.isc_event_block_a:types{abi=FBABI,ret=H,p,p,H,p} --bufsize,event_buffer*,result_buffer*,count,name_buffer**
	--BSTREAMs: useless layer on top of the blob API
	lib.Bopen:types{abi=FBABI,ret=p,p,p,p,s} --BSTREAM*,blob_id*,dbh*,trh*,mode*
	lib.BLOB_close:types{abi=FBABI,ret=i,p} --1=ok,BSTREAM*
	lib.BLOB_put:types{abi=FBABI,ret=i,c,p} --1=ok,c,BSTREAM*
	lib.BLOB_get:types{abi=FBABI,ret=i,p} --1=ok,BSTREAM*
	--undocumented, so we're not binding
	lib.isc_transact_request:types{abi=FBABI,ret=i,p,p,p,H,s,H,s,H,s} --s,s*,dbh*,trh*,H,s,H,s,H,s
	lib.isc_compile_request:types{abi=FBABI,ret=i,p,p,p,h,s} --s,s*,dbh*,req*,h,s
	lib.isc_compile_request2:types{abi=FBABI,ret=i,p,p,p,h,s} --s,s*,dbh*,req*,h,s
	lib.isc_ddl:types{abi=FBABI,ret=i,p,p,p,h,s} --s,s*,dbh*,trh*,h,s
	]]

	return lib
end

function isc_que_events_callback(f)
	return alien.callback(f,{abi=FBABI,ret=v,p,H,p})
end

