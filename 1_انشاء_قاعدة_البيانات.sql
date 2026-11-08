-- ⚠️ هذا الملف لسيرفر Supabase جديد وفاضي فقط. لو اتشغّل على السيرفر الحالي هيقف فورًا من غير ما يغيّر أي حاجة.
do $$ begin
  if to_regclass('public.users') is not null then
    raise exception 'وقف ✋ السيرفر ده فيه البرنامج بالفعل. الملف ده لسيرفر جديد وفاضي فقط، ومفيش أي حاجة اتغيّرت.';
  end if;
end $$;

-- ============================================================================
-- إدارة المخازن — مصنع القطامي: إنشاء قاعدة البيانات كاملة على سيرفر Supabase جديد
-- الاستخدام: Supabase ← SQL Editor ← New query ← الصق الملف كله ← Run
-- الجزء 1: الجداول والفهارس (هيكل فاضي بدون بيانات)، الجزء 2: الصلاحيات والدوال (setup.sql)
-- البيانات نفسها ترجع بعد كده من آخر نسخة احتياطية (الإدارة ← النسخ الاحتياطي ← الاسترجاع)
-- ============================================================================
--
-- PostgreSQL database dump
--


-- Dumped from database version 16.15 (Ubuntu 16.15-0ubuntu0.24.04.1)
-- Dumped by pg_dump version 16.15 (Ubuntu 16.15-0ubuntu0.24.04.1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--



--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--



--
-- Name: admin_delete(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_delete(p_table text, p_id integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
declare n int;
begin
  if not public.app_is_admin() then raise exception 'هذه العملية للمدير فقط' using errcode = '42501'; end if;
  if p_table not in ('employees', 'vehicles', 'warehouses', 'factories', 'regions') then raise exception 'جدول غير مسموح'; end if;
  execute format('delete from public.%I where id = $1', p_table) using p_id;
  get diagnostics n = row_count;
  return jsonb_build_object('deleted', n);
end $_$;


--
-- Name: admin_logins(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_logins() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
  select coalesce(jsonb_agg(jsonb_build_object('email', lower(u.email), 'last_sign_in_at', to_char(u.last_sign_in_at at time zone 'Asia/Kuwait', 'YYYY-MM-DD HH24:MI'))), '[]'::jsonb)
  from auth.users u where public.app_is_admin()
$$;


--
-- Name: admin_offline_keys(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_offline_keys() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select coalesce(jsonb_agg(jsonb_build_object('username', k.username, 'salt', k.salt, 'iter', k.iter, 'wrapped', k.wrapped, 'updated_at', k.updated_at)), '[]'::jsonb)
  from public.offline_keys k where public.app_is_admin()
$$;


--
-- Name: admin_restore(text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_restore(p_table text, p_rows jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
declare cols text; upd text; n int;
begin
  if not public.app_is_admin() then raise exception 'هذه العملية للمدير فقط' using errcode = '42501'; end if;
  if p_table not in ('employees', 'vehicles', 'regions', 'factories', 'warehouses', 'prod_warehouses', 'materials', 'event_types', 'deliveries',
                     'expenses', 'diesel_refuels', 'diesel_odometer', 'batches', 'issues', 'perf_records', 'emp_records', 'goods_groups',
                     'goods_items', 'goods_records', 'goods_lines', 'activity_log', 'users') then raise exception 'جدول غير مسموح'; end if;
  select string_agg(quote_ident(c.column_name), ',' order by c.ordinal_position),
         string_agg(format('%1$I = excluded.%1$I', c.column_name), ',' order by c.ordinal_position) filter (where c.column_name <> 'id')
    into cols, upd
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = p_table and c.column_name <> 'password_hash'
    and exists (select 1 from jsonb_array_elements(p_rows) r where r ? c.column_name limit 1);
  if p_table = 'users' then
    -- على سيرفر جديد: حساب المدير المؤقت (نفس الاسم برقم مختلف) يُستبدل بصف النسخة
    delete from public.users u using jsonb_array_elements(p_rows) r
      where lower(u.username) = lower(r ->> 'username') and u.id <> (r ->> 'id')::int;
    p_rows := (select jsonb_agg(r || jsonb_build_object('password_hash', '-')) from jsonb_array_elements(p_rows) r);
    cols := cols || ',password_hash';
  end if;
  execute format('insert into public.%I (%s) select %s from jsonb_populate_recordset(null::public.%I, $1) on conflict (id) do update set %s',
                 p_table, cols, cols, p_table, upd) using p_rows;
  get diagnostics n = row_count;
  execute format('select setval(pg_get_serial_sequence(%L, %L), greatest(coalesce((select max(id) from public.%I), 0), 1))', 'public.' || p_table, 'id', p_table);
  return jsonb_build_object('rows', n);
end $_$;


--
-- Name: admin_save(text, integer, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_save(p_table text, p_id integer, p_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
declare allowed text[]; k text; cols text; res jsonb;
begin
  if not public.app_is_admin() then raise exception 'هذه العملية للمدير فقط' using errcode = '42501'; end if;
  allowed := case p_table
    when 'users' then array['username', 'full_name', 'is_admin', 'active', 'perms', 'email']
    when 'employees' then array['name', 'job_title', 'is_driver', 'in_performance', 'active']
    when 'vehicles' then array['number', 'model', 'type', 'active', 'diesel_rate']
    when 'warehouses' then array['name', 'active']
    when 'factories' then array['name', 'active']
    when 'regions' then array['name', 'active']
    else null end;
  if allowed is null then raise exception 'جدول غير مسموح'; end if;
  for k in select jsonb_object_keys(p_data) loop
    if not k = any(allowed) then raise exception 'عمود غير مسموح: %', k; end if;
  end loop;
  if p_table = 'users' and p_data ? 'email' then p_data := jsonb_set(p_data, '{email}', coalesce(to_jsonb(nullif(lower(trim(p_data ->> 'email')), '')), 'null'::jsonb)); end if;
  if p_id is null then
    if p_table = 'users' then p_data := p_data || jsonb_build_object('password_hash', '-', 'created_at', to_char(now() at time zone 'Asia/Kuwait', 'YYYY-MM-DD HH24:MI:SS')); end if;
    select string_agg(quote_ident(x), ',') into cols from jsonb_object_keys(p_data) x;
    execute format('insert into public.%I (%s) select %s from jsonb_populate_record(null::public.%I, $1) returning to_jsonb(%I.*)', p_table, cols, cols, p_table, p_table)
      using p_data into res;
  else
    select string_agg(quote_ident(x), ',') into cols from jsonb_object_keys(p_data) x;
    execute format('update public.%I set (%s) = (select %s from jsonb_populate_record(null::public.%I, $1)) where id = $2 returning to_jsonb(%I.*)', p_table, cols, cols, p_table, p_table)
      using p_data, p_id into res;
    if res is null then raise exception 'الصف غير موجود'; end if;
  end if;
  return res - 'password_hash';
end $_$;


--
-- Name: admin_save_offline_key(text, text, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_save_offline_key(p_username text, p_salt text, p_iter integer, p_wrapped text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if not public.app_is_admin() then raise exception 'هذه العملية للمدير فقط' using errcode = '42501'; end if;
  insert into public.offline_keys (username, salt, iter, wrapped, updated_at) values (p_username, p_salt, p_iter, p_wrapped, now())
  on conflict (username) do update set salt = excluded.salt, iter = excluded.iter, wrapped = excluded.wrapped, updated_at = now();
end $$;


--
-- Name: admin_set_login(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_set_login(p_email text, p_password text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'auth'
    AS $_$
declare uid uuid;
begin
  if not public.app_is_admin() then raise exception 'هذه العملية للمدير فقط' using errcode = '42501'; end if;
  p_email := lower(trim(coalesce(p_email, '')));
  if p_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'الإيميل غير صحيح'; end if;
  if length(coalesce(p_password, '')) < 8 then raise exception 'كلمة المرور 8 أحرف على الأقل'; end if;
  select id into uid from auth.users where lower(email) = p_email;
  if uid is null then
    uid := gen_random_uuid();
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                            created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change,
                            email_change_token_current, reauthentication_token, is_super_admin)
    values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', p_email, crypt(p_password, gen_salt('bf')), now(),
            '{"provider": "email", "providers": ["email"]}', '{}', now(), now(), '', '', '', '', '', '', false);
    insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (uid::text, uid, jsonb_build_object('sub', uid::text, 'email', p_email, 'email_verified', true), 'email', now(), now(), now());
    return jsonb_build_object('created', true);
  end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = uid;
  return jsonb_build_object('created', false);
end $_$;


--
-- Name: app_can_setting(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_can_setting(k text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select case when k = 'diesel_general_rate' then public.app_level('diesel') >= 3
              when k in ('mat_warning_days', 'mat_critical_days') then public.app_level('materials') >= 3
              when k in ('perf_daily_threshold', 'perf_monthly_threshold') then public.app_level('performance') >= 3
              when k = 'emp_followup_threshold' then public.app_level('employees') >= 3
              when k = 'fix_dismissed' then public.app_level('fixes') >= 2
              else false end
$$;


--
-- Name: app_data_key(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_data_key() RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select s.data_key from public.app_secret s where exists (select 1 from public.app_user())
$$;


--
-- Name: app_heartbeat(boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_heartbeat(p_online boolean DEFAULT true) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  update public.users set last_seen = now(), seen_online = coalesce(p_online, true)
  where id = (select a.id from public.app_user() a)
$$;


--
-- Name: app_is_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_is_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select coalesce((select a.is_admin = 1 from public.app_user() a), false)
$$;


--
-- Name: app_level(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_level(sec text) RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select coalesce((select case when a.is_admin = 1 then 3
                               else coalesce(nullif(a.perms, '')::jsonb ->> sec, '0')::int end
                   from public.app_user() a), 0)
$$;


--
-- Name: app_me(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_me() RETURNS json
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select json_build_object('id', a.id, 'username', a.username, 'full_name', a.full_name,
                           'is_admin', a.is_admin = 1, 'perms', coalesce(nullif(a.perms, ''), '{}')::json)
  from public.app_user() a
$$;


--
-- Name: app_save_offline_key(text, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_save_offline_key(p_salt text, p_iter integer, p_wrapped text) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  insert into public.offline_keys (username, salt, iter, wrapped, updated_at)
  select a.username, p_salt, p_iter, p_wrapped, now() from public.app_user() a
  on conflict (username) do update set salt = excluded.salt, iter = excluded.iter, wrapped = excluded.wrapped, updated_at = now()
$$;


--
-- Name: app_user(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_user() RETURNS TABLE(id integer, username text, full_name text, is_admin integer, perms text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select u.id, u.username, u.full_name, u.is_admin, u.perms
  from public.users u
  where u.active = 1
    and coalesce(auth.jwt() ->> 'email', '') <> ''
    and (lower(u.email) = lower(auth.jwt() ->> 'email')
         or (lower(split_part(auth.jwt() ->> 'email', '@', 2)) = 'qattami.app'
             and lower(u.username) = lower(split_part(auth.jwt() ->> 'email', '@', 1))))
  order by (lower(u.email) = lower(auth.jwt() ->> 'email')) desc nulls last
  limit 1
$$;


--
-- Name: goods_delete(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.goods_delete(p_id integer) RETURNS json
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare rid int;
begin
  delete from goods_lines where record_id = p_id;
  delete from goods_records where id = p_id returning id into rid;
  if rid is null then raise exception 'ليست لديك صلاحية لهذه العملية أو السند غير موجود' using errcode = '42501'; end if;
  return json_build_object('id', rid);
end $$;


--
-- Name: goods_save(integer, text, integer, integer, integer, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.goods_save(p_id integer, p_date text, p_group integer, p_factory integer, p_warehouse integer, p_notes text, p_lines text, p_now text) RETURNS json
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $_$
declare
  rid int; no text; me text := (select a.username from public.app_user() a); tot float8;
begin
  if me is null then raise exception 'ليست لديك صلاحية لهذه العملية' using errcode = '42501'; end if;
  if p_date is null or p_date !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'التاريخ غير صحيح'; end if;
  if p_factory is null then raise exception 'اختر المصنع'; end if;
  if p_warehouse is null and exists (select 1 from factories where id = p_factory and name ~ 'ستايروبور|المواد العازلة') then raise exception 'اختر المخزن'; end if;
  select coalesce(sum(value::float8), 0) into tot from jsonb_each_text(p_lines::jsonb);
  if tot <= 0 then raise exception 'اكتب كمية بند واحد على الأقل'; end if;
  if exists (select 1 from jsonb_each_text(p_lines::jsonb) j where value::float8 < 0
             or not exists (select 1 from goods_items i where i.id = j.key::int and i.group_id = p_group)) then
    raise exception 'بند غير تابع لهذه المجموعة أو كمية سالبة';
  end if;
  if p_id is null then
    for i in 1..5 loop
      select 'GDS-' || lpad((coalesce(max(substring(record_no from 5)::int), 0) + 1)::text, 4, '0') into no
        from goods_records where record_no ~ '^GDS-\d+$';
      begin
        insert into goods_records(record_no, date, group_id, notes, created_by, created_at, factory_id, warehouse_id)
          values (no, p_date, p_group, nullif(trim(p_notes), ''), me, p_now, p_factory, p_warehouse) returning id into rid;
        exit;
      exception when unique_violation then rid := null;
      end;
    end loop;
    if rid is null then raise exception 'تعارض في رقم السند، حاول مرة أخرى'; end if;
  else
    update goods_records set date = p_date, notes = nullif(trim(p_notes), ''), factory_id = p_factory, warehouse_id = p_warehouse, updated_by = me, updated_at = p_now
      where id = p_id and group_id = p_group returning id into rid;
    if rid is null then raise exception 'ليست لديك صلاحية لهذه العملية أو السند غير موجود' using errcode = '42501'; end if;
    delete from goods_lines where record_id = rid;
  end if;
  insert into goods_lines(record_id, item_id, qty)
    select rid, key::int, value::float8 from jsonb_each_text(p_lines::jsonb) where value::float8 > 0;
  return json_build_object('rec', (select row_to_json(r) from goods_records r where r.id = rid),
                           'lines', (select coalesce(json_agg(l), '[]'::json) from goods_lines l where l.record_id = rid));
end $_$;


--
-- Name: mat_issue_delete(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mat_issue_delete(p_id integer) RETURNS json
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare i record; did int;
begin
  select * into i from issues where id = p_id;
  if i.id is null then raise exception 'السند غير موجود'; end if;
  if i.child_batch_id is not null and exists (select 1 from issues where batch_id = i.child_batch_id) then
    raise exception 'لا يمكن الحذف: الكمية المنقولة حُوِّل منها بعد ذلك. احذف تلك التحويلات أولًا.';
  end if;
  delete from issues where id = p_id returning id into did;
  if did is null then raise exception 'ليست لديك صلاحية لهذه العملية' using errcode = '42501'; end if;
  if i.child_batch_id is not null then delete from batches where id = i.child_batch_id; end if;
  return json_build_object('id', did, 'child', i.child_batch_id);
end $$;


--
-- Name: mat_issue_edit(integer, text, double precision, integer, integer, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mat_issue_edit(p_id integer, p_date text, p_qty double precision, p_dest integer, p_factory integer, p_notes text, p_now text) RETURNS json
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  me text := (select a.username from public.app_user() a); i record; rem float8; used float8; to_name text;
begin
  select * into i from issues where id = p_id;
  if i.id is null then raise exception 'السند غير موجود'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'يجب أن تكون الكمية أكبر من صفر'; end if;
  perform pg_advisory_xact_lock(88001, i.batch_id);
  rem := (select total_qty from batches where id = i.batch_id) - coalesce((select sum(qty) from issues where batch_id = i.batch_id and id <> p_id), 0);
  if p_qty > rem + 1e-9 then raise exception 'الكمية أكبر من المتاح في الدفعة (%)', round(rem::numeric); end if;
  if coalesce(i.kind, 'prod') = 'internal' then
    used := coalesce((select sum(qty) from issues where batch_id = i.child_batch_id), 0);
    if p_qty < used - 1e-9 then raise exception 'تم تحويل % كجم من الدفعة المنقولة؛ لا يمكن أن تقل الكمية عن ذلك', round(used::numeric); end if;
    update batches set total_qty = p_qty, updated_by = me, updated_at = p_now where id = i.child_batch_id;
    update issues set date = p_date, qty = p_qty, notes = nullif(trim(p_notes), ''), updated_by = me, updated_at = p_now where id = p_id;
  else
    select name into to_name from prod_warehouses where id = p_dest;
    if to_name is null or p_factory is null then raise exception 'مخزن الإنتاج والمصنع مطلوبان'; end if;
    update issues set date = p_date, qty = p_qty, issued_to = to_name, to_warehouse_id = p_dest, factory_id = p_factory,
      notes = nullif(trim(p_notes), ''), updated_by = me, updated_at = p_now where id = p_id;
  end if;
  if not found then raise exception 'ليست لديك صلاحية لهذه العملية' using errcode = '42501'; end if;
  return json_build_object('issue', (select row_to_json(x) from issues x where x.id = p_id),
                           'child', (select row_to_json(c) from batches c where c.id = i.child_batch_id));
end $$;


--
-- Name: mat_transfer(text, text, integer, double precision, text, integer, integer, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mat_transfer(p_no text, p_date text, p_batch integer, p_qty double precision, p_kind text, p_dest integer, p_factory integer, p_notes text, p_now text) RETURNS json
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  me text := (select a.username from public.app_user() a); b record; rem float8; to_name text; child int; cno text; n int := 1; iid int;
begin
  if me is null then raise exception 'ليست لديك صلاحية لهذه العملية' using errcode = '42501'; end if;
  if coalesce(trim(p_no), '') = '' then raise exception 'رقم التحويل مطلوب'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'يجب أن تكون الكمية أكبر من صفر'; end if;
  perform pg_advisory_xact_lock(88001, p_batch);   -- قفل على الدفعة طوال العملية
  select * into b from batches where id = p_batch;
  if b.id is null then raise exception 'الدفعة غير موجودة'; end if;
  rem := b.total_qty - coalesce((select sum(qty) from issues where batch_id = p_batch), 0);
  if p_qty > rem + 1e-9 then raise exception 'الكمية (%) أكبر من المتاح (%)', round(p_qty::numeric), round(rem::numeric); end if;
  if p_kind = 'prod' then
    select name into to_name from prod_warehouses where id = p_dest;
    if to_name is null then raise exception 'مخزن الإنتاج غير موجود'; end if;
    insert into issues(issue_no, date, batch_id, qty, issued_to, notes, created_by, created_at, factory_id, to_warehouse_id, kind)
      values (trim(p_no), p_date, p_batch, p_qty, to_name, nullif(trim(p_notes), ''), me, p_now, p_factory, p_dest, 'prod') returning id into iid;
  elsif p_kind = 'internal' then
    select name into to_name from warehouses where id = p_dest;
    if to_name is null or p_dest = b.warehouse_id then raise exception 'اختر مخزنًا مستلمًا غير مخزن الدفعة'; end if;
    while exists (select 1 from batches where batch_no = b.batch_no || '-T' || n) loop n := n + 1; end loop;
    cno := b.batch_no || '-T' || n;
    insert into batches(batch_no, material_id, warehouse_id, prod_date, expiry_date, arrival_date, weight_per_bag, bags, total_qty, notes,
                        created_by, created_at, factory_id, parent_batch_id)
      values (cno, b.material_id, p_dest, b.prod_date, b.expiry_date, p_date, b.weight_per_bag,
              case when coalesce(b.weight_per_bag, 0) > 0 then round(p_qty / b.weight_per_bag)::int else 0 end, p_qty,
              'منقولة من الدفعة ' || b.batch_no || ' بالسند ' || trim(p_no), me, p_now, p_factory, b.id) returning id into child;
    insert into issues(issue_no, date, batch_id, qty, issued_to, notes, created_by, created_at, factory_id, to_store_id, child_batch_id, kind)
      values (trim(p_no), p_date, p_batch, p_qty, to_name, nullif(trim(p_notes), ''), me, p_now, p_factory, p_dest, child, 'internal') returning id into iid;
  else
    raise exception 'نوع التحويل غير صحيح';
  end if;
  return json_build_object('issue', (select row_to_json(i) from issues i where i.id = iid),
                           'child', (select row_to_json(c) from batches c where c.id = child));
end $$;


--
-- Name: users_keep_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.users_keep_admin() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if old.is_admin = 1 and old.active = 1 and (new.is_admin <> 1 or new.active <> 1)
     and not exists (select 1 from public.users where id <> old.id and is_admin = 1 and active = 1) then
    raise exception 'يجب أن يبقى مدير مفعّل واحد على الأقل';
  end if;
  return new;
end $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: activity_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activity_log (
    id integer NOT NULL,
    ts text NOT NULL,
    username text,
    section text,
    action text,
    details text
);


--
-- Name: activity_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.activity_log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: activity_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.activity_log_id_seq OWNED BY public.activity_log.id;


--
-- Name: app_secret; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_secret (
    id integer DEFAULT 1 NOT NULL,
    data_key text NOT NULL,
    CONSTRAINT app_secret_id_check CHECK ((id = 1))
);


--
-- Name: batches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.batches (
    id integer NOT NULL,
    batch_no text NOT NULL,
    material_id integer NOT NULL,
    warehouse_id integer NOT NULL,
    prod_date text,
    expiry_date text,
    arrival_date text,
    weight_per_bag double precision NOT NULL,
    bags integer NOT NULL,
    total_qty double precision NOT NULL,
    notes text,
    created_by text,
    created_at text,
    updated_by text,
    updated_at text,
    factory_id integer,
    parent_batch_id integer
);


--
-- Name: batches_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.batches_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: batches_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.batches_id_seq OWNED BY public.batches.id;


--
-- Name: deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.deliveries (
    id integer NOT NULL,
    record_no text NOT NULL,
    date text NOT NULL,
    driver_id integer NOT NULL,
    vehicle_id integer NOT NULL,
    region_id integer NOT NULL,
    orders integer NOT NULL,
    notes text,
    created_by text,
    created_at text,
    updated_by text,
    updated_at text,
    factory_id integer,
    warehouse_id integer
);


--
-- Name: deliveries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.deliveries_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: deliveries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.deliveries_id_seq OWNED BY public.deliveries.id;


--
-- Name: diesel_odometer; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.diesel_odometer (
    id integer NOT NULL,
    month text NOT NULL,
    vehicle_id integer NOT NULL,
    start_km double precision,
    end_km double precision,
    updated_by text,
    updated_at text
);


--
-- Name: diesel_odometer_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.diesel_odometer_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: diesel_odometer_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.diesel_odometer_id_seq OWNED BY public.diesel_odometer.id;


--
-- Name: diesel_refuels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.diesel_refuels (
    id integer NOT NULL,
    date text NOT NULL,
    vehicle_id integer NOT NULL,
    driver_id integer NOT NULL,
    liters double precision NOT NULL,
    created_by text,
    created_at text
);


--
-- Name: diesel_refuels_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.diesel_refuels_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: diesel_refuels_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.diesel_refuels_id_seq OWNED BY public.diesel_refuels.id;


--
-- Name: emp_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.emp_records (
    id integer NOT NULL,
    record_no text NOT NULL,
    date text NOT NULL,
    employee_id integer NOT NULL,
    event_type_id integer NOT NULL,
    notes text,
    action_taken text,
    created_by text,
    created_at text,
    updated_by text,
    updated_at text
);


--
-- Name: emp_records_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.emp_records_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: emp_records_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.emp_records_id_seq OWNED BY public.emp_records.id;


--
-- Name: employees; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.employees (
    id integer NOT NULL,
    name text NOT NULL,
    job_title text,
    is_driver integer DEFAULT 0 NOT NULL,
    in_performance integer DEFAULT 0 NOT NULL,
    active integer DEFAULT 1 NOT NULL
);


--
-- Name: employees_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.employees_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: employees_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.employees_id_seq OWNED BY public.employees.id;


--
-- Name: event_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_types (
    id integer NOT NULL,
    name text NOT NULL,
    is_critical integer DEFAULT 0 NOT NULL,
    counts_negative integer DEFAULT 1 NOT NULL,
    active integer DEFAULT 1 NOT NULL,
    severity text,
    points double precision
);


--
-- Name: event_types_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.event_types_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: event_types_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.event_types_id_seq OWNED BY public.event_types.id;


--
-- Name: expenses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.expenses (
    id integer NOT NULL,
    invoice_no text NOT NULL,
    vehicle_id integer NOT NULL,
    driver_id integer NOT NULL,
    date text NOT NULL,
    amount double precision NOT NULL,
    problem text,
    created_by text,
    created_at text,
    updated_by text,
    updated_at text
);


--
-- Name: expenses_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.expenses_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: expenses_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.expenses_id_seq OWNED BY public.expenses.id;


--
-- Name: factories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.factories (
    id integer NOT NULL,
    name text NOT NULL,
    active integer DEFAULT 1 NOT NULL
);


--
-- Name: factories_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.factories_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: factories_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.factories_id_seq OWNED BY public.factories.id;


--
-- Name: goods_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.goods_groups (
    id integer NOT NULL,
    name text NOT NULL,
    sort integer DEFAULT 0 NOT NULL,
    active integer DEFAULT 1 NOT NULL,
    factory_id integer
);


--
-- Name: goods_groups_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.goods_groups_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: goods_groups_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.goods_groups_id_seq OWNED BY public.goods_groups.id;


--
-- Name: goods_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.goods_items (
    id integer NOT NULL,
    group_id integer NOT NULL,
    name text NOT NULL,
    sort integer DEFAULT 0 NOT NULL,
    active integer DEFAULT 1 NOT NULL
);


--
-- Name: goods_items_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.goods_items_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: goods_items_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.goods_items_id_seq OWNED BY public.goods_items.id;


--
-- Name: goods_lines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.goods_lines (
    id integer NOT NULL,
    record_id integer NOT NULL,
    item_id integer NOT NULL,
    qty double precision NOT NULL
);


--
-- Name: goods_lines_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.goods_lines_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: goods_lines_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.goods_lines_id_seq OWNED BY public.goods_lines.id;


--
-- Name: goods_monthly; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.goods_monthly (
    id integer NOT NULL,
    month text NOT NULL,
    item_id integer NOT NULL,
    qty double precision NOT NULL,
    updated_by text,
    updated_at text
);


--
-- Name: goods_monthly_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.goods_monthly_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: goods_monthly_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.goods_monthly_id_seq OWNED BY public.goods_monthly.id;


--
-- Name: goods_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.goods_records (
    id integer NOT NULL,
    record_no text NOT NULL,
    date text NOT NULL,
    group_id integer NOT NULL,
    notes text,
    created_by text,
    created_at text,
    updated_by text,
    updated_at text,
    factory_id integer,
    warehouse_id integer
);


--
-- Name: goods_records_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.goods_records_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: goods_records_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.goods_records_id_seq OWNED BY public.goods_records.id;


--
-- Name: issues; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issues (
    id integer NOT NULL,
    issue_no text NOT NULL,
    date text NOT NULL,
    batch_id integer NOT NULL,
    qty double precision NOT NULL,
    issued_to text,
    notes text,
    created_by text,
    created_at text,
    updated_by text,
    updated_at text,
    factory_id integer,
    to_warehouse_id integer,
    kind text,
    to_store_id integer,
    child_batch_id integer
);


--
-- Name: issues_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.issues_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: issues_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.issues_id_seq OWNED BY public.issues.id;


--
-- Name: login_guard; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.login_guard (
    username text NOT NULL,
    fails integer DEFAULT 0 NOT NULL,
    locked_until double precision
);


--
-- Name: materials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.materials (
    id integer NOT NULL,
    name text NOT NULL,
    active integer DEFAULT 1 NOT NULL,
    description text
);


--
-- Name: materials_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.materials_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: materials_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.materials_id_seq OWNED BY public.materials.id;


--
-- Name: offline_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.offline_keys (
    username text NOT NULL,
    salt text NOT NULL,
    iter integer NOT NULL,
    wrapped text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: perf_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.perf_records (
    id integer NOT NULL,
    record_no text NOT NULL,
    date text NOT NULL,
    warehouse_id integer NOT NULL,
    worker_id integer NOT NULL,
    items_count integer NOT NULL,
    errors integer NOT NULL,
    accuracy double precision NOT NULL,
    notes text,
    created_by text,
    created_at text,
    updated_by text,
    updated_at text
);


--
-- Name: perf_records_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.perf_records_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: perf_records_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.perf_records_id_seq OWNED BY public.perf_records.id;


--
-- Name: prod_warehouses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.prod_warehouses (
    id integer NOT NULL,
    name text NOT NULL,
    active integer DEFAULT 1 NOT NULL
);


--
-- Name: prod_warehouses_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.prod_warehouses_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: prod_warehouses_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.prod_warehouses_id_seq OWNED BY public.prod_warehouses.id;


--
-- Name: regions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.regions (
    id integer NOT NULL,
    name text NOT NULL,
    active integer DEFAULT 1 NOT NULL
);


--
-- Name: regions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.regions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: regions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.regions_id_seq OWNED BY public.regions.id;


--
-- Name: settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.settings (
    key text NOT NULL,
    value text
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id integer NOT NULL,
    username text NOT NULL,
    full_name text NOT NULL,
    password_hash text NOT NULL,
    is_admin integer DEFAULT 0 NOT NULL,
    active integer DEFAULT 1 NOT NULL,
    perms text DEFAULT '{}'::text NOT NULL,
    created_at text,
    email text,
    last_seen timestamp with time zone,
    seen_online boolean DEFAULT false NOT NULL
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: vehicles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vehicles (
    id integer NOT NULL,
    number text NOT NULL,
    model text,
    type text,
    diesel_rate double precision,
    active integer DEFAULT 1 NOT NULL
);


--
-- Name: vehicles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.vehicles_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: vehicles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.vehicles_id_seq OWNED BY public.vehicles.id;


--
-- Name: warehouses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.warehouses (
    id integer NOT NULL,
    name text NOT NULL,
    active integer DEFAULT 1 NOT NULL
);


--
-- Name: warehouses_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.warehouses_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: warehouses_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.warehouses_id_seq OWNED BY public.warehouses.id;


--
-- Name: activity_log id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_log ALTER COLUMN id SET DEFAULT nextval('public.activity_log_id_seq'::regclass);


--
-- Name: batches id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batches ALTER COLUMN id SET DEFAULT nextval('public.batches_id_seq'::regclass);


--
-- Name: deliveries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries ALTER COLUMN id SET DEFAULT nextval('public.deliveries_id_seq'::regclass);


--
-- Name: diesel_odometer id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.diesel_odometer ALTER COLUMN id SET DEFAULT nextval('public.diesel_odometer_id_seq'::regclass);


--
-- Name: diesel_refuels id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.diesel_refuels ALTER COLUMN id SET DEFAULT nextval('public.diesel_refuels_id_seq'::regclass);


--
-- Name: emp_records id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.emp_records ALTER COLUMN id SET DEFAULT nextval('public.emp_records_id_seq'::regclass);


--
-- Name: employees id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employees ALTER COLUMN id SET DEFAULT nextval('public.employees_id_seq'::regclass);


--
-- Name: event_types id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_types ALTER COLUMN id SET DEFAULT nextval('public.event_types_id_seq'::regclass);


--
-- Name: expenses id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses ALTER COLUMN id SET DEFAULT nextval('public.expenses_id_seq'::regclass);


--
-- Name: factories id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.factories ALTER COLUMN id SET DEFAULT nextval('public.factories_id_seq'::regclass);


--
-- Name: goods_groups id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_groups ALTER COLUMN id SET DEFAULT nextval('public.goods_groups_id_seq'::regclass);


--
-- Name: goods_items id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_items ALTER COLUMN id SET DEFAULT nextval('public.goods_items_id_seq'::regclass);


--
-- Name: goods_lines id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_lines ALTER COLUMN id SET DEFAULT nextval('public.goods_lines_id_seq'::regclass);


--
-- Name: goods_monthly id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_monthly ALTER COLUMN id SET DEFAULT nextval('public.goods_monthly_id_seq'::regclass);


--
-- Name: goods_records id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_records ALTER COLUMN id SET DEFAULT nextval('public.goods_records_id_seq'::regclass);


--
-- Name: issues id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issues ALTER COLUMN id SET DEFAULT nextval('public.issues_id_seq'::regclass);


--
-- Name: materials id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.materials ALTER COLUMN id SET DEFAULT nextval('public.materials_id_seq'::regclass);


--
-- Name: perf_records id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.perf_records ALTER COLUMN id SET DEFAULT nextval('public.perf_records_id_seq'::regclass);


--
-- Name: prod_warehouses id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prod_warehouses ALTER COLUMN id SET DEFAULT nextval('public.prod_warehouses_id_seq'::regclass);


--
-- Name: regions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.regions ALTER COLUMN id SET DEFAULT nextval('public.regions_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: vehicles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vehicles ALTER COLUMN id SET DEFAULT nextval('public.vehicles_id_seq'::regclass);


--
-- Name: warehouses id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.warehouses ALTER COLUMN id SET DEFAULT nextval('public.warehouses_id_seq'::regclass);


--
-- Name: activity_log activity_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_log
    ADD CONSTRAINT activity_log_pkey PRIMARY KEY (id);


--
-- Name: app_secret app_secret_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_secret
    ADD CONSTRAINT app_secret_pkey PRIMARY KEY (id);


--
-- Name: batches batches_batch_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batches
    ADD CONSTRAINT batches_batch_no_key UNIQUE (batch_no);


--
-- Name: batches batches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batches
    ADD CONSTRAINT batches_pkey PRIMARY KEY (id);


--
-- Name: deliveries deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_pkey PRIMARY KEY (id);


--
-- Name: deliveries deliveries_record_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_record_no_key UNIQUE (record_no);


--
-- Name: diesel_odometer diesel_odometer_month_vehicle_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.diesel_odometer
    ADD CONSTRAINT diesel_odometer_month_vehicle_id_key UNIQUE (month, vehicle_id);


--
-- Name: diesel_odometer diesel_odometer_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.diesel_odometer
    ADD CONSTRAINT diesel_odometer_pkey PRIMARY KEY (id);


--
-- Name: diesel_refuels diesel_refuels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.diesel_refuels
    ADD CONSTRAINT diesel_refuels_pkey PRIMARY KEY (id);


--
-- Name: emp_records emp_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.emp_records
    ADD CONSTRAINT emp_records_pkey PRIMARY KEY (id);


--
-- Name: emp_records emp_records_record_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.emp_records
    ADD CONSTRAINT emp_records_record_no_key UNIQUE (record_no);


--
-- Name: employees employees_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employees
    ADD CONSTRAINT employees_name_key UNIQUE (name);


--
-- Name: employees employees_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employees
    ADD CONSTRAINT employees_pkey PRIMARY KEY (id);


--
-- Name: event_types event_types_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_types
    ADD CONSTRAINT event_types_name_key UNIQUE (name);


--
-- Name: event_types event_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_types
    ADD CONSTRAINT event_types_pkey PRIMARY KEY (id);


--
-- Name: expenses expenses_invoice_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_invoice_no_key UNIQUE (invoice_no);


--
-- Name: expenses expenses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_pkey PRIMARY KEY (id);


--
-- Name: factories factories_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.factories
    ADD CONSTRAINT factories_name_key UNIQUE (name);


--
-- Name: factories factories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.factories
    ADD CONSTRAINT factories_pkey PRIMARY KEY (id);


--
-- Name: goods_groups goods_groups_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_groups
    ADD CONSTRAINT goods_groups_name_key UNIQUE (name);


--
-- Name: goods_groups goods_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_groups
    ADD CONSTRAINT goods_groups_pkey PRIMARY KEY (id);


--
-- Name: goods_items goods_items_group_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_items
    ADD CONSTRAINT goods_items_group_id_name_key UNIQUE (group_id, name);


--
-- Name: goods_items goods_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_items
    ADD CONSTRAINT goods_items_pkey PRIMARY KEY (id);


--
-- Name: goods_lines goods_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_lines
    ADD CONSTRAINT goods_lines_pkey PRIMARY KEY (id);


--
-- Name: goods_lines goods_lines_record_id_item_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_lines
    ADD CONSTRAINT goods_lines_record_id_item_id_key UNIQUE (record_id, item_id);


--
-- Name: goods_monthly goods_monthly_month_item_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_monthly
    ADD CONSTRAINT goods_monthly_month_item_id_key UNIQUE (month, item_id);


--
-- Name: goods_monthly goods_monthly_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_monthly
    ADD CONSTRAINT goods_monthly_pkey PRIMARY KEY (id);


--
-- Name: goods_records goods_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_records
    ADD CONSTRAINT goods_records_pkey PRIMARY KEY (id);


--
-- Name: goods_records goods_records_record_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_records
    ADD CONSTRAINT goods_records_record_no_key UNIQUE (record_no);


--
-- Name: issues issues_issue_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issues
    ADD CONSTRAINT issues_issue_no_key UNIQUE (issue_no);


--
-- Name: issues issues_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issues
    ADD CONSTRAINT issues_pkey PRIMARY KEY (id);


--
-- Name: login_guard login_guard_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.login_guard
    ADD CONSTRAINT login_guard_pkey PRIMARY KEY (username);


--
-- Name: materials materials_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.materials
    ADD CONSTRAINT materials_name_key UNIQUE (name);


--
-- Name: materials materials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.materials
    ADD CONSTRAINT materials_pkey PRIMARY KEY (id);


--
-- Name: offline_keys offline_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.offline_keys
    ADD CONSTRAINT offline_keys_pkey PRIMARY KEY (username);


--
-- Name: perf_records perf_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.perf_records
    ADD CONSTRAINT perf_records_pkey PRIMARY KEY (id);


--
-- Name: perf_records perf_records_record_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.perf_records
    ADD CONSTRAINT perf_records_record_no_key UNIQUE (record_no);


--
-- Name: prod_warehouses prod_warehouses_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prod_warehouses
    ADD CONSTRAINT prod_warehouses_name_key UNIQUE (name);


--
-- Name: prod_warehouses prod_warehouses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prod_warehouses
    ADD CONSTRAINT prod_warehouses_pkey PRIMARY KEY (id);


--
-- Name: regions regions_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.regions
    ADD CONSTRAINT regions_name_key UNIQUE (name);


--
-- Name: regions regions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.regions
    ADD CONSTRAINT regions_pkey PRIMARY KEY (id);


--
-- Name: settings settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settings
    ADD CONSTRAINT settings_pkey PRIMARY KEY (key);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: users users_username_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_username_key UNIQUE (username);


--
-- Name: vehicles vehicles_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vehicles
    ADD CONSTRAINT vehicles_number_key UNIQUE (number);


--
-- Name: vehicles vehicles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vehicles
    ADD CONSTRAINT vehicles_pkey PRIMARY KEY (id);


--
-- Name: warehouses warehouses_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.warehouses
    ADD CONSTRAINT warehouses_name_key UNIQUE (name);


--
-- Name: warehouses warehouses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.warehouses
    ADD CONSTRAINT warehouses_pkey PRIMARY KEY (id);


--
-- Name: deliveries_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX deliveries_date_idx ON public.deliveries USING btree (date);


--
-- Name: diesel_refuels_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX diesel_refuels_date_idx ON public.diesel_refuels USING btree (date);


--
-- Name: emp_records_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX emp_records_date_idx ON public.emp_records USING btree (date);


--
-- Name: expenses_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX expenses_date_idx ON public.expenses USING btree (date);


--
-- Name: goods_lines_record_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX goods_lines_record_idx ON public.goods_lines USING btree (record_id);


--
-- Name: issues_batch_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX issues_batch_idx ON public.issues USING btree (batch_id);


--
-- Name: ix_deliv_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_deliv_date ON public.deliveries USING btree (date);


--
-- Name: ix_emp_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_emp_date ON public.emp_records USING btree (date);


--
-- Name: ix_expenses_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_expenses_date ON public.expenses USING btree (date);


--
-- Name: ix_goods_lines_rec; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_goods_lines_rec ON public.goods_lines USING btree (record_id);


--
-- Name: ix_goods_month; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_goods_month ON public.goods_monthly USING btree (month);


--
-- Name: ix_goods_rec_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_goods_rec_date ON public.goods_records USING btree (date);


--
-- Name: ix_issues_batch; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_issues_batch ON public.issues USING btree (batch_id);


--
-- Name: ix_log_ts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_log_ts ON public.activity_log USING btree (ts);


--
-- Name: ix_perf_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_perf_date ON public.perf_records USING btree (date);


--
-- Name: ix_refuels_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_refuels_date ON public.diesel_refuels USING btree (date);


--
-- Name: perf_records_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX perf_records_date_idx ON public.perf_records USING btree (date);


--
-- Name: users_email_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_email_key ON public.users USING btree (lower(email)) WHERE (email IS NOT NULL);


--
-- Name: users users_keep_admin; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER users_keep_admin BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.users_keep_admin();


--
-- Name: batches batches_material_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batches
    ADD CONSTRAINT batches_material_id_fkey FOREIGN KEY (material_id) REFERENCES public.materials(id);


--
-- Name: batches batches_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batches
    ADD CONSTRAINT batches_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id);


--
-- Name: deliveries deliveries_driver_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_driver_id_fkey FOREIGN KEY (driver_id) REFERENCES public.employees(id);


--
-- Name: deliveries deliveries_region_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_region_id_fkey FOREIGN KEY (region_id) REFERENCES public.regions(id);


--
-- Name: deliveries deliveries_vehicle_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_vehicle_id_fkey FOREIGN KEY (vehicle_id) REFERENCES public.vehicles(id);


--
-- Name: diesel_odometer diesel_odometer_vehicle_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.diesel_odometer
    ADD CONSTRAINT diesel_odometer_vehicle_id_fkey FOREIGN KEY (vehicle_id) REFERENCES public.vehicles(id);


--
-- Name: diesel_refuels diesel_refuels_driver_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.diesel_refuels
    ADD CONSTRAINT diesel_refuels_driver_id_fkey FOREIGN KEY (driver_id) REFERENCES public.employees(id);


--
-- Name: diesel_refuels diesel_refuels_vehicle_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.diesel_refuels
    ADD CONSTRAINT diesel_refuels_vehicle_id_fkey FOREIGN KEY (vehicle_id) REFERENCES public.vehicles(id);


--
-- Name: emp_records emp_records_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.emp_records
    ADD CONSTRAINT emp_records_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id);


--
-- Name: emp_records emp_records_event_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.emp_records
    ADD CONSTRAINT emp_records_event_type_id_fkey FOREIGN KEY (event_type_id) REFERENCES public.event_types(id);


--
-- Name: expenses expenses_driver_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_driver_id_fkey FOREIGN KEY (driver_id) REFERENCES public.employees(id);


--
-- Name: expenses expenses_vehicle_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_vehicle_id_fkey FOREIGN KEY (vehicle_id) REFERENCES public.vehicles(id);


--
-- Name: goods_items goods_items_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_items
    ADD CONSTRAINT goods_items_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.goods_groups(id);


--
-- Name: goods_lines goods_lines_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_lines
    ADD CONSTRAINT goods_lines_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.goods_items(id);


--
-- Name: goods_lines goods_lines_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_lines
    ADD CONSTRAINT goods_lines_record_id_fkey FOREIGN KEY (record_id) REFERENCES public.goods_records(id);


--
-- Name: goods_monthly goods_monthly_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_monthly
    ADD CONSTRAINT goods_monthly_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.goods_items(id);


--
-- Name: goods_records goods_records_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_records
    ADD CONSTRAINT goods_records_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.goods_groups(id);


--
-- Name: goods_records goods_records_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_records
    ADD CONSTRAINT goods_records_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id);


--
-- Name: issues issues_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issues
    ADD CONSTRAINT issues_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.batches(id);


--
-- Name: perf_records perf_records_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.perf_records
    ADD CONSTRAINT perf_records_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id);


--
-- Name: perf_records perf_records_worker_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.perf_records
    ADD CONSTRAINT perf_records_worker_id_fkey FOREIGN KEY (worker_id) REFERENCES public.employees(id);


--
-- Name: activity_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.activity_log ENABLE ROW LEVEL SECURITY;

--
-- Name: activity_log app_add; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_add ON public.activity_log FOR INSERT TO authenticated WITH CHECK ((username = ( SELECT a.username
   FROM public.app_user() a(id, username, full_name, is_admin, perms))));


--
-- Name: batches app_add; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_add ON public.batches FOR INSERT TO authenticated WITH CHECK (((( SELECT public.app_level('materials'::text) AS app_level) >= 2) AND (created_by = ( SELECT a.username
   FROM public.app_user() a(id, username, full_name, is_admin, perms)))));


--
-- Name: deliveries app_add; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_add ON public.deliveries FOR INSERT TO authenticated WITH CHECK (((( SELECT public.app_level('deliveries'::text) AS app_level) >= 2) AND (created_by = ( SELECT a.username
   FROM public.app_user() a(id, username, full_name, is_admin, perms)))));


--
-- Name: diesel_odometer app_add; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_add ON public.diesel_odometer FOR INSERT TO authenticated WITH CHECK ((( SELECT public.app_level('diesel'::text) AS app_level) >= 2));


--
-- Name: diesel_refuels app_add; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_add ON public.diesel_refuels FOR INSERT TO authenticated WITH CHECK (((( SELECT public.app_level('diesel'::text) AS app_level) >= 2) AND (created_by = ( SELECT a.username
   FROM public.app_user() a(id, username, full_name, is_admin, perms)))));


--
-- Name: emp_records app_add; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_add ON public.emp_records FOR INSERT TO authenticated WITH CHECK (((( SELECT public.app_level('employees'::text) AS app_level) >= 2) AND (created_by = ( SELECT a.username
   FROM public.app_user() a(id, username, full_name, is_admin, perms)))));


--
-- Name: event_types app_add; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_add ON public.event_types FOR INSERT TO authenticated WITH CHECK ((( SELECT public.app_level('employees'::text) AS app_level) >= 3));


--
-- Name: expenses app_add; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_add ON public.expenses FOR INSERT TO authenticated WITH CHECK (((( SELECT public.app_level('cars'::text) AS app_level) >= 2) AND (created_by = ( SELECT a.username
   FROM public.app_user() a(id, username, full_name, is_admin, perms)))));


--
-- Name: goods_groups app_add; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_add ON public.goods_groups FOR INSERT TO authenticated WITH CHECK ((( SELECT public.app_level('goods'::text) AS app_level) >= 3));


--
-- Name: goods_items app_add; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_add ON public.goods_items FOR INSERT TO authenticated WITH CHECK ((( SELECT public.app_level('goods'::text) AS app_level) >= 3));


--
-- Name: goods_lines app_add; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_add ON public.goods_lines FOR INSERT TO authenticated WITH CHECK (((( SELECT public.app_level('goods'::text) AS app_level) >= 3) OR ((( SELECT public.app_level('goods'::text) AS app_level) >= 2) AND (EXISTS ( SELECT 1
   FROM public.goods_records r
  WHERE ((r.id = goods_lines.record_id) AND (r.created_by = ( SELECT a.username
           FROM public.app_user() a(id, username, full_name, is_admin, perms)))))))));


--
-- Name: goods_records app_add; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_add ON public.goods_records FOR INSERT TO authenticated WITH CHECK (((( SELECT public.app_level('goods'::text) AS app_level) >= 2) AND (created_by = ( SELECT a.username
   FROM public.app_user() a(id, username, full_name, is_admin, perms)))));


--
-- Name: issues app_add; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_add ON public.issues FOR INSERT TO authenticated WITH CHECK (((( SELECT public.app_level('materials'::text) AS app_level) >= 2) AND (created_by = ( SELECT a.username
   FROM public.app_user() a(id, username, full_name, is_admin, perms)))));


--
-- Name: materials app_add; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_add ON public.materials FOR INSERT TO authenticated WITH CHECK ((( SELECT public.app_level('materials'::text) AS app_level) >= 3));


--
-- Name: perf_records app_add; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_add ON public.perf_records FOR INSERT TO authenticated WITH CHECK (((( SELECT public.app_level('performance'::text) AS app_level) >= 2) AND (created_by = ( SELECT a.username
   FROM public.app_user() a(id, username, full_name, is_admin, perms)))));


--
-- Name: prod_warehouses app_add; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_add ON public.prod_warehouses FOR INSERT TO authenticated WITH CHECK ((( SELECT public.app_level('materials'::text) AS app_level) >= 3));


--
-- Name: regions app_add; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_add ON public.regions FOR INSERT TO authenticated WITH CHECK ((( SELECT public.app_level('deliveries'::text) AS app_level) >= 2));


--
-- Name: settings app_add; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_add ON public.settings FOR INSERT TO authenticated WITH CHECK (public.app_can_setting(key));


--
-- Name: batches app_del; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_del ON public.batches FOR DELETE TO authenticated USING ((( SELECT public.app_level('materials'::text) AS app_level) >= 3));


--
-- Name: deliveries app_del; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_del ON public.deliveries FOR DELETE TO authenticated USING ((( SELECT public.app_level('deliveries'::text) AS app_level) >= 3));


--
-- Name: diesel_odometer app_del; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_del ON public.diesel_odometer FOR DELETE TO authenticated USING ((( SELECT public.app_level('diesel'::text) AS app_level) >= 3));


--
-- Name: diesel_refuels app_del; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_del ON public.diesel_refuels FOR DELETE TO authenticated USING ((( SELECT public.app_level('diesel'::text) AS app_level) >= 3));


--
-- Name: emp_records app_del; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_del ON public.emp_records FOR DELETE TO authenticated USING ((( SELECT public.app_level('employees'::text) AS app_level) >= 3));


--
-- Name: expenses app_del; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_del ON public.expenses FOR DELETE TO authenticated USING ((( SELECT public.app_level('cars'::text) AS app_level) >= 3));


--
-- Name: goods_items app_del; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_del ON public.goods_items FOR DELETE TO authenticated USING ((( SELECT public.app_level('goods'::text) AS app_level) >= 3));


--
-- Name: goods_lines app_del; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_del ON public.goods_lines FOR DELETE TO authenticated USING ((( SELECT public.app_level('goods'::text) AS app_level) >= 3));


--
-- Name: goods_records app_del; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_del ON public.goods_records FOR DELETE TO authenticated USING ((( SELECT public.app_level('goods'::text) AS app_level) >= 3));


--
-- Name: issues app_del; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_del ON public.issues FOR DELETE TO authenticated USING ((( SELECT public.app_level('materials'::text) AS app_level) >= 3));


--
-- Name: perf_records app_del; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_del ON public.perf_records FOR DELETE TO authenticated USING ((( SELECT public.app_level('performance'::text) AS app_level) >= 3));


--
-- Name: batches app_edit; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_edit ON public.batches FOR UPDATE TO authenticated USING ((( SELECT public.app_level('materials'::text) AS app_level) >= 3)) WITH CHECK ((( SELECT public.app_level('materials'::text) AS app_level) >= 3));


--
-- Name: deliveries app_edit; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_edit ON public.deliveries FOR UPDATE TO authenticated USING ((( SELECT public.app_level('deliveries'::text) AS app_level) >= 3)) WITH CHECK ((( SELECT public.app_level('deliveries'::text) AS app_level) >= 3));


--
-- Name: diesel_odometer app_edit; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_edit ON public.diesel_odometer FOR UPDATE TO authenticated USING ((( SELECT public.app_level('diesel'::text) AS app_level) >= 2)) WITH CHECK ((( SELECT public.app_level('diesel'::text) AS app_level) >= 2));


--
-- Name: emp_records app_edit; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_edit ON public.emp_records FOR UPDATE TO authenticated USING ((( SELECT public.app_level('employees'::text) AS app_level) >= 3)) WITH CHECK ((( SELECT public.app_level('employees'::text) AS app_level) >= 3));


--
-- Name: event_types app_edit; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_edit ON public.event_types FOR UPDATE TO authenticated USING ((( SELECT public.app_level('employees'::text) AS app_level) >= 3)) WITH CHECK ((( SELECT public.app_level('employees'::text) AS app_level) >= 3));


--
-- Name: expenses app_edit; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_edit ON public.expenses FOR UPDATE TO authenticated USING ((( SELECT public.app_level('cars'::text) AS app_level) >= 3)) WITH CHECK ((( SELECT public.app_level('cars'::text) AS app_level) >= 3));


--
-- Name: goods_groups app_edit; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_edit ON public.goods_groups FOR UPDATE TO authenticated USING ((( SELECT public.app_level('goods'::text) AS app_level) >= 3)) WITH CHECK ((( SELECT public.app_level('goods'::text) AS app_level) >= 3));


--
-- Name: goods_items app_edit; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_edit ON public.goods_items FOR UPDATE TO authenticated USING ((( SELECT public.app_level('goods'::text) AS app_level) >= 3)) WITH CHECK ((( SELECT public.app_level('goods'::text) AS app_level) >= 3));


--
-- Name: goods_records app_edit; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_edit ON public.goods_records FOR UPDATE TO authenticated USING ((( SELECT public.app_level('goods'::text) AS app_level) >= 3)) WITH CHECK ((( SELECT public.app_level('goods'::text) AS app_level) >= 3));


--
-- Name: issues app_edit; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_edit ON public.issues FOR UPDATE TO authenticated USING ((( SELECT public.app_level('materials'::text) AS app_level) >= 3)) WITH CHECK ((( SELECT public.app_level('materials'::text) AS app_level) >= 3));


--
-- Name: materials app_edit; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_edit ON public.materials FOR UPDATE TO authenticated USING ((( SELECT public.app_level('materials'::text) AS app_level) >= 3)) WITH CHECK ((( SELECT public.app_level('materials'::text) AS app_level) >= 3));


--
-- Name: perf_records app_edit; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_edit ON public.perf_records FOR UPDATE TO authenticated USING ((( SELECT public.app_level('performance'::text) AS app_level) >= 3)) WITH CHECK ((( SELECT public.app_level('performance'::text) AS app_level) >= 3));


--
-- Name: prod_warehouses app_edit; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_edit ON public.prod_warehouses FOR UPDATE TO authenticated USING ((( SELECT public.app_level('materials'::text) AS app_level) >= 3)) WITH CHECK ((( SELECT public.app_level('materials'::text) AS app_level) >= 3));


--
-- Name: regions app_edit; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_edit ON public.regions FOR UPDATE TO authenticated USING ((( SELECT public.app_level('deliveries'::text) AS app_level) >= 2)) WITH CHECK ((( SELECT public.app_level('deliveries'::text) AS app_level) >= 2));


--
-- Name: settings app_edit; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_edit ON public.settings FOR UPDATE TO authenticated USING (public.app_can_setting(key)) WITH CHECK (public.app_can_setting(key));


--
-- Name: vehicles app_rate; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_rate ON public.vehicles FOR UPDATE TO authenticated USING ((( SELECT public.app_level('diesel'::text) AS app_level) >= 3)) WITH CHECK ((( SELECT public.app_level('diesel'::text) AS app_level) >= 3));


--
-- Name: activity_log app_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_read ON public.activity_log FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.app_user() a(id, username, full_name, is_admin, perms)
  WHERE (a.is_admin = 1))));


--
-- Name: batches app_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_read ON public.batches FOR SELECT TO authenticated USING ((( SELECT public.app_level('materials'::text) AS app_level) >= 1));


--
-- Name: deliveries app_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_read ON public.deliveries FOR SELECT TO authenticated USING ((( SELECT public.app_level('deliveries'::text) AS app_level) >= 1));


--
-- Name: diesel_odometer app_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_read ON public.diesel_odometer FOR SELECT TO authenticated USING ((( SELECT public.app_level('diesel'::text) AS app_level) >= 1));


--
-- Name: diesel_refuels app_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_read ON public.diesel_refuels FOR SELECT TO authenticated USING ((( SELECT public.app_level('diesel'::text) AS app_level) >= 1));


--
-- Name: emp_records app_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_read ON public.emp_records FOR SELECT TO authenticated USING ((( SELECT public.app_level('employees'::text) AS app_level) >= 1));


--
-- Name: employees app_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_read ON public.employees FOR SELECT TO authenticated USING ((( SELECT count(*) AS count
   FROM public.app_user() app_user(id, username, full_name, is_admin, perms)) > 0));


--
-- Name: event_types app_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_read ON public.event_types FOR SELECT TO authenticated USING ((( SELECT count(*) AS count
   FROM public.app_user() app_user(id, username, full_name, is_admin, perms)) > 0));


--
-- Name: expenses app_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_read ON public.expenses FOR SELECT TO authenticated USING ((( SELECT public.app_level('cars'::text) AS app_level) >= 1));


--
-- Name: factories app_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_read ON public.factories FOR SELECT TO authenticated USING ((( SELECT count(*) AS count
   FROM public.app_user() app_user(id, username, full_name, is_admin, perms)) > 0));


--
-- Name: goods_groups app_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_read ON public.goods_groups FOR SELECT TO authenticated USING ((( SELECT count(*) AS count
   FROM public.app_user() app_user(id, username, full_name, is_admin, perms)) > 0));


--
-- Name: goods_items app_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_read ON public.goods_items FOR SELECT TO authenticated USING ((( SELECT count(*) AS count
   FROM public.app_user() app_user(id, username, full_name, is_admin, perms)) > 0));


--
-- Name: goods_lines app_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_read ON public.goods_lines FOR SELECT TO authenticated USING ((( SELECT public.app_level('goods'::text) AS app_level) >= 1));


--
-- Name: goods_records app_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_read ON public.goods_records FOR SELECT TO authenticated USING ((( SELECT public.app_level('goods'::text) AS app_level) >= 1));


--
-- Name: issues app_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_read ON public.issues FOR SELECT TO authenticated USING ((( SELECT public.app_level('materials'::text) AS app_level) >= 1));


--
-- Name: materials app_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_read ON public.materials FOR SELECT TO authenticated USING ((( SELECT count(*) AS count
   FROM public.app_user() app_user(id, username, full_name, is_admin, perms)) > 0));


--
-- Name: perf_records app_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_read ON public.perf_records FOR SELECT TO authenticated USING ((( SELECT public.app_level('performance'::text) AS app_level) >= 1));


--
-- Name: prod_warehouses app_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_read ON public.prod_warehouses FOR SELECT TO authenticated USING ((( SELECT count(*) AS count
   FROM public.app_user() app_user(id, username, full_name, is_admin, perms)) > 0));


--
-- Name: regions app_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_read ON public.regions FOR SELECT TO authenticated USING ((( SELECT count(*) AS count
   FROM public.app_user() app_user(id, username, full_name, is_admin, perms)) > 0));


--
-- Name: settings app_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_read ON public.settings FOR SELECT TO authenticated USING (((( SELECT count(*) AS count
   FROM public.app_user() app_user(id, username, full_name, is_admin, perms)) > 0) AND (key = ANY (ARRAY['diesel_general_rate'::text, 'mat_warning_days'::text, 'mat_critical_days'::text, 'perf_monthly_threshold'::text, 'perf_daily_threshold'::text, 'emp_followup_threshold'::text]))));


--
-- Name: users app_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_read ON public.users FOR SELECT TO authenticated USING (( SELECT public.app_is_admin() AS app_is_admin));


--
-- Name: vehicles app_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_read ON public.vehicles FOR SELECT TO authenticated USING ((( SELECT count(*) AS count
   FROM public.app_user() app_user(id, username, full_name, is_admin, perms)) > 0));


--
-- Name: warehouses app_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_read ON public.warehouses FOR SELECT TO authenticated USING ((( SELECT count(*) AS count
   FROM public.app_user() app_user(id, username, full_name, is_admin, perms)) > 0));


--
-- Name: app_secret; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.app_secret ENABLE ROW LEVEL SECURITY;

--
-- Name: batches; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.batches ENABLE ROW LEVEL SECURITY;

--
-- Name: deliveries; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.deliveries ENABLE ROW LEVEL SECURITY;

--
-- Name: diesel_odometer; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.diesel_odometer ENABLE ROW LEVEL SECURITY;

--
-- Name: diesel_refuels; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.diesel_refuels ENABLE ROW LEVEL SECURITY;

--
-- Name: emp_records; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.emp_records ENABLE ROW LEVEL SECURITY;

--
-- Name: employees; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.employees ENABLE ROW LEVEL SECURITY;

--
-- Name: event_types; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.event_types ENABLE ROW LEVEL SECURITY;

--
-- Name: expenses; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.expenses ENABLE ROW LEVEL SECURITY;

--
-- Name: factories; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.factories ENABLE ROW LEVEL SECURITY;

--
-- Name: goods_groups; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.goods_groups ENABLE ROW LEVEL SECURITY;

--
-- Name: goods_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.goods_items ENABLE ROW LEVEL SECURITY;

--
-- Name: goods_lines; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.goods_lines ENABLE ROW LEVEL SECURITY;

--
-- Name: goods_monthly; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.goods_monthly ENABLE ROW LEVEL SECURITY;

--
-- Name: goods_records; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.goods_records ENABLE ROW LEVEL SECURITY;

--
-- Name: issues; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.issues ENABLE ROW LEVEL SECURITY;

--
-- Name: login_guard; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.login_guard ENABLE ROW LEVEL SECURITY;

--
-- Name: materials; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.materials ENABLE ROW LEVEL SECURITY;

--
-- Name: offline_keys; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.offline_keys ENABLE ROW LEVEL SECURITY;

--
-- Name: perf_records; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.perf_records ENABLE ROW LEVEL SECURITY;

--
-- Name: prod_warehouses; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.prod_warehouses ENABLE ROW LEVEL SECURITY;

--
-- Name: regions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.regions ENABLE ROW LEVEL SECURITY;

--
-- Name: settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.settings ENABLE ROW LEVEL SECURITY;

--
-- Name: users; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

--
-- Name: vehicles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.vehicles ENABLE ROW LEVEL SECURITY;

--
-- Name: warehouses; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.warehouses ENABLE ROW LEVEL SECURITY;

--
-- PostgreSQL database dump complete
--




-- ============================ الجزء 2 ============================
set search_path = public, extensions;
-- ============================================================================
-- إعداد النسخة السريعة من برنامج المخازن (تُشغَّل مرة واحدة في Supabase ← SQL Editor ← Run)
-- آمنة للتشغيل أكثر من مرة. لا تمسح ولا تغيّر أي بيانات؛ تضيف فقط قواعد الحماية والصلاحيات.
--
-- الفكرة: كل مستخدم في البرنامج (مثل amir) له حساب دخول في Supabase بإيميل  amir@qattami.app
-- وصلاحياته تُقرأ من جدول users نفسه (نفس الصلاحيات المضبوطة في البرنامج القديم).
-- ============================================================================

-- 1) من هو المستخدم الحالي في البرنامج؟
--    إما بإيميل حقيقي مربوط بالمستخدم (عمود email في جدول users)، أو بالشكل  اسم_الدخول@qattami.app
alter table public.users add column if not exists email text;
create unique index if not exists users_email_key on public.users (lower(email)) where email is not null;
create or replace function public.app_user()
returns table(id int, username text, full_name text, is_admin int, perms text)
language sql stable security definer set search_path = public as $$
  select u.id, u.username, u.full_name, u.is_admin, u.perms
  from public.users u
  where u.active = 1
    and coalesce(auth.jwt() ->> 'email', '') <> ''
    and (lower(u.email) = lower(auth.jwt() ->> 'email')
         or (lower(split_part(auth.jwt() ->> 'email', '@', 2)) = 'qattami.app'
             and lower(u.username) = lower(split_part(auth.jwt() ->> 'email', '@', 1))))
  order by (lower(u.email) = lower(auth.jwt() ->> 'email')) desc nulls last
  limit 1
$$;

-- 2) مستوى صلاحية المستخدم في قسم: 0 بدون، 1 عرض، 2 عرض وإضافة، 3 كاملة (المدير = 3 في كل الأقسام)
create or replace function public.app_level(sec text)
returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select case when a.is_admin = 1 then 3
                               else coalesce(nullif(a.perms, '')::jsonb ->> sec, '0')::int end
                   from public.app_user() a), 0)
$$;

-- 3) بيانات المستخدم الحالي للواجهة (بدون كلمة المرور)
create or replace function public.app_me()
returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('id', a.id, 'username', a.username, 'full_name', a.full_name,
                           'is_admin', a.is_admin = 1, 'perms', coalesce(nullif(a.perms, ''), '{}')::json)
  from public.app_user() a
$$;

revoke all on function public.app_user() from public, anon;
revoke all on function public.app_level(text) from public, anon;
revoke all on function public.app_me() from public, anon;
grant execute on function public.app_user() to authenticated;
grant execute on function public.app_level(text) to authenticated;
grant execute on function public.app_me() to authenticated;

-- 4) الزائر بدون دخول (anon) لا يرى أي جدول إطلاقًا
do $$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t.tablename);
    execute format('revoke all on table public.%I from anon', t.tablename);
  end loop;
end $$;

-- 5) القوائم الأساسية: يقرأها أي مستخدم مسجّل في البرنامج
do $$
declare t text;
begin
  foreach t in array array['employees', 'vehicles', 'regions', 'factories', 'warehouses'] loop
    execute format('grant select on table public.%I to authenticated', t);
    execute format('drop policy if exists app_read on public.%I', t);
    execute format('create policy app_read on public.%I for select to authenticated using ((select count(*) from public.app_user()) > 0)', t);
  end loop;
end $$;

-- المناطق: من له صلاحية إضافة في الأوردرات يضيف منطقة جديدة من نموذج التوصيل
grant insert, update on table public.regions to authenticated;
grant usage, select on sequence public.regions_id_seq to authenticated;
drop policy if exists app_add on public.regions;
create policy app_add on public.regions for insert to authenticated with check ((select public.app_level('deliveries')) >= 2);
drop policy if exists app_edit on public.regions;
create policy app_edit on public.regions for update to authenticated
  using ((select public.app_level('deliveries')) >= 2) with check ((select public.app_level('deliveries')) >= 2);

-- 6) الأوردرات المسلّمة: عرض (1) / إضافة (2) / تعديل وحذف (3)
grant select, insert, update, delete on table public.deliveries to authenticated;
grant usage, select on sequence public.deliveries_id_seq to authenticated;
drop policy if exists app_read on public.deliveries;
create policy app_read on public.deliveries for select to authenticated using ((select public.app_level('deliveries')) >= 1);
drop policy if exists app_add on public.deliveries;
create policy app_add on public.deliveries for insert to authenticated
  with check ((select public.app_level('deliveries')) >= 2 and created_by = (select a.username from public.app_user() a));
drop policy if exists app_edit on public.deliveries;
create policy app_edit on public.deliveries for update to authenticated
  using ((select public.app_level('deliveries')) >= 3) with check ((select public.app_level('deliveries')) >= 3);
drop policy if exists app_del on public.deliveries;
create policy app_del on public.deliveries for delete to authenticated using ((select public.app_level('deliveries')) >= 3);

-- 7) سجل النشاط: كل مستخدم يسجّل باسمه هو فقط، ولا يقرأ السجل إلا المدير
grant insert, select on table public.activity_log to authenticated;
grant usage, select on sequence public.activity_log_id_seq to authenticated;
drop policy if exists app_add on public.activity_log;
create policy app_add on public.activity_log for insert to authenticated
  with check (username = (select a.username from public.app_user() a));
drop policy if exists app_read on public.activity_log;
create policy app_read on public.activity_log for select to authenticated
  using (exists (select 1 from public.app_user() a where a.is_admin = 1));

-- 8) تعبئة الديزل: عرض (1) / إضافة تعبئة وقراءات العداد (2) / حذف وإعدادات (3)
grant select, insert, delete on table public.diesel_refuels to authenticated;
grant usage, select on sequence public.diesel_refuels_id_seq to authenticated;
drop policy if exists app_read on public.diesel_refuels;
create policy app_read on public.diesel_refuels for select to authenticated using ((select public.app_level('diesel')) >= 1);
drop policy if exists app_add on public.diesel_refuels;
create policy app_add on public.diesel_refuels for insert to authenticated
  with check ((select public.app_level('diesel')) >= 2 and created_by = (select a.username from public.app_user() a));
drop policy if exists app_del on public.diesel_refuels;
create policy app_del on public.diesel_refuels for delete to authenticated using ((select public.app_level('diesel')) >= 3);

grant select, insert, update, delete on table public.diesel_odometer to authenticated;
grant usage, select on sequence public.diesel_odometer_id_seq to authenticated;
drop policy if exists app_read on public.diesel_odometer;
create policy app_read on public.diesel_odometer for select to authenticated using ((select public.app_level('diesel')) >= 1);
drop policy if exists app_add on public.diesel_odometer;
create policy app_add on public.diesel_odometer for insert to authenticated with check ((select public.app_level('diesel')) >= 2);
drop policy if exists app_edit on public.diesel_odometer;
create policy app_edit on public.diesel_odometer for update to authenticated
  using ((select public.app_level('diesel')) >= 2) with check ((select public.app_level('diesel')) >= 2);
drop policy if exists app_del on public.diesel_odometer;
create policy app_del on public.diesel_odometer for delete to authenticated using ((select public.app_level('diesel')) >= 3);

-- المعدل الطبيعي لكل مركبة: صاحب الصلاحية الكاملة في الديزل يعدّل هذا العمود فقط (لا رقم المركبة ولا نوعها)
revoke update on table public.vehicles from authenticated;
grant update (diesel_rate) on table public.vehicles to authenticated;
drop policy if exists app_rate on public.vehicles;
create policy app_rate on public.vehicles for update to authenticated
  using ((select public.app_level('diesel')) >= 3) with check ((select public.app_level('diesel')) >= 3);

-- 9) الإعدادات العامة: تُقرأ إعدادات الأقسام فقط (لا أسرار)، ويعدّل كل قسم إعداده
grant select, insert, update on table public.settings to authenticated;
drop policy if exists app_read on public.settings;
create policy app_read on public.settings for select to authenticated
  using ((select count(*) from public.app_user()) > 0 and key in ('diesel_general_rate', 'mat_warning_days', 'mat_critical_days',
         'perf_monthly_threshold', 'perf_daily_threshold', 'emp_followup_threshold', 'fix_dismissed'));
-- (قواعد تعديل الإعدادات في البند 12 بالأسفل)

-- 10) صيانة السيارات (فواتير الصيانة): عرض (1) / إضافة (2) / تعديل وحذف (3)
grant select, insert, update, delete on table public.expenses to authenticated;
grant usage, select on sequence public.expenses_id_seq to authenticated;
drop policy if exists app_read on public.expenses;
create policy app_read on public.expenses for select to authenticated using ((select public.app_level('cars')) >= 1);
drop policy if exists app_add on public.expenses;
create policy app_add on public.expenses for insert to authenticated
  with check ((select public.app_level('cars')) >= 2 and created_by = (select a.username from public.app_user() a));
drop policy if exists app_edit on public.expenses;
create policy app_edit on public.expenses for update to authenticated
  using ((select public.app_level('cars')) >= 3) with check ((select public.app_level('cars')) >= 3);
drop policy if exists app_del on public.expenses;
create policy app_del on public.expenses for delete to authenticated using ((select public.app_level('cars')) >= 3);

-- 11) البضاعة المسلّمة: عرض (1) / تسجيل سند (2) / تعديل وحذف والمجموعات والبنود (3)
do $$
declare t text;
begin
  foreach t in array array['goods_groups', 'goods_items'] loop
    execute format('grant select, insert, update on table public.%I to authenticated', t);
    execute format('grant usage, select on sequence public.%I to authenticated', t || '_id_seq');
    execute format('drop policy if exists app_read on public.%I', t);
    execute format('create policy app_read on public.%I for select to authenticated using ((select count(*) from public.app_user()) > 0)', t);
    execute format('drop policy if exists app_add on public.%I', t);
    execute format('create policy app_add on public.%I for insert to authenticated with check ((select public.app_level(''goods'')) >= 3)', t);
    execute format('drop policy if exists app_edit on public.%I', t);
    execute format('create policy app_edit on public.%I for update to authenticated using ((select public.app_level(''goods'')) >= 3) with check ((select public.app_level(''goods'')) >= 3)', t);
  end loop;
end $$;

-- حذف بند (لو لم تُسجَّل له كميات) لصاحب الصلاحية الكاملة
grant delete on table public.goods_items to authenticated;
drop policy if exists app_del on public.goods_items;
create policy app_del on public.goods_items for delete to authenticated using ((select public.app_level('goods')) >= 3);

grant select, insert, update, delete on table public.goods_records to authenticated;
grant usage, select on sequence public.goods_records_id_seq to authenticated;
drop policy if exists app_read on public.goods_records;
create policy app_read on public.goods_records for select to authenticated using ((select public.app_level('goods')) >= 1);
drop policy if exists app_add on public.goods_records;
create policy app_add on public.goods_records for insert to authenticated
  with check ((select public.app_level('goods')) >= 2 and created_by = (select a.username from public.app_user() a));
drop policy if exists app_edit on public.goods_records;
create policy app_edit on public.goods_records for update to authenticated
  using ((select public.app_level('goods')) >= 3) with check ((select public.app_level('goods')) >= 3);
drop policy if exists app_del on public.goods_records;
create policy app_del on public.goods_records for delete to authenticated using ((select public.app_level('goods')) >= 3);

grant select, insert, delete on table public.goods_lines to authenticated;
grant usage, select on sequence public.goods_lines_id_seq to authenticated;
drop policy if exists app_read on public.goods_lines;
create policy app_read on public.goods_lines for select to authenticated using ((select public.app_level('goods')) >= 1);
drop policy if exists app_add on public.goods_lines;
create policy app_add on public.goods_lines for insert to authenticated
  with check ((select public.app_level('goods')) >= 3
    or ((select public.app_level('goods')) >= 2 and exists (select 1 from public.goods_records r
         where r.id = record_id and r.created_by = (select a.username from public.app_user() a))));
drop policy if exists app_del on public.goods_lines;
create policy app_del on public.goods_lines for delete to authenticated using ((select public.app_level('goods')) >= 3);

-- حفظ السند وبنوده دفعة واحدة (إما يُحفظ كله أو لا شيء). تعمل بصلاحيات المستخدم نفسه، فالقواعد أعلاه تنطبق عليها.
-- p_id فارغ = سند جديد؛ p_lines نص JSON بالشكل {"رقم_البند": الكمية}
-- المخزن الذي خرجت منه البضاعة (لمصنع الاستايروبور)
alter table public.goods_records add column if not exists warehouse_id integer references public.warehouses(id);
drop function if exists public.goods_save(int, text, int, int, text, text, text);
create or replace function public.goods_save(p_id int, p_date text, p_group int, p_factory int, p_warehouse int, p_notes text, p_lines text, p_now text)
returns json language plpgsql security invoker set search_path = public as $$
declare
  rid int; no text; me text := (select a.username from public.app_user() a); tot float8;
begin
  if me is null then raise exception 'ليست لديك صلاحية لهذه العملية' using errcode = '42501'; end if;
  if p_date is null or p_date !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'التاريخ غير صحيح'; end if;
  if p_factory is null then raise exception 'اختر المصنع'; end if;
  if p_warehouse is null and exists (select 1 from factories where id = p_factory and name ~ 'ستايروبور|المواد العازلة') then raise exception 'اختر المخزن'; end if;
  select coalesce(sum(value::float8), 0) into tot from jsonb_each_text(p_lines::jsonb);
  if tot <= 0 then raise exception 'اكتب كمية بند واحد على الأقل'; end if;
  if exists (select 1 from jsonb_each_text(p_lines::jsonb) j where value::float8 < 0
             or not exists (select 1 from goods_items i where i.id = j.key::int and i.group_id = p_group)) then
    raise exception 'بند غير تابع لهذه المجموعة أو كمية سالبة';
  end if;
  if p_id is null then
    for i in 1..5 loop
      select 'GDS-' || lpad((coalesce(max(substring(record_no from 5)::int), 0) + 1)::text, 4, '0') into no
        from goods_records where record_no ~ '^GDS-\d+$';
      begin
        insert into goods_records(record_no, date, group_id, notes, created_by, created_at, factory_id, warehouse_id)
          values (no, p_date, p_group, nullif(trim(p_notes), ''), me, p_now, p_factory, p_warehouse) returning id into rid;
        exit;
      exception when unique_violation then rid := null;
      end;
    end loop;
    if rid is null then raise exception 'تعارض في رقم السند، حاول مرة أخرى'; end if;
  else
    update goods_records set date = p_date, notes = nullif(trim(p_notes), ''), factory_id = p_factory, warehouse_id = p_warehouse, updated_by = me, updated_at = p_now
      where id = p_id and group_id = p_group returning id into rid;
    if rid is null then raise exception 'ليست لديك صلاحية لهذه العملية أو السند غير موجود' using errcode = '42501'; end if;
    delete from goods_lines where record_id = rid;
  end if;
  insert into goods_lines(record_id, item_id, qty)
    select rid, key::int, value::float8 from jsonb_each_text(p_lines::jsonb) where value::float8 > 0;
  return json_build_object('rec', (select row_to_json(r) from goods_records r where r.id = rid),
                           'lines', (select coalesce(json_agg(l), '[]'::json) from goods_lines l where l.record_id = rid));
end $$;

create or replace function public.goods_delete(p_id int)
returns json language plpgsql security invoker set search_path = public as $$
declare rid int;
begin
  delete from goods_lines where record_id = p_id;
  delete from goods_records where id = p_id returning id into rid;
  if rid is null then raise exception 'ليست لديك صلاحية لهذه العملية أو السند غير موجود' using errcode = '42501'; end if;
  return json_build_object('id', rid);
end $$;
revoke all on function public.goods_save(int, text, int, int, int, text, text, text) from public, anon;
revoke all on function public.goods_delete(int) from public, anon;
grant execute on function public.goods_save(int, text, int, int, int, text, text, text) to authenticated;
grant execute on function public.goods_delete(int) to authenticated;

-- 12) صلاحية المواد الخام: عرض (1) / استلام وتحويل (2) / تعديل وحذف والإعدادات والأصناف (3)
do $$
declare t text;
begin
  foreach t in array array['materials', 'prod_warehouses'] loop
    execute format('grant select, insert, update on table public.%I to authenticated', t);
    execute format('grant usage, select on sequence public.%I to authenticated', t || '_id_seq');
    execute format('drop policy if exists app_read on public.%I', t);
    execute format('create policy app_read on public.%I for select to authenticated using ((select count(*) from public.app_user()) > 0)', t);
    execute format('drop policy if exists app_add on public.%I', t);
    execute format('create policy app_add on public.%I for insert to authenticated with check ((select public.app_level(''materials'')) >= 3)', t);
    execute format('drop policy if exists app_edit on public.%I', t);
    execute format('create policy app_edit on public.%I for update to authenticated using ((select public.app_level(''materials'')) >= 3) with check ((select public.app_level(''materials'')) >= 3)', t);
  end loop;
  foreach t in array array['batches', 'issues'] loop
    execute format('grant select, insert, update, delete on table public.%I to authenticated', t);
    execute format('grant usage, select on sequence public.%I to authenticated', t || '_id_seq');
    execute format('drop policy if exists app_read on public.%I', t);
    execute format('create policy app_read on public.%I for select to authenticated using ((select public.app_level(''materials'')) >= 1)', t);
    execute format('drop policy if exists app_add on public.%I', t);
    execute format('create policy app_add on public.%I for insert to authenticated with check ((select public.app_level(''materials'')) >= 2 and created_by = (select a.username from public.app_user() a))', t);
    execute format('drop policy if exists app_edit on public.%I', t);
    execute format('create policy app_edit on public.%I for update to authenticated using ((select public.app_level(''materials'')) >= 3) with check ((select public.app_level(''materials'')) >= 3)', t);
    execute format('drop policy if exists app_del on public.%I', t);
    execute format('create policy app_del on public.%I for delete to authenticated using ((select public.app_level(''materials'')) >= 3)', t);
  end loop;
end $$;

-- 13) الإعدادات: كل قسم يعدّل إعداداته فقط (لصاحب الصلاحية الكاملة في القسم)
create or replace function public.app_can_setting(k text)
returns boolean language sql stable security definer set search_path = public as $$
  select case when k = 'diesel_general_rate' then public.app_level('diesel') >= 3
              when k in ('mat_warning_days', 'mat_critical_days') then public.app_level('materials') >= 3
              when k in ('perf_daily_threshold', 'perf_monthly_threshold') then public.app_level('performance') >= 3
              when k = 'emp_followup_threshold' then public.app_level('employees') >= 3
              when k = 'fix_dismissed' then public.app_level('fixes') >= 2
              else false end
$$;
revoke all on function public.app_can_setting(text) from public, anon;
grant execute on function public.app_can_setting(text) to authenticated;
drop policy if exists app_add on public.settings;
create policy app_add on public.settings for insert to authenticated with check (public.app_can_setting(key));
drop policy if exists app_edit on public.settings;
create policy app_edit on public.settings for update to authenticated using (public.app_can_setting(key)) with check (public.app_can_setting(key));

-- 14) مؤشر الأداء القياسي (سجلات الجرد): عرض (1) / تسجيل (2) / تعديل وحذف (3)
grant select, insert, update, delete on table public.perf_records to authenticated;
grant usage, select on sequence public.perf_records_id_seq to authenticated;
drop policy if exists app_read on public.perf_records;
create policy app_read on public.perf_records for select to authenticated using ((select public.app_level('performance')) >= 1);
drop policy if exists app_add on public.perf_records;
create policy app_add on public.perf_records for insert to authenticated
  with check ((select public.app_level('performance')) >= 2 and created_by = (select a.username from public.app_user() a));
drop policy if exists app_edit on public.perf_records;
create policy app_edit on public.perf_records for update to authenticated
  using ((select public.app_level('performance')) >= 3) with check ((select public.app_level('performance')) >= 3);
drop policy if exists app_del on public.perf_records;
create policy app_del on public.perf_records for delete to authenticated using ((select public.app_level('performance')) >= 3);

-- 15) تقييم موظفي المخزن: عرض (1) / إضافة سند (2) / تعديل وحذف وأنواع الأحداث (3)
grant select, insert, update, delete on table public.emp_records to authenticated;
grant usage, select on sequence public.emp_records_id_seq to authenticated;
drop policy if exists app_read on public.emp_records;
create policy app_read on public.emp_records for select to authenticated using ((select public.app_level('employees')) >= 1);
drop policy if exists app_add on public.emp_records;
create policy app_add on public.emp_records for insert to authenticated
  with check ((select public.app_level('employees')) >= 2 and created_by = (select a.username from public.app_user() a));
drop policy if exists app_edit on public.emp_records;
create policy app_edit on public.emp_records for update to authenticated
  using ((select public.app_level('employees')) >= 3) with check ((select public.app_level('employees')) >= 3);
drop policy if exists app_del on public.emp_records;
create policy app_del on public.emp_records for delete to authenticated using ((select public.app_level('employees')) >= 3);

grant select, insert, update on table public.event_types to authenticated;
grant usage, select on sequence public.event_types_id_seq to authenticated;
drop policy if exists app_read on public.event_types;
create policy app_read on public.event_types for select to authenticated using ((select count(*) from public.app_user()) > 0);
drop policy if exists app_add on public.event_types;
create policy app_add on public.event_types for insert to authenticated with check ((select public.app_level('employees')) >= 3);
drop policy if exists app_edit on public.event_types;
create policy app_edit on public.event_types for update to authenticated
  using ((select public.app_level('employees')) >= 3) with check ((select public.app_level('employees')) >= 3);

-- سند تحويل من دفعة (يتأكد من الرصيد داخل نفس العملية حتى لا يُحوَّل أكثر من الموجود من جهازين معًا)
-- p_kind: 'prod' إلى مخزن إنتاج (يخرج من الرصيد) أو 'internal' إلى مخزن من مخازني (تُنشأ دفعة جديدة هناك)
create or replace function public.mat_transfer(p_no text, p_date text, p_batch int, p_qty float8, p_kind text, p_dest int,
                                               p_factory int, p_notes text, p_now text)
returns json language plpgsql security invoker set search_path = public as $$
declare
  me text := (select a.username from public.app_user() a); b record; rem float8; to_name text; child int; cno text; n int := 1; iid int;
begin
  if me is null then raise exception 'ليست لديك صلاحية لهذه العملية' using errcode = '42501'; end if;
  if coalesce(trim(p_no), '') = '' then raise exception 'رقم التحويل مطلوب'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'يجب أن تكون الكمية أكبر من صفر'; end if;
  perform pg_advisory_xact_lock(88001, p_batch);   -- قفل على الدفعة طوال العملية
  select * into b from batches where id = p_batch;
  if b.id is null then raise exception 'الدفعة غير موجودة'; end if;
  rem := b.total_qty - coalesce((select sum(qty) from issues where batch_id = p_batch), 0);
  if p_qty > rem + 1e-9 then raise exception 'الكمية (%) أكبر من المتاح (%)', round(p_qty::numeric), round(rem::numeric); end if;
  if p_kind = 'prod' then
    select name into to_name from prod_warehouses where id = p_dest;
    if to_name is null then raise exception 'مخزن الإنتاج غير موجود'; end if;
    insert into issues(issue_no, date, batch_id, qty, issued_to, notes, created_by, created_at, factory_id, to_warehouse_id, kind)
      values (trim(p_no), p_date, p_batch, p_qty, to_name, nullif(trim(p_notes), ''), me, p_now, p_factory, p_dest, 'prod') returning id into iid;
  elsif p_kind = 'internal' then
    select name into to_name from warehouses where id = p_dest;
    if to_name is null or p_dest = b.warehouse_id then raise exception 'اختر مخزنًا مستلمًا غير مخزن الدفعة'; end if;
    while exists (select 1 from batches where batch_no = b.batch_no || '-T' || n) loop n := n + 1; end loop;
    cno := b.batch_no || '-T' || n;
    insert into batches(batch_no, material_id, warehouse_id, prod_date, expiry_date, arrival_date, weight_per_bag, bags, total_qty, notes,
                        created_by, created_at, factory_id, parent_batch_id)
      values (cno, b.material_id, p_dest, b.prod_date, b.expiry_date, p_date, b.weight_per_bag,
              case when coalesce(b.weight_per_bag, 0) > 0 then round(p_qty / b.weight_per_bag)::int else 0 end, p_qty,
              'منقولة من الدفعة ' || b.batch_no || ' بالسند ' || trim(p_no), me, p_now, p_factory, b.id) returning id into child;
    insert into issues(issue_no, date, batch_id, qty, issued_to, notes, created_by, created_at, factory_id, to_store_id, child_batch_id, kind)
      values (trim(p_no), p_date, p_batch, p_qty, to_name, nullif(trim(p_notes), ''), me, p_now, p_factory, p_dest, child, 'internal') returning id into iid;
  else
    raise exception 'نوع التحويل غير صحيح';
  end if;
  return json_build_object('issue', (select row_to_json(i) from issues i where i.id = iid),
                           'child', (select row_to_json(c) from batches c where c.id = child));
end $$;

create or replace function public.mat_issue_edit(p_id int, p_date text, p_qty float8, p_dest int, p_factory int, p_notes text, p_now text)
returns json language plpgsql security invoker set search_path = public as $$
declare
  me text := (select a.username from public.app_user() a); i record; rem float8; used float8; to_name text;
begin
  select * into i from issues where id = p_id;
  if i.id is null then raise exception 'السند غير موجود'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'يجب أن تكون الكمية أكبر من صفر'; end if;
  perform pg_advisory_xact_lock(88001, i.batch_id);
  rem := (select total_qty from batches where id = i.batch_id) - coalesce((select sum(qty) from issues where batch_id = i.batch_id and id <> p_id), 0);
  if p_qty > rem + 1e-9 then raise exception 'الكمية أكبر من المتاح في الدفعة (%)', round(rem::numeric); end if;
  if coalesce(i.kind, 'prod') = 'internal' then
    used := coalesce((select sum(qty) from issues where batch_id = i.child_batch_id), 0);
    if p_qty < used - 1e-9 then raise exception 'تم تحويل % كجم من الدفعة المنقولة؛ لا يمكن أن تقل الكمية عن ذلك', round(used::numeric); end if;
    update batches set total_qty = p_qty, updated_by = me, updated_at = p_now where id = i.child_batch_id;
    update issues set date = p_date, qty = p_qty, notes = nullif(trim(p_notes), ''), updated_by = me, updated_at = p_now where id = p_id;
  else
    select name into to_name from prod_warehouses where id = p_dest;
    if to_name is null or p_factory is null then raise exception 'مخزن الإنتاج والمصنع مطلوبان'; end if;
    update issues set date = p_date, qty = p_qty, issued_to = to_name, to_warehouse_id = p_dest, factory_id = p_factory,
      notes = nullif(trim(p_notes), ''), updated_by = me, updated_at = p_now where id = p_id;
  end if;
  if not found then raise exception 'ليست لديك صلاحية لهذه العملية' using errcode = '42501'; end if;
  return json_build_object('issue', (select row_to_json(x) from issues x where x.id = p_id),
                           'child', (select row_to_json(c) from batches c where c.id = i.child_batch_id));
end $$;

create or replace function public.mat_issue_delete(p_id int)
returns json language plpgsql security invoker set search_path = public as $$
declare i record; did int;
begin
  select * into i from issues where id = p_id;
  if i.id is null then raise exception 'السند غير موجود'; end if;
  if i.child_batch_id is not null and exists (select 1 from issues where batch_id = i.child_batch_id) then
    raise exception 'لا يمكن الحذف: الكمية المنقولة حُوِّل منها بعد ذلك. احذف تلك التحويلات أولًا.';
  end if;
  delete from issues where id = p_id returning id into did;
  if did is null then raise exception 'ليست لديك صلاحية لهذه العملية' using errcode = '42501'; end if;
  if i.child_batch_id is not null then delete from batches where id = i.child_batch_id; end if;
  return json_build_object('id', did, 'child', i.child_batch_id);
end $$;
revoke all on function public.mat_transfer(text, text, int, float8, text, int, int, text, text) from public, anon;
revoke all on function public.mat_issue_edit(int, text, float8, int, int, text, text) from public, anon;
revoke all on function public.mat_issue_delete(int) from public, anon;
grant execute on function public.mat_transfer(text, text, int, float8, text, int, int, text, text) to authenticated;
grant execute on function public.mat_issue_edit(int, text, float8, int, int, text, text) to authenticated;
grant execute on function public.mat_issue_delete(int) to authenticated;

-- 16) صفحات المدير: المستخدمون والبيانات الأساسية والنسخ الاحتياطي (للمدير فقط، وتعمل من خلال دوال آمنة)
create or replace function public.app_is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select a.is_admin = 1 from public.app_user() a), false)
$$;
revoke all on function public.app_is_admin() from public, anon;
grant execute on function public.app_is_admin() to authenticated;

