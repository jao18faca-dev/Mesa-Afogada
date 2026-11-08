-- Maré Baixa · banco de dados
-- Cole tudo no SQL Editor do Supabase e clique em Run. Pode rodar de novo sem medo.

-- ------------------------------------------------------------ tabelas
create table if not exists public.perfis (
  id uuid primary key references auth.users on delete cascade,
  nome text not null,
  criado timestamptz not null default now()
);

create table if not exists public.mesas (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  mestre uuid not null default auth.uid() references auth.users on delete cascade,
  codigo text not null unique default upper(substr(md5(random()::text), 1, 6)),
  criado timestamptz not null default now()
);

create table if not exists public.membros (
  mesa_id uuid not null references public.mesas on delete cascade,
  user_id uuid not null references auth.users on delete cascade,
  entrou timestamptz not null default now(),
  primary key (mesa_id, user_id)
);

create table if not exists public.fichas (
  id uuid primary key default gen_random_uuid(),
  dono uuid not null default auth.uid() references auth.users on delete cascade,
  mesa_id uuid references public.mesas on delete set null,
  nome text not null default '',
  dados jsonb not null default '{}'::jsonb,
  atualizado timestamptz not null default now()
);

create table if not exists public.itens (
  id uuid primary key default gen_random_uuid(),
  mesa_id uuid not null references public.mesas on delete cascade,
  nome text not null,
  tipo text not null default 'item',
  espacos int not null default 1,
  descricao text not null default '',
  criado timestamptz not null default now()
);

create index if not exists fichas_dono on public.fichas (dono);
create index if not exists fichas_mesa on public.fichas (mesa_id);
create index if not exists itens_mesa on public.itens (mesa_id);

alter table public.perfis enable row level security;
alter table public.mesas enable row level security;
alter table public.membros enable row level security;
alter table public.fichas enable row level security;
alter table public.itens enable row level security;

-- ------------------------------------------------------------ quem é quem
create or replace function public.e_mestre(m uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from mesas where id = m and mestre = auth.uid());
$$;

create or replace function public.e_membro(m uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from membros where mesa_id = m and user_id = auth.uid())
      or exists (select 1 from mesas where id = m and mestre = auth.uid());
$$;

-- ------------------------------------------------------------ regras de acesso
drop policy if exists perfis_ler on public.perfis;
drop policy if exists perfis_criar on public.perfis;
drop policy if exists perfis_mudar on public.perfis;
create policy perfis_ler on public.perfis for select to authenticated using (true);
create policy perfis_criar on public.perfis for insert to authenticated with check (id = auth.uid());
create policy perfis_mudar on public.perfis for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists mesas_ler on public.mesas;
drop policy if exists mesas_criar on public.mesas;
drop policy if exists mesas_mudar on public.mesas;
drop policy if exists mesas_apagar on public.mesas;
create policy mesas_ler on public.mesas for select to authenticated using (mestre = auth.uid() or public.e_membro(id));
create policy mesas_criar on public.mesas for insert to authenticated with check (mestre = auth.uid());
create policy mesas_mudar on public.mesas for update to authenticated using (mestre = auth.uid()) with check (mestre = auth.uid());
create policy mesas_apagar on public.mesas for delete to authenticated using (mestre = auth.uid());

drop policy if exists membros_ler on public.membros;
drop policy if exists membros_sair on public.membros;
create policy membros_ler on public.membros for select to authenticated using (user_id = auth.uid() or public.e_membro(mesa_id));
create policy membros_sair on public.membros for delete to authenticated using (user_id = auth.uid() or public.e_mestre(mesa_id));

drop policy if exists fichas_ler on public.fichas;
drop policy if exists fichas_criar on public.fichas;
drop policy if exists fichas_mudar on public.fichas;
drop policy if exists fichas_apagar on public.fichas;
create policy fichas_ler on public.fichas for select to authenticated
  using (dono = auth.uid() or (mesa_id is not null and public.e_membro(mesa_id)));
create policy fichas_criar on public.fichas for insert to authenticated
  with check (dono = auth.uid() and (mesa_id is null or public.e_membro(mesa_id)));
create policy fichas_mudar on public.fichas for update to authenticated
  using (dono = auth.uid() or (mesa_id is not null and public.e_mestre(mesa_id)))
  with check ((dono = auth.uid() and (mesa_id is null or public.e_membro(mesa_id))) or (mesa_id is not null and public.e_mestre(mesa_id)));
create policy fichas_apagar on public.fichas for delete to authenticated using (dono = auth.uid());

