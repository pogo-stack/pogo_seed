create table __user_sessions (
	id serial primary key,
	user_id int not null references __users (id),
	session_id varchar not null,
	started_on timestamptz null,
	active_on timestamptz null,
	ended_on timestamptz null
);

create table __user_emails (
	id serial primary key,
	user_id int not null references __users (id),
	email_address varchar not null,
	is_validated boolean not null default(false),
	updated_time_stamp timestamptz not null default(current_timestamp),
	CONSTRAINT "idx__user_emails_unique" UNIQUE (email_address)
);

create table __user_details (
	id serial primary key,
	user_id int not null references __users (id),
	nick_name varchar not null,
	first_name varchar null,
	last_name varchar null,
	updated_time_stamp timestamptz not null default(current_timestamp),
	CONSTRAINT "idx__user_details_unique" UNIQUE (user_id)

);
