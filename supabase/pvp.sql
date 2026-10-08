-- 맞수 · 2단계 스키마: 랭크 대전(PvP) — 매칭, 서버 판정, MMR
-- 먼저 schema.sql 을 실행한 뒤, 이 파일 전체를 SQL Editor 에 붙여넣고 Run 하세요. (여러 번 실행해도 안전합니다)
--
-- 구조 요약
--  · 모든 테이블은 접근 규칙(RLS)으로 잠겨 있고, 앱은 아래 함수(RPC)로만 접근해요.
--  · 서버가 판(속성 배치·보상 순서)을 만들고, 두 사람이 낸 카드는 둘 다 낼 때까지 서버에만 있어요.
--  · 둘 다 내면 서버가 판정해서 결과를 두 사람에게 동시에 보여줘요.
--  · 시간 초과/이탈/기권 처리와 MMR(Elo) 계산도 서버가 해요.

-- ───────── 전적(MMR) ─────────
create table if not exists public.pvp_stats (
  user_id    uuid primary key references public.profiles(id) on delete cascade,
  mmr        int  not null default 1000 check (mmr >= 0),
  games      int  not null default 0,
  wins       int  not null default 0,
  losses     int  not null default 0,
  draws      int  not null default 0,
  updated_at timestamptz not null default now()
);
alter table public.pvp_stats enable row level security;
drop policy if exists "pvp_stats is public" on public.pvp_stats;
create policy "pvp_stats is public" on public.pvp_stats for select using (true);
revoke insert, update, delete, truncate on public.pvp_stats from anon, authenticated;

insert into public.pvp_stats (user_id) select id from public.profiles on conflict (user_id) do nothing;

-- 새 계정이 생길 때 PvP 전적 행도 같이 만들기 (schema.sql 의 함수를 확장)
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, nickname)
  values (new.id, '플레이어' || substr(replace(new.id::text, '-', ''), 1, 6))
  on conflict (id) do nothing;
  insert into public.pve_rank  (user_id) values (new.id) on conflict (user_id) do nothing;
  insert into public.pvp_stats (user_id) values (new.id) on conflict (user_id) do nothing;
  return new;
end $$;

-- ───────── 대기열 / 판 / 수 / 라운드 기록 (직접 접근 불가) ─────────
create table if not exists public.pvp_queue (
  user_id   uuid primary key references public.profiles(id) on delete cascade,
  mmr       int  not null,
  joined_at timestamptz not null default now(),
  seen_at   timestamptz not null default now(),
  match_id  uuid
);