drop policy if exists itens_ler on public.itens;
drop policy if exists itens_mestre on public.itens;
create policy itens_ler on public.itens for select to authenticated using (public.e_membro(mesa_id));
create policy itens_mestre on public.itens for all to authenticated using (public.e_mestre(mesa_id)) with check (public.e_mestre(mesa_id));

-- ------------------------------------------------------------ ações
-- entrar numa mesa com o código
create or replace function public.entrar_mesa(cod text) returns uuid
language plpgsql security definer set search_path = public as $$
declare m uuid;
begin
  if auth.uid() is null then raise exception 'sem login'; end if;
  select id into m from mesas where codigo = upper(trim(cod));
  if m is null then raise exception 'mesa não encontrada'; end if;
  insert into membros (mesa_id, user_id) values (m, auth.uid()) on conflict do nothing;
  return m;
end $$;

-- o mestre (ou o dono) põe um item na ficha sem apagar o que o jogador mudou
create or replace function public.dar_item(f uuid, lista text, item jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare d uuid; m uuid;
begin
  if lista not in ('itens', 'armas') then raise exception 'lista inválida'; end if;
  select dono, mesa_id into d, m from fichas where id = f;
  if d is null then raise exception 'ficha não encontrada'; end if;
  if not (d = auth.uid() or (m is not null and public.e_mestre(m))) then raise exception 'sem permissão'; end if;
  update fichas set
    dados = jsonb_set(jsonb_set(dados, array[lista], coalesce(dados -> lista, '[]'::jsonb) || jsonb_build_array(item)),
                      '{atualizado}', to_jsonb((extract(epoch from clock_timestamp()) * 1000)::bigint)),
    atualizado = now()
  where id = f;
end $$;

-- cria o perfil com o nome escolhido no cadastro
create or replace function public.novo_usuario() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into perfis (id, nome) values (new.id, coalesce(nullif(new.raw_user_meta_data ->> 'nome', ''), split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists ao_criar_usuario on auth.users;
create trigger ao_criar_usuario after insert on auth.users for each row execute function public.novo_usuario();

-- ------------------------------------------------------------ permissões da API
revoke all on public.perfis, public.mesas, public.membros, public.fichas, public.itens from anon;
grant usage on schema public to authenticated;
grant select, insert, update on public.perfis to authenticated;
grant select, insert, update, delete on public.mesas, public.membros, public.fichas, public.itens to authenticated;
revoke execute on function public.entrar_mesa(text), public.dar_item(uuid, text, jsonb), public.e_mestre(uuid), public.e_membro(uuid) from public, anon;
grant execute on function public.entrar_mesa(text), public.dar_item(uuid, text, jsonb), public.e_mestre(uuid), public.e_membro(uuid) to authenticated;

-- ------------------------------------------------------------ Juramento e Badaladas (também em segredos.sql)

create or replace function public.mestre_da_ficha(f uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from fichas fi join mesas m on m.id = fi.mesa_id where fi.id = f and m.mestre = auth.uid());
$$;

create or replace function public.ve_ficha(f uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from fichas fi where fi.id = f and (fi.dono = auth.uid() or (fi.mesa_id is not null and public.e_membro(fi.mesa_id))));
$$;

create table if not exists public.ficha_juramento (
  ficha_id uuid primary key references public.fichas on delete cascade,
  juramento text not null,
  degrau int not null default 1 check (degrau between 1 and 3),
  atualizado timestamptz not null default now()
);

create table if not exists public.ficha_segredo (
  ficha_id uuid primary key references public.fichas on delete cascade,
  badaladas int not null default 0 check (badaladas between 0 and 5),
  atualizado timestamptz not null default now()
);

alter table public.ficha_juramento enable row level security;
alter table public.ficha_segredo enable row level security;

drop policy if exists fj_ler on public.ficha_juramento;
drop policy if exists fj_mestre on public.ficha_juramento;
drop policy if exists fs_mestre on public.ficha_segredo;
create policy fj_ler on public.ficha_juramento for select to authenticated using (public.ve_ficha(ficha_id));
create policy fj_mestre on public.ficha_juramento for all to authenticated using (public.mestre_da_ficha(ficha_id)) with check (public.mestre_da_ficha(ficha_id));
create policy fs_mestre on public.ficha_segredo for all to authenticated using (public.mestre_da_ficha(ficha_id)) with check (public.mestre_da_ficha(ficha_id));

revoke all on public.ficha_juramento, public.ficha_segredo from anon;
grant select, insert, update, delete on public.ficha_juramento, public.ficha_segredo to authenticated;
revoke execute on function public.mestre_da_ficha(uuid), public.ve_ficha(uuid) from public, anon;
grant execute on function public.mestre_da_ficha(uuid), public.ve_ficha(uuid) to authenticated;
