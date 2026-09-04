/**
 * lendas_live / events.sp
 *
 * Hooks de evento de jogo (CS:S clássico — nomes e campos confirmados
 * contra o SDK real, nada de suposição de API do CS2) + a máquina de fase
 * usada pra derivar "clock" sem precisar ler estado interno do motor.
 *
 * "clock" (segundos restantes) é sempre calculado a partir de
 * `GetGameTime() - g_flPhaseStartTime` contra o convar real da fase atual
 * (mp_freezetime / mp_roundtime / mp_c4timer) — nunca contra um relógio
 * inventado. Em "warmup"/"ended" não há uma referência igualmente
 * confiável, então o campo é OMITIDO ali (ver Lendas_GetRoundClockSeconds).
 */

void Lendas_HookEvents()
{
	HookEvent("round_start", Event_RoundStart);
	HookEvent("round_freeze_end", Event_RoundFreezeEnd);
	HookEvent("round_end", Event_RoundEnd);
	HookEvent("player_death", Event_PlayerDeath);
	HookEvent("bomb_planted", Event_BombPlanted);
	HookEvent("bomb_defused", Event_BombDefused);
	HookEvent("bomb_exploded", Event_BombExploded);
	HookEvent("player_team", Event_PlayerTeam);
}

void Lendas_ResetMatchState()
{
	g_iCurrentRound = 0;
	g_bBombPlanted = false;
	strcopy(g_sPhase, sizeof(g_sPhase), "warmup");
	g_flPhaseStartTime = GetGameTime();
}

static int Lendas_ClampClock(float value)
{
	return value < 0.0 ? 0 : RoundFloat(value);
}

/** -1 = sem referência confiável pra essa fase (warmup/ended) — o chamador omite o campo. */
int Lendas_GetRoundClockSeconds()
{
	float elapsed = GetGameTime() - g_flPhaseStartTime;

	if (StrEqual(g_sPhase, "freezetime"))
	{
		ConVar cv = FindConVar("mp_freezetime");
		float total = (cv != null) ? cv.FloatValue : 6.0;
		return Lendas_ClampClock(total - elapsed);
	}

	if (StrEqual(g_sPhase, "live"))
	{
		ConVar cv = FindConVar("mp_roundtime");
		float total = (cv != null) ? cv.FloatValue * 60.0 : 115.0;
		return Lendas_ClampClock(total - elapsed);
	}

	if (StrEqual(g_sPhase, "bomb"))
	{
		ConVar cv = FindConVar("mp_c4timer");
		float total = (cv != null) ? cv.FloatValue : 45.0;
		return Lendas_ClampClock(total - elapsed);
	}

	return -1;
}

/** Mesmo domínio de `RoundEndReason` no frontend — ver CSRoundEndReason em cstrike.inc pros códigos. */
void Lendas_MapRoundEndReason(int reasonCode, char[] out, int maxlen)
{
	switch (reasonCode)
	{
		case 0: strcopy(out, maxlen, "bomb");         // CSRoundEnd_TargetBombed
		case 6: strcopy(out, maxlen, "defuse");       // CSRoundEnd_BombDefused
		case 10: strcopy(out, maxlen, "time");        // CSRoundEnd_Draw
		case 11: strcopy(out, maxlen, "time");        // CSRoundEnd_TargetSaved (tempo esgotou sem bomba)
		default: strcopy(out, maxlen, "elimination"); // CTWin/TerroristWin e o resto — caso mais comum de longe
	}
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_iCurrentRound++;
	strcopy(g_sPhase, sizeof(g_sPhase), "freezetime");
	g_flPhaseStartTime = GetGameTime();
	g_bBombPlanted = false;

	char timestamp[32], eventJson[128];
	Lendas_NowIso(timestamp, sizeof(timestamp));
	Format(eventJson, sizeof(eventJson), "{\"kind\":\"round_start\",\"round\":%d,\"timestamp\":\"%s\"}", g_iCurrentRound, timestamp);
	Lendas_Enqueue(eventJson);
}

