/**
 * L.E.N.D.A.S. Live
 *
 * Manda estado real do servidor (mapa, placar, round, bomba) e dos
 * jogadores conectados (SteamID64, time, vida, kills...) pro backend do
 * LENDAS, que repassa via SSE pro painel. Plugin SEPARADO do
 * lendas_steamfilter — não altera, não substitui, não duplica a lógica de
 * requisitos dele. Ver auditoria em server/README.md do projeto LENDAS.
 *
 * SteamID64 é capturado aqui e só aqui — a resolução de avatar via Steam
 * Web API acontece inteiramente no backend (STEAM_API_KEY nunca existe
 * neste plugin nem em lugar nenhum do frontend).
 *
 * Requer: extensão SteamWorks (mesma já usada pelo lendas_steamfilter)
 *   https://github.com/KyleSanderson/SteamWorks
 *
 * Compilar com o compiler do SourceMod 1.12 (mesma toolchain do
 * lendas_steamfilter — ver LEIA-ME.md pra recompilar noutra versão).
 */

#pragma semicolon 1
#pragma newdecls required
// Padrão do compilador é pequeno demais pro buffer de flush (queue.sp monta
// um corpo de até LENDAS_BODY_MAXLEN + um eventJson de 16384 bytes na mesma
// pilha) — sem isso, o primeiro flush real deriva em "Not enough space on
// the heap" (confirmado em produção 2026-08-26). Uma primeira tentativa com
// 32768 cells (128KB) ainda não foi suficiente — subindo bem mais alto
// desta vez, com folga grande de propósito.
#pragma dynamic 65536

#include <sourcemod>
#include <cstrike>
#include <sdktools>
#include <SteamWorks>

#define PLUGIN_VERSION "1.0.0"

#include "lendas_live/globals.sp"
#include "lendas_live/json.sp"
#include "lendas_live/time.sp"
#include "lendas_live/config.sp"
#include "lendas_live/queue.sp"
#include "lendas_live/http.sp"
#include "lendas_live/players.sp"
#include "lendas_live/events.sp"

public Plugin myinfo =
{
	name        = "L.E.N.D.A.S. Live",
	author      = "L.E.N.D.A.S.",
	description = "Envia placar, round e jogadores ao vivo pro painel LENDAS",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	Lendas_CreateConVars();
	Lendas_QueueInit();
	Lendas_HookEvents();
	Lendas_ResetMatchState();
	Lendas_RecheckAlreadyConnectedClients();

	CreateTimer(g_cvSnapshotInterval.FloatValue, Timer_Snapshot, _, TIMER_REPEAT);
	CreateTimer(g_cvFlushInterval.FloatValue, Timer_Flush, _, TIMER_REPEAT);

	LogMessage("[Lendas] Plugin carregado (v%s)", PLUGIN_VERSION);
}

public void OnMapStart()
{
	Lendas_ResetMatchState();
	// Quem já estava autenticado antes da troca de mapa continua conectado
	// no mesmo client index — OnClientAuthorized não dispara de novo (o
	// SteamID já foi validado na conexão original). Ver nota em
	// OnClientPutInServer logo abaixo: o motivo real de precisar disso aqui
	// é que o reset que existia lá derrubava justamente esse caso.
	Lendas_RecheckAlreadyConnectedClients();

	char map[64], timestamp[32], eventJson[128];
	GetCurrentMap(map, sizeof(map));
	Lendas_NowIso(timestamp, sizeof(timestamp));
	Format(eventJson, sizeof(eventJson), "{\"kind\":\"map_start\",\"map\":\"%s\",\"timestamp\":\"%s\"}", map, timestamp);
	Lendas_Enqueue(eventJson);

	if (g_cvDebug.BoolValue)
		LogMessage("[Lendas] Map changed: %s", map);
}

public void OnMapEnd()
{
	char map[64], timestamp[32], eventJson[128];
	GetCurrentMap(map, sizeof(map));
	Lendas_NowIso(timestamp, sizeof(timestamp));
	Format(eventJson, sizeof(eventJson), "{\"kind\":\"map_end\",\"map\":\"%s\",\"timestamp\":\"%s\"}", map, timestamp);
	Lendas_Enqueue(eventJson);
}

/**
 * NÃO reseta g_bAuthorized aqui (era o bug: confirmado em produção
 * 2026-08-26 que o placar ficava vazio depois de QUALQUER troca de mapa).
 * OnClientPutInServer dispara de novo pra todo cliente que permanece
 * conectado através de um changelevel — não só pra conexão nova — porque a
 * entidade dele é recriada no mapa novo. Zerar aqui incondicionalmente
 * desautorizava quem já estava jogando, e como OnClientAuthorized só roda
 * uma vez por conexão real (não por mapa), ninguém corrigia isso de volta.
 * A limpeza de slot reusado já é garantida por OnClientDisconnect, que
 * sempre roda antes de qualquer novo cliente reaproveitar o mesmo índice —
 * esse reset aqui nunca foi necessário pra isso.
 */

/**
 * Momento certo pra capturar identidade: dispara quando o SteamID do
 * cliente já está validado. Bot e conexão LAN não têm SteamID64 de
 * verdade — nunca marcados como autorizados, nunca aparecem pro LENDAS.
 */
public void OnClientAuthorized(int client, const char[] auth)
{
	if (g_cvDebug.BoolValue)
		LogMessage("[Lendas] OnClientAuthorized: client=%d fake=%d auth=\"%s\"", client, IsFakeClient(client), auth);

	if (IsFakeClient(client))
		return;

	char steamId64[32];
	bool gotId = GetClientAuthId(client, AuthId_SteamID64, steamId64, sizeof(steamId64));
	if (g_cvDebug.BoolValue)
		LogMessage("[Lendas] GetClientAuthId(SteamID64): ok=%d valor=\"%s\"", gotId, steamId64);

	if (!gotId)
		return;

	bool looksValid = Lendas_LooksLikeSteamId64(steamId64);
	if (g_cvDebug.BoolValue)
		LogMessage("[Lendas] Lendas_LooksLikeSteamId64: %d (len=%d)", looksValid, strlen(steamId64));

	if (!looksValid)
		return;

	g_bAuthorized[client] = true;
	Lendas_EnqueuePlayerConnect(client);
}

public void OnClientDisconnect(int client)
{
	if (!g_bAuthorized[client])
	{
		g_bAuthorized[client] = false;
		return;
	}

	char steamId64[32];
	GetClientAuthId(client, AuthId_SteamID64, steamId64, sizeof(steamId64));
	Lendas_EnqueuePlayerDisconnect(steamId64, GetClientUserId(client));

	g_bAuthorized[client] = false;
}

public Action Timer_Snapshot(Handle timer)
{
	if (!Lendas_IsEnabled())
		return Plugin_Continue;

	char serverSnapshot[1024];
	Lendas_BuildServerSnapshot(serverSnapshot, sizeof(serverSnapshot));
	Lendas_Enqueue(serverSnapshot);

	char playerSnapshot[LENDAS_EVENT_JSON_MAXLEN];
	Lendas_BuildPlayerSnapshot(playerSnapshot, sizeof(playerSnapshot));
	Lendas_Enqueue(playerSnapshot);

	return Plugin_Continue;
}

public Action Timer_Flush(Handle timer)
{
	Lendas_FlushQueue();
	return Plugin_Continue;
}
