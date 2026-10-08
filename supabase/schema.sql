-- 맞수 · 1단계 스키마: 프로필(닉네임) + PvE 랭킹
-- Supabase 대시보드 → SQL Editor → New query 에 통째로 붙여넣고 Run 하세요. (여러 번 실행해도 안전합니다)

-- ───────── 테이블 ─────────
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  nickname    text not null,
  created_at  timestamptz not null default now(),
  constraint nickname_len check (char_length(nickname) between 2 and 12)
);
create unique index if not exists profiles_nickname_lower on public.profiles (lower(nickname));

create table if not exists public.pve_rank (
  user_id     uuid primary key references public.profiles(id) on delete cascade,
  rp          int  not null default 0 check (rp between 0 and 100000),
  n           int  not null default 0,
  best        int  not null default 0,
  recent      jsonb not null default '[]'::jsonb,
  updated_at  timestamptz not null default now()
);

-- ───────── 접근 규칙(RLS): 누구나 읽기, 쓰기는 아래 함수로만 ─────────
alter table public.profiles enable row level security;
alter table public.pve_rank enable row level security;

drop policy if exists "profiles are public" on public.profiles;
create policy "profiles are public" on public.profiles for select using (true);
drop policy if exists "pve_rank is public" on public.pve_rank;
create policy "pve_rank is public" on public.pve_rank for select using (true);

-- 직접 쓰기 금지(정책도 없음). 아래 security definer 함수만 값을 바꿀 수 있어요.
revoke insert, update, delete, truncate on public.profiles from anon, authenticated;
revoke insert, update, delete, truncate on public.pve_rank from anon, authenticated;

-- ───────── 가입하면 프로필·랭킹 행 자동 생성 ─────────
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, nickname)
  values (new.id, '플레이어' || substr(replace(new.id::text, '-', ''), 1, 6))
  on conflict (id) do nothing;
  insert into public.pve_rank (user_id) values (new.id) on conflict (user_id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- 이미 가입한 계정이 있으면 채워 넣기
insert into public.profiles (id, nickname)
  select u.id, '플레이어' || substr(replace(u.id::text, '-', ''), 1, 6) from auth.users u
  on conflict (id) do nothing;
insert into public.pve_rank (user_id) select id from public.profiles on conflict (user_id) do nothing;

-- ───────── 닉네임 변경 ─────────
create or replace function public.set_nickname(p_nick text)
returns text language plpgsql security definer set search_path = public as $$
declare n text := btrim(coalesce(p_nick, ''));
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if char_length(n) not between 2 and 12 or n !~ '^[0-9A-Za-z가-힣_ ]+$' then
    raise exception 'invalid_nickname';
  end if;
  begin
    update public.profiles set nickname = n where id = auth.uid();
  exception when unique_violation then
    raise exception 'nickname_taken';
  end;
  return n;
end $$;

-- ───────── 랭킹 도전 결과 제출: RP는 서버가 계산 ─────────
-- 5판 합계(p_total)만 받아서 RP 변화를 서버가 계산합니다. (공식은 앱과 동일)
--   기준 점수 = 150 + 0.5 × RP,  변화량 = round((합계 − 기준) / 5),  RP 최소 0
create or replace function public.submit_challenge(p_total int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r      public.pve_rank;
  delta  int;
  newrp  int;
  rec    jsonb;
  newrec jsonb;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if p_total is null or p_total < 0 or p_total > 800 then raise exception 'invalid_total'; end if;

  insert into public.pve_rank (user_id) values (auth.uid()) on conflict (user_id) do nothing;
  select * into r from public.pve_rank where user_id = auth.uid() for update;

  -- 5판은 아무리 빨라도 1분은 걸려요. 연속 제출 방지.
  if r.n > 0 and r.updated_at > now() - interval '60 seconds' then raise exception 'too_fast'; end if;

  delta := floor((p_total - (150 + 0.5 * r.rp)) / 5 + 0.5)::int;
  newrp := greatest(0, r.rp + delta);
  rec   := jsonb_build_object('t', p_total, 'd', newrp - r.rp, 'at', (extract(epoch from now()) * 1000)::bigint);
  select coalesce(jsonb_agg(x order by i), '[]'::jsonb) into newrec
    from (select x, i from jsonb_array_elements(jsonb_build_array(rec) || r.recent) with ordinality as t(x, i)
          order by i limit 10) s;

  update public.pve_rank
     set rp = newrp, n = n + 1, best = greatest(best, p_total), recent = newrec, updated_at = now()
   where user_id = auth.uid();

  return jsonb_build_object('rp_before', r.rp, 'rp_after', newrp, 'n', r.n + 1,
                            'best', greatest(r.best, p_total), 'recent', newrec);
end $$;

revoke all on function public.set_nickname(text) from public, anon;
revoke all on function public.submit_challenge(int) from public, anon;
grant execute on function public.set_nickname(text) to authenticated;
grant execute on function public.submit_challenge(int) to authenticated;
