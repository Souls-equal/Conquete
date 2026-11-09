-- Conquête online MVP: Supabase Auth anonymous + private Realtime channels.
-- Run this complete script in Supabase > SQL Editor as project owner.
-- The game board is intentionally NOT stored here: the room creator's browser
-- currently acts as the game authority and only publishes each player's view.

create table if not exists public.conquete_rooms (
  code text primary key check (code ~ '^[A-HJ-NP-Z2-9]{10}$'),
  host_id uuid not null,
  status text not null default 'waiting' check (status in ('waiting', 'started')),
  created_at timestamptz not null default now()
);

create table if not exists public.conquete_members (
  room_code text not null references public.conquete_rooms(code) on delete cascade,
  player_id uuid not null,
  user_id uuid not null,
  player_index smallint not null check (player_index between 0 and 7),
  player_name text not null check (char_length(player_name) between 1 and 24),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (room_code, player_id),
  unique (room_code, user_id)
);

-- A departed lobby seat can be reused while the old membership stays inactive.
alter table public.conquete_members drop constraint if exists conquete_members_room_code_player_index_key;
create unique index if not exists conquete_members_active_seat_key
  on public.conquete_members(room_code, player_index) where active;
create index if not exists conquete_members_active_user_key
  on public.conquete_members(user_id, room_code) where active;

alter table public.conquete_rooms enable row level security;
alter table public.conquete_members enable row level security;
revoke all on public.conquete_rooms from anon, authenticated;
revoke all on public.conquete_members from anon, authenticated;

-- These SECURITY DEFINER helpers are used by Realtime RLS policies. Their
-- owner is the database role that runs this SQL (normally postgres), so the
-- membership lookups do not recursively invoke the table policies.
create or replace function public.conquete_topic_can_read(p_topic text)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.conquete_members m
    where m.user_id = auth.uid()
      and m.active
      and p_topic in (
        'cq_' || m.room_code || '_lobby',
        'cq_' || m.room_code || '_join'
      )
  )
  or exists (
    select 1
    from public.conquete_members m
    join public.conquete_rooms r on r.code = m.room_code
    where m.active
      and (m.user_id = auth.uid() or r.host_id = auth.uid())
      and (
        p_topic = 'cq_' || m.room_code || '_view_' || m.player_id::text
        or p_topic = 'cq_' || m.room_code || '_cmd_' || m.player_id::text
      )
  );
$$;

create or replace function public.conquete_topic_can_send(p_topic text)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.conquete_members m
    join public.conquete_rooms r on r.code = m.room_code
    where m.user_id = auth.uid()
      and m.active
      and r.host_id = auth.uid()
      and p_topic = 'cq_' || m.room_code || '_lobby'
  )
  or exists (
    select 1
    from public.conquete_members m
    where m.user_id = auth.uid()
      and m.active
      and p_topic = 'cq_' || m.room_code || '_join'
  )
  or exists (
    select 1
    from public.conquete_members m
    where m.user_id = auth.uid()
      and m.active
      and p_topic = 'cq_' || m.room_code || '_cmd_' || m.player_id::text
  )
  or exists (
    select 1
    from public.conquete_members m
    join public.conquete_rooms r on r.code = m.room_code
    where r.host_id = auth.uid()
      and m.active
      and p_topic = 'cq_' || m.room_code || '_view_' || m.player_id::text
  );
$$;

create or replace function public.conquete_create_room(
  p_code text,
  p_player_id uuid,
  p_player_name text
)
returns smallint
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'Connexion Supabase requise.'; end if;
  if p_code !~ '^[A-HJ-NP-Z2-9]{10}$' then raise exception 'Code de salle invalide.'; end if;
  if nullif(trim(p_player_name), '') is null then raise exception 'Pseudo requis.'; end if;

  insert into public.conquete_rooms(code, host_id, status)
  values (p_code, auth.uid(), 'waiting');
  insert into public.conquete_members(room_code, player_id, user_id, player_index, player_name)
  values (p_code, p_player_id, auth.uid(), 0, left(trim(p_player_name), 24));
  return 0;
end;
$$;

create or replace function public.conquete_join_room(
  p_code text,
  p_player_id uuid,
  p_player_name text
)
returns smallint
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_status text;
  v_index smallint;
  v_existing record;