-- المستخدمون: المدير يقرأ القائمة (بدون كلمات المرور القديمة)
revoke all on table public.users from authenticated;
grant select (id, username, full_name, is_admin, active, perms, created_at, email) on table public.users to authenticated;
drop policy if exists app_read on public.users;
create policy app_read on public.users for select to authenticated using ((select public.app_is_admin()));

-- الحماية: لا يُوقَف آخر مدير مفعّل
create or replace function public.users_keep_admin()
returns trigger language plpgsql set search_path = public as $$
begin
  if old.is_admin = 1 and old.active = 1 and (new.is_admin <> 1 or new.active <> 1)
     and not exists (select 1 from public.users where id <> old.id and is_admin = 1 and active = 1) then
    raise exception 'يجب أن يبقى مدير مفعّل واحد على الأقل';
  end if;
  return new;
end $$;
drop trigger if exists users_keep_admin on public.users;
create trigger users_keep_admin before update on public.users for each row execute function public.users_keep_admin();

-- حفظ صف في جدول من البيانات الأساسية (إضافة لو p_id فارغ، وإلا تعديل). الأعمدة المسموح بها فقط.
create or replace function public.admin_save(p_table text, p_id int, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare allowed text[]; k text; cols text; res jsonb;
begin
  if not public.app_is_admin() then raise exception 'هذه العملية للمدير فقط' using errcode = '42501'; end if;
  allowed := case p_table
    when 'users' then array['username', 'full_name', 'is_admin', 'active', 'perms', 'email']
    when 'employees' then array['name', 'job_title', 'is_driver', 'in_performance', 'active']
    when 'vehicles' then array['number', 'model', 'type', 'active', 'diesel_rate']
    when 'warehouses' then array['name', 'active']
    when 'factories' then array['name', 'active']
    when 'regions' then array['name', 'active']
    else null end;
  if allowed is null then raise exception 'جدول غير مسموح'; end if;
  for k in select jsonb_object_keys(p_data) loop
    if not k = any(allowed) then raise exception 'عمود غير مسموح: %', k; end if;
  end loop;
  if p_table = 'users' and p_data ? 'email' then p_data := jsonb_set(p_data, '{email}', coalesce(to_jsonb(nullif(lower(trim(p_data ->> 'email')), '')), 'null'::jsonb)); end if;
  if p_id is null then
    if p_table = 'users' then p_data := p_data || jsonb_build_object('password_hash', '-', 'created_at', to_char(now() at time zone 'Asia/Kuwait', 'YYYY-MM-DD HH24:MI:SS')); end if;
    select string_agg(quote_ident(x), ',') into cols from jsonb_object_keys(p_data) x;
    execute format('insert into public.%I (%s) select %s from jsonb_populate_record(null::public.%I, $1) returning to_jsonb(%I.*)', p_table, cols, cols, p_table, p_table)
      using p_data into res;
  else
    select string_agg(quote_ident(x), ',') into cols from jsonb_object_keys(p_data) x;
    execute format('update public.%I set (%s) = (select %s from jsonb_populate_record(null::public.%I, $1)) where id = $2 returning to_jsonb(%I.*)', p_table, cols, cols, p_table, p_table)
      using p_data, p_id into res;
    if res is null then raise exception 'الصف غير موجود'; end if;
  end if;
  return res - 'password_hash';
end $$;

create or replace function public.admin_delete(p_table text, p_id int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.app_is_admin() then raise exception 'هذه العملية للمدير فقط' using errcode = '42501'; end if;
  if p_table not in ('employees', 'vehicles', 'warehouses', 'factories', 'regions') then raise exception 'جدول غير مسموح'; end if;
  execute format('delete from public.%I where id = $1', p_table) using p_id;
  get diagnostics n = row_count;
  return jsonb_build_object('deleted', n);
end $$;

-- حساب الدخول في Supabase: المدير ينشئه أو يغيّر كلمة مروره من البرنامج مباشرة
create or replace function public.admin_set_login(p_email text, p_password text)
returns jsonb language plpgsql security definer set search_path = public, extensions, auth as $$
declare uid uuid;
begin
  if not public.app_is_admin() then raise exception 'هذه العملية للمدير فقط' using errcode = '42501'; end if;
  p_email := lower(trim(coalesce(p_email, '')));
  if p_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'الإيميل غير صحيح'; end if;
  if length(coalesce(p_password, '')) < 8 then raise exception 'كلمة المرور 8 أحرف على الأقل'; end if;
  select id into uid from auth.users where lower(email) = p_email;
  if uid is null then
    uid := gen_random_uuid();
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                            created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change,
                            email_change_token_current, reauthentication_token, is_super_admin)
    values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', p_email, crypt(p_password, gen_salt('bf')), now(),
            '{"provider": "email", "providers": ["email"]}', '{}', now(), now(), '', '', '', '', '', '', false);
    insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (uid::text, uid, jsonb_build_object('sub', uid::text, 'email', p_email, 'email_verified', true), 'email', now(), now(), now());
    return jsonb_build_object('created', true);
  end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = uid;
  return jsonb_build_object('created', false);
