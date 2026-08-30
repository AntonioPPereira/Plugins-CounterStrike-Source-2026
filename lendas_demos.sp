#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION "2.0.0"

/**
 * lendas_demos
 *
 * Grava uma demo do SourceTV por mapa e organiza tudo em demos/YYYY-MM/.
 *
 * O nome do arquivo NAO e livre: o backend do site so reconhece uma demo
 * cujo nome case com YYYYMMDD-HHMM-<mapa>.dem (ver server/src/lib/demoId.ts,
 * que valida com um regex fechado e reconstroi o caminho a partir dele).
 * Por isso o nome do mapa passa por Lendas_Sanitizar: qualquer caractere
 * fora de [A-Za-z0-9_] vira "_", senao a demo grava mas o site a ignora.
 *
 * Substitui a versao "Demo Organizer", que so ajustava tv_replaydir e nunca
 * chamava tv_record — o servidor ficou sem gravar nada de 28/08 em diante.
 */
public Plugin myinfo =
{
	name = "[LENDAS] Demos",
	author = "LENDAS",
	description = "Grava a demo do SourceTV por mapa em demos/YYYY-MM/ no formato que o site le",
	version = PLUGIN_VERSION,
	url = "",
};

ConVar g_cvEnabled;
ConVar g_cvDelay;
ConVar g_cvTvEnable;

/** Pasta do mes corrente, ex: "2026-08". Recalculada a cada mapa. */
char g_sPeriodo[16];
bool g_bGravando;

public void OnPluginStart()
{
	CreateConVar("lendas_demos_version", PLUGIN_VERSION, "Versao do plugin",
		FCVAR_NOTIFY | FCVAR_DONTRECORD);

	g_cvEnabled = CreateConVar("lendas_demos_enabled", "1",
		"1 = grava demo do SourceTV a cada mapa.", _, true, 0.0, true, 1.0);

	/**
	 * O bot do SourceTV nao existe no instante do OnMapStart: ele entra
	 * alguns segundos depois. Chamar tv_record antes disso falha silencioso,
	 * que e exatamente o tipo de erro dificil de perceber (o log diz que
	 * gravou, o arquivo nunca aparece). Por isso o atraso.
	 */
	g_cvDelay = CreateConVar("lendas_demos_delay", "12.0",
		"Segundos apos a troca de mapa antes de comecar a gravar (espera o SourceTV subir).",
		_, true, 3.0, true, 60.0);

	g_cvTvEnable = FindConVar("tv_enable");

	AutoExecConfig(true, "lendas_demos");
}

public void OnMapStart()
{
	g_bGravando = false;

	FormatTime(g_sPeriodo, sizeof(g_sPeriodo), "%Y-%m");

	// A pasta precisa existir ANTES do tv_record: o SourceTV nao cria
	// diretorio, ele simplesmente falha se o caminho nao existir.
	char destino[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, destino, sizeof(destino), "../../demos/%s", g_sPeriodo);
	if (!DirExists(destino))
	{
		CreateDirectory(destino, 511);
		LogMessage("[Demos] Pasta criada: demos/%s", g_sPeriodo);
	}

	ServerCommand("tv_replaydir \"demos/%s\"", g_sPeriodo);
	LogMessage("[Demos] Demos indo para: demos/%s", g_sPeriodo);

	if (!g_cvEnabled.BoolValue)
	{
		LogMessage("[Demos] lendas_demos_enabled=0 - nao vou gravar.");
		return;
	}

	CreateTimer(g_cvDelay.FloatValue, Timer_Gravar);
}

public void OnMapEnd()
{
	// Fecha o arquivo antes do mapa morrer: demo interrompida pela troca de
	// mapa sem stoprecord costuma ficar truncada e nao abre no jogo.
	if (g_bGravando)
	{
		ServerCommand("tv_stoprecord");
		g_bGravando = false;
	}
}

public Action Timer_Gravar(Handle timer)
{
	if (!g_cvEnabled.BoolValue)
		return Plugin_Stop;

	if (g_cvTvEnable != null && !g_cvTvEnable.BoolValue)
	{
		LogError("[Demos] tv_enable esta 0 - o SourceTV nao esta ligado, nenhuma demo sera gravada.");
		return Plugin_Stop;
	}

	char mapa[PLATFORM_MAX_PATH];
	GetCurrentMap(mapa, sizeof(mapa));

	char mapaLimpo[PLATFORM_MAX_PATH];
	Lendas_Sanitizar(mapa, mapaLimpo, sizeof(mapaLimpo));

	char carimbo[32];
	FormatTime(carimbo, sizeof(carimbo), "%Y%m%d-%H%M");

	// Sempre para a anterior: tv_record recusa iniciar se ja houver uma
	// gravacao em andamento (e ai a demo deste mapa nunca existiria).
	ServerCommand("tv_stoprecord");
	ServerCommand("tv_record \"demos/%s/%s-%s\"", g_sPeriodo, carimbo, mapaLimpo);
	g_bGravando = true;

	LogMessage("[Demos] Gravando: demos/%s/%s-%s.dem", g_sPeriodo, carimbo, mapaLimpo);
	return Plugin_Stop;
}

/**
 * Mapas de workshop e nomes com "-", "." ou barra quebrariam o regex do
 * backend (e, no caso da barra, criariam subpasta). Tudo que nao for
 * [A-Za-z0-9_] vira "_".
 */
void Lendas_Sanitizar(const char[] entrada, char[] saida, int maxlen)
{
	int j = 0;
	for (int i = 0; entrada[i] != '\0' && j < maxlen - 1; i++)
	{
		int c = entrada[i];
		bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
			|| (c >= '0' && c <= '9') || c == '_';
		saida[j++] = ok ? c : '_';
	}
	saida[j] = '\0';
}
