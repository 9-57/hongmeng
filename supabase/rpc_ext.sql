-- ============================================================
-- 碳足迹 App · Supabase 增量 RPC（在 schema.sql 之后执行）
--
-- 新增三个 RPC，用于客户端把本地能力完整映射到云端：
--   revoke_claim      删除记录导致每日任务不再达标时，回滚该任务奖励
--   clear_records     清空当前账号的记录 / 领奖 / 徽章，并重置消费积分
--   replace_snapshot  用备份内容整体覆盖当前账号数据（恢复备份）
-- 与 schema.sql 保持一致：SECURITY DEFINER + 固定 search_path + 只授予 RPC。
-- ============================================================

-- 回滚一条每日任务领奖记录（服务端按该行 reward 反向调整 spent_point）
create or replace function public.revoke_claim(
  p_token      text,
  p_task_id    text,
  p_claim_date date
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := public._session_user(p_token);
  v_date   date := coalesce(p_claim_date, current_date);
  v_reward integer;
  v_spent  integer;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'code', 'unauthorized', 'message', '登录已失效，请重新登录');
  end if;

  delete from public.task_claims
   where user_id = v_uid
     and task_id = p_task_id
     and claim_date = v_date
  returning reward into v_reward;

  select spent_point into v_spent from public.users where id = v_uid;

  if v_reward is null then
    return jsonb_build_object('ok', true, 'revoked', false, 'spentPoint', v_spent);
  end if;

  update public.users
     set spent_point = spent_point + v_reward
   where id = v_uid
  returning spent_point into v_spent;

  return jsonb_build_object('ok', true, 'revoked', true, 'spentPoint', v_spent);
end;
$$;

-- 清空当前账号的业务数据（保留账号本身、昵称与月目标）
create or replace function public.clear_records(p_token text)
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

  delete from public.carbon_records where user_id = v_uid;
  delete from public.task_claims    where user_id = v_uid;
  delete from public.user_badges    where user_id = v_uid;

  update public.users set spent_point = 0 where id = v_uid;

  return jsonb_build_object('ok', true, 'spentPoint', 0);
end;
$$;

-- 用备份数据整体覆盖当前账号（records / claims / badges + 昵称月目标积分）
-- p_payload 结构：
-- {
--   "records": [ CarbonRecord... ],
--   "claims":  [ { "claimDate": "yyyy-MM-dd", "taskId": "t_walk", "reward": 8 } ],
--   "badges":  [ { "badgeId": "r_bamboo", "cost": 100 } ],
--   "nickname": "低碳同学",
--   "monthGoal": 30,
--   "spentPoint": 0
-- }
create or replace function public.replace_snapshot(
  p_token   text,
  p_payload jsonb
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

  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    return jsonb_build_object('ok', false, 'code', 'invalid_payload', 'message', '备份内容格式不正确');
  end if;

  delete from public.carbon_records where user_id = v_uid;
  delete from public.task_claims    where user_id = v_uid;
  delete from public.user_badges    where user_id = v_uid;

  insert into public.carbon_records (
    id, user_id, activity_id, activity_name, category_id, unit,
    qty, factor, reduction, point, record_date, record_time, note
  )
  select
    coalesce(nullif(e ->> 'id', ''), gen_random_uuid()::text),
    v_uid,
    coalesce(e ->> 'activityId', ''),
    coalesce(e ->> 'activityName', ''),
    coalesce(e ->> 'categoryId', ''),
    coalesce(e ->> 'unit', ''),
    coalesce((e ->> 'qty')::numeric, 0),
    coalesce((e ->> 'factor')::numeric, 0),
    coalesce((e ->> 'reduction')::numeric, 0),
    coalesce((e ->> 'point')::integer, 0),
    coalesce((e ->> 'date')::date, current_date),
    coalesce((e ->> 'time')::bigint, (extract(epoch from now()) * 1000)::bigint),
    coalesce(e ->> 'note', '')
  from jsonb_array_elements(
         case when jsonb_typeof(p_payload -> 'records') = 'array'
              then p_payload -> 'records' else '[]'::jsonb end
       ) e
  on conflict (user_id, id) do nothing;

  insert into public.task_claims (user_id, claim_date, task_id, reward)
  select
    v_uid,
    coalesce((c ->> 'claimDate')::date, current_date),
    coalesce(c ->> 'taskId', ''),
    greatest(coalesce((c ->> 'reward')::integer, 0), 0)
  from jsonb_array_elements(
         case when jsonb_typeof(p_payload -> 'claims') = 'array'
              then p_payload -> 'claims' else '[]'::jsonb end
       ) c
  on conflict (user_id, claim_date, task_id) do nothing;

  insert into public.user_badges (user_id, badge_id, kind, cost)
  select
    v_uid,
    coalesce(b ->> 'badgeId', ''),
    'redeem',
    greatest(coalesce((b ->> 'cost')::integer, 0), 0)
  from jsonb_array_elements(
         case when jsonb_typeof(p_payload -> 'badges') = 'array'
              then p_payload -> 'badges' else '[]'::jsonb end
       ) b
  on conflict (user_id, badge_id) do nothing;

  update public.users
     set nickname    = coalesce(nullif(trim(coalesce(p_payload ->> 'nickname', '')), ''), nickname),
         month_goal  = greatest(coalesce((p_payload ->> 'monthGoal')::numeric, month_goal), 0),
         spent_point = coalesce((p_payload ->> 'spentPoint')::integer, spent_point)
   where id = v_uid;

  select count(*) into v_count from public.carbon_records where user_id = v_uid;

  return jsonb_build_object('ok', true, 'records', v_count);
exception
  when others then
    return jsonb_build_object('ok', false, 'code', 'restore_failed', 'message', SQLERRM);
end;
$$;

grant execute on function public.revoke_claim(text, text, date)      to anon, authenticated;
grant execute on function public.clear_records(text)                 to anon, authenticated;
grant execute on function public.replace_snapshot(text, jsonb)       to anon, authenticated;

notify pgrst, 'reload schema';