/** Não é um evento que o LENDAS pediu pra enfileirar — só marca o início do tempo "live" pro cálculo de clock. */
public void Event_RoundFreezeEnd(Event event, const char[] name, bool dontBroadcast)
{
	strcopy(g_sPhase, sizeof(g_sPhase), "live");
	g_flPhaseStartTime = GetGameTime();
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	int winnerTeam = event.GetInt("winner");
	int reasonCode = event.GetInt("reason");

	char winner[4];
	strcopy(winner, sizeof(winner), (winnerTeam == CS_TEAM_T) ? "T" : "CT");

	char reason[16];
	Lendas_MapRoundEndReason(reasonCode, reason, sizeof(reason));

	// Melhor esforço: no CS:S o placar via CS_GetTeamScore já costuma refletir
	// o round que acabou de terminar neste ponto do evento. Se um dia isso
	// se mostrar defasado em teste real, mover pra um timer de 0s (Next Frame).
	int ctScore = CS_GetTeamScore(CS_TEAM_CT);
	int tScore = CS_GetTeamScore(CS_TEAM_T);

	char timestamp[32], eventJson[256];
	Lendas_NowIso(timestamp, sizeof(timestamp));
	Format(eventJson, sizeof(eventJson),
		"{\"kind\":\"round_end\",\"round\":%d,\"winner\":\"%s\",\"reason\":\"%s\",\"ctScore\":%d,\"tScore\":%d,\"timestamp\":\"%s\"}",
		g_iCurrentRound, winner, reason, ctScore, tScore, timestamp);
	Lendas_Enqueue(eventJson);

	strcopy(g_sPhase, sizeof(g_sPhase), "freezetime");
	g_flPhaseStartTime = GetGameTime();
	g_bBombPlanted = false;
}

public void Event_BombPlanted(Event event, const char[] name, bool dontBroadcast)
{
	g_bBombPlanted = true;
	strcopy(g_sPhase, sizeof(g_sPhase), "bomb");
	g_flPhaseStartTime = GetGameTime();

	char timestamp[32], eventJson[64];
	Lendas_NowIso(timestamp, sizeof(timestamp));
	Format(eventJson, sizeof(eventJson), "{\"kind\":\"bomb_planted\",\"timestamp\":\"%s\"}", timestamp);
	Lendas_Enqueue(eventJson);
}

public void Event_BombDefused(Event event, const char[] name, bool dontBroadcast)
{
	g_bBombPlanted = false;

	char timestamp[32], eventJson[64];
	Lendas_NowIso(timestamp, sizeof(timestamp));
	Format(eventJson, sizeof(eventJson), "{\"kind\":\"bomb_defused\",\"timestamp\":\"%s\"}", timestamp);
	Lendas_Enqueue(eventJson);
}

public void Event_BombExploded(Event event, const char[] name, bool dontBroadcast)
{
	g_bBombPlanted = false;

	char timestamp[32], eventJson[64];
	Lendas_NowIso(timestamp, sizeof(timestamp));
	Format(eventJson, sizeof(eventJson), "{\"kind\":\"bomb_exploded\",\"timestamp\":\"%s\"}", timestamp);
	Lendas_Enqueue(eventJson);
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if (victim <= 0 || !g_bAuthorized[victim])
		return; // sem SteamID64 real da vitima, nao monta o evento (nunca inventa identidade)

	char victimSteamId64[32], victimTeam[8];
	GetClientAuthId(victim, AuthId_SteamID64, victimSteamId64, sizeof(victimSteamId64));
	Lendas_TeamToString(GetClientTeam(victim), victimTeam, sizeof(victimTeam));

	char weapon[64], weaponEsc[64];
	event.GetString("weapon", weapon, sizeof(weapon));
	Lendas_JsonEscape(weapon, weaponEsc, sizeof(weaponEsc));
	bool headshot = event.GetBool("headshot");

	char attackerPart[160];
	attackerPart[0] = '\0';
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if (attacker > 0 && attacker != victim && g_bAuthorized[attacker])
	{
		char attackerSteamId64[32], attackerTeam[8];
		GetClientAuthId(attacker, AuthId_SteamID64, attackerSteamId64, sizeof(attackerSteamId64));
		Lendas_TeamToString(GetClientTeam(attacker), attackerTeam, sizeof(attackerTeam));
		Format(attackerPart, sizeof(attackerPart),
			",\"attackerSteamId64\":\"%s\",\"attackerTeam\":\"%s\"", attackerSteamId64, attackerTeam);
	}

	char timestamp[32], eventJson[512];
	Lendas_NowIso(timestamp, sizeof(timestamp));
	Format(eventJson, sizeof(eventJson),
		"{\"kind\":\"player_death\",\"victimSteamId64\":\"%s\",\"victimTeam\":\"%s\"%s,\"weapon\":\"%s\",\"headshot\":%s,\"timestamp\":\"%s\"}",
		victimSteamId64, victimTeam, attackerPart, weaponEsc, headshot ? "true" : "false", timestamp);

	Lendas_Enqueue(eventJson);
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	if (event.GetBool("disconnect"))
		return; // mudanca de time so por causa da desconexao - player_disconnect ja cobre isso

	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0)
		return;

	Lendas_EnqueuePlayerTeam(client, event.GetInt("team"));
}