end $$;

-- أي المستخدمين له حساب دخول، ومتى دخل آخر مرة
drop function if exists public.admin_logins();
create or replace function public.admin_logins()
returns jsonb language sql stable security definer set search_path = public, auth as $$
  select coalesce(jsonb_agg(jsonb_build_object('email', lower(u.email), 'last_sign_in_at', to_char(u.last_sign_in_at at time zone 'Asia/Kuwait', 'YYYY-MM-DD HH24:MI'))), '[]'::jsonb)
  from auth.users u where public.app_is_admin()
$$;

-- الاسترجاع من نسخة احتياطية: يضيف الصفوف الناقصة ويحدّث الموجودة (لا يحذف شيئًا)، ثم يضبط العدّادات
create or replace function public.admin_restore(p_table text, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare cols text; upd text; n int;
begin
  if not public.app_is_admin() then raise exception 'هذه العملية للمدير فقط' using errcode = '42501'; end if;
  if p_table not in ('employees', 'vehicles', 'regions', 'factories', 'warehouses', 'prod_warehouses', 'materials', 'event_types', 'deliveries',
                     'expenses', 'diesel_refuels', 'diesel_odometer', 'batches', 'issues', 'perf_records', 'emp_records', 'goods_groups',
                     'goods_items', 'goods_records', 'goods_lines', 'activity_log', 'users') then raise exception 'جدول غير مسموح'; end if;
  select string_agg(quote_ident(c.column_name), ',' order by c.ordinal_position),
         string_agg(format('%1$I = excluded.%1$I', c.column_name), ',' order by c.ordinal_position) filter (where c.column_name <> 'id')
    into cols, upd
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = p_table and c.column_name <> 'password_hash'
    and exists (select 1 from jsonb_array_elements(p_rows) r where r ? c.column_name limit 1);
  if p_table = 'users' then
    -- على سيرفر جديد: حساب المدير المؤقت (نفس الاسم برقم مختلف) يُستبدل بصف النسخة
    delete from public.users u using jsonb_array_elements(p_rows) r
      where lower(u.username) = lower(r ->> 'username') and u.id <> (r ->> 'id')::int;
    p_rows := (select jsonb_agg(r || jsonb_build_object('password_hash', '-')) from jsonb_array_elements(p_rows) r);
    cols := cols || ',password_hash';
  end if;
  execute format('insert into public.%I (%s) select %s from jsonb_populate_recordset(null::public.%I, $1) on conflict (id) do update set %s',
                 p_table, cols, cols, p_table, upd) using p_rows;
  get diagnostics n = row_count;
  execute format('select setval(pg_get_serial_sequence(%L, %L), greatest(coalesce((select max(id) from public.%I), 0), 1))', 'public.' || p_table, 'id', p_table);
  return jsonb_build_object('rows', n);
end $$;

revoke all on function public.admin_save(text, int, jsonb) from public, anon;
revoke all on function public.admin_delete(text, int) from public, anon;
revoke all on function public.admin_set_login(text, text) from public, anon;
revoke all on function public.admin_logins() from public, anon;
revoke all on function public.admin_restore(text, jsonb) from public, anon;
grant execute on function public.admin_save(text, int, jsonb) to authenticated;
grant execute on function public.admin_delete(text, int) to authenticated;
grant execute on function public.admin_set_login(text, text) to authenticated;
grant execute on function public.admin_logins() to authenticated;
grant execute on function public.admin_restore(text, jsonb) to authenticated;


-- ================= 17) حالة الاتصال: من متصل الآن، ومتى ظهر آخر مرة =================
alter table public.users add column if not exists last_seen timestamptz;
alter table public.users add column if not exists seen_online boolean not null default false;
grant select (last_seen, seen_online) on table public.users to authenticated;