create table if not exists public.pvp_matches (
  id         uuid primary key default gen_random_uuid(),
  p1         uuid not null references public.profiles(id),
  p2         uuid not null references public.profiles(id),
  els        int[] not null,                       -- 카드 번호(1~9) → 속성(0불 1풀 2물)
  prizes     int[] not null,                       -- 라운드별 보상(서버만 알고, 라운드마다 공개)
  round      int  not null default 0,              -- 진행 중인 라운드(0부터)
  carry      int  not null default 0,
  hand1      int[] not null default '{1,2,3,4,5,6,7,8,9}',
  hand2      int[] not null default '{1,2,3,4,5,6,7,8,9}',
  sk1        text[] not null default '{double,ward,recall}',   -- 아직 안 쓴 스킬
  sk2        text[] not null default '{double,ward,recall}',
  score1     int not null default 0,
  score2     int not null default 0,
  wins1      int not null default 0,
  wins2      int not null default 0,
  miss1      int not null default 0,               -- 연속 시간 초과 횟수
  miss2      int not null default 0,
  status     text not null default 'active' check (status in ('active', 'done')),
  winner     smallint,                             -- 1, 2, 0(무승부)
  reason     text,                                 -- normal / forfeit / timeout / abandoned
  deadline   timestamptz not null,
  mmr1_before int, mmr2_before int, mmr1_after int, mmr2_after int,
  created_at  timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists pvp_matches_p1_active on public.pvp_matches (p1) where status = 'active';
create index if not exists pvp_matches_p2_active on public.pvp_matches (p2) where status = 'active';

create table if not exists public.pvp_moves (
  match_id uuid not null references public.pvp_matches(id) on delete cascade,
  round    int  not null,
  seat     smallint not null check (seat in (1, 2)),
  card     int  not null check (card between 1 and 9),
  skill    text check (skill in ('double', 'ward', 'recall')),
  auto     boolean not null default false,
  primary key (match_id, round, seat)
);

create table if not exists public.pvp_rounds (
  match_id uuid not null references public.pvp_matches(id) on delete cascade,
  round    int  not null,
  c1 int not null, c2 int not null, s1 text, s2 text,
  stake int not null, winner smallint not null,
  primary key (match_id, round)
);

alter table public.pvp_queue   enable row level security;
alter table public.pvp_matches enable row level security;
alter table public.pvp_moves   enable row level security;
alter table public.pvp_rounds  enable row level security;
revoke all on public.pvp_queue, public.pvp_matches, public.pvp_moves, public.pvp_rounds from anon, authenticated;

-- ───────── 내부 함수 ─────────
-- 대기 시간이 길수록 MMR 차이 허용 범위를 넓혀요: 100 → 140 → 180 … (최대 800)
create or replace function public.pvp_window(p_wait numeric)
returns int language sql immutable as $$ select least(800, 100 + 40 * floor(greatest(p_wait, 0)))::int $$;

-- 판 종료 + (랭크전이면) MMR 갱신. 1~10판은 변동 폭 48, 이후 32.
create or replace function public.pvp_finish(p_id uuid, p_winner smallint, p_reason text, p_rated boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  m pvp_matches; s1 pvp_stats; s2 pvp_stats;
  e1 numeric; sc1 numeric; k1 int; k2 int; d1 int := 0; d2 int := 0;
begin
  select * into m from pvp_matches where id = p_id for update;
  if m.status = 'done' then return; end if;
  if p_rated then
    select * into s1 from pvp_stats where user_id = m.p1 for update;
    select * into s2 from pvp_stats where user_id = m.p2 for update;
    e1  := 1 / (1 + power(10, (s2.mmr - s1.mmr) / 400.0));
    sc1 := case p_winner when 1 then 1 when 2 then 0 else 0.5 end;
    k1  := case when s1.games < 10 then 48 else 32 end;
    k2  := case when s2.games < 10 then 48 else 32 end;
    d1  := round(k1 * (sc1 - e1));
    d2  := round(k2 * ((1 - sc1) - (1 - e1)));
    update pvp_stats set mmr = greatest(0, mmr + d1), games = games + 1,
           wins = wins + (p_winner = 1)::int, losses = losses + (p_winner = 2)::int, draws = draws + (p_winner = 0)::int,
           updated_at = now() where user_id = m.p1;
    update pvp_stats set mmr = greatest(0, mmr + d2), games = games + 1,
           wins = wins + (p_winner = 2)::int, losses = losses + (p_winner = 1)::int, draws = draws + (p_winner = 0)::int,
           updated_at = now() where user_id = m.p2;
    update pvp_matches set mmr1_before = s1.mmr, mmr2_before = s2.mmr,
           mmr1_after = greatest(0, s1.mmr + d1), mmr2_after = greatest(0, s2.mmr + d2) where id = p_id;
  end if;
  update pvp_matches set status = 'done', winner = p_winner, reason = p_reason, finished_at = now() where id = p_id;
end $$;

-- 두 사람의 수가 모두 있으면 한 라운드를 판정해서 반영. (앱의 resolveRound/commitRound 와 같은 규칙)
create or replace function public.pvp_play_round(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  m pvp_matches; a pvp_moves; b pvp_moves;
  ea int; eb int; adva boolean; advb boolean; wa boolean; wb boolean;
  bona int; bonb int; va int; vb int; dbl int; base int; stake int; win smallint;
  rec1 boolean; rec2 boolean; res smallint;
begin
  select * into m from pvp_matches where id = p_id for update;
  if m.status <> 'active' then return; end if;
  select * into a from pvp_moves where match_id = p_id and round = m.round and seat = 1;
  select * into b from pvp_moves where match_id = p_id and round = m.round and seat = 2;
  if a.match_id is null or b.match_id is null then return; end if;

  ea := m.els[a.card]; eb := m.els[b.card];
  adva := ((ea + 1) % 3 = eb); advb := ((eb + 1) % 3 = ea);
  wa := coalesce(a.skill = 'ward', false); wb := coalesce(b.skill = 'ward', false);
  bona := case when adva and not wb then 3 else 0 end;
  bonb := case when advb and not wa then 3 else 0 end;
  va := a.card + bona; vb := b.card + bonb;
  dbl := coalesce((a.skill = 'double')::int, 0) + coalesce((b.skill = 'double')::int, 0);
  base := m.prizes[m.round + 1] + m.carry;
  stake := base * (1 + dbl);
  win := case when va > vb then 1 when vb > va then 2 else 0 end;
  rec1 := coalesce(a.skill = 'recall', false) and win = 2;   -- 회수: 지면 카드를 돌려받음
  rec2 := coalesce(b.skill = 'recall', false) and win = 1;

  if not rec1 then m.hand1 := array_remove(m.hand1, a.card); end if;
  if not rec2 then m.hand2 := array_remove(m.hand2, b.card); end if;
  if a.skill is not null then m.sk1 := array_remove(m.sk1, a.skill); end if;
  if b.skill is not null then m.sk2 := array_remove(m.sk2, b.skill); end if;
  if win = 1 then m.score1 := m.score1 + stake; m.wins1 := m.wins1 + 1; m.carry := 0;
  elsif win = 2 then m.score2 := m.score2 + stake; m.wins2 := m.wins2 + 1; m.carry := 0;
  else m.carry := stake; end if;

  insert into pvp_rounds (match_id, round, c1, c2, s1, s2, stake, winner)
  values (p_id, m.round, a.card, b.card, a.skill, b.skill, stake, win);

  update pvp_matches set hand1 = m.hand1, hand2 = m.hand2, sk1 = m.sk1, sk2 = m.sk2,
         score1 = m.score1, score2 = m.score2, wins1 = m.wins1, wins2 = m.wins2, carry = m.carry,
         round = m.round + 1, deadline = now() + interval '30 seconds'
   where id = p_id;

  if m.round + 1 >= 9 then
    res := case when m.score1 > m.score2 then 1 when m.score2 > m.score1 then 2
                when m.wins1 > m.wins2 then 1 when m.wins2 > m.wins1 then 2 else 0 end;
    perform pvp_finish(p_id, res, 'normal', true);
  end if;
end $$;

-- 시간 초과 처리: 못 낸 사람은 무작위 카드가 자동으로 나가요. 연속 2번이면 기권패, 둘 다면 무효.
create or replace function public.pvp_advance(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m pvp_matches; has1 boolean; has2 boolean; c int;
begin
  select * into m from pvp_matches where id = p_id for update;
  if m.id is null or m.status <> 'active' or now() <= m.deadline then return; end if;
  if now() > m.deadline + interval '90 seconds' then
    perform pvp_finish(p_id, 0::smallint, 'abandoned', false); return;
  end if;
  select exists(select 1 from pvp_moves where match_id = p_id and round = m.round and seat = 1) into has1;
  select exists(select 1 from pvp_moves where match_id = p_id and round = m.round and seat = 2) into has2;
  if not has1 then
    c := m.hand1[1 + floor(random() * array_length(m.hand1, 1))::int];
    insert into pvp_moves (match_id, round, seat, card, skill, auto) values (p_id, m.round, 1, c, null, true);
    m.miss1 := m.miss1 + 1;
  end if;
  if not has2 then
    c := m.hand2[1 + floor(random() * array_length(m.hand2, 1))::int];
    insert into pvp_moves (match_id, round, seat, card, skill, auto) values (p_id, m.round, 2, c, null, true);
    m.miss2 := m.miss2 + 1;
  end if;
  update pvp_matches set miss1 = m.miss1, miss2 = m.miss2 where id = p_id;
  if m.miss1 >= 2 and m.miss2 >= 2 then perform pvp_finish(p_id, 0::smallint, 'abandoned', false);
  elsif m.miss1 >= 2 then perform pvp_finish(p_id, 2::smallint, 'timeout', true);
  elsif m.miss2 >= 2 then perform pvp_finish(p_id, 1::smallint, 'timeout', true);
  else perform pvp_play_round(p_id); end if;
end $$;

-- 호출한 사람 기준의 판 상태. 상대가 낸 카드는 라운드가 끝나기 전에는 절대 포함되지 않아요.
create or replace function public.pvp_build_state(p_id uuid, p_uid uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  m pvp_matches; v_seat int; opp uuid; me_s pvp_stats; op_s pvp_stats; opnick text;
  mh int[]; oh int[]; msk text[]; osk text[]; ms int; os int; mw int; ow int;
  lg jsonb; sub boolean; osub boolean; res text := null; before_ int; after_ int; known int[];
begin
  select * into m from pvp_matches where id = p_id;
  if m.id is null or (m.p1 <> p_uid and m.p2 <> p_uid) then raise exception 'not_found'; end if;
  v_seat := case when m.p1 = p_uid then 1 else 2 end;
  opp  := case when v_seat = 1 then m.p2 else m.p1 end;
  mh := case when v_seat = 1 then m.hand1 else m.hand2 end;  oh := case when v_seat = 1 then m.hand2 else m.hand1 end;
  msk := case when v_seat = 1 then m.sk1 else m.sk2 end;     osk := case when v_seat = 1 then m.sk2 else m.sk1 end;
  ms := case when v_seat = 1 then m.score1 else m.score2 end; os := case when v_seat = 1 then m.score2 else m.score1 end;
  mw := case when v_seat = 1 then m.wins1 else m.wins2 end;   ow := case when v_seat = 1 then m.wins2 else m.wins1 end;
  select nickname into opnick from profiles where id = opp;
  select * into me_s from pvp_stats where user_id = p_uid;
  select * into op_s from pvp_stats where user_id = opp;
  select coalesce(jsonb_agg(jsonb_build_object(
      'round', r.round,
      'cards',  case when v_seat = 1 then jsonb_build_array(r.c1, r.c2) else jsonb_build_array(r.c2, r.c1) end,
      'skills', case when v_seat = 1 then jsonb_build_array(r.s1, r.s2) else jsonb_build_array(r.s2, r.s1) end
    ) order by r.round), '[]'::jsonb) into lg from pvp_rounds r where r.match_id = p_id;
  select exists(select 1 from pvp_moves where match_id = p_id and round = m.round and seat = v_seat) into sub;
  select exists(select 1 from pvp_moves where match_id = p_id and round = m.round and seat = 3 - v_seat) into osub;
  known := m.prizes[1:least(m.round + 1, 9)];       -- 지나간 라운드 + 지금 라운드 보상까지만 공개
  if m.status = 'done' then
    res := case when m.winner = 0 then 'draw' when m.winner = v_seat then 'me' else 'opp' end;
    before_ := case when v_seat = 1 then m.mmr1_before else m.mmr2_before end;
    after_  := case when v_seat = 1 then m.mmr1_after  else m.mmr2_after  end;
  end if;
  return jsonb_build_object(
    'id', m.id, 'seat', v_seat, 'status', m.status, 'round', m.round, 'carry', m.carry,
    'els', to_jsonb(m.els), 'prizes', to_jsonb(known),
    'my_hand', to_jsonb(mh), 'opp_hand', to_jsonb(oh),
    'my_skills', to_jsonb(msk), 'opp_skills', to_jsonb(osk),
    'score', jsonb_build_array(ms, os), 'wins', jsonb_build_array(mw, ow),
    'submitted', sub, 'opp_submitted', osub,
    'deadline_in', greatest(0, ceil(extract(epoch from (m.deadline - now()))))::int,
    'log', lg,
    'opp', jsonb_build_object('nick', coalesce(opnick, '플레이어'), 'mmr', op_s.mmr, 'games', op_s.games),
    'me', jsonb_build_object('mmr', me_s.mmr, 'games', me_s.games),
    'result', res, 'reason', m.reason,
    'mmr_before', before_, 'mmr_after', after_);
end $$;

-- ───────── 앱이 부르는 함수(RPC) ─────────
-- 매칭: 1~2초마다 호출. 상대를 찾으면 matched, 아니면 waiting.
create or replace function public.pvp_queue_tick()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); my pvp_queue; cand pvp_queue; st pvp_stats; mid uuid; act uuid;
  wait_s numeric; seat_swap boolean; els_ int[]; pr int[]; waiting int; a uuid; b uuid;
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  -- 진행 중인 판이 있으면 그 판으로 복귀
  select id into act from pvp_matches where status = 'active' and (p1 = uid or p2 = uid) limit 1;
  if act is not null then
    perform pvp_advance(act);
    if exists (select 1 from pvp_matches where id = act and status = 'active') then
      delete from pvp_queue where user_id = uid;
      return jsonb_build_object('status', 'matched', 'match_id', act);
    end if;
  end if;
  delete from pvp_queue where user_id = uid and match_id is not null
    and not exists (select 1 from pvp_matches pm where pm.id = pvp_queue.match_id and pm.status = 'active');
  insert into pvp_stats (user_id) values (uid) on conflict (user_id) do nothing;
  select * into st from pvp_stats where user_id = uid;
  insert into pvp_queue (user_id, mmr) values (uid, st.mmr)
    on conflict (user_id) do update set seen_at = now(), mmr = excluded.mmr;
  select * into my from pvp_queue where user_id = uid for update;
  if my.match_id is not null then       -- 상대가 먼저 짝을 지어 줬어요
    delete from pvp_queue where user_id = uid;
    return jsonb_build_object('status', 'matched', 'match_id', my.match_id);
  end if;
  wait_s := extract(epoch from (now() - my.joined_at));
  select q.* into cand from pvp_queue q
   where q.user_id <> uid and q.match_id is null and q.seen_at > now() - interval '6 seconds'
     and abs(q.mmr - my.mmr) <= greatest(pvp_window(wait_s), pvp_window(extract(epoch from (now() - q.joined_at))))
   order by abs(q.mmr - my.mmr), q.joined_at
   limit 1 for update skip locked;
  if cand.user_id is not null then
    els_ := (select array_agg(x order by random()) from unnest(array[0,0,0,1,1,1,2,2,2]) x);
    pr   := (select array_agg(x order by random()) from unnest(array[1,1,2,2,3,3,4,4,5]) x);
    seat_swap := random() < 0.5;
    a := case when seat_swap then cand.user_id else uid end;
    b := case when seat_swap then uid else cand.user_id end;
    insert into pvp_matches (p1, p2, els, prizes, deadline)
    values (a, b, els_, pr, now() + interval '45 seconds') returning id into mid;
    update pvp_queue set match_id = mid where user_id = cand.user_id;
    delete from pvp_queue where user_id = uid;
    return jsonb_build_object('status', 'matched', 'match_id', mid);
  end if;
  select count(*) into waiting from pvp_queue where user_id <> uid and match_id is null and seen_at > now() - interval '6 seconds';
  return jsonb_build_object('status', 'waiting', 'waited', floor(wait_s)::int,
                            'window', pvp_window(wait_s), 'mmr', my.mmr, 'others', waiting);
end $$;

create or replace function public.pvp_queue_cancel()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  delete from pvp_queue where user_id = auth.uid() and match_id is null;
end $$;

create or replace function public.pvp_state(p_match uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  if not exists (select 1 from pvp_matches where id = p_match and (p1 = uid or p2 = uid)) then raise exception 'not_found'; end if;
  perform pvp_advance(p_match);
  return pvp_build_state(p_match, uid);
end $$;

create or replace function public.pvp_submit(p_match uuid, p_round int, p_card int, p_skill text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); m pvp_matches; v_seat int; mh int[]; msk text[];
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  select * into m from pvp_matches where id = p_match for update;
  if m.id is null or (m.p1 <> uid and m.p2 <> uid) then raise exception 'not_found'; end if;
  perform pvp_advance(p_match);
  select * into m from pvp_matches where id = p_match;
  -- 이미 끝났거나, 그 사이 라운드가 넘어갔으면(시간 초과) 내 수는 받지 않고 현재 상태만 돌려줘요
  if m.status <> 'active' or m.round <> p_round then return pvp_build_state(p_match, uid); end if;
  v_seat := case when m.p1 = uid then 1 else 2 end;
  mh  := case when v_seat = 1 then m.hand1 else m.hand2 end;
  msk := case when v_seat = 1 then m.sk1 else m.sk2 end;
  if p_skill = '' then p_skill := null; end if;
  if p_card is null or not (p_card = any(mh)) then raise exception 'invalid_card'; end if;
  if p_skill is not null and not (p_skill = any(msk)) then raise exception 'invalid_skill'; end if;
  if exists (select 1 from pvp_moves pmv where pmv.match_id = p_match and pmv.round = p_round and pmv.seat = v_seat) then
    return pvp_build_state(p_match, uid);        -- 이미 냈어요(중복 호출은 무시)
  end if;
  insert into pvp_moves (match_id, round, seat, card, skill) values (p_match, p_round, v_seat, p_card, p_skill);
  if v_seat = 1 then update pvp_matches set miss1 = 0 where id = p_match;
  else update pvp_matches set miss2 = 0 where id = p_match; end if;
  perform pvp_play_round(p_match);
  return pvp_build_state(p_match, uid);
end $$;

create or replace function public.pvp_forfeit(p_match uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); m pvp_matches;
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  select * into m from pvp_matches where id = p_match for update;
  if m.id is null or (m.p1 <> uid and m.p2 <> uid) then raise exception 'not_found'; end if;
  if m.status = 'active' then
    perform pvp_finish(p_match, case when m.p1 = uid then 2 else 1 end::smallint, 'forfeit', true);
  end if;
  return pvp_build_state(p_match, uid);
end $$;

-- 앱을 다시 켰을 때 진행 중인 판으로 돌아가기(대기열에는 넣지 않아요)
create or replace function public.pvp_current()
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); act uuid;
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  select id into act from pvp_matches where status = 'active' and (p1 = uid or p2 = uid) limit 1;
  if act is null then return null; end if;
  perform pvp_advance(act);
  if exists (select 1 from pvp_matches where id = act and status = 'active') then return act; end if;
  return null;
end $$;

-- ───────── 권한: 앱(로그인한 사용자)은 아래 함수만 호출 가능 ─────────
revoke all on function public.pvp_window(numeric) from public, anon, authenticated;
revoke all on function public.pvp_finish(uuid, smallint, text, boolean) from public, anon, authenticated;
revoke all on function public.pvp_play_round(uuid) from public, anon, authenticated;
revoke all on function public.pvp_advance(uuid) from public, anon, authenticated;
revoke all on function public.pvp_build_state(uuid, uuid) from public, anon, authenticated;
revoke all on function public.pvp_queue_tick() from public, anon;
revoke all on function public.pvp_queue_cancel() from public, anon;
revoke all on function public.pvp_state(uuid) from public, anon;
revoke all on function public.pvp_submit(uuid, int, int, text) from public, anon;
revoke all on function public.pvp_forfeit(uuid) from public, anon;
revoke all on function public.pvp_current() from public, anon;
grant execute on function public.pvp_queue_tick() to authenticated;
grant execute on function public.pvp_queue_cancel() to authenticated;
grant execute on function public.pvp_state(uuid) to authenticated;
grant execute on function public.pvp_submit(uuid, int, int, text) to authenticated;
grant execute on function public.pvp_forfeit(uuid) to authenticated;
grant execute on function public.pvp_current() to authenticated;
