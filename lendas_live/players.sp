/**
 * lendas_live / players.sp
 *
 * Leitura de estado de jogador (natives confirmados contra o SDK real do
 * SourceMod 1.12 — nada daqui e suposicao) e os eventos de ciclo de vida
 * (connect/disconnect/team). Nunca manda um jogador sem SteamID64 real:
 * quem ainda nao autenticou simplesmente nao aparece no snapshot nem gera
 * player_connect ainda (g_bAuthorized so vira true em OnClientAuthorized).
 */

/**
 * Checagem barata (sem validar dígito verificador nenhum — o backend já
 * valida a fundo) só pra nunca marcar como autorizado um bot ou um cliente
 * em modo LAN, cujo "auth" não é um SteamID64 de verdade.
 */
bool Lendas_LooksLikeSteamId64(const char[] value)
{
	if (strlen(value) != 17)
		return false;

	for (int i = 0; i < 17; i++)
	{
		if (value[i] < '0' || value[i] > '9')
			return false;
	}

	return true;
}

void Lendas_TeamToString(int team, char[] out, int maxlen)
{
	if (team == CS_TEAM_CT)
		strcopy(out, maxlen, "CT");
	else if (team == CS_TEAM_T)
		strcopy(out, maxlen, "T");
	else
		strcopy(out, maxlen, "SPEC");
}

/** "weapon_ak47" -> "ak47", casando com o formato ja usado no resto do LENDAS. */
void Lendas_StripWeaponPrefix(const char[] classname, char[] out, int maxlen)
{
	if (strncmp(classname, "weapon_", 7) == 0)
		strcopy(out, maxlen, classname[7]);
	else
		strcopy(out, maxlen, classname);
}

static bool Lendas_IsLiveClient(int client)
{
	return client >= 1
		&& client <= MaxClients
		&& IsClientInGame(client)
		&& !IsFakeClient(client)
		&& g_bAuthorized[client];
}

/**
 * CS_GetClientAssists/CS_GetClientContributionScore/CS_GetMVPCount são
 * nativos do extension cstrike marcados como opcionais no próprio SDK
 * (MarkNativeAsOptional em cstrike.inc). Uma primeira tentativa usou
 * GetFeatureStatus pra checar disponibilidade antes de chamar — mas
 * confirmado em produção 2026-08-26 que isso NÃO é confiável aqui:
 * GetFeatureStatus reportou CS_GetClientAssists como disponível e o native
 * lançou "not supported on this game" do mesmo jeito, derrubando
 * Lendas_BuildPlayerSnapshot inteiro toda vez que havia jogador real em
 * campo. Por isso os três nem são chamados mais nesta instalação.
 */

/** Um objeto JSON de jogador (com chaves ao redor) — usado só dentro do array de player_snapshot. */
static void Lendas_AppendPlayerJson(int client, char[] buffer, int maxlen)
{
	char steamId64[32], steamId[32], nickname[64], nicknameEsc[160], team[8], weapon[64], weaponClean[64];

	GetClientAuthId(client, AuthId_SteamID64, steamId64, sizeof(steamId64));
	GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));
	GetClientName(client, nickname, sizeof(nickname));
	Lendas_JsonEscape(nickname, nicknameEsc, sizeof(nicknameEsc));
	Lendas_TeamToString(GetClientTeam(client), team, sizeof(team));
	GetClientWeapon(client, weapon, sizeof(weapon));
	Lendas_StripWeaponPrefix(weapon, weaponClean, sizeof(weaponClean));

	bool alive = IsPlayerAlive(client);
	int health = alive ? GetClientHealth(client) : 0;
	int armor = GetClientArmor(client);
	int money = GetEntProp(client, Prop_Send, "m_iAccount");
	int kills = GetClientFrags(client);
	int deaths = GetClientDeaths(client);
	int assists = 0;
	int mvps = 0;
	// Sem contribution score nativo utilizável nesta instalação: kills valem
	// mais que assists, mesma proporção usada pelo próprio jogo pra
	// pontuação de round (assists sempre 0, ver nota acima).
	int score = kills * 2;
	int ping = RoundFloat(GetClientLatency(client, NetFlow_Both) * 1000.0);
	int connectedSeconds = RoundFloat(GetClientTime(client));
	int userId = GetClientUserId(client);

	Format(buffer, maxlen,
		"{\"steamId64\":\"%s\",\"steamId\":\"%s\",\"nickname\":\"%s\",\"userId\":%d,\"team\":\"%s\",\
\"alive\":%s,\"health\":%d,\"armor\":%d,\"money\":%d,\"kills\":%d,\"deaths\":%d,\"assists\":%d,\
\"score\":%d,\"ping\":%d,\"weapon\":\"%s\",\"mvps\":%d,\"connectedSeconds\":%d}",
		steamId64, steamId, nicknameEsc, userId, team,
		alive ? "true" : "false", health, armor, money, kills, deaths, assists,
		score, ping, weaponClean, mvps, connectedSeconds);
}