-- البرنامج يستدعيها كل دقيقة وهو مفتوح، ومرة بـ false عند تسجيل الخروج
drop function if exists public.app_heartbeat(boolean);
create or replace function public.app_heartbeat(p_online boolean default true)
returns void language sql security definer set search_path = public as $$
  update public.users set last_seen = now(), seen_online = coalesce(p_online, true)
  where id = (select a.id from public.app_user() a)
$$;
revoke all on function public.app_heartbeat(boolean) from public, anon;
grant execute on function public.app_heartbeat(boolean) to authenticated;


-- ================= 18) الدخول بدون إنترنت: مفتاح تشفير مشترك، ونسخة منه مقفولة بكلمة مرور كل مستخدم =================
-- البرنامج يحفظ نسخة مشفّرة من البيانات في «ملف الطوارئ»، ولا يفتحها إلا اسم مستخدم وكلمة مرور صحيحان.
create table if not exists public.app_secret (id int primary key default 1 check (id = 1), data_key text not null);
alter table public.app_secret enable row level security;
revoke all on table public.app_secret from anon, authenticated;
insert into public.app_secret (id, data_key) values (1, encode(extensions.gen_random_bytes(32), 'base64')) on conflict (id) do nothing;

create table if not exists public.offline_keys (username text primary key, salt text not null, iter int not null, wrapped text not null, updated_at timestamptz not null default now());
alter table public.offline_keys enable row level security;
revoke all on table public.offline_keys from anon, authenticated;

