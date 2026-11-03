-- ============================================================
-- 碳足迹 App · Supabase 数据库初始化脚本
--
-- 用法：Supabase Dashboard -> 对应项目的 SQL Editor -> 粘贴整段执行
--
-- 架构（方案 B）：
--   1. 所有业务表开启 RLS，且不建立任何 policy —— anon / publishable key 无法直接读写表
--   2. 客户端只调用 public 下的 RPC 函数
--   3. RPC 全部 SECURITY DEFINER，内部用会话 token 解析出 user_id，天然按账号隔离
--   4. service_role / secret key 只保留在服务端，绝不进客户端
-- ============================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- ============================================================
-- 一、表结构
-- ============================================================

-- 账号表：用户名 + bcrypt 密码哈希，不使用 Supabase Auth
create table if not exists public.users (
  id            uuid primary key default gen_random_uuid(),
  username      text not null unique,
  password_hash text not null,
  nickname      text not null default '低碳同学',
  month_goal    numeric(10, 2) not null default 30,
  -- 已消费积分：兑换勋章 +cost，领取任务奖励 -reward（与客户端原有语义保持一致）
  spent_point   integer not null default 0,
  created_at    timestamptz not null default now(),
  last_login_at timestamptz,
  constraint users_username_len check (char_length(username) between 3 and 32),
  constraint users_month_goal_ok check (month_goal >= 0)
);

-- 碳记录：与客户端 CarbonRecord 一一对应
create table if not exists public.carbon_records (
  id            text not null,
  user_id       uuid not null references public.users (id) on delete cascade,
  activity_id   text not null,
  activity_name text not null default '',
  category_id   text not null default '',
  unit          text not null default '',
  qty           numeric(12, 3) not null default 0,
  factor        numeric(12, 6) not null default 0,
  reduction     numeric(14, 3) not null default 0,
  point         integer not null default 0,
  record_date   date not null,
  record_time   bigint not null,
  note          text not null default '',
  created_at    timestamptz not null default now(),
  primary key (user_id, id)
);

create index if not exists idx_carbon_records_user_date
  on public.carbon_records (user_id, record_date desc, record_time desc);

-- 已获得的徽章 / 已兑换的徽章
create table if not exists public.user_badges (
  user_id     uuid not null references public.users (id) on delete cascade,
  badge_id    text not null,
  kind        text not null default 'achievement' check (kind in ('achievement', 'redeem')),
  cost        integer not null default 0,
  obtained_at timestamptz not null default now(),
  primary key (user_id, badge_id)
);

-- 每日任务领奖记录：唯一键对应客户端 taskKey = yyyy-MM-dd#taskId
create table if not exists public.task_claims (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.users (id) on delete cascade,
  claim_date date not null,
  task_id    text not null,
  reward     integer not null default 0,
  created_at timestamptz not null default now(),
  unique (user_id, claim_date, task_id)
);

-- 证书（当前无发证规则，仅预留结构化存储）
create table if not exists public.certificates (
  id        uuid primary key default gen_random_uuid(),
  user_id   uuid not null references public.users (id) on delete cascade,
  cert_no   text not null unique,
  title     text not null,
  level     text not null default '',
  issued_at timestamptz not null default now(),
  payload   jsonb not null default '{}'::jsonb
);

create index if not exists idx_certificates_user
  on public.certificates (user_id, issued_at desc);

-- 登录会话：token 由客户端本地保存，服务端只认这里的记录
create table if not exists public.sessions (
  token        text primary key,
  user_id      uuid not null references public.users (id) on delete cascade,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null,
  last_seen_at timestamptz not null default now()
);

create index if not exists idx_sessions_user on public.sessions (user_id);

-- ============================================================
-- 二、关闭直连访问（RLS 开启 + 零 policy）
-- ============================================================

alter table public.users          enable row level security;
alter table public.carbon_records enable row level security;
alter table public.user_badges    enable row level security;
alter table public.task_claims    enable row level security;
alter table public.certificates   enable row level security;
alter table public.sessions       enable row level security;

