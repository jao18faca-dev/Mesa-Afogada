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

-- ------------------------------------------------------------ Tabuleiro (também em tabuleiro.sql)
-- ------------------------------------------------------------ tabelas
-- um tabuleiro por mesa. terreno e névoa: uma letra por quadrado, linha por linha.
--   terreno: . chão · g grama · r terra · s areia · k pedra · m tábuas · o caverna
--            a água rasa · f água funda · l lama · v mato alto · d entulho (difícil)
--            c mureta (meia cobertura) · b rocha · p parede (bloqueiam)
--   névoa:   0 aberto · 1 coberto
create table if not exists public.tabuleiros (
  mesa_id uuid primary key references public.mesas on delete cascade,
  cols int not null default 24 check (cols between 4 and 400),
  linhas int not null default 16 check (linhas between 4 and 400),
  terreno text not null default '',
  nevoa text not null default '',
  turno jsonb not null default '{}'::jsonb,
  fundo_versao int not null default 0,
  versao bigint not null default 0,
  atualizado timestamptz not null default now()
);
-- cena: ambiente do mapa e objetos (árvores, rochas, caixotes…) desenhados por cima do terreno
alter table public.tabuleiros add column if not exists cena jsonb not null default '{}'::jsonb;

-- a imagem de fundo fica numa tabela à parte, para a consulta de todo segundo continuar leve
create table if not exists public.tabuleiro_fundo (
  mesa_id uuid primary key references public.mesas on delete cascade,
  imagem text not null default '' check (length(imagem) < 4000000),
  atualizado timestamptz not null default now()
);

create table if not exists public.pecas (
  id uuid primary key default gen_random_uuid(),
  mesa_id uuid not null references public.mesas on delete cascade,
  ficha_id uuid references public.fichas on delete cascade,
  nome text not null default '',
  tipo text not null default 'inimigo' check (tipo in ('pj', 'inimigo', 'aliado', 'objeto')),
  cor text not null default '#c0392d',
  x int not null default 0,
  y int not null default 0,
  tam int not null default 1 check (tam between 1 and 4),
  oculta boolean not null default false,
  chefe boolean not null default false,
  pv int,
  pv_max int,
  atualizado timestamptz not null default now()
);
create index if not exists pecas_mesa on public.pecas (mesa_id);

-- áreas de mantra que alguém pôs no tabuleiro (raio, cone ou linha)
create table if not exists public.marcas (
  id uuid primary key default gen_random_uuid(),
  mesa_id uuid not null references public.mesas on delete cascade,
  autor uuid not null default auth.uid() references auth.users on delete cascade,
  forma text not null check (forma in ('circulo', 'cone', 'linha')),
  x real not null, y real not null,
  ax real not null, ay real not null,
  metros real not null check (metros > 0 and metros <= 60),
  cor text not null default '#3fb3d2',
  rotulo text not null default '',
  criado timestamptz not null default now()
);
create index if not exists marcas_mesa on public.marcas (mesa_id);

alter table public.tabuleiros enable row level security;
alter table public.tabuleiro_fundo enable row level security;
alter table public.pecas enable row level security;
alter table public.marcas enable row level security;

-- ------------------------------------------------------------ quem é quem
create or replace function public.dono_da_ficha(f uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from fichas where id = f and dono = auth.uid());
$$;

-- o quadrado (px, py) está debaixo da névoa?
create or replace function public.na_nevoa(m uuid, px int, py int) returns boolean
language sql security definer stable set search_path = public as $$
  select coalesce((select px >= 0 and py >= 0 and px < t.cols and substr(t.nevoa, py * t.cols + px + 1, 1) = '1'
                   from tabuleiros t where t.mesa_id = m), false);
$$;

-- ------------------------------------------------------------ regras de acesso
drop policy if exists tb_ler on public.tabuleiros;
drop policy if exists tb_mestre on public.tabuleiros;
create policy tb_ler on public.tabuleiros for select to authenticated using (public.e_membro(mesa_id));
create policy tb_mestre on public.tabuleiros for all to authenticated using (public.e_mestre(mesa_id)) with check (public.e_mestre(mesa_id));

drop policy if exists tbf_ler on public.tabuleiro_fundo;
drop policy if exists tbf_mestre on public.tabuleiro_fundo;
create policy tbf_ler on public.tabuleiro_fundo for select to authenticated using (public.e_membro(mesa_id));
create policy tbf_mestre on public.tabuleiro_fundo for all to authenticated using (public.e_mestre(mesa_id)) with check (public.e_mestre(mesa_id));

-- o jogador não recebe peças ocultas nem peças debaixo da névoa (a dele ele sempre vê)
drop policy if exists pecas_ler on public.pecas;
drop policy if exists pecas_mestre on public.pecas;
create policy pecas_ler on public.pecas for select to authenticated using (
  public.e_mestre(mesa_id)
  or (public.e_membro(mesa_id) and (
        (ficha_id is not null and public.dono_da_ficha(ficha_id))
     or (not oculta and not public.na_nevoa(mesa_id, x, y)))));
create policy pecas_mestre on public.pecas for all to authenticated using (public.e_mestre(mesa_id)) with check (public.e_mestre(mesa_id));

drop policy if exists marcas_ler on public.marcas;
drop policy if exists marcas_criar on public.marcas;
drop policy if exists marcas_apagar on public.marcas;
create policy marcas_ler on public.marcas for select to authenticated using (public.e_membro(mesa_id));
create policy marcas_criar on public.marcas for insert to authenticated with check (autor = auth.uid() and public.e_membro(mesa_id));
create policy marcas_apagar on public.marcas for delete to authenticated using (autor = auth.uid() or public.e_mestre(mesa_id));