create or replace function public.app_data_key()
returns text language sql stable security definer set search_path = public as $$
  select s.data_key from public.app_secret s where exists (select 1 from public.app_user())
$$;
create or replace function public.app_save_offline_key(p_salt text, p_iter int, p_wrapped text)
returns void language sql security definer set search_path = public as $$
  insert into public.offline_keys (username, salt, iter, wrapped, updated_at)
  select a.username, p_salt, p_iter, p_wrapped, now() from public.app_user() a
  on conflict (username) do update set salt = excluded.salt, iter = excluded.iter, wrapped = excluded.wrapped, updated_at = now()
$$;
create or replace function public.admin_save_offline_key(p_username text, p_salt text, p_iter int, p_wrapped text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.app_is_admin() then raise exception 'هذه العملية للمدير فقط' using errcode = '42501'; end if;
  insert into public.offline_keys (username, salt, iter, wrapped, updated_at) values (p_username, p_salt, p_iter, p_wrapped, now())
  on conflict (username) do update set salt = excluded.salt, iter = excluded.iter, wrapped = excluded.wrapped, updated_at = now();
end $$;
create or replace function public.admin_offline_keys()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('username', k.username, 'salt', k.salt, 'iter', k.iter, 'wrapped', k.wrapped, 'updated_at', k.updated_at)), '[]'::jsonb)
  from public.offline_keys k where public.app_is_admin()
