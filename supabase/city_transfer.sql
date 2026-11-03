-- ============================================================
-- 城市碳普惠积分互通（App → 模拟城市平台）
-- 依赖：schema.sql 已执行（users / carbon_records / sessions / _session_user）
-- 作用：转出碳积分时在本地记账并扣减可用积分；平台调用失败可回滚
-- ============================================================

-- 一、转出流水表
create table if not exists public.city_transfers (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.users(id) on delete cascade,
  request_id  text not null,
  app_point   integer not null check (app_point > 0),
  city_point  integer not null default 0 check (city_point >= 0),
  city_no     text not null default '',
  created_at  timestamptz not null default now(),
  unique (user_id, request_id)
);

create index if not exists city_transfers_user_time_idx
  on public.city_transfers (user_id, created_at desc);

alter table public.city_transfers enable row level security;
revoke all on table public.city_transfers from anon, authenticated;

-- 二、转出：先在本账号扣分记账，再由客户端调用城市平台
create or replace function public.transfer_to_city(
  p_token      text,
  p_amount     integer,
  p_request_id text,
  p_city_no    text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := public._session_user(p_token);
  v_amount integer := coalesce(p_amount, 0);
  v_req    text := nullif(trim(coalesce(p_request_id, '')), '');
  v_earned bigint;
  v_spent  integer;
  v_avail  bigint;
  v_rec    public.city_transfers;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'code', 'unauthorized',
                              'message', '登录已失效，请重新登录');
  end if;

  if v_req is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_request',
                              'message', '缺少请求编号');
  end if;

  if v_amount <= 0 or v_amount % 10 <> 0 then
    return jsonb_build_object('ok', false, 'code', 'invalid_amount',
                              'message', '转出积分需为 10 的倍数',
                              'availablePoint', 0);
  end if;

  if v_amount > 100000 then
    return jsonb_build_object('ok', false, 'code', 'invalid_amount',
                              'message', '单次转出不能超过 100000 碳积分');
  end if;

  -- 幂等：同一请求号直接返回首次结果
  select * into v_rec
    from public.city_transfers
   where user_id = v_uid and request_id = v_req;

  if found then
    select coalesce(sum(point), 0) into v_earned
      from public.carbon_records where user_id = v_uid;
    select spent_point into v_spent from public.users where id = v_uid;
    return jsonb_build_object(
      'ok', true,
      'duplicated', true,
      'appPoint', v_rec.app_point,
      'cityPoint', v_rec.city_point,
      'spentPoint', v_spent,
      'availablePoint', v_earned - v_spent
    );
  end if;

  -- 锁定用户行，串行化同一账号的并发转出
  select spent_point into v_spent
    from public.users where id = v_uid
    for update;

  select coalesce(sum(point), 0) into v_earned
    from public.carbon_records where user_id = v_uid;

  v_avail := v_earned - v_spent;

  if v_avail < v_amount then
    return jsonb_build_object('ok', false, 'code', 'insufficient_point',
                              'message', '可用碳积分不足',
                              'availablePoint', v_avail);
  end if;

  insert into public.city_transfers (user_id, request_id, app_point, city_point, city_no)
  values (v_uid, v_req, v_amount, v_amount / 10, coalesce(p_city_no, ''));

  update public.users
     set spent_point = spent_point + v_amount
   where id = v_uid
  returning spent_point into v_spent;

  return jsonb_build_object(
    'ok', true,
    'duplicated', false,
    'appPoint', v_amount,
    'cityPoint', v_amount / 10,
    'spentPoint', v_spent,
    'availablePoint', v_earned - v_spent
  );
exception
  when unique_violation then
    select * into v_rec
      from public.city_transfers
     where user_id = v_uid and request_id = v_req;
    select coalesce(sum(point), 0) into v_earned
      from public.carbon_records where user_id = v_uid;
    select spent_point into v_spent from public.users where id = v_uid;
    return jsonb_build_object(
      'ok', true, 'duplicated', true,
      'appPoint', v_rec.app_point, 'cityPoint', v_rec.city_point,
      'spentPoint', v_spent, 'availablePoint', v_earned - v_spent
    );
  when others then
    return jsonb_build_object('ok', false, 'code', 'transfer_failed',
                              'message', '积分转出失败，请稍后重试');
end;
$$;

-- 三、回滚：城市平台调用失败时撤销对应流水并退回积分
create or replace function public.revert_city_transfer(
  p_token      text,
  p_request_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := public._session_user(p_token);
  v_req    text := nullif(trim(coalesce(p_request_id, '')), '');
  v_rec    public.city_transfers;
  v_spent  integer;
  v_earned bigint;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'code', 'unauthorized',
                              'message', '登录已失效，请重新登录');
  end if;

  if v_req is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_request',
                              'message', '缺少请求编号');
  end if;

  delete from public.city_transfers
   where user_id = v_uid and request_id = v_req
  returning * into v_rec;

  if not found then
    select spent_point into v_spent from public.users where id = v_uid;
    select coalesce(sum(point), 0) into v_earned
      from public.carbon_records where user_id = v_uid;
    return jsonb_build_object(
      'ok', true, 'duplicated', true, 'reverted', 0,
      'spentPoint', v_spent, 'availablePoint', v_earned - v_spent
    );
  end if;

  update public.users
     set spent_point = greatest(0, spent_point - v_rec.app_point)
   where id = v_uid
  returning spent_point into v_spent;

  select coalesce(sum(point), 0) into v_earned
    from public.carbon_records where user_id = v_uid;

  return jsonb_build_object(
    'ok', true, 'duplicated', false, 'reverted', v_rec.app_point,
    'spentPoint', v_spent, 'availablePoint', v_earned - v_spent
  );
exception
  when others then
    return jsonb_build_object('ok', false, 'code', 'revert_failed',
                              'message', '积分回滚失败，请稍后重试');
end;
$$;

-- 四、权限：只允许 anon 通过 RPC 访问，表本身对客户端完全关闭
revoke all on function public.transfer_to_city(text, integer, text, text)
  from public, anon, authenticated;
revoke all on function public.revert_city_transfer(text, text)
  from public, anon, authenticated;

grant execute on function public.transfer_to_city(text, integer, text, text)
  to anon, authenticated;
grant execute on function public.revert_city_transfer(text, text)
  to anon, authenticated;

notify pgrst, 'reload schema';