-- ------------------------------------------------------------ ações
-- o jogador move a própria peça; o Mestre move qualquer uma
create or replace function public.mover_peca(p uuid, nx int, ny int) returns void
language plpgsql security definer set search_path = public as $$
declare pe pecas; t tabuleiros;
begin
  select * into pe from pecas where id = p;
  if pe.id is null then raise exception 'peça não encontrada'; end if;
  if not (public.e_mestre(pe.mesa_id) or (pe.ficha_id is not null and public.dono_da_ficha(pe.ficha_id))) then raise exception 'sem permissão'; end if;
  select * into t from tabuleiros where mesa_id = pe.mesa_id;
  update pecas set x = greatest(0, least(coalesce(t.cols, 80) - pe.tam, nx)),
                   y = greatest(0, least(coalesce(t.linhas, 80) - pe.tam, ny)),
                   atualizado = now()
  where id = p;
end $$;

-- ritmo (rápido ou lento), PA que sobram e "passei a vez" de uma peça
create or replace function public.turno_peca(p uuid, ritmo text default null, pa int default null, feito boolean default null) returns void
language plpgsql security definer set search_path = public as $$
declare pe pecas; k text := p::text;
begin
  select * into pe from pecas where id = p;
  if pe.id is null then raise exception 'peça não encontrada'; end if;
  if not (public.e_mestre(pe.mesa_id) or (pe.ficha_id is not null and public.dono_da_ficha(pe.ficha_id))) then raise exception 'sem permissão'; end if;
  if ritmo is not null and ritmo not in ('rapido', 'lento') then raise exception 'ritmo inválido'; end if;
  update tabuleiros set turno = turno
      || case when ritmo is null then '{}'::jsonb else jsonb_build_object('ritmo', coalesce(turno -> 'ritmo', '{}'::jsonb) || jsonb_build_object(k, ritmo)) end
      || case when pa is null then '{}'::jsonb else jsonb_build_object('pa', coalesce(turno -> 'pa', '{}'::jsonb) || jsonb_build_object(k, greatest(0, least(3, pa)))) end
      || case when feito is null then '{}'::jsonb else jsonb_build_object('feito', coalesce(turno -> 'feito', '{}'::jsonb) || jsonb_build_object(k, feito)) end
  where mesa_id = pe.mesa_id;
end $$;

-- o Mestre muda partes do turno sem apagar o que os jogadores acabaram de escolher
create or replace function public.turno_mudar(m uuid, chaves jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.e_mestre(m) then raise exception 'sem permissão'; end if;
  update tabuleiros set turno = turno || chaves where mesa_id = m;
end $$;

-- ------------------------------------------------------------ versão: quem está olhando só baixa o tabuleiro quando algo mudou
create or replace function public.tb_versao() returns trigger
language plpgsql as $$
begin
  new.versao := old.versao + 1;
  new.atualizado := now();
  return new;
end $$;
drop trigger if exists tb_versao on public.tabuleiros;
create trigger tb_versao before update on public.tabuleiros for each row execute function public.tb_versao();

create or replace function public.tb_mexeu() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'tabuleiro_fundo' then
    update tabuleiros set fundo_versao = fundo_versao + 1 where mesa_id = coalesce(new.mesa_id, old.mesa_id);
  else
    update tabuleiros set atualizado = now() where mesa_id = coalesce(new.mesa_id, old.mesa_id);
  end if;
  return null;
end $$;
drop trigger if exists pecas_mexeu on public.pecas;
create trigger pecas_mexeu after insert or update or delete on public.pecas for each row execute function public.tb_mexeu();
drop trigger if exists marcas_mexeu on public.marcas;
create trigger marcas_mexeu after insert or update or delete on public.marcas for each row execute function public.tb_mexeu();
drop trigger if exists fundo_mexeu on public.tabuleiro_fundo;
create trigger fundo_mexeu after insert or update or delete on public.tabuleiro_fundo for each row execute function public.tb_mexeu();

-- ------------------------------------------------------------ permissões da API
revoke all on public.tabuleiros, public.tabuleiro_fundo, public.pecas, public.marcas from anon;
grant select, insert, update, delete on public.tabuleiros, public.tabuleiro_fundo, public.pecas, public.marcas to authenticated;
revoke execute on function public.dono_da_ficha(uuid), public.na_nevoa(uuid, int, int), public.mover_peca(uuid, int, int),
  public.turno_peca(uuid, text, int, boolean), public.turno_mudar(uuid, jsonb) from public, anon;
grant execute on function public.dono_da_ficha(uuid), public.na_nevoa(uuid, int, int), public.mover_peca(uuid, int, int),
  public.turno_peca(uuid, text, int, boolean), public.turno_mudar(uuid, jsonb) to authenticated;

-- mapas enormes (até 400 × 400 quadrados): troca o limite de quem já tinha a tabela
alter table public.tabuleiros drop constraint if exists tabuleiros_cols_check;
alter table public.tabuleiros drop constraint if exists tabuleiros_linhas_check;
alter table public.tabuleiros add constraint tabuleiros_cols_check check (cols between 4 and 400);
alter table public.tabuleiros add constraint tabuleiros_linhas_check check (linhas between 4 and 400);