$$;
revoke all on function public.app_data_key() from public, anon;
revoke all on function public.app_save_offline_key(text, int, text) from public, anon;
revoke all on function public.admin_save_offline_key(text, text, int, text) from public, anon;
revoke all on function public.admin_offline_keys() from public, anon;
grant execute on function public.app_data_key() to authenticated;
grant execute on function public.app_save_offline_key(text, int, text) to authenticated;
grant execute on function public.admin_save_offline_key(text, text, int, text) to authenticated;
grant execute on function public.admin_offline_keys() to authenticated;

-- فهارس تسرّع الترتيب والتحميل
create index if not exists deliveries_date_idx on public.deliveries (date);
create index if not exists diesel_refuels_date_idx on public.diesel_refuels (date);
create index if not exists expenses_date_idx on public.expenses (date);
create index if not exists goods_lines_record_idx on public.goods_lines (record_id);
create index if not exists issues_batch_idx on public.issues (batch_id);
create index if not exists perf_records_date_idx on public.perf_records (date);
create index if not exists emp_records_date_idx on public.emp_records (date);

-- 19) اسم العميل في سندات الأوردرات
alter table public.deliveries add column if not exists customer text;
create index if not exists deliveries_customer_idx on public.deliveries (customer);

-- ============================================================================
-- العملاء: خانة «اسم العميل» في سندات الأوردرات + قائمة العملاء من ملفات الإكسيل القديمة (1196 عميل)
-- شغّله مرة واحدة في Supabase: SQL Editor ← New query ← الصق ← Run
-- آمن: بيضيف خانة وجدول جديد بس، ومش بيغيّر ولا يمسح أي بيانات. ولو اتشغّل مرتين مفيش مشكلة
-- ============================================================================
alter table public.deliveries add column if not exists customer text;
create index if not exists deliveries_customer_idx on public.deliveries (customer);

create table if not exists public.customers (id serial primary key, name text not null unique, active int not null default 1);
alter table public.customers enable row level security;
revoke all on table public.customers from anon;
grant select, insert, update on table public.customers to authenticated;
grant usage, select on sequence public.customers_id_seq to authenticated;
drop policy if exists app_read on public.customers;
create policy app_read on public.customers for select to authenticated using ((select count(*) from public.app_user()) > 0);
drop policy if exists app_add on public.customers;
create policy app_add on public.customers for insert to authenticated with check ((select public.app_level('deliveries')) >= 2);
drop policy if exists app_edit on public.customers;
create policy app_edit on public.customers for update to authenticated
  using ((select public.app_level('deliveries')) >= 2) with check ((select public.app_level('deliveries')) >= 2);