revoke all on table public.users          from anon, authenticated;
revoke all on table public.carbon_records from anon, authenticated;
revoke all on table public.user_badges    from anon, authenticated;
revoke all on table public.task_claims    from anon, authenticated;
revoke all on table public.certificates   from anon, authenticated;
revoke all on table public.sessions       from anon, authenticated;

-- ============================================================
-- 三、内部辅助函数
-- ============================================================

-- 由 token 解析 user_id；顺带刷新 last_seen_at
create or replace function public._session_user(p_token text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid;
begin
  if p_token is null or char_length(p_token) < 16 then
    return null;
  end if;

  select s.user_id into v_uid
    from public.sessions s
   where s.token = p_token
     and s.expires_at > now();

  if v_uid is not null then
    update public.sessions set last_seen_at = now() where token = p_token;
  end if;

  return v_uid;
end;
$$;

-- 统一的用户 JSON 结构（客户端直接按 camelCase 读取）
create or replace function public._user_json(u public.users)
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'id',          u.id,
    'username',    u.username,
    'nickname',    u.nickname,
    'monthGoal',   u.month_goal,
    'spentPoint',  u.spent_point,
    'createdAt',   u.created_at,
    'lastLoginAt', u.last_login_at
  );
$$;

-- 生成会话 token：两段 uuid 拼成 64 位 hex，无需 pgcrypto 的随机字节
create or replace function public._new_token()
returns text
language sql
volatile
as $$
  select replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
$$;

-- ============================================================
-- 四、对外 RPC
-- ============================================================

-- 注册：成功即自动登录并返回 token
create or replace function public.register_user(
  p_username text,
  p_password text,
  p_nickname text default '低碳同学'
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_name  text := lower(trim(coalesce(p_username, '')));
  v_nick  text := coalesce(nullif(trim(coalesce(p_nickname, '')), ''), '低碳同学');
  v_user  public.users;
  v_token text;
begin
  if char_length(v_name) < 3 or char_length(v_name) > 32 then
    return jsonb_build_object('ok', false, 'code', 'invalid_username', 'message', '用户名需为 3-32 位');
  end if;

  if p_password is null or char_length(p_password) < 6 then
    return jsonb_build_object('ok', false, 'code', 'invalid_password', 'message', '密码至少 6 位');
  end if;

  if exists (select 1 from public.users where username = v_name) then
    return jsonb_build_object('ok', false, 'code', 'username_taken', 'message', '用户名已被占用');
  end if;

  insert into public.users (username, password_hash, nickname, last_login_at)
  values (v_name, extensions.crypt(p_password, extensions.gen_salt('bf', 10)), v_nick, now())
  returning * into v_user;

  v_token := public._new_token();
  insert into public.sessions (token, user_id, expires_at)
  values (v_token, v_user.id, now() + interval '30 days');

  return jsonb_build_object('ok', true, 'token', v_token, 'user', public._user_json(v_user));
exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'code', 'username_taken', 'message', '用户名已被占用');
  when others then
    return jsonb_build_object('ok', false, 'code', 'register_failed', 'message', SQLERRM);
end;
$$;

