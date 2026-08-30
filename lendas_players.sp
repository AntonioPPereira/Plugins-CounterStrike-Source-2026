#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION "1.0.0"
#define ARQUIVO "data/lendas_players.json"
#define NICK_MAX 64
#define ID_MAX 32

/**
 * lendas_players
 *
 * Mantém um índice `nick -> SteamID64` num JSON dentro do servidor, que o
 * backend lê por SFTP pra descobrir quem é quem no ranking.
 *
 * Por que isso existe: o ranking do site vem do HLstatsX, que expõe só o
 * nick — nunca o SteamID (auditado, não é falta de tentar). Sem SteamID não
 * há como buscar o avatar real na Steam, e todo mundo fica com o emblema
 * gerado. O servidor de jogo, por outro lado, conhece o SteamID de cada
 * jogador que entra. Este plugin só registra esse par.
 *
 * O índice é CUMULATIVO: carrega o arquivo existente ao subir e só
 * acrescenta. Um jogador que não entra há meses continua no índice, que é
 * justamente o caso que interessa (ele ainda aparece no ranking histórico).
 *
 * Não guarda nada além de nick e SteamID64 — nem IP, nem horário, nem
 * qualquer coisa que o site não vá usar.
 */
public Plugin myinfo =
{
	name = "[LENDAS] Player Directory",
	author = "LENDAS",
	description = "Índice nick -> SteamID64 pro site resolver avatares reais",
	version = PLUGIN_VERSION,
	url = "",
};

ConVar g_cvEnabled;

StringMap g_hIndice;
/** Só grava quando algo mudou de verdade — evita reescrever o arquivo à toa. */
bool g_bSujo;

public void OnPluginStart()
{
	CreateConVar("lendas_players_version", PLUGIN_VERSION, "Versao do plugin",
		FCVAR_NOTIFY | FCVAR_DONTRECORD);

	g_cvEnabled = CreateConVar("lendas_players_enabled", "1",
		"1 = mantem o indice nick -> SteamID64 que o site usa pra achar avatares.",
		_, true, 0.0, true, 1.0);

	AutoExecConfig(true, "lendas_players");

	g_hIndice = new StringMap();
	Lendas_Carregar();

	// Grava no máximo a cada 60s, e só se houver mudança.
	CreateTimer(60.0, Timer_Gravar, _, TIMER_REPEAT);
}

public void OnMapEnd()
{
	// Última chance antes da troca de mapa levar o que ainda não foi gravado.
	Lendas_Gravar();
}

public void OnClientPostAdminCheck(int client)
{
	if (!g_cvEnabled.BoolValue || IsFakeClient(client))
		return;

	char id[ID_MAX];
	if (!GetClientAuthId(client, AuthId_SteamID64, id, sizeof(id)))
		return;

	char nick[NICK_MAX];
	if (!GetClientName(client, nick, sizeof(nick)))
		return;

	Lendas_Registrar(nick, id);
}

void Lendas_Registrar(const char[] nick, const char[] id)
{
	char limpo[NICK_MAX];
	strcopy(limpo, sizeof(limpo), nick);
	TrimString(limpo);
	if (limpo[0] == '\0')
		return;

	char atual[ID_MAX];
	if (g_hIndice.GetString(limpo, atual, sizeof(atual)) && StrEqual(atual, id))
		return; // já conhecido, nada mudou

	/**
	 * Quem trocou de nick fica no índice com os dois — o ranking do HLstatsX
	 * pode estar mostrando o nick antigo, e perder esse vínculo tiraria o
	 * avatar de quem já tinha.
	 */
	g_hIndice.SetString(limpo, id);
	g_bSujo = true;
}

public Action Timer_Gravar(Handle t)
{
	Lendas_Gravar();
	return Plugin_Continue;
}

