-- Maré Baixa · Juramento e Badaladas só pelo Mestre
-- Cole no SQL Editor do Supabase e clique em Run. Pode rodar de novo sem medo.
-- O Juramento fica numa tabela que só o Mestre da mesa altera; o jogador lê o dele depois que o Mestre anotar.
-- As Badaladas ficam numa tabela que só o Mestre da mesa lê e altera.

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
