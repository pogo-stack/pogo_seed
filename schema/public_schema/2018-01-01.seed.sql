CREATE TYPE pogo__server__return__type AS (
	http_code integer,
	response_content bytea,
	additional jsonb
);

CREATE TYPE pogo__server____pipeline_return__type AS (
	server_return pogo__server__return__type,
	continue_execution boolean
);

CREATE SEQUENCE seq_pogo
	START WITH 1
	INCREMENT BY 1
	NO MINVALUE
	NO MAXVALUE
	CACHE 1;

CREATE TYPE pogo__return__type AS (
	text_content text,
	jsonb_content jsonb,
	binary_content bytea,
	response_content jsonb
);

create table __users (
	id serial primary key,
	created_time_stamp timestamptz not null default(current_timestamp)
);


CREATE TABLE __pogo__errors (
	id character varying NOT NULL,
	time_stamp timestamp with time zone,
	user_id integer,
	params character varying,
	line_number integer,
	stack character varying,
	sql_state character varying,
	sql_error character varying,
	function_name character varying
);

create table __pogo_requests_audit (
	id serial primary key,
	domain varchar not null,
	path varchar not null,
	function_name varchar null,
	request jsonb not null,
	cookies jsonb not null,
	headers jsonb not null,
	files jsonb not null,
	time_stamp timestamp with time zone not null default clock_timestamp()
);


create table __pogo__all_schemas (
	id serial primary key,
	schema_name varchar not null
);

create table __pogo__schema_routing (
	id serial primary key,
	domain_name varchar not null,
	additional_data jsonb null,
	schema_id integer not null references __pogo__all_schemas(id),
	is_default boolean not null default(false),
	time_stamp timestamp with time zone not null default clock_timestamp()
);

create table __pogo_lu_schema_rights (
	id integer primary key,
	name varchar not null
);

insert into __pogo_lu_schema_rights (id, name) values (1, 'Owner'), (2, 'Admin');

create table __pogo_schema_users (
	id serial primary key,
	schema_id integer not null references __pogo__all_schemas(id),
	user_id integer not null references __users(id),
	schema_right_id integer references __pogo_lu_schema_rights(id),
	time_stamp timestamp with time zone not null default clock_timestamp()
);

create unique index idx_schema_routing_unique on __pogo__schema_routing (domain_name, schema_id);
create unique index ids_schema_routing_unique_domain on __pogo__schema_routing (domain_name);

create table __pogo__files(
	id serial primary key,
	file_name varchar not null,
	file_contents bytea not null,
	mime_type varchar not null,
	user_id integer not null references __users(id),
	additional jsonb null,
	time_stamp timestamp with time zone not null default clock_timestamp()
);

create table __pogo__breakpoints(
	id serial primary key, 
	page varchar,
	line int
);


create table __pogo_debugger_queue(
   id varchar primary key,
   request_time_stamp timestamp with time zone not null,
   response_time_stamp timestamp with time zone,
   request jsonb,
   response jsonb,
   request_count integer null default(0)
);


create table __pogo_debugger_trace(
   id serial primary key,
   thread_id varchar not null,
   frame_depth integer null,
   page varchar null,
   line integer null,
   time_stamp timestamp with time zone not null default clock_timestamp()
);


create or replace function __pogo_assign_schema(domain varchar, new_schema_name varchar, user_id integer, additional_data jsonb)
returns bool
LANGUAGE plpgsql
AS $$
declare
	x_next_reserved_schema_id integer := (select pas.id from __pogo__all_schemas pas where schema_name like '_reserve%' order by schema_name limit 1);
	x_next_reserved_schema_name varchar := (select pas.schema_name from __pogo__all_schemas pas where pas.id = x_next_reserved_schema_id);