begin
  if auth.uid() is null then raise exception 'Connexion Supabase requise.'; end if;
  if nullif(trim(p_player_name), '') is null then raise exception 'Pseudo requis.'; end if;

  select status into v_status
  from public.conquete_rooms
  where code = p_code
  for update;
  if not found then raise exception 'Salle introuvable.'; end if;

  select player_id, player_index into v_existing
  from public.conquete_members
  where room_code = p_code and user_id = auth.uid();
  if found then
    if v_existing.player_id <> p_player_id then
      raise exception 'Ce navigateur occupe déjà une place dans cette salle.';
    end if;
    if exists (
      select 1 from public.conquete_members m
      where m.room_code = p_code and m.player_index = v_existing.player_index
        and m.active and m.player_id <> p_player_id
    ) then
      if v_status <> 'waiting' then
        raise exception 'Cette place a été reprise ; demande un nouveau code à l’hôte.';
      end if;
      select seat::smallint into v_index
      from generate_series(1, 7) as seats(seat)
      where not exists (
        select 1 from public.conquete_members m
        where m.room_code = p_code and m.player_index = seats.seat and m.active
      )
      order by seat
      limit 1;
      if v_index is null then raise exception 'La salle est complète (8 joueurs maximum).'; end if;
      update public.conquete_members
        set active = true, player_index = v_index, player_name = left(trim(p_player_name), 24)
        where room_code = p_code and player_id = p_player_id;
      return v_index;
    end if;
    update public.conquete_members
      set active = true, player_name = left(trim(p_player_name), 24)
      where room_code = p_code and player_id = p_player_id;
    return v_existing.player_index;
  end if;

  if v_status <> 'waiting' then raise exception 'La partie a déjà commencé.'; end if;

  select seat::smallint into v_index
  from generate_series(1, 7) as seats(seat)
  where not exists (
    select 1 from public.conquete_members m
    where m.room_code = p_code and m.player_index = seats.seat and m.active
  )
  order by seat
  limit 1;
  if v_index is null then raise exception 'La salle est complète (8 joueurs maximum).'; end if;

  insert into public.conquete_members(room_code, player_id, user_id, player_index, player_name)
  values (p_code, p_player_id, auth.uid(), v_index, left(trim(p_player_name), 24));
  return v_index;
end;
$$;

create or replace function public.conquete_list_members(p_code text)
returns jsonb
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_members jsonb;
begin
  if not exists (
    select 1 from public.conquete_members m
    where m.room_code = p_code and m.user_id = auth.uid() and m.active
  ) then raise exception 'Tu ne fais pas partie de cette salle.'; end if;

  select coalesce(
    jsonb_agg(jsonb_build_object(
      'player_id', player_id,
      'player_index', player_index,
      'player_name', player_name
    ) order by player_index),
    '[]'::jsonb
  ) into v_members
  from public.conquete_members
  where room_code = p_code and active;
  return v_members;
end;
$$;

create or replace function public.conquete_start_room(p_code text)
returns boolean
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_host uuid;
  v_count integer;
begin
  select host_id into v_host
  from public.conquete_rooms
  where code = p_code and status = 'waiting'
  for update;
  if not found then raise exception 'Salle introuvable ou déjà lancée.'; end if;
  if v_host <> auth.uid() then raise exception 'Seul l’hôte peut lancer la partie.'; end if;
  select count(*) into v_count from public.conquete_members where room_code = p_code and active;
  if v_count < 2 then raise exception 'Il faut au moins deux joueurs.'; end if;
  update public.conquete_rooms set status = 'started' where code = p_code;
  return true;
end;
$$;

create or replace function public.conquete_leave_room(p_code text)
returns boolean
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_host uuid;
  v_status text;
  v_index smallint;
  v_member record;
begin
  select host_id, status into v_host, v_status
  from public.conquete_rooms where code = p_code
  for update;
  if not found then return false; end if;
  if v_host = auth.uid() then
    delete from public.conquete_rooms where code = p_code;
    return true;
  end if;

  select player_index into v_index
  from public.conquete_members
  where room_code = p_code and user_id = auth.uid() and active;
  if not found then return false; end if;
  update public.conquete_members
    set active = false
    where room_code = p_code and user_id = auth.uid() and active;

  -- Keep seat indexes dense while the lobby is still open. During a live game,
  -- seat indexes remain fixed so a disconnected player can rejoin that seat.
  if v_status = 'waiting' then
    -- Shift seats from low to high so each destination is free before it is used.
    for v_member in
      select player_id, player_index
      from public.conquete_members
      where room_code = p_code and active and player_index > v_index
      order by player_index
    loop
      update public.conquete_members
        set player_index = v_member.player_index - 1
        where room_code = p_code and player_id = v_member.player_id;
    end loop;
  end if;
  return true;
end;
$$;

revoke all on function public.conquete_topic_can_read(text) from public;
revoke all on function public.conquete_topic_can_send(text) from public;
revoke all on function public.conquete_create_room(text, uuid, text) from public;
revoke all on function public.conquete_join_room(text, uuid, text) from public;
revoke all on function public.conquete_list_members(text) from public;
revoke all on function public.conquete_start_room(text) from public;
revoke all on function public.conquete_leave_room(text) from public;
grant execute on function public.conquete_topic_can_read(text) to authenticated;
grant execute on function public.conquete_topic_can_send(text) to authenticated;
grant execute on function public.conquete_create_room(text, uuid, text) to authenticated;
grant execute on function public.conquete_join_room(text, uuid, text) to authenticated;
grant execute on function public.conquete_list_members(text) to authenticated;
grant execute on function public.conquete_start_room(text) to authenticated;
grant execute on function public.conquete_leave_room(text) to authenticated;

-- Supabase Realtime private-channel authorization.
drop policy if exists "Conquête: members read authorized private channels" on realtime.messages;
create policy "Conquête: members read authorized private channels"
on realtime.messages for select to authenticated
using (public.conquete_topic_can_read(realtime.topic()));

drop policy if exists "Conquête: authorized private-channel broadcasts" on realtime.messages;
create policy "Conquête: authorized private-channel broadcasts"
on realtime.messages for insert to authenticated
with check (public.conquete_topic_can_send(realtime.topic()));