-- 登录
create or replace function public.login_user(
  p_username text,
  p_password text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_name  text := lower(trim(coalesce(p_username, '')));
  v_user  public.users;
  v_token text;
begin
  delete from public.sessions where expires_at < now();

  select * into v_user from public.users where username = v_name;

  if v_user.id is null
     or v_user.password_hash <> extensions.crypt(coalesce(p_password, ''), v_user.password_hash) then
    return jsonb_build_object('ok', false, 'code', 'invalid_credentials', 'message', '用户名或密码错误');
  end if;

  update public.users set last_login_at = now() where id = v_user.id returning * into v_user;

  v_token := public._new_token();
  insert into public.sessions (token, user_id, expires_at)
  values (v_token, v_user.id, now() + interval '30 days');

  return jsonb_build_object('ok', true, 'token', v_token, 'user', public._user_json(v_user));
end;
$$;

-- 退出登录：销毁当前 token
create or replace function public.logout_user(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  delete from public.sessions where token = p_token;
  return jsonb_build_object('ok', true);
end;
$$;

-- 拉取当前账号的全量数据（登录后 / 启动校验时调用）
create or replace function public.get_snapshot(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid  uuid := public._session_user(p_token);
  v_user public.users;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'code', 'unauthorized', 'message', '登录已失效，请重新登录');
  end if;

  select * into v_user from public.users where id = v_uid;

  return jsonb_build_object(
    'ok', true,
    'user', public._user_json(v_user),
    'records', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',           r.id,
        'activityId',   r.activity_id,
        'activityName', r.activity_name,
        'categoryId',   r.category_id,
        'unit',         r.unit,
        'qty',          r.qty,
        'factor',       r.factor,
        'reduction',    r.reduction,
        'point',        r.point,
        'date',         to_char(r.record_date, 'YYYY-MM-DD'),
        'time',         r.record_time,
        'note',         r.note
      ) order by r.record_date desc, r.record_time desc)
      from public.carbon_records r
      where r.user_id = v_uid
    ), '[]'::jsonb),
    'badges', coalesce((
      select jsonb_agg(jsonb_build_object(
        'badgeId',    b.badge_id,
        'kind',       b.kind,
        'cost',       b.cost,
        'obtainedAt', (extract(epoch from b.obtained_at) * 1000)::bigint
      ))
      from public.user_badges b
      where b.user_id = v_uid
    ), '[]'::jsonb),
    'claims', coalesce((
      select jsonb_agg(jsonb_build_object(
        'claimDate', to_char(c.claim_date, 'YYYY-MM-DD'),
        'taskId',    c.task_id,
        'reward',    c.reward
      ))
      from public.task_claims c
      where c.user_id = v_uid
    ), '[]'::jsonb),
    'certificates', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',       c.id,
        'certNo',   c.cert_no,
        'title',    c.title,
        'level',    c.level,
        'issuedAt', (extract(epoch from c.issued_at) * 1000)::bigint,
        'payload',  c.payload
      ) order by c.issued_at desc)
      from public.certificates c
      where c.user_id = v_uid
    ), '[]'::jsonb)
  );
end;
$$;

-- 新增一条记录
create or replace function public.add_record(
  p_token  text,
  p_record jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := public._session_user(p_token);
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'code', 'unauthorized', 'message', '登录已失效，请重新登录');
  end if;

  if p_record is null or coalesce(p_record ->> 'id', '') = '' then
    return jsonb_build_object('ok', false, 'code', 'invalid_record', 'message', '记录缺少 id');
  end if;

  insert into public.carbon_records (
    id, user_id, activity_id, activity_name, category_id, unit,
    qty, factor, reduction, point, record_date, record_time, note
  ) values (
    p_record ->> 'id',
    v_uid,
    coalesce(p_record ->> 'activityId', ''),
    coalesce(p_record ->> 'activityName', ''),
    coalesce(p_record ->> 'categoryId', ''),
    coalesce(p_record ->> 'unit', ''),
    coalesce((p_record ->> 'qty')::numeric, 0),
    coalesce((p_record ->> 'factor')::numeric, 0),
    coalesce((p_record ->> 'reduction')::numeric, 0),
    coalesce((p_record ->> 'point')::integer, 0),
    coalesce((p_record ->> 'date')::date, current_date),
    coalesce((p_record ->> 'time')::bigint, (extract(epoch from now()) * 1000)::bigint),
    coalesce(p_record ->> 'note', '')
  )
  on conflict (user_id, id) do nothing;

  return jsonb_build_object('ok', true, 'id', p_record ->> 'id');
exception
  when others then
    return jsonb_build_object('ok', false, 'code', 'insert_failed', 'message', SQLERRM);
end;
$$;

-- 删除一条记录
create or replace function public.delete_record(
  p_token     text,
  p_record_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid   uuid := public._session_user(p_token);
  v_count integer := 0;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'code', 'unauthorized', 'message', '登录已失效，请重新登录');
  end if;

  delete from public.carbon_records
   where user_id = v_uid
     and id = p_record_id;

  get diagnostics v_count = row_count;
  return jsonb_build_object('ok', true, 'deleted', v_count);
