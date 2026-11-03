-- ============================================================
-- 碳足迹 App · 家庭系统 Supabase 脚本
--
-- 用法：Supabase Dashboard -> SQL Editor -> 整段粘贴执行（可重复执行）
-- 前置：schema.sql 已执行（依赖 public.users / public.sessions / public._session_user）
--
-- 设计与项目原有方案保持一致：
--   1. 业务表开 RLS 且不建 policy，anon 无法直接读写
--   2. 客户端只调 public 下的 RPC，全部 SECURITY DEFINER
--   3. RPC 内部用会话 token 解析 user_id，返回统一 { ok, code, message } 信封
--
-- 业务流程（用户描述的那套）：
--   A 搜索 B  ->  A 发邀请（pending）
--             ->  B 在「我的家庭」看到邀请卡片，点同意
--             ->  服务端在同一事务里创建 family + 两条 member（A=owner, B=member）
--             ->  双方此后 get_family 都能拿到同一个家庭
-- ============================================================

-- ============================================================
-- 0. 可调参数
-- ============================================================

-- 家庭人数上限：改这里即可（2 = 只能两人家庭）
create or replace function public._family_max_members()
returns integer
language sql
immutable
as $$ select 6 $$;

-- 邀请有效期（天）
create or replace function public._family_invite_days()
returns integer
language sql
immutable
as $$ select 7 $$;

-- 随机邀请码（8 位，用于"邀请码加入"这种兜底方式）
create or replace function public._new_family_code()
returns text
language sql
volatile
as $$
  select upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
$$;

-- ============================================================
-- 1. 表结构
-- ============================================================

create table if not exists public.families (
  id          uuid primary key default gen_random_uuid(),
  name        text not null default '我的低碳家庭',
  owner_id    uuid not null references public.users (id) on delete cascade,
  invite_code text not null unique,
  created_at  timestamptz not null default now(),
  constraint families_name_len check (char_length(name) between 1 and 24)
);

-- 家庭成员：user_id 唯一 => 一个账号只能属于一个家庭
create table if not exists public.family_members (
  family_id uuid not null references public.families (id) on delete cascade,
  user_id   uuid not null references public.users (id) on delete cascade,
  role      text not null default 'member' check (role in ('owner', 'member')),
  joined_at timestamptz not null default now(),
  primary key (family_id, user_id),
  constraint family_members_one_family unique (user_id)
);

create index if not exists idx_family_members_family
  on public.family_members (family_id);

-- 家庭邀请
--   family_id 为空 => 组建型邀请（邀请人当时还没有家庭，同意时新建家庭）
--   family_id 非空 => 加入型邀请（邀请人已有家庭，同意时并入该家庭）
create table if not exists public.family_invites (
  id           uuid primary key default gen_random_uuid(),
  family_id    uuid references public.families (id) on delete cascade,
  inviter_id   uuid not null references public.users (id) on delete cascade,
  invitee_id   uuid not null references public.users (id) on delete cascade,
  family_name  text not null default '',
  status       text not null default 'pending'
               check (status in ('pending', 'accepted', 'rejected', 'canceled')),
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '7 days',
  responded_at timestamptz,
  constraint family_invites_not_self check (inviter_id <> invitee_id)
);

create unique index if not exists uq_family_invites_pending
  on public.family_invites (inviter_id, invitee_id)
  where status = 'pending';

create index if not exists idx_family_invites_invitee
  on public.family_invites (invitee_id, status);

-- ============================================================
-- 2. 关闭直连访问（与 schema.sql 同一个策略）
-- ============================================================

alter table public.families       enable row level security;
alter table public.family_members enable row level security;
alter table public.family_invites enable row level security;

revoke all on table public.families       from anon, authenticated;
revoke all on table public.family_members from anon, authenticated;
revoke all on table public.family_invites from anon, authenticated;

-- ============================================================
-- 3. 内部辅助：组装家庭 JSON（成员 + 各自减排统计）
-- ============================================================

