# Maré Baixa

Site da mesa de **Deep Tales**: o Livro Profano (versão dos jogadores), fichas online com login de nome e senha, e mesas onde o Mestre vê e mexe nas fichas e entrega itens.

## Como pôr no ar
1. **Supabase → SQL Editor:** cole o conteúdo de `supabase/setup.sql` e clique em **Run**.
2. **Supabase → Authentication → Sign In / Providers → Email:** desligue **Confirm email** (o login é só nome e senha, sem e-mail de verdade).
3. **GitHub → Settings → Pages:** em *Branch*, escolha `main` e `/ (root)` e salve. O site fica em `https://jao18faca-dev.github.io/Mesa-Afogada/`.

## Como funciona
- Cada pessoa entra com nome e senha (mínimo 6 letras). Se o nome não existe, a conta é criada na hora.
- **Fichas:** cada jogador cria as suas e escolhe em qual mesa cada uma joga.
- **Mesas:** o Mestre cria a mesa e passa o código. Na mesa ele vê as fichas de todos, abre qualquer uma para mexer, e dá itens do catálogo (armas, Trajes, Peças, consumíveis e itens que ele mesmo criar).
- As telas se atualizam sozinhas a cada poucos segundos.
- Senha esquecida: o Mestre apaga a conta em *Authentication → Users* no Supabase, e a pessoa cria de novo (as fichas da conta apagada somem junto).

`index.html` é gerado a partir do livro; não edite à mão.