void Lendas_BuildServerSnapshot(char[] buffer, int maxlen)
{
	char hostname[128], hostnameEsc[300], map[64], timestamp[32];
	ConVar hostnameCvar = FindConVar("hostname");
	if (hostnameCvar != null)
		hostnameCvar.GetString(hostname, sizeof(hostname));
	else
		hostname[0] = '\0';
	Lendas_JsonEscape(hostname, hostnameEsc, sizeof(hostnameEsc));
	GetCurrentMap(map, sizeof(map));
	Lendas_NowIso(timestamp, sizeof(timestamp));

	int players = 0;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && !IsFakeClient(client))
			players++;
	}

	int ctScore = CS_GetTeamScore(CS_TEAM_CT);
	int tScore = CS_GetTeamScore(CS_TEAM_T);
	int maxRounds = 0;
	ConVar maxRoundsCvar = FindConVar("mp_maxrounds");
	if (maxRoundsCvar != null)
		maxRounds = maxRoundsCvar.IntValue;

	int clockSeconds = Lendas_GetRoundClockSeconds();

	Format(buffer, maxlen,
		"{\"kind\":\"server_snapshot\",\"hostname\":\"%s\",\"map\":\"%s\",\"players\":%d,\"maxPlayers\":%d,\
\"round\":%d,\"maxRounds\":%d,\"ctScore\":%d,\"tScore\":%d,\"phase\":\"%s\",\"bombPlanted\":%s",
		hostnameEsc, map, players, MaxClients,
		g_iCurrentRound, maxRounds, ctScore, tScore, g_sPhase, g_bBombPlanted ? "true" : "false");

	if (clockSeconds >= 0)
	{
		char clockPart[32];
		Format(clockPart, sizeof(clockPart), ",\"clock\":%d", clockSeconds);
		StrCat(buffer, maxlen, clockPart);
	}

	char timestampPart[48];
	Format(timestampPart, sizeof(timestampPart), ",\"timestamp\":\"%s\"}", timestamp);
	StrCat(buffer, maxlen, timestampPart);
}

void Lendas_BuildPlayerSnapshot(char[] buffer, int maxlen)
{
	char timestamp[32];
	Lendas_NowIso(timestamp, sizeof(timestamp));

	Format(buffer, maxlen, "{\"kind\":\"player_snapshot\",\"timestamp\":\"%s\",\"players\":[", timestamp);

	// Folga generosa: nickname de 64 chars pode dobrar de tamanho ao escapar
	// (pior caso, todo composto de aspas/barra invertida) + os demais campos.
	char playerJson[768];
	bool first = true;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!Lendas_IsLiveClient(client))
			continue;

		Lendas_AppendPlayerJson(client, playerJson, sizeof(playerJson));
		if (!first)
			StrCat(buffer, maxlen, ",");
		StrCat(buffer, maxlen, playerJson);
		first = false;
	}

	StrCat(buffer, maxlen, "]}");
}

/**
 * OnClientAuthorized só dispara uma vez por conexão real — nunca de novo só
 * porque o plugin recarregou ou o mapa trocou. Chamada em dois pontos que
 * precisam recuperar "quem já está autenticado" sem depender disso:
 * OnPluginStart (reload/atualização zera g_bAuthorized pra todo mundo) e
 * OnMapStart (troca de mapa, só por garantia — ver nota em
 * OnClientPutInServer no lendas_live.sp principal). Ambos confirmados em
 * produção 2026-08-26.
 */
void Lendas_RecheckAlreadyConnectedClients()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client) || g_bAuthorized[client])
			continue;

		char steamId64[32];
		if (!GetClientAuthId(client, AuthId_SteamID64, steamId64, sizeof(steamId64)))
			continue;
		if (!Lendas_LooksLikeSteamId64(steamId64))
			continue;

		g_bAuthorized[client] = true;
	}
}

void Lendas_EnqueuePlayerConnect(int client)
{
	char steamId64[32], steamId[32], nickname[64], nicknameEsc[160], timestamp[32], event[512];
	GetClientAuthId(client, AuthId_SteamID64, steamId64, sizeof(steamId64));
	GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));
	GetClientName(client, nickname, sizeof(nickname));
	Lendas_JsonEscape(nickname, nicknameEsc, sizeof(nicknameEsc));
	Lendas_NowIso(timestamp, sizeof(timestamp));

	Format(event, sizeof(event),
		"{\"kind\":\"player_connect\",\"steamId64\":\"%s\",\"steamId\":\"%s\",\"nickname\":\"%s\",\"userId\":%d,\"timestamp\":\"%s\"}",
		steamId64, steamId, nicknameEsc, GetClientUserId(client), timestamp);

	Lendas_Enqueue(event);

	if (g_cvDebug.BoolValue)
		LogMessage("[Lendas] Player authorized: %s", steamId64);
}

void Lendas_EnqueuePlayerDisconnect(const char[] steamId64, int userId)
{
	char timestamp[32], event[256];
	Lendas_NowIso(timestamp, sizeof(timestamp));

	Format(event, sizeof(event),
		"{\"kind\":\"player_disconnect\",\"steamId64\":\"%s\",\"userId\":%d,\"timestamp\":\"%s\"}",
		steamId64, userId, timestamp);

	Lendas_Enqueue(event);
}

void Lendas_EnqueuePlayerTeam(int client, int newTeam)
{
	if (!g_bAuthorized[client])
		return;

	char steamId64[32], team[8], timestamp[32], event[192];
	GetClientAuthId(client, AuthId_SteamID64, steamId64, sizeof(steamId64));
	Lendas_TeamToString(newTeam, team, sizeof(team));
	Lendas_NowIso(timestamp, sizeof(timestamp));

	Format(event, sizeof(event),
		"{\"kind\":\"player_team\",\"steamId64\":\"%s\",\"team\":\"%s\",\"timestamp\":\"%s\"}",
		steamId64, team, timestamp);

	Lendas_Enqueue(event);
}