begin
	if x_next_reserved_schema_id is not null then
		update __pogo__all_schemas set schema_name = new_schema_name where id = x_next_reserved_schema_id;
		execute 'alter schema ' || x_next_reserved_schema_name || ' rename to ' || new_schema_name;
		insert into __pogo__schema_routing (domain_name, schema_id, additional_data) values (domain, x_next_reserved_schema_id, additional_data);
		insert into __pogo_schema_users (user_id, schema_id, schema_right_id) values (user_id, x_next_reserved_schema_id, 1);
		return true;
	end if;
	return false;
end;
$$;

create or replace function __pogo_change_active_schema(domain varchar)
returns integer
LANGUAGE plpgsql
AS $$
declare
	x_schema_name varchar;
	x_schema_id integer;
begin
	select (select pas.schema_name from __pogo__all_schemas pas where pas.id = pgs.schema_id), schema_id 
	from __pogo__schema_routing pgs 
	into x_schema_name, x_schema_id
	where domain_name ilike domain 
	order by length(domain_name) limit 1;
	
	if x_schema_name is not null then
		execute 'set search_path=' || x_schema_name || ', public';
		return x_schema_id;
	end if;
	return null;
end;
$$;

CREATE FUNCTION __pogo__param_nullif(value anyelement, parameter_type varchar)
RETURNS anyelement AS $$
BEGIN
	if parameter_type in ('integer', 'boolean') then
		return nullif(value::varchar, '');
	end if;
	return value;
END;
$$ LANGUAGE plpgsql;



CREATE FUNCTION f_drop_pogo_compiled_function(p_name text) RETURNS integer
	LANGUAGE plpgsql
	AS $$
DECLARE
	st text;
	dropped_count integer;
BEGIN
	if p_name not like 'psp+_%' escape '+' and p_name not like 'psp2+_%' escape '+' and p_name not like 'f+_%' escape '+' then
	return -1;
	end if;

	select
	count(1),
	string_agg(format('drop function %s(%s);', oid::regproc, pg_get_function_identity_arguments(oid)), ' ')
	from pg_proc
	where proname = p_name
	and pg_function_is_visible(oid)
	into dropped_count, st;

	if dropped_count > 0 then
	EXECUTE st;
	end if;

	return dropped_count;
END
$$;



CREATE or replace FUNCTION coalesce2(st character varying) RETURNS character varying
	LANGUAGE plpgsql
	AS $$
BEGIN
	if st is null then return ''; end if;
	return replace(replace(st, '<', '&lt;'), '>', '&gt;');
END;
$$;


CREATE OR REPLACE FUNCTION __pogo_break_point_should_stop(line integer, page varchar, thread_id varchar, existing_frame_depth integer, is_record_trace boolean = false)
RETURNS boolean
LANGUAGE plpgsql
AS $function2$
declare
begin
if thread_id = '<n/a>' then
	return false;
end if;
if is_record_trace then
	insert into __pogo_debugger_trace (thread_id, page, line, frame_depth)
			values (thread_id, page, line, existing_frame_depth);