create or replace function public._family_json(p_family_id uuid, p_me uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today  date := (now() at time zone 'Asia/Shanghai')::date;
  v_family public.families;
  v_members jsonb;
begin
  select * into v_family from public.families where id = p_family_id;
  if v_family.id is null then
    return null;
  end if;

  select coalesce(jsonb_agg(row_json order by joined_at), '[]'::jsonb)
    into v_members
    from (
      select m.joined_at,
             jsonb_build_object(
               'userId',         m.user_id,
               'username',       u.username,
               'nickname',       u.nickname,
               'role',           m.role,
               'isMe',           (m.user_id = p_me),
               'isOwner',        (m.role = 'owner'),
               'joinedAt',       m.joined_at,
               'todayReduction', coalesce((
                  select sum(r.reduction) from public.carbon_records r
                   where r.user_id = m.user_id and r.record_date = v_today), 0),
               'monthReduction', coalesce((
                  select sum(r.reduction) from public.carbon_records r
                   where r.user_id = m.user_id
                     and r.record_date >= date_trunc('month', v_today)::date), 0),
               'totalReduction', coalesce((
                  select sum(r.reduction) from public.carbon_records r
                   where r.user_id = m.user_id), 0)
             ) as row_json
        from public.family_members m
        join public.users u on u.id = m.user_id
       where m.family_id = p_family_id
    ) s;

  return jsonb_build_object(
    'id',          v_family.id,
    'name',        v_family.name,
    'inviteCode',  v_family.invite_code,
    'ownerId',     v_family.owner_id,
    'createdAt',   v_family.created_at,
    'memberLimit', public._family_max_members(),
    'members',     v_members
  );
end;
$$;

-- 我当前所在的 family_id（没有则 null）
create or replace function public._my_family_id(p_uid uuid)
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select family_id from public.family_members where user_id = p_uid limit 1;
$$;

-- ============================================================
-- 4. 对外 RPC
-- ============================================================

-- ------------------------------------------------------------
-- 4.1 搜索可邀请的用户（按用户名或昵称模糊匹配）
--     只返回：用户名 / 昵称 / 是否已有家庭，不泄露其他信息
-- ------------------------------------------------------------
create or replace function public.family_search(
  p_token   text,
  p_keyword text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid   uuid := public._session_user(p_token);
  v_kw    text := trim(coalesce(p_keyword, ''));
  v_mine  uuid;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'code', 'unauthorized', 'message', '登录已失效，请重新登录');
  end if;

  if v_kw = '' then
    return jsonb_build_object('ok', false, 'code', 'empty_keyword', 'message', '请输入用户名或昵称');
  end if;

  v_mine := public._my_family_id(v_uid);

  return jsonb_build_object(
    'ok', true,
    'users', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',          u.id,
               'username',    u.username,
               'nickname',    u.nickname,
               'hasFamily',   (m.user_id is not null),
               'isInMyFamily', coalesce(m.family_id = v_mine, false)
             ) order by (u.username = v_kw) desc, (u.nickname = v_kw) desc, u.username)
        from (
          select id, username, nickname
            from public.users
           where id <> v_uid
             and (username ilike '%' || v_kw || '%' or nickname ilike '%' || v_kw || '%')
           order by username
           limit 10
        ) u
        left join public.family_members m on m.user_id = u.id
    ), '[]'::jsonb)
  );
end;
$$;

-- ------------------------------------------------------------
-- 4.2 发送邀请
--     inviter 没有家庭 -> 组建型（family_id = null）
--     inviter 已有家庭 -> 加入型（family_id = 我的家庭）
-- ------------------------------------------------------------
create or replace function public.family_invite(
  p_token       text,
  p_invitee_id  uuid,
  p_family_name text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid     uuid := public._session_user(p_token);
  v_mine    uuid;
  v_full    boolean;
  v_invite  public.family_invites;
  v_target  public.users;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'code', 'unauthorized', 'message', '登录已失效，请重新登录');
  end if;

  if p_invitee_id is null or p_invitee_id = v_uid then
    return jsonb_build_object('ok', false, 'code', 'invalid_target', 'message', '不能邀请自己');
  end if;

  select * into v_target from public.users where id = p_invitee_id;
  if v_target.id is null then
    return jsonb_build_object('ok', false, 'code', 'user_not_found', 'message', '该用户不存在');
  end if;

  v_mine := public._my_family_id(v_uid);

  -- 对方已有家庭
  if public._my_family_id(p_invitee_id) is not null then
    return jsonb_build_object('ok', false, 'code', 'target_in_family',
                              'message', v_target.nickname || ' 已经在其他家庭里了');
  end if;

  -- 我的家庭是否已满
  if v_mine is not null then
    select count(*) >= public._family_max_members() into v_full
      from public.family_members where family_id = v_mine;
    if v_full then
      return jsonb_build_object('ok', false, 'code', 'family_full',
                                'message', '家庭人数已满（最多 ' || public._family_max_members() || ' 人）');
    end if;
  end if;

  -- 对方已经邀请过我 -> 提示去收件箱处理
  if exists (select 1 from public.family_invites
              where inviter_id = p_invitee_id and invitee_id = v_uid and status = 'pending') then
    return jsonb_build_object('ok', false, 'code', 'invite_pending_from_target',
                              'message', v_target.nickname || ' 已经向你发出邀请，去「我的家庭」里处理吧');
  end if;

  -- 幂等：已经发过同一条
  select * into v_invite from public.family_invites
   where inviter_id = v_uid and invitee_id = p_invitee_id and status = 'pending';
  if v_invite.id is not null then
    return jsonb_build_object('ok', true, 'inviteId', v_invite.id,
                              'duplicated', true, 'message', '邀请已发送，等待对方同意');
  end if;

  insert into public.family_invites (family_id, inviter_id, invitee_id, family_name, expires_at)
  values (
    v_mine,
    v_uid,
    p_invitee_id,
    coalesce(nullif(trim(p_family_name), ''), '我的低碳家庭'),
    now() + (public._family_invite_days() || ' days')::interval
  )
  returning * into v_invite;

  return jsonb_build_object('ok', true, 'inviteId', v_invite.id, 'duplicated', false,
                            'message', '邀请已发送，等待 ' || v_target.nickname || ' 同意');
exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'code', 'duplicate_invite', 'message', '邀请已存在，等待对方同意');
end;
$$;

-- ------------------------------------------------------------
-- 4.3 处理邀请：同意
--     组建型 -> 新建家庭（inviter 为 owner）
--     加入型 -> 并入对方家庭
-- ------------------------------------------------------------
create or replace function public.family_accept(
  p_token     text,
  p_invite_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid   uuid := public._session_user(p_token);
  v_inv   public.family_invites;
  v_mine  uuid;
  v_fid   uuid;
  v_cnt   integer;
  v_name  text;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'code', 'unauthorized', 'message', '登录已失效，请重新登录');
  end if;

  select * into v_inv from public.family_invites where id = p_invite_id for update;
  if v_inv.id is null then
    return jsonb_build_object('ok', false, 'code', 'invite_not_found', 'message', '邀请不存在或已撤销');
  end if;
  if v_inv.invitee_id <> v_uid then
    return jsonb_build_object('ok', false, 'code', 'not_yours', 'message', '这不是发给你的邀请');
  end if;
  if v_inv.status <> 'pending' then
    return jsonb_build_object('ok', false, 'code', 'invite_closed', 'message', '该邀请已处理过了');
  end if;
  if v_inv.expires_at < now() then
    update public.family_invites
       set status = 'canceled', responded_at = now()
     where id = v_inv.id;
    return jsonb_build_object('ok', false, 'code', 'invite_expired', 'message', '邀请已过期，请对方重新发起');
  end if;

  v_mine := public._my_family_id(v_uid);
  if v_mine is not null then
    if v_inv.family_id is not null and v_inv.family_id = v_mine then
      update public.family_invites set status = 'accepted', responded_at = now() where id = v_inv.id;
      return jsonb_build_object('ok', true, 'family', public._family_json(v_mine, v_uid));
    end if;
    return jsonb_build_object('ok', false, 'code', 'already_in_family',
                              'message', '你已经在一个家庭里了，先退出再同意新邀请');
  end if;

  v_fid := v_inv.family_id;
  if v_fid is null then
    -- 邀请人在等待期间可能已经建了家庭，那就直接并进去
    v_fid := public._my_family_id(v_inv.inviter_id);
  end if;

  if v_fid is null then
    v_name := coalesce(nullif(trim(v_inv.family_name), ''), '我的低碳家庭');
    insert into public.families (name, owner_id, invite_code)
    values (v_name, v_inv.inviter_id, public._new_family_code())
    returning id into v_fid;

    insert into public.family_members (family_id, user_id, role)
    values (v_fid, v_inv.inviter_id, 'owner')
    on conflict do nothing;
  end if;

  select count(*) into v_cnt from public.family_members where family_id = v_fid;
  if v_cnt >= public._family_max_members() then
    return jsonb_build_object('ok', false, 'code', 'family_full', 'message', '对方家庭人数已满');
  end if;

  insert into public.family_members (family_id, user_id, role)
  values (v_fid, v_uid, 'member')
  on conflict (family_id, user_id) do nothing;

  update public.family_invites
     set status = 'accepted', responded_at = now()
   where id = v_inv.id;

  -- 双方其他还在 pending 的邀请一并作废，避免"同意一个又冒出好几个"
  update public.family_invites
     set status = 'canceled', responded_at = now()
   where status = 'pending'
     and id <> v_inv.id
     and (inviter_id in (v_inv.inviter_id, v_uid) or invitee_id in (v_inv.inviter_id, v_uid));

  return jsonb_build_object('ok', true, 'family', public._family_json(v_fid, v_uid));
exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'code', 'already_in_family',
                              'message', '你已经在其他家庭里了，请先退出');
end;
$$;

-- ------------------------------------------------------------
-- 4.4 处理邀请：拒绝
-- ------------------------------------------------------------
create or replace function public.family_reject(
  p_token     text,
  p_invite_id uuid
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

  update public.family_invites
     set status = 'rejected', responded_at = now()
   where id = p_invite_id and invitee_id = v_uid and status = 'pending';

  if not found then
    return jsonb_build_object('ok', false, 'code', 'invite_not_found', 'message', '邀请不存在或已处理');
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- 4.5 撤回自己发出的邀请
-- ------------------------------------------------------------
create or replace function public.family_cancel(
  p_token     text,
  p_invite_id uuid
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

  update public.family_invites
     set status = 'canceled', responded_at = now()
   where id = p_invite_id and inviter_id = v_uid and status = 'pending';

  if not found then
    return jsonb_build_object('ok', false, 'code', 'invite_not_found', 'message', '邀请不存在或已处理');
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- 4.6 家庭状态：家庭详情 + 收到/发出的待处理邀请
--     客户端进「我的家庭」页拉一次即可（也可轮询刷新红点）
-- ------------------------------------------------------------
create or replace function public.family_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid  uuid := public._session_user(p_token);
  v_fid  uuid;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'code', 'unauthorized', 'message', '登录已失效，请重新登录');
  end if;

  v_fid := public._my_family_id(v_uid);

  return jsonb_build_object(
    'ok', true,
    'hasFamily', (v_fid is not null),
    'family', case when v_fid is null then null else public._family_json(v_fid, v_uid) end,
    'incoming', coalesce((
      select jsonb_agg(jsonb_build_object(
               'inviteId',      i.id,
               'inviterId',     i.inviter_id,
               'nickname',      u.nickname,
               'username',      u.username,
               'familyName',    i.family_name,
               'hasFamily',     (i.family_id is not null),
               'createdAt',     i.created_at,
               'expiresAt',     i.expires_at
             ) order by i.created_at desc)
        from public.family_invites i
        join public.users u on u.id = i.inviter_id
       where i.invitee_id = v_uid
         and i.status = 'pending'
         and i.expires_at > now()
    ), '[]'::jsonb),
    'outgoing', coalesce((
      select jsonb_agg(jsonb_build_object(
               'inviteId',   i.id,
               'inviteeId',  i.invitee_id,
               'nickname',   u.nickname,
               'username',   u.username,
               'createdAt',  i.created_at,
               'expiresAt',  i.expires_at
             ) order by i.created_at desc)
        from public.family_invites i
        join public.users u on u.id = i.invitee_id
       where i.inviter_id = v_uid
         and i.status = 'pending'
         and i.expires_at > now()
    ), '[]'::jsonb)
  );
end;
$$;

-- ------------------------------------------------------------
-- 4.7 退出 / 解散家庭
--     房主退出 = 解散（成员一并清空）
--     成员退出 = 只删自己那行
-- ------------------------------------------------------------
create or replace function public.family_leave(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid  uuid := public._session_user(p_token);
  v_fid  uuid;
  v_role text;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'code', 'unauthorized', 'message', '登录已失效，请重新登录');
  end if;

  select family_id, role into v_fid, v_role
    from public.family_members where user_id = v_uid;

  if v_fid is null then
    return jsonb_build_object('ok', false, 'code', 'no_family', 'message', '你还没有加入家庭');
  end if;

  if v_role = 'owner' then
    update public.family_invites
       set status = 'canceled', responded_at = now()
     where status = 'pending' and family_id = v_fid;
    delete from public.families where id = v_fid;
    return jsonb_build_object('ok', true, 'dissolved', true, 'message', '家庭已解散');
  end if;

  delete from public.family_members where family_id = v_fid and user_id = v_uid;
  return jsonb_build_object('ok', true, 'dissolved', false, 'message', '已退出家庭');
end;
$$;

-- ============================================================
-- 5. 自检（执行完可以跑一下，返回 ok 即安装成功）
-- ============================================================
-- select public._family_max_members() as member_limit,
--        (select count(*) from public.families) as families,
--        (select count(*) from public.family_members) as members,
--        (select count(*) from public.family_invites) as invites;
