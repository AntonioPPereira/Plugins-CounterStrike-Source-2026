/**
 * lendas_live / globals.sp
 *
 * Estado compartilhado entre módulos. Incluído PRIMEIRO em lendas_live.sp
 * de propósito: variável global em SourcePawn precisa existir antes de
 * qualquer outro arquivo incluído referenciar (ao contrário de função, que
 * pode ser referenciada antes de aparecer no texto — aqui não se arrisca).
 */

/** Autenticado (SteamID64 real confirmado) — só então o jogador existe pro LENDAS. */
bool g_bAuthorized[MAXPLAYERS + 1];

/** Não existe native "round atual" no CS:S — contado a partir de round_start, zerado a cada mapa. */
bool g_bBombPlanted;
int g_iCurrentRound;

/**
 * "warmup" | "freezetime" | "live" | "bomb" | "halftime" | "ended" — o
 * clock (segundos restantes) é derivado disso + `g_flPhaseStartTime`
 * (GetGameTime() de quando a fase atual começou) contra os convars reais
 * (mp_freezetime / mp_roundtime / mp_c4timer). "halftime" não tem evento
 * de jogo confiável no CS:S clássico — nunca é setado, fica documentado
 * como limitação (ver README de instalação do plugin).
 */
char g_sPhase[16] = "warmup";
float g_flPhaseStartTime;