end if;
return coalesce(nullif(coalesce( 
		( 
			(coalesce(
				current_setting('__pogo.breakpoint__requests', true), '{}')
			)::jsonb#>>('{'|| page ||',' || line::varchar || '}')::varchar[]  )::varchar, ''), '') != '', false) 
				or 
			(coalesce(
				current_setting('__pogo.breakpoint__step', true), 'false')
			)::boolean;
return false;
end;
$function2$;



CREATE OR REPLACE FUNCTION __pogo_stack_push(page_name varchar, page_line integer, is_set boolean, debug_state jsonb, thread_id varchar, page_file_name varchar, existing_frame_depth integer)
RETURNS integer
LANGUAGE plpgsql
AS $function$
declare
	x_depth integer;
	x_stored_stack_depth integer; 
begin
	if nullif(coalesce(current_setting('__pogo.breakpoint__requests', true), '{}'), '{}') is null then
		return -1;
	end if;
	if not is_set then
		insert into __pogo_call_stack (page, line, state, file_name) 
		values (page_name, page_line, debug_state, page_file_name); 
	else
		update __pogo_call_stack set line = page_line, state = debug_state 
		where depth = existing_frame_depth;
	end if;
	x_depth := (select count(1) from __pogo_call_stack);
	return x_depth;
end;
$function$;


CREATE OR REPLACE FUNCTION __pogo_break_points_set(breakpoint_request jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
declare
	x_existing_breakpoints jsonb := coalesce(current_setting('__pogo.breakpoint__requests', true), '{}')::jsonb;
	x_new_breakpoints jsonb; 
begin
	with existing_breakpoints as (
		select aaa.key as page_name, bbb.key as line, bbb.value as breakpoint_id from jsonb_each(x_existing_breakpoints) aaa, jsonb_each(aaa.value) as bbb
	), new_breakpoints as (
		select aa.key as page_name, bb.key as line, bb.value as breakpoint_id from jsonb_each(breakpoint_request) aa, jsonb_each(aa.value) as bb
	), a as (
		select nb.* from new_breakpoints as nb
		union
		select eb.* from existing_breakpoints eb where eb.page_name not in (select nb.page_name from new_breakpoints as nb)
	), b as (
		select jsonb_build_object(a.page_name, jsonb_object_agg(a.line, a.breakpoint_id)) as page_breakpoints from a
		group by page_name
	)
	select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from b, jsonb_each(b.page_breakpoints)
	into x_new_breakpoints;
	perform set_config('__pogo.breakpoint__requests', x_new_breakpoints::varchar, false);
	create temporary table if not exists __pogo_call_stack (
		depth serial primary key,
		page varchar not null,
		file_name varchar not null,
		line integer not null,
		state jsonb null
	);
	return coalesce(current_setting('__pogo.breakpoint__requests', true), '{}')::jsonb;
end;
$function$;

CREATE OR REPLACE FUNCTION __pogo_break_points_clear()
RETURNS integer
LANGUAGE plpgsql
AS $function$
declare
begin
	perform set_config('__pogo.breakpoint__requests', '{}'::varchar, false);
	return 0;
end;
$function$;



CREATE OR REPLACE FUNCTION __pogo_break_points_verify(breakpoint_request jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
declare
begin
	return (
		with b_request as (
			select jsonb_array_elements(breakpoint_request) as b
		), c_pages as (
			select distinct b->>'page' as page from b_request
		), c_breakpoints as (
			select b->>'page' as page, jsonb_array_elements(b->'breakpoints') as breakpint from b_request
		), breakpoints as (
			select 
				(breakpint->>'line')::integer as line, 
				breakpint->>'id' as breakpoint_id,
				page 
			from c_breakpoints
		), calculated_breakpoints as (
			select
				e.page,
				e.line as real_line,
				r.line requested_line,
				abs(e.line - r.line) as distance,
				breakpoint_id
			from __pogo__breakpoints e , breakpoints r
			where e.page = r.page
		), ranked_breakpoints as (
			select
				*,
				row_number() over (partition by page, breakpoint_id order by breakpoint_id, distance) as rank
			from calculated_breakpoints
		), verified_breakpoints as (
			select distinct real_line, breakpoint_id, page
			from ranked_breakpoints rb
			where rb.rank = 1
			group by real_line, breakpoint_id, page
		), verified_breakpoints_json as (
				select jsonb_build_object('page', page, 'breakpoints', jsonb_agg(jsonb_build_object('id', breakpoint_id, 'line', real_line))) as page
				from verified_breakpoints
				where real_line is 
				not null
				group by page
			union
				select jsonb_build_object('page', page, 'breakpoints', '[]'::jsonb) from c_pages where page not in (select page from ranked_breakpoints)
		)
		select jsonb_agg(page) from verified_breakpoints_json
	);end;
$function$;


CREATE OR REPLACE FUNCTION __pogo_break_point(page_line integer, page_name varchar, thread_id varchar, current_page_stack_depth integer)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
declare
x_request_id varchar := nextval('seq_pogo');
x_dblink_name varchar := 'debugger_dblink_' || x_request_id;
x_request_hash varchar := md5(x_request_id);
notification jsonb;
x_response jsonb;
x_new_state jsonb := (select 
							jsonb_build_object(
									'depth', (select count(1) from __pogo_call_stack), 
									'states', jsonb_agg(
												jsonb_build_object(
													'page', __pogo_call_stack.page, 
													'file_name', __pogo_call_stack.file_name, 
													'line', __pogo_call_stack.line, 
													'state', state) 
												order by (case when depth = current_page_stack_depth then 65535 else depth end) desc
												)
									)
						from __pogo_call_stack)::jsonb;
begin
perform dblink_connect(x_dblink_name,'user=' || current_user || ' dbname=' || current_database());
	loop
		begin
			if (select count(1) from __pogo_debugger_queue where id = x_request_hash) = 0 then
			perform dblink_exec(x_dblink_name, 'insert into __pogo_debugger_queue (id, request_time_stamp, request) values (''' || x_request_hash || ''', current_timestamp, ' || quote_literal(x_new_state::text) || ')');
			else
			perform dblink_exec(x_dblink_name, 'update __pogo_debugger_queue set request_count=request_count+1');
			end if;
		perform dblink_exec(x_dblink_name,'commit;');
		notification := json_build_object(
			'hash', x_request_hash,
			'status', 'paused_on_breakpoint',
			'line', page_line,
			'page', page_name,
			'thread_id', thread_id,
			'current_stack_depth', current_page_stack_depth
		);
		perform dblink_exec(x_dblink_name, 'notify queue_debugger, ''' || coalesce(notification::text, '') || ''';');
		perform dblink_exec(x_dblink_name,'commit;');
		select response from __pogo_debugger_queue where id = x_request_hash into x_response;
		if x_response is not null then
				case x_response->>'command'
					when 'continue' then
						perform set_config('__pogo.breakpoint__step', false::varchar, false);
						return jsonb_build_object('command', 'continue');
					when 'clear_breakpoints' then
						perform __pogo_break_points_clear();
						perform set_config('__pogo.breakpoint__step', false::varchar, false);
						return jsonb_build_object('command', 'continue');
					when 'step' then
							perform set_config('__pogo.breakpoint__step', true::varchar, false);
						return jsonb_build_object('command', 'continue');
					when 'set_breakpoints' then
						perform __pogo_break_points_set(x_response->'breakpoints');
						return jsonb_build_object('command', 'retry'); /* set breakpoints response */
					else
						return jsonb_build_object('comman', 'continue');
				end case;
		end if;
		perform pg_sleep(1);
				exception
					when others then
						begin
							insert into __pogo__errors
							(
								id,
								time_stamp,
								user_id,
								params,
								sql_state,
								sql_error,
								function_name
							)
							values
							(
								md5(clock_timestamp()::varchar || 0 || coalesce(sqlstate::varchar,'') || coalesce(sqlerrm::varchar,'')),
								clock_timestamp(),
								0,
								coalesce(x_new_state::varchar, ''),
								sqlstate,
								sqlerrm,
								'pogo_debugger'
							);
							return null;
							exception when others then null;
							return null;
						end;
		end;
	end loop;
perform dblink_disconnect(x_dblink_name);
	exception when others then
	begin
						insert into __pogo__errors
							(
								id,
								time_stamp,
								user_id,
								params,
								sql_state,
								sql_error,
								function_name
							)
							values
							(
								md5(clock_timestamp()::varchar || 0 || coalesce(sqlstate::varchar,'') || coalesce(sqlerrm::varchar,'')),
								clock_timestamp(),
								0,
								coalesce(x_new_state::varchar, ''),
								sqlstate,
								sqlerrm,
								'pogo_debugger'
							);        --perform dblink_disconnect(x_dblink_name);
	end;
return null;
end;
$function$;