end;
$$;

-- 领取每日任务奖励
create or replace function public.claim_task(
  p_token      text,
  p_task_id    text,
  p_claim_date date,
  p_reward     integer
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid   uuid := public._session_user(p_token);
  v_date  date := coalesce(p_claim_date, current_date);
  v_add   integer := greatest(coalesce(p_reward, 0), 0);
  v_spent integer;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'code', 'unauthorized', 'message', '登录已失效，请重新登录');
  end if;

  insert into public.task_claims (user_id, claim_date, task_id, reward)
  values (v_uid, v_date, p_task_id, v_add)
  on conflict (user_id, claim_date, task_id) do nothing;

  if not found then
    return jsonb_build_object('ok', false, 'code', 'already_claimed', 'message', '今天已经领过了');
  end if;

  update public.users
     set spent_point = spent_point - v_add
   where id = v_uid
  returning spent_point into v_spent;

  return jsonb_build_object('ok', true, 'spentPoint', v_spent);
end;
$$;

-- 兑换徽章
create or replace function public.redeem_badge(
  p_token    text,
  p_badge_id text,
  p_cost     integer
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := public._session_user(p_token);
  v_cost   integer := greatest(coalesce(p_cost, 0), 0);
  v_earned bigint;
  v_spent  integer;
  v_avail  bigint;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'code', 'unauthorized', 'message', '登录已失效，请重新登录');
  end if;

  if exists (select 1 from public.user_badges where user_id = v_uid and badge_id = p_badge_id) then
    return jsonb_build_object('ok', false, 'code', 'already_owned', 'message', '已经拥有该徽章');
  end if;

  select coalesce(sum(point), 0) into v_earned from public.carbon_records where user_id = v_uid;
  select spent_point into v_spent from public.users where id = v_uid;
  v_avail := v_earned - v_spent;

  if v_avail < v_cost then
    return jsonb_build_object('ok', false, 'code', 'insufficient_point', 'message', '积分不足',
                              'available', v_avail);
  end if;

  insert into public.user_badges (user_id, badge_id, kind, cost)
  values (v_uid, p_badge_id, 'redeem', v_cost);

  update public.users
     set spent_point = spent_point + v_cost
   where id = v_uid
  returning spent_point into v_spent;

  return jsonb_build_object('ok', true, 'spentPoint', v_spent, 'available', v_avail - v_cost);
end;
$$;

-- 更新昵称 / 月目标
create or replace function public.update_profile(
  p_token      text,
  p_nickname   text,
  p_month_goal numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid  uuid := public._session_user(p_token);
  v_user public.users;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'code', 'unauthorized', 'message', '登录已失效，请重新登录');
  end if;

  update public.users
     set nickname   = coalesce(nullif(trim(coalesce(p_nickname, '')), ''), nickname),
         month_goal = greatest(coalesce(p_month_goal, month_goal), 0)
   where id = v_uid
  returning * into v_user;

  return jsonb_build_object('ok', true, 'user', public._user_json(v_user));
end;
$$;

-- ============================================================
-- 五、权限：只开放 RPC，不开放表
-- ============================================================

revoke all on function public._session_user(text)   from public, anon, authenticated;
revoke all on function public._user_json(public.users) from public, anon, authenticated;
revoke all on function public._new_token()          from public, anon, authenticated;

grant execute on function public.register_user(text, text, text)   to anon, authenticated;
grant execute on function public.login_user(text, text)            to anon, authenticated;
grant execute on function public.logout_user(text)                 to anon, authenticated;
grant execute on function public.get_snapshot(text)                to anon, authenticated;
grant execute on function public.add_record(text, jsonb)           to anon, authenticated;
grant execute on function public.delete_record(text, text)         to anon, authenticated;
grant execute on function public.claim_task(text, text, date, integer) to anon, authenticated;
grant execute on function public.redeem_badge(text, text, integer) to anon, authenticated;
grant execute on function public.update_profile(text, text, numeric) to anon, authenticated;

-- 让 PostgREST 立即刷新 schema 缓存
notify pgrst, 'reload schema';