create or replace function public.admin_save(p_table text, p_id int, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare allowed text[]; k text; cols text; res jsonb;
begin
  if not public.app_is_admin() then raise exception 'هذه العملية للمدير فقط' using errcode = '42501'; end if;
  allowed := case p_table
    when 'users' then array['username', 'full_name', 'is_admin', 'active', 'perms', 'email']
    when 'employees' then array['name', 'job_title', 'is_driver', 'in_performance', 'active']
    when 'vehicles' then array['number', 'model', 'type', 'active', 'diesel_rate']
    when 'warehouses' then array['name', 'active']
    when 'factories' then array['name', 'active']
    when 'regions' then array['name', 'active']
    when 'customers' then array['name', 'active']
    else null end;
  if allowed is null then raise exception 'جدول غير مسموح'; end if;
  for k in select jsonb_object_keys(p_data) loop
    if not k = any(allowed) then raise exception 'عمود غير مسموح: %', k; end if;
  end loop;
  if p_table = 'users' and p_data ? 'email' then p_data := jsonb_set(p_data, '{email}', coalesce(to_jsonb(nullif(lower(trim(p_data ->> 'email')), '')), 'null'::jsonb)); end if;
  if p_id is null then
    if p_table = 'users' then p_data := p_data || jsonb_build_object('password_hash', '-', 'created_at', to_char(now() at time zone 'Asia/Kuwait', 'YYYY-MM-DD HH24:MI:SS')); end if;
    select string_agg(quote_ident(x), ',') into cols from jsonb_object_keys(p_data) x;
    execute format('insert into public.%I (%s) select %s from jsonb_populate_record(null::public.%I, $1) returning to_jsonb(%I.*)', p_table, cols, cols, p_table, p_table)
      using p_data into res;
  else
    select string_agg(quote_ident(x), ',') into cols from jsonb_object_keys(p_data) x;
    execute format('update public.%I set (%s) = (select %s from jsonb_populate_record(null::public.%I, $1)) where id = $2 returning to_jsonb(%I.*)', p_table, cols, cols, p_table, p_table)
      using p_data, p_id into res;
    if res is null then raise exception 'الصف غير موجود'; end if;
  end if;
  return res - 'password_hash';
end $$;

create or replace function public.admin_delete(p_table text, p_id int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.app_is_admin() then raise exception 'هذه العملية للمدير فقط' using errcode = '42501'; end if;
  if p_table not in ('employees', 'vehicles', 'warehouses', 'factories', 'regions', 'customers') then raise exception 'جدول غير مسموح'; end if;
  execute format('delete from public.%I where id = $1', p_table) using p_id;
  get diagnostics n = row_count;
  return jsonb_build_object('deleted', n);
end $$;

create or replace function public.admin_restore(p_table text, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare cols text; upd text; n int;
begin
  if not public.app_is_admin() then raise exception 'هذه العملية للمدير فقط' using errcode = '42501'; end if;
  if p_table not in ('employees', 'vehicles', 'regions', 'factories', 'warehouses', 'prod_warehouses', 'materials', 'event_types', 'deliveries',
                     'expenses', 'diesel_refuels', 'diesel_odometer', 'batches', 'issues', 'perf_records', 'emp_records', 'goods_groups',
                     'goods_items', 'goods_records', 'goods_lines', 'activity_log', 'users', 'customers', 'car_problems') then raise exception 'جدول غير مسموح'; end if;
  select string_agg(quote_ident(c.column_name), ',' order by c.ordinal_position),
         string_agg(format('%1$I = excluded.%1$I', c.column_name), ',' order by c.ordinal_position) filter (where c.column_name <> 'id')
    into cols, upd
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = p_table and c.column_name <> 'password_hash'
    and exists (select 1 from jsonb_array_elements(p_rows) r where r ? c.column_name limit 1);
  if p_table = 'users' then
    -- على سيرفر جديد: حساب المدير المؤقت (نفس الاسم برقم مختلف) يُستبدل بصف النسخة
    delete from public.users u using jsonb_array_elements(p_rows) r
      where lower(u.username) = lower(r ->> 'username') and u.id <> (r ->> 'id')::int;
    p_rows := (select jsonb_agg(r || jsonb_build_object('password_hash', '-')) from jsonb_array_elements(p_rows) r);
    cols := cols || ',password_hash';
  end if;
  execute format('insert into public.%I (%s) select %s from jsonb_populate_recordset(null::public.%I, $1) on conflict (id) do update set %s',
                 p_table, cols, cols, p_table, upd) using p_rows;
  get diagnostics n = row_count;
  execute format('select setval(pg_get_serial_sequence(%L, %L), greatest(coalesce((select max(id) from public.%I), 0), 1))', 'public.' || p_table, 'id', p_table);
  return jsonb_build_object('rows', n);
end $$;

insert into public.customers (name) values
('20xx'),
('3bees'),
('3بيس'),
('BY ROYAL MOVEN'),
('acico'),
('adoor'),
('ador'),
('adore'),
('air'),
('alamdar'),
('alternative'),
('arkan'),
('ash kuaite'),
('awgco'),
('barton'),
('barton café'),
('bascota'),
('bbq'),
('beeter from scrath'),
('beiru'),
('beirut'),
('bento'),
('better'),
('bron degree'),
('cakes and co'),
('calocaterin'),
('clusters'),
('delite'),
('doh'),
('dolce bello'),
('dolcissmo'),
('dr.juice'),
('dulce swwet'),
('eat softy'),
('food mates'),
('froyo forzen'),
('gelarto roza'),
('gravety café'),
('gravity'),
('house of holand'),
('ibuild'),
('index'),
('kcb'),
('kcbc'),
('kcpc'),
('kgl'),
('khrafy global'),
('lazibens'),
('leancaf'),
('lereve'),
('liva'),
('liva wellnes'),
('lovable sweet'),
('mbn'),
('mk inter national'),
('mmc'),
('moosh'),
('nejoud'),
('noor organic'),
('ogs'),
('oj.s'),
('oyo'),
('oyo kuwait'),
('oyoكويت'),
('pre'),
('pree'),
('q8 juice'),
('recafco'),
('red cream'),
('refrigeration'),
('rise'),
('rise for pies'),
('run2diet'),
('rych'),
('santa'),
('santa nata'),
('saysco'),
('simply juice'),
('soho'),
('steak house'),
('the bakry'),
('wheat graas'),
('wuhan'),
('zone'),
('ا/امانى'),
('ا/مرام'),
('ابتسام'),
('ابحار'),
('ابراج الكويت'),
('ابراهيم اسماعيل'),
('ابراهيم اليحي'),
('ابراهيم يحيي'),
('ابروفد لايف'),
('ابو رامي'),
('ابو فاضل'),
('ابو فالح'),
('ابو ملك'),
('ابو مهدي'),
('ابواحمد'),
('ابوادم'),
('ابوالفهود'),
('ابوايمن'),
('ابوبدر'),
('ابوتامر'),
('ابوجابر'),
('ابوجاسم'),
('ابوجراح'),
('ابوجمال'),
('ابوحسن'),
('ابوحسين'),
('ابوحمد'),
('ابوخالد'),
('ابوداود'),
('ابوداوود'),
('ابوراشد'),
('ابوزياد'),
('ابوسالم'),
('ابوسعد'),
('ابوسعود'),
('ابوسلطان'),
('ابوسيف'),
('ابوصالح'),
('ابوطلال'),
('ابوعبدالرحمن'),
('ابوعبدالعزيز'),
('ابوعبدالله'),
('ابوعثمان'),
('ابوعزيز'),
('ابوعلي'),
('ابوعمار'),
('ابوعمر'),
('ابوعوض'),
('ابوعيد'),
('ابوعيسى'),
('ابوغيث'),
('ابوفلاح'),
('ابوفهد'),
('ابوفهد العازمى'),
('ابوفواز'),
('ابوفيصل'),
('ابومالك'),
('ابومبارك'),
('ابومحروس'),
('ابومحمد'),
('ابومرزوق'),
('ابومسار'),
('ابومشعل'),
('ابوميسر'),
('ابونادر'),
('ابوناصر'),
('ابونواف'),
('ابويوسف'),
('ابيتا'),
('اتحاد'),
('اتحاد العبدلي'),
('اتحاد المزارعين'),
('اجيال'),
('احمد'),
('احمد الرفاعى'),
('احمد العميرى'),
('احمد المزيدي'),
('احمد النويضي'),
('احمد منور'),
('احمد ناصر'),
('احمد\احمد'),
('احمدالعازمى'),
('احمدالفهد'),
('احمدعبيد'),
('احمدعمر'),
('ادور'),
('ادوور'),
('اديب'),
('اديب العوضى'),
('ارابيسك'),
('ارت كيو'),
('اركان'),
('اس اف تكنولوجي'),
('اسامه'),
('اسطنبولي'),
('اسطنبولي باشا'),
('اسعار زمان'),
('اسماء'),
('اسماءعبداللطيف'),
('اسماعيل'),
('اسواق العايش'),
('اسيا'),
('اسياباك'),
('اشرف السنافر'),
('افراح الخليج'),
('افراح الفيصل'),
('افوكادو'),
('افوكادو وعسل'),
('اكس بى اس'),
('اكلة سمج'),
('اكياس'),
('الابداعيه'),
('الاتحاد'),
('الارنتيفو'),
('الاستثمار'),
('الافينيوز'),
('الاكواب الفضية'),
('الانماء'),
('البامبرا'),
('البستان'),
('البعيجان'),
('البغلي'),
('البناء الشامل'),
('البيت الخليجي'),
('البيت الكويتى'),
('البيت الهادي'),
('البيرق'),
('البيوت الجاهزة'),
('التجهيزات'),
('التجهيزات الزراعية'),
('الترناتيف'),
('الترنيتف'),
('التقنيات'),
('التقنيات المتكاملة'),
('التلال'),
('التمور'),
('الثنيان'),
('الجزيرة'),
('الجمعية'),
('الجهرا'),
('الجهرا ماركت'),
('الحميدان'),
('الحميضى'),
('الحياة الخضراء'),
('الخباز'),
('الخبرات'),
('الخبرات الماسيه'),
('الخرافي'),
('الداعيات'),
('الدانة'),
('الداو'),
('الدايره المشتركه'),
('الدره'),
('الدهان'),
('الدهماء'),
('الدوسري'),
('الديرة'),
('الرئيسي'),
('الرابطة'),
('الراية البيضاء'),
('الرايه'),
('الرزاق'),
('الرشيدي'),
('الرفاعى'),
('الروضان'),
('الروميضى'),
('الري'),
('الرياض'),
('الزان'),
('السعدى'),
('السقا'),
('السلمان'),
('السيد ابوعزيز'),
('السيد احمد'),
('السيد ايوب'),
('السيد خالد'),
('السيد سليمان'),
('السيد عبد الله'),
('السيد عبد المحسن'),
('السيد عبيد'),
('السيد علي'),
('السيد فيصل'),
('السيد مشعل'),
('السيد يوسف'),
('السيدسالم'),
('السيدفهد'),
('السيف'),
('الشرار'),
('الشركه الابداعيه'),
('الشركه العربيه'),
('الشركه العربيه للابواب'),
('الشركه الفرنسيه'),
('الشركه الكويتيه'),
('الشلاحي'),
('الشويخ'),
('الصفا'),
('الصفار'),
('الصليبيه'),
('الصواغ'),
('الضاحيه'),
('الضبيب'),
('الطحيني'),
('الطلع'),
('الطلع الهضيم'),
('الطيب'),
('الظفيري'),
('العارضيه'),
('العازمي'),
('العالم الصغير'),
('العامرى الذهبية'),
('العبيد'),
('العجمي'),
('العردة'),
('العلاج'),
('العلم'),
('العلياء'),
('العميري'),
('العنجري'),
('الغانم'),
('الفاخر'),
('الفحاحيل'),
('الفحيط'),
('الفردوس'),
('الفرنسيه'),
('الفرنسيه الكويتيه'),
('الفرنسيه المتحده'),
('الفضالة'),
('الفنار'),
('القرين'),
('الكادي'),
('الكاظمى'),
('الكربيانى'),
('الكويتيه الفرنسيه'),
('اللحوم اليومية'),
('اللوتس'),
('المتحدة'),
('المتحدة الاولى'),
('المتحدة للاسماك'),
('المتروك'),
('المجحم'),
('المجموعه الاهليه'),
('المدار'),
('المركز الملكي'),
('المسرة'),
('المسيلة'),
('المصالح البرونزيه'),
('المطيري'),
('المعادن'),
('المكان'),
('الملك'),
('الملكي'),
('المملكة'),
('المملكه سوق'),
('المنار الازرق'),
('المنعش'),
('النخبه'),
('النخيل'),
('النخيل سنتر'),
('النزهه'),
('النصف'),
('النعيم'),
('النموزجيه'),
('الهاجري'),
('الهانى'),
('الهده'),
('الهملان'),
('الهناء'),
('الهندسية المتقدمة'),
('الوطنية'),
('الوطنيه الطبيه'),
('اليسري'),
('اليمامة'),
('اليوغسلافي'),
('ام احمد'),
('ام اس'),
('ام اس العالميه'),
('ام الخير'),
('ام القري'),
('ام ام سى'),
('ام بى ان'),
('ام سالم'),
('ام عبد العزيز'),
('ام فهد'),
('ام كندا'),
('ام كي'),
('ام ناصر'),
('ام يوسف'),
('اماكن'),
('امان'),
('امبرس'),
('امغره'),
('امكان'),
('امكان العالميه'),
('ان بوكس'),
('اناند'),
('انتري'),
('اندكس'),
('انديكس'),
('انوار الخمسة'),
('انور'),
('اوبال'),
('اوبرا'),
('اوجى اس'),
('اوراسكوم'),
('اوطان'),
('اوطان الدولي'),
('اوفرجار'),
('اون سايد'),
('ايت'),
('ايركونديشن'),
('ايمان'),
('ايمن'),
('ايه ار تى'),
('ايه سويت'),
('بابلو'),
('بابي تومي'),
('باراك'),
('بارتون'),
('بارتون كافيه'),
('بارتون كيف'),
('بارتى'),
('بارتي تايم'),
('بارد'),
('بارديسرسح'),
('بافونى'),
('باقي اليوم في صبحان'),
('باكداش'),
('باكرى'),
('بان كويت'),
('بايلو'),
('بتول الكندري'),
('بحر'),
('بحر الخليج'),
('بدر'),
('بدر العازمي'),
('بدر النجدي'),
('بدر الهده'),
('بدر سالم'),
('بدر سالم الهده'),
('بدون اسم'),
('براك'),
('براك العصفور'),
('براون'),
('برجور'),
('برقان'),
('بروتو جويس'),
('بريد توك'),
('بريز جوس'),
('بريس'),
('بريس انتر ناشونال'),
('بريست'),
('بريمير'),
('بسام'),
('بسام الدماك'),
('بسكوته'),
('بشار'),
('بطل'),
('بطل الدكان'),
('بكداش'),
('بكري'),
('بكيو'),
('بلاتينيوم'),
('بلال'),
('بندر'),
('بهاء'),
('بهبهاني'),
('بوبيان'),
('بوبيان والفنار'),
('بوبيان وفنار'),
('بورا'),
('بورابورا'),
('بوظة'),
('بوظه الفارس'),
('بيان'),
('بيت الانماء'),
('بيترا'),
('بيروت'),
('بيست هيلث'),
('بيكفام'),
('بيكوكورنر'),
('بيكيو كورنو'),
('بينتو'),
('تجهيزات'),
('تجهيزات زراعيه'),
('تراميسو'),
('تركي'),
('تشكن برست'),
('تشيد العالميه'),
('تشيكن بريست'),
('تقديم'),
('تقنية المستقبل'),
('تكنولوجي'),
('تمجيد'),
('تمرية'),
('تمور'),
('تمور استريت'),
('تميز'),
('تميز الخليجيه'),
('توب كير'),
('توفيق'),
('تونتى جرام'),
('تونتي'),
('تيتوس'),
('جابر'),
('جابر ابو مرزوق'),
('جابرالكاظمى'),
('جابرمرزوق'),
('جاردن استيشن'),
('جاسم'),
('جاسم سهيل'),
('جاسيو'),
('جاكلت'),
('جاكليت'),
('جانا بكري'),
('جاهز'),
('جدر بيبي'),
('جراح'),
('جرافتى كافيه'),
('جرافيتى'),
('جرجس'),
('جرفتي'),
('جرين'),
('جرين لاند'),
('جلارتوه'),
('جلال'),
('جلال العازمى'),
('جلوبال'),
('جلوبل'),
('جلوبل فود'),
('جمال'),
('جمال التجارية'),
('جمال الكاظمى'),
('جمعيه'),
('جمعيه العبدلي'),
('جميلة الميضان'),
('جنرال الكويت'),
('جواد الصفار'),
('جوب اوردر'),
('جوردان'),
('جوردن استار'),
('جوزكونتر'),
('جوس'),
('جوس بايو'),
('جوس بلانت'),
('جوستو جروب'),
('جولف'),
('جوهره السعد'),
('جويس فاكتورى'),
('جويل'),
('جيلاتكو'),
('جيلاتو روز'),
('جيلاتوه'),
('جيلارتو'),
('جيلارتوروسا'),
('جيلارتوه روزه'),
('جيلراتو'),
('حاتم'),
('حافظ'),
('حامد'),
('حجرمكة'),
('حسام'),
('حسن'),
('حسن ابل'),
('حسن الناصر'),
('حسين'),
('حسين الشريف'),
('حسين سعود'),
('حسين علي'),
('حضانه اوييبي'),
('حكيم'),
('حكيم كاترينج'),
('حلاوه كاكاو'),
('حلويات الفردوس'),
('حلويات النصر'),
('حلويات جاكليت'),
('حلويات دليزيا'),
('حلويات قوزال'),
('حلويات كارميللو'),
('حلويات كراميلو'),
('حلويات لوريف'),
('حلويات لين'),
('حلويات مورانو'),
('حمان'),
('حمد'),
('حمد الدخيل'),
('حمدان'),
('حمدان الدماك'),
('حمده'),
('حمود'),
('حمود الخالد'),
('حميد'),
('حور العالمية'),
('خالد'),
('خالد الشراح'),
('خالد العازمي'),
('خالد عبد الكريم'),
('خالد محمد'),
('خالدالعتيبى'),
('خالدفرحان'),
('خضير'),
('خضيرالعازمي'),
('خلف غالى'),
('خلود الكندري'),
('خوخ ومانجا'),
('خوخ ومشمش'),
('خوش عصير'),
('د جويس'),
('داكا'),
('داليا'),
('دانه'),
('دانه فيش'),
('داوود'),
('دراجون'),
('دراجون فروت'),
('دروبس'),
('دريم'),
('دريم لاند'),
('دكتور موسي'),
('دلايت'),
('دليزيا'),
('دندوش'),
('دهلوس'),
('دولت'),
('دولسي'),
('دولمن'),
('دوه'),
('ديانا'),
('ديب'),
('ديب اند ديب'),
('ديب&ديب'),
('ديفاجو'),
('ديلشيص'),
('ديليس'),
('ديليس سويت'),
('ديليشيس'),
('ذياد'),
('راسكو للتجارة'),
('راشد'),
('راشد العجمى'),
('رافا'),
('راميس'),
('راميش'),
('رانيا'),
('رايس'),
('ربيع'),
('ربيع الحداد'),
('رجب'),
('رفيق'),
('ركن الفراوله'),
('روبوبس'),
('روتانا'),
('رومانة'),
('رويال'),
('رويال جوينت'),
('رياض'),
('ريتاج'),
('ريتش'),
('ريتش جيلاتو'),
('ريدكريم'),
('ريس'),
('ريس بيس'),
('ريس جلات'),
('ريس جيلاتوه'),
('ريس فور بيس'),
('ريفال'),
('ريفريش'),
('ريقال'),
('زاهد'),
('زهرا'),
('زهره'),
('زهره كافيه'),
('زوارة الحبايب'),
('زون'),
('زون سيفن'),
('زياد'),
('زيد'),
('زينب'),
('زينه'),
('سابل'),
('سابل المتحده'),
('سابليه'),
('سارة'),
('سالم'),
('سالم العجمى'),
('سالم المزارع'),
('سالم الهدة'),
('سالم فلاح'),
('سامح'),
('سامى'),
('سانتا'),
('ستيك هاوس'),
('سحر الجزيره'),
('سرياباك'),
('سعد'),
('سعود'),
('سعود مبارك'),
('سفن سيزون'),
('سكر'),
('سلطان'),
('سلطان الخالد'),
('سليمان'),
('سمارات'),
('سمارت فون'),
('سمبل'),
('سمبل جوس'),
('سمك الفحاحيل'),
('سناك ات'),
('سنديان'),
('سوق اسعار زمان'),
('سوق السمك'),
('سوق الشمم'),
('سوق الكادي'),
('سوق المملكه'),
('سوق النادر'),
('سوق النقى'),
('سوق بيتك'),
('سوق كاظمه'),
('سوق لندن'),
('سوق ميلسون'),
('سومانى'),
('سوهو'),
('سويت'),
('سويت استور'),
('سيبون'),
('سيتى'),
('سيتى ماركت'),
('سيمبلى جوس'),
('شارع التمور'),
('شاكوماكو'),
('شاهين'),
('شبل'),
('شرق'),
('شركة بحر الخليج'),
('شركه الامارات'),
('شركه التقنيات'),
('شركه التكامل'),
('شركه الحسن'),
('شركه الرئيسي'),
('شركه الرايه'),
('شركه الرايه البيضاء'),
('شركه الرياض'),
('شركه السيف'),
('شركه الطحين'),
('شركه الفلاح'),
('شركه المنار'),
('شركه الواوان'),
('شركه الوتر'),
('شركه امكان'),
('شركه باك'),
('شركه بحر'),
('شركه تجهيزات'),
('شركه تجهيزات زراعيه'),
('شركه تقديم'),
('شركه تقديم للتجهيزات'),
('شركه تمور'),
('شركه تميز'),
('شركه تيتوس'),
('شركه جاسيو'),
('شركه جبل الصفاه'),
('شركه جنات'),
('شركه دوه'),
('شركه ديانا'),
('شركه رياض'),
('شركه سنديان'),
('شركه فخاره'),
('شركه كاظمه'),
('شركه مانجو طلعت'),
('شركه مدي'),
('شركه مروج'),
('شركه نجود'),
('شركه واو'),
('شرمبر'),
('شرمير'),
('شريمبر'),
('شزره الكويت'),
('شمرات'),
('شموع المستقبل'),
('شوجر'),
('شوكليت'),
('شوكليت اند مور'),
('شوكليت نيس'),
('شيماء كاترينج'),
('صالح'),
('صالح الضبيب'),
('صفوان'),
('صلاح'),
('صلاح فلاح'),
('صهيب'),
('صياح'),
('صياح العازمى'),
('صيداليوم'),
('طارق'),
('طارق الهاجرى'),
('طبق الخير'),
('طلال'),
('طلال الشطي'),
('طيور الجنه'),
('عائشة'),
('عادل'),
('عادل الكندرى'),
('عاصم'),
('عالم العصير'),
('عالم المانجو'),
('عايض عمير'),
('عبد الرحمن'),
('عبد الرحمن عبدالله'),
('عبد الرحمن ناصر'),
('عبد الله الخالدي'),
('عبد الله الرفاعي'),
('عبد الله العطيه'),
('عبد الله العنجري'),
('عبد المحسن'),
('عبد المحسن الرفاعي'),
('عبدالرحمن العجمى'),
('عبدالعزيز'),
('عبدالعزيز الدماك'),
('عبدالله'),
('عبدالله الدماك'),
('عبدالله الساير'),
('عبدالله العازمى'),
('عبدالله الملا'),
('عبدالله بدر الملا'),
('عبدالله راشد'),
('عبدالوهاب'),
('عبيد'),
('عبيد حمود'),
('عبير'),
('عثق'),
('عثق للفطاير'),
('عجم'),
('عدنان'),
('عدنان الجريوى'),
('عزيز'),
('عزيز اسماعيل'),
('عصاير العبدلي'),
('عصير الباشا'),
('عصير الشويخ'),
('عصير الضاحية'),
('عصير تايم'),
('عصير جوس'),
('عصير روتانا'),
('عصير كيفان'),
('عصير ماربي'),
('عصيرالمنعش'),
('عصيربورا'),
('علي'),
('علي ابوفواز'),
('علي العازمي'),
('علي الغانم'),
('عماد'),
('عمار'),
('عماير'),
('عمر'),
('عمر سعد'),
('عنتر'),
('عواد'),
('عوض'),
('عياد'),
('عيد'),
('عيسى'),
('غنيم'),
('فارس'),
('فارس العجمى'),
('فاضل'),
('فاضل الشرف'),
('فاطمه'),
('فالح'),
('فالح الرشيدى'),
('فالكون بلس'),
('فجر الايمان'),
('فخاره'),
('فداء'),
('فرج وخالد'),
('فرش فش'),
('فرهاد'),
('فرهارد'),
('فروت'),
('فروت بوكس'),
('فروت كات'),
('فروله وموز'),
('فرويو'),
('فرويو فور زين'),
('فريش'),
('فريش بوكس'),
('فريش بوينت'),
('فريش فيش'),
('فريش مانجو'),
('فريو'),
('فريو فروزون'),
('فطائر عثق'),
('فلاح'),
('فلاح الظفيري'),
('فلاح راشد'),
('فلاور'),
('فلاورسويت'),
('فلوندو'),
('فنار'),
('فنار وبوبيان'),
('فهد'),
('فهد مسفر'),
('فهدالدماك'),
('فهدالهاجرى'),
('فهدمرزوق'),
('فواز'),
('فود'),
('فود ماتيس'),
('فود ميتس'),
('فور سيزون'),
('فورست'),
('فوريو'),
('فيتيرا'),
('فيراج'),
('فيش لوز'),
('فيصل'),
('فيصل الدماك'),
('قطرات منعشة'),
('قلعه العصير'),
('قهوه زهره'),
('قوزال'),
('كاب ديزاين'),
('كاترنج'),
('كارميللو'),
('كاستلو'),
('كاش'),
('كاطمة'),
('كاظمه'),
('كافيه لطيفه'),
('كاكاو'),
('كاكو'),
('كالو'),
('كالو كترنج'),
('كانتين'),
('كاوكا'),
('كباب'),
('كباب شمس'),
('كراميلو'),
('كريتف'),
('كريستال'),
('كريستوفر'),
('كريم'),
('كسار'),
('كمال'),
('كمال الدين'),
('كنافة حبيبة'),
('كواليتي'),
('كورالانشائية'),
('كوستال'),
('كوفي'),
('كوكا كاتر'),
('كونتراكتورز'),
('كويت اسويدش'),
('كويت العز'),
('كويت فارم'),
('كويت كيك'),
('كى جى ال'),
('كيان'),
('كيتشن دريم'),
('كيكس اند كو'),
('لابجيت'),
('لارت شكليت'),
('لازا بينس'),
('لازى'),
('لازيبنز'),
('لافا كيك'),
('لامار'),
('لامير'),
('لجنه اخاك المسلم'),
('لطفي'),
('لطيفه'),
('لطيفه كافيه'),
('لقمان'),
('لقمه'),
('لمار'),
('لودور'),
('لوريف'),
('لوزان'),
('لوزوموز'),
('لوفت'),
('لوي'),
('ليرف فور سويت'),
('ليريف'),
('ليريف سويت'),
('ليريف للحلويات'),
('ليشياس'),
('ليفا'),
('لين'),
('لين كافيه'),
('لين كيف'),
('م محمد'),
('م/ سعد'),
('م/ابراهيم'),
('م/حازم'),
('م/سامي'),
('م/طارق'),
('م/عبدالله'),
('م/وائل'),
('مؤسسة الدهماء'),
('ماجد جميل'),
('ماجيك باك'),
('ماجيك هوم'),
('ماركت'),
('ماركت الجهرا'),
('ماكسيم'),
('مانجو'),
('مانجو طلعت'),
('مبارك'),
('مبارك الدماك'),
('مبارك السعود'),
('مبارك الظفيرى'),
('مبارك سعود'),
('مبارك عوض'),
('مبروك'),
('مجموع طلبيات السنه'),
('محبوب'),
('محسن'),
('محسن الرفاعى'),
('محل'),
('محل المدينه'),
('محل مختار'),
('محل وليد'),
('محمد'),
('محمد اسماعيل'),
('محمد الاسكندراني'),
('محمد البعيجان'),
('محمد الحسين'),
('محمد الرميدي'),
('محمد الغريب'),
('محمد المطيري'),
('محمد الهلالي'),
('محمد حسين'),
('محمد حمد العجمي'),
('محمد سيد'),
('محمد طه'),
('محمد عبد المحسن'),
('محمد عبدالمحسن الرفاعى'),
('محمد علي'),
('محمد مسعود'),
('محمد نبيل'),
('محمد ياسر'),
('محمدابراهيم'),
('محمدالعجمى'),
('محمدالعلاج'),
('محمدالفضالة'),
('محمددهلوس'),
('محمدسهيل'),
('محمدضارى'),
('محمدغانم'),
('محمدنعيم'),
('محمود'),
('محمود الجوهري'),
('محي'),
('محي الدين'),
('مخبز'),
('مختار'),
('مختبر ميدلاب'),
('مدرسه اقرا'),
('مدرسه الاوائل'),
('مدني'),
('مدى للبيوت'),
('مرام'),
('مرزوق'),
('مركز الكويت'),
('مركز الكويت الصناعي'),
('مركز زهرة'),
('مركزهايدرو'),
('مروج'),
('مروج للضيافه'),
('مريم'),
('مريم الغنام'),
('مزايا'),
('مزرعة اسماء'),
('مزرعة نواره'),
('مزرعةفاضل الشرف'),
('مزرعه الثنيان'),
('مزرعه الفهم'),
('مزرعه اليمامه'),
('مزرعه جميله'),
('مزرعه عدنان'),
('مزرعه غنيم'),
('مزرعه كيفكو'),
('مساعد'),
('مستر هوم'),
('مسمكه العازمي'),
('مسمكه اليوم'),
('مسمكه صيد اليوم'),
('مشارى الرشيدى'),
('مشارى العلاج'),
('مشاري'),
('مشعل'),
('مشعل الحربي'),
('مشعل المطوع'),
('مصطفي'),
('مصنع ارت كيو'),
('مصنع الرابطه'),
('مصنع الشرار'),
('مصنع اوطان'),
('مصنع شذره الكويت'),
('مصنع شزه'),
('مطابع الروضان'),
('مطبعة توفيق'),
('مطبعة جرين لاند'),
('مطبعه بلاتينيوم'),
('مطبعه سلطان'),
('مطبعه سهاري'),
('مطبعه كشخه'),
('مطعم ابيتا'),
('مطعم زواره الحبايب'),
('مطعم مهمش'),
('مطعم هوبو'),
('مقبل'),
('مقبل الروميضى'),
('مقبل العازمى'),
('مكتب الخليج'),
('مكتب الرايه'),
('مكتبه الاسره'),
('مكسيم'),
('ملحمة الصدارة'),
('ملحمه'),
('ملحمه الخاروف'),
('ملحمه الفاخر'),
('ملحمه الملك'),
('ملحمه النخبه'),
('ملكي'),
('مناحل الثنيان'),
('مناير الجاسم'),
('مندنى'),
('مندنى واحمد'),
('مندي'),
('منزل البناء'),
('منصور'),
('مها'),
('مهدي'),
('مهند'),
('مهندس تمجيد'),
('مهندس سامي'),
('مودرن هاوس'),
('مور اند مور'),
('موسسه الاحمدي'),
('موسى الدماك'),
('موسي'),
('موش'),
('موقع الصين'),
('مولتن سويت'),
('مووش'),
('ميدلاند'),
('ميس الريم'),
('ميسلون'),
('ميلاد'),
('ميلانو'),
('ميلسون'),
('ميم'),
('ناصر'),
('ناصر الشماع'),
('نايف'),
('نايف المطيري'),
('نبيل'),
('نجمه اسيا'),
('نجود'),
('نجويد'),
('نديم'),
('نستي بي'),
('نسر البريه'),
('نواره'),
('نواف'),
('نور'),
('نور اورجانيك'),
('نور حسن'),
('نوره'),
('نوره العثمان'),
('نيوجود'),
('هاشم'),
('هانوفيل'),
('هاني'),
('هاي كواليتي'),
('هايدرو'),
('هشام'),
('هلال'),
('هنيدى'),
('هوردى'),
('هوك الاهلية'),
('هوم جاردن'),
('هيثم العمر'),
('هيكترز'),
('واحد عصير'),
('واشنطونيا'),
('واو'),
('وايس مان'),
('وبوبيان'),
('وترميكر'),
('وحيد'),
('ورثه مقبل'),
('وليد'),
('وليدالفضالة'),
('ويت جراس'),
('يحيي'),
('يسرا'),
('يسرسح'),
('يقين'),
('يكيو كورنر'),
('يوار'),
('يواركيه'),
('يوركي سويت'),
('يوريكا'),
('يوريكا سويت'),
('يوسف'),
('يوسف الصفران'),
('يوسف الغانم'),
('يوسف الكربيانى'),
('يوسف غانم'),
('يونايتد'),
('يونايتد دانه'),
('يونايتد فود')
on conflict (name) do nothing;

-- إضافة وتعديل العملاء: للمدير بس (الموظف بيختار من القائمة)
drop policy if exists app_add on public.customers;
create policy app_add on public.customers for insert to authenticated with check ((select public.app_is_admin()));
drop policy if exists app_edit on public.customers;
create policy app_edit on public.customers for update to authenticated using ((select public.app_is_admin())) with check ((select public.app_is_admin()));

-- 20) توحيد اسم العميل: كل السندات اللي فيها الأسماء الغلط تتعدّل للاسم الصح، والأسماء الغلط تتشال من القائمة
create or replace function public.merge_customers_core(p_keep text, p_drop text[], p_by text, p_now text)
returns int language plpgsql security definer set search_path = public as $$
declare n int; k text := btrim(regexp_replace(p_keep, '\s+', ' ', 'g'));
begin
  if k is null or k = '' then raise exception 'اكتب الاسم الصح'; end if;
  p_drop := array(select x from unnest(p_drop) x where x is not null and x <> k);
  update public.deliveries d set
    customer = (select string_agg(x, ' + ' order by o) from (
                  select case when btrim(p) = any(p_drop) then k else btrim(p) end x, min(o) o
                  from unnest(string_to_array(d.customer, '+')) with ordinality u(p, o) where btrim(p) <> '' group by 1) s),
    updated_by = coalesce(p_by, d.updated_by), updated_at = coalesce(p_now, d.updated_at)
  where d.customer is not null and exists (select 1 from unnest(string_to_array(d.customer, '+')) p where btrim(p) = any(p_drop));
  get diagnostics n = row_count;
  insert into public.customers (name, active) values (k, 1) on conflict (name) do update set active = 1;
  delete from public.customers where name = any(p_drop);
  return n;
end $$;
revoke all on function public.merge_customers_core(text, text[], text, text) from public, anon, authenticated;

drop function if exists public.merge_customers(text, text[], text);
create or replace function public.merge_customers(p_keep text, p_drop jsonb, p_now text)
returns int language plpgsql security definer set search_path = public as $$
declare me text := (select a.username from public.app_user() a);
begin
  if me is null or not public.app_is_admin() then
    raise exception 'تعديل وحذف وتوحيد أسماء العملاء للمدير بس' using errcode = '42501'; end if;
  return public.merge_customers_core(p_keep, array(select jsonb_array_elements_text(p_drop)), me, p_now);
end $$;
revoke all on function public.merge_customers(text, jsonb, text) from public, anon;
grant execute on function public.merge_customers(text, jsonb, text) to authenticated;

-- نفس العميل متكتب بطرق مختلفة: بيتوحّدوا
select public.merge_customers_core('adoor', array['ador'], null, null);  -- adoor = ador
select public.merge_customers_core('pree', array['pre'], null, null);  -- pre = pree
select public.merge_customers_core('ابراهيم اليحي', array['ابراهيم يحيي'], null, null);  -- ابراهيم اليحي = ابراهيم يحيي
select public.merge_customers_core('الاتحاد', array['اتحاد'], null, null);  -- اتحاد = الاتحاد
select public.merge_customers_core('التجهيزات', array['تجهيزات'], null, null);  -- التجهيزات = تجهيزات
select public.merge_customers_core('التجهيزات الزراعية', array['تجهيزات زراعيه'], null, null);  -- التجهيزات الزراعية = تجهيزات زراعيه
select public.merge_customers_core('تمور', array['التمور'], null, null);  -- التمور = تمور
select public.merge_customers_core('الجمعية', array['جمعيه'], null, null);  -- الجمعية = جمعيه
select public.merge_customers_core('الدانة', array['دانه'], null, null);  -- الدانة = دانه
select public.merge_customers_core('الرياض', array['رياض'], null, null);  -- الرياض = رياض
select public.merge_customers_core('العبيد', array['عبيد'], null, null);  -- العبيد = عبيد
select public.merge_customers_core('الفنار', array['فنار'], null, null);  -- الفنار = فنار
select public.merge_customers_core('الملكي', array['ملكي'], null, null);  -- الملكي = ملكي
select public.merge_customers_core('هاني', array['الهانى'], null, null);  -- الهانى = هاني
select public.merge_customers_core('شركه الرياض', array['شركه رياض'], null, null);  -- شركه الرياض = شركه رياض
select public.merge_customers_core('مبارك سعود', array['مبارك السعود'], null, null);  -- مبارك السعود = مبارك سعود
select public.merge_customers_core('محمد حسين', array['محمد الحسين'], null, null);  -- محمد الحسين = محمد حسين
select public.merge_customers_core('يوسف غانم', array['يوسف الغانم'], null, null);  -- يوسف الغانم = يوسف غانم
select public.merge_customers_core('3بيس', array['3bees'], null, null);

-- 21) قائمة مشاكل الصيانة الثابتة: الموظف بيختار منها بس، والمدير بيضيف ويعدّل ويحذف
create table if not exists public.car_problems (id serial primary key, name text not null unique, active int not null default 1);
alter table public.car_problems enable row level security;
revoke all on table public.car_problems from anon;
grant select, insert, update on table public.car_problems to authenticated;
grant usage, select on sequence public.car_problems_id_seq to authenticated;
drop policy if exists app_read on public.car_problems;
create policy app_read on public.car_problems for select to authenticated using ((select count(*) from public.app_user()) > 0);
drop policy if exists app_add on public.car_problems;
create policy app_add on public.car_problems for insert to authenticated with check ((select public.app_is_admin()));
drop policy if exists app_edit on public.car_problems;
create policy app_edit on public.car_problems for update to authenticated using ((select public.app_is_admin())) with check ((select public.app_is_admin()));

-- تغيير اسم مشكلة (أو دمج/حذف مع نقل الفواتير): بيعدّل كل الفواتير اللي فيها الاسم القديم
-- شكل المشكلة في الفاتورة: «تاير جديد + تصليح بنشر — تفاصيل»
create or replace function public.merge_problems(p_keep text, p_drop jsonb, p_now text)
returns int language plpgsql security definer set search_path = public as $$
declare me text := (select a.username from public.app_user() a); k text := btrim(regexp_replace(p_keep, '\s+', ' ', 'g')); d text[]; n int;
begin
  if me is null or not public.app_is_admin() then raise exception 'تعديل وحذف مشاكل الصيانة للمدير بس' using errcode = '42501'; end if;
  if k is null or k = '' then raise exception 'اكتب اسم المشكلة'; end if;
  d := array(select x from jsonb_array_elements_text(p_drop) x where x <> k);
  update public.expenses e set
    problem = (select string_agg(x, ' + ' order by o) from (
                 select case when btrim(p) = any(d) then k else btrim(p) end x, min(o) o
                 from unnest(string_to_array(split_part(e.problem, ' — ', 1), '+')) with ordinality u(p, o) where btrim(p) <> '' group by 1) s)
              || case when position(' — ' in e.problem) > 0 then substr(e.problem, position(' — ' in e.problem)) else '' end,
    updated_by = me, updated_at = coalesce(p_now, e.updated_at)
  where exists (select 1 from unnest(string_to_array(split_part(e.problem, ' — ', 1), '+')) p where btrim(p) = any(d));
  get diagnostics n = row_count;
  insert into public.car_problems (name, active) values (k, 1) on conflict (name) do update set active = 1;
  delete from public.car_problems where name = any(d);
  return n;
end $$;
revoke all on function public.merge_problems(text, jsonb, text) from public, anon;
grant execute on function public.merge_problems(text, jsonb, text) to authenticated;

create or replace function public.problem_delete(p_name text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.app_is_admin() then raise exception 'حذف مشاكل الصيانة للمدير بس' using errcode = '42501'; end if;
  delete from public.car_problems where name = p_name;
end $$;
revoke all on function public.problem_delete(text) from public, anon;
grant execute on function public.problem_delete(text) to authenticated;

-- القائمة المبدئية (المدير يقدر يعدّل ويضيف من تبويب «الإعدادات» في صيانة السيارات)
insert into public.car_problems (name) values
('تاير جديد'),
('تصليح بنشر'),
('تيوب'),
('تاير اسبير'),
('بنشر متنقل'),
('تبديل زيت ماكينة'),
('زيت جير'),
('زيت سكان'),
('فلتر زيت'),
('فلتر ديزل'),
('فلتر هواء'),
('فلتر مكيف'),
('سيرفس كامل'),
('سفايف وفحمات'),
('كليبر بريك'),
('خرط فراويل'),
('فحص مكيف'),
('تعبئة غاز مكيف'),
('كمبروسر مكيف'),
('ثلاجة مكيف'),
('مروحة مكيف'),
('بطارية'),
('دينمو'),
('سلف'),
('لمبات'),
('تصليح كهرباء'),
('هرن'),
('مساحات'),
('جير'),
('كلاتش ودسك'),
('طرمبة كلاتش'),
('طرمبة زيت'),
('بخاخات'),
('قايش'),
('رديتر'),
('برمجة كمبيوتر'),
('بوشات ودراعات'),
('سبرنقات'),
('بالون هواء'),
('هوز هواء'),
('لحام'),
('مخرطة'),
('سمكرة'),
('صبغ'),
('قطع غيار'),
('فحص سنوي'),
('نقل وسطحة')
on conflict (name) do nothing;

-- 22) تصنيف مشاكل الصيانة (ميكانيكا، تكييف وتبريد، إطارات، إيجار ميكانيكي، إيجار كهربائي، قطع غيار، إيجار صبغ وسمكرة، حداد)
alter table public.car_problems add column if not exists category text;
-- تصنيف مبدئي للمشاكل اللي ملهاش تصنيف (المدير يغيّره من «الإعدادات» في صيانة السيارات)
update public.car_problems set category = case
    when name ~ 'تاير|تواير|بنشر|تيوب|إطار|اطار|كفر' then 'إطارات'
    when name ~ 'مكيف|تكييف|تكيف|غاز|كمبروس|ثلاجة|ثلاجه|رديتر|تبريد|مروحة|مروحه' then 'تكييف وتبريد'
    when name ~ 'كهرباء|كهربا|لمبات|لمبة|لمبه|ليتات|لايتات|دينمو|دينامو|سلف|هرن|بطارية|بطاريه|برمجة|برمجه|كمبيوتر|فيش|مساحات|سلك|سنسر' then 'إيجار كهربائي'
    when name ~ 'صبغ|سمكرة|سمكره' then 'إيجار صبغ وسمكرة'
    when name ~ 'لحام|لحيم|حداد|مخرطة|مخرطه|خرط' then 'حداد'
    when name ~ 'قطع غيار|شراء' then 'قطع غيار'
    when name ~ '^\s*(ايجار|إيجار|اجرة|أجرة|اجره)' then 'إيجار ميكانيكي'
    else 'ميكانيكا' end
where category is null or category = '';


select 'تم الإعداد بنجاح ✅' as result;