void Lendas_Gravar()
{
	if (!g_bSujo || g_hIndice == null)
		return;

	char destino[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, destino, sizeof(destino), ARQUIVO);

	// Grava em temporário e renomeia: se o backend ler no meio da escrita,
	// pega o arquivo anterior inteiro em vez de um JSON cortado.
	char temp[PLATFORM_MAX_PATH];
	Format(temp, sizeof(temp), "%s.tmp", destino);

	File f = OpenFile(temp, "w");
	if (f == null)
	{
		LogError("[Players] nao consegui escrever em %s", temp);
		return;
	}

	f.WriteLine("{\"generatedAt\":%d,\"players\":{", GetTime());

	StringMapSnapshot snap = g_hIndice.Snapshot();
	char nick[NICK_MAX], id[ID_MAX], nickEsc[NICK_MAX * 2];
	int n = 0;
	for (int i = 0; i < snap.Length; i++)
	{
		snap.GetKey(i, nick, sizeof(nick));
		if (!g_hIndice.GetString(nick, id, sizeof(id)))
			continue;
		Lendas_JsonEscape(nick, nickEsc, sizeof(nickEsc));
		f.WriteLine("%s\"%s\":\"%s\"", n == 0 ? "" : ",", nickEsc, id);
		n++;
	}
	delete snap;

	f.WriteLine("}}");
	delete f;

	DeleteFile(destino);
	if (!RenameFile(destino, temp))
	{
		LogError("[Players] falha ao renomear %s -> %s", temp, destino);
		return;
	}

	g_bSujo = false;
	LogMessage("[Players] indice gravado: %d jogador(es) em addons/sourcemod/%s", n, ARQUIVO);
}

/**
 * Relê o arquivo pra continuar de onde parou. Um parser mínimo basta: o
 * formato é sempre `"nick":"id"` escrito por este mesmo plugin, uma entrada
 * por linha — não é JSON genérico vindo de fora.
 */
void Lendas_Carregar()
{
	char origem[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, origem, sizeof(origem), ARQUIVO);

	File f = OpenFile(origem, "r");
	if (f == null)
	{
		LogMessage("[Players] sem indice anterior — comecando do zero.");
		return;
	}

	char linha[NICK_MAX * 3];
	int n = 0;
	while (f.ReadLine(linha, sizeof(linha)))
	{
		int aspas1 = FindCharInString(linha, '"');
		if (aspas1 == -1)
			continue;

		// nick: entre o 1o e o 2o par de aspas (respeitando \" escapado)
		char nick[NICK_MAX];
		int j = 0, i = aspas1 + 1;
		bool fechou = false;
		for (; linha[i] != '\0' && j < NICK_MAX - 1; i++)
		{
			if (linha[i] == '\\' && linha[i + 1] != '\0')
			{
				nick[j++] = linha[++i];
				continue;
			}
			if (linha[i] == '"') { fechou = true; break; }
			nick[j++] = linha[i];
		}
		nick[j] = '\0';
		if (!fechou || nick[0] == '\0')
			continue;

		// id: primeira sequência de dígitos depois do nick
		char id[ID_MAX];
		int k = 0;
		for (; linha[i] != '\0' && k < ID_MAX - 1; i++)
		{
			if (linha[i] >= '0' && linha[i] <= '9')
				id[k++] = linha[i];
			else if (k > 0)
				break;
		}
		id[k] = '\0';
		if (k < 17)
			continue; // SteamID64 tem 17 dígitos; menos que isso não é um

		g_hIndice.SetString(nick, id);
		n++;
	}
	delete f;
	LogMessage("[Players] indice carregado: %d jogador(es).", n);
}

/** Escapa o mínimo que um JSON válido exige. */
void Lendas_JsonEscape(const char[] entrada, char[] saida, int maxlen)
{
	int j = 0;
	for (int i = 0; entrada[i] != '\0' && j < maxlen - 7; i++)
	{
		int c = entrada[i];
		if (c == '"' || c == '\\')
		{
			saida[j++] = '\\';
			saida[j++] = c;
		}
		else if (c >= 0 && c < 32)
		{
			// controle: descarta, não vale quebrar o JSON por ele
		}
		else
		{
			saida[j++] = c;
		}
	}
	saida[j] = '\0';
}
