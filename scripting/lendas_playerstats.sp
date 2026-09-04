#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION "1.0.0"
#define ARQUIVO "data/lendas_playerstats.json"
#define ID_MAX 32
#define NICK_MAX 64
#define CHAVE_MAX 128

/**
 * lendas_playerstats
 *
 * Conta, por jogador, o que o HLstatsX desta rede não entrega: abates com
 * cada arma, headshots, bombas plantadas e desarmadas.
 *
 * Por que não sai do HLstatsX: o `mode=playerinfo` desta instalação trava
 * pra qualquer jogador com avatar Steam real, e a página de prêmios está
 * vazia porque o cron de awards não roda. Ou seja, os pódios por arma
 * simplesmente não existem pra serem lidos — só contando aqui.
 *
 * Consequência honesta: os números começam do zero na instalação. Isto NÃO
 * é o histórico do servidor; é o que foi contado desde que o plugin subiu.
 * O site precisa dizer isso, e o campo `since` existe pra isso.
 *
 * Armazenamento: um StringMap achatado, chave "steamid64|campo", onde campo
 * é o código da arma ou um contador especial (`_hs`, `_plant`, `_defuse`).
 * Mapa aninhado seria mais bonito e bem mais chato de liberar sem vazar
 * handle — achatar mantém tudo num Handle só.
 */
public Plugin myinfo =
{
	name = "[LENDAS] Player Stats",
	author = "LENDAS",
	description = "Conta abates por arma, headshots e bombas por jogador",
	version = PLUGIN_VERSION,
	url = "",
};

ConVar g_cvEnabled;
ConVar g_cvInterval;

StringMap g_hContadores;
StringMap g_hNomes;
bool g_bSujo;
/** Unix time em que a contagem começou — vai pro JSON e o site exibe. */
int g_iDesde;

public void OnPluginStart()
{
	CreateConVar("lendas_playerstats_version", PLUGIN_VERSION, "Versao do plugin",
		FCVAR_NOTIFY | FCVAR_DONTRECORD);

	g_cvEnabled = CreateConVar("lendas_playerstats_enabled", "1",
		"1 = conta abates por arma, headshots e bombas por jogador.", _, true, 0.0, true, 1.0);

	g_cvInterval = CreateConVar("lendas_playerstats_interval", "120.0",
		"Segundos entre gravacoes do JSON que o site le.", _, true, 30.0, true, 900.0);

	AutoExecConfig(true, "lendas_playerstats");

	g_hContadores = new StringMap();
	g_hNomes = new StringMap();
	g_iDesde = GetTime();
	Lendas_Carregar();

	HookEvent("player_death", Evt_Morte);
	HookEvent("bomb_planted", Evt_Plantou);
	HookEvent("bomb_defused", Evt_Desarmou);

	CreateTimer(g_cvInterval.FloatValue, Timer_Gravar, _, TIMER_REPEAT);

	RegAdminCmd("sm_lendas_stats_flush", Cmd_Flush, ADMFLAG_ROOT,
		"Grava agora o JSON de estatisticas por jogador.");
}

public void OnMapEnd()
{
	Lendas_Gravar();
}

public Action Cmd_Flush(int client, int args)
{
	Lendas_Gravar();
	ReplyToCommand(client, "[LENDAS] estatisticas gravadas.");
	return Plugin_Handled;
}

public Action Timer_Gravar(Handle t)
{
	Lendas_Gravar();
	return Plugin_Continue;
}

/* ---------------------------------------------------------------- *
 * Eventos
 * ---------------------------------------------------------------- */

public void Evt_Morte(Event evento, const char[] nome, bool naoTransmitir)
{
	if (!g_cvEnabled.BoolValue)
		return;

	int assassino = GetClientOfUserId(evento.GetInt("attacker"));
	int vitima = GetClientOfUserId(evento.GetInt("userid"));

	// Sem atacante (queda, mundo) ou suicídio não contam como abate.
	if (assassino <= 0 || assassino == vitima || !IsClientInGame(assassino) || IsFakeClient(assassino))
		return;

	/**
	 * Fogo amigo não vira abate: num MIX o placar do HLstatsX já desconta,
	 * e contar aqui deixaria o pódio de arma inflado por acidente.
	 */
	if (vitima > 0 && IsClientInGame(vitima) && GetClientTeam(assassino) == GetClientTeam(vitima))
		return;

	char id[ID_MAX];
	if (!Lendas_Id(assassino, id, sizeof(id)))
		return;

	char arma[32];
	evento.GetString("weapon", arma, sizeof(arma));
	Lendas_LimparArma(arma, sizeof(arma));
	if (arma[0] == '\0')
		return;

	Lendas_Somar(id, arma, 1);
	if (evento.GetBool("headshot"))
		Lendas_Somar(id, "_hs", 1);
}

public void Evt_Plantou(Event evento, const char[] nome, bool naoTransmitir)
{
	Lendas_ContarAcao(evento, "_plant");
}

public void Evt_Desarmou(Event evento, const char[] nome, bool naoTransmitir)
{
	Lendas_ContarAcao(evento, "_defuse");
}

void Lendas_ContarAcao(Event evento, const char[] campo)
{
	if (!g_cvEnabled.BoolValue)
		return;
	int client = GetClientOfUserId(evento.GetInt("userid"));
	if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
		return;

	char id[ID_MAX];
	if (Lendas_Id(client, id, sizeof(id)))
		Lendas_Somar(id, campo, 1);
}

/* ---------------------------------------------------------------- *
 * Acumulação
 * ---------------------------------------------------------------- */

/** Pega o SteamID64 e, de quebra, mantém o nick atual pra exibição. */
bool Lendas_Id(int client, char[] id, int maxlen)
{
	if (!GetClientAuthId(client, AuthId_SteamID64, id, maxlen))
		return false;

	char nick[NICK_MAX];
	if (GetClientName(client, nick, sizeof(nick)))
		g_hNomes.SetString(id, nick);
	return true;
}

void Lendas_Somar(const char[] id, const char[] campo, int quanto)
{
	char chave[CHAVE_MAX];
	Format(chave, sizeof(chave), "%s|%s", id, campo);

	int atual = 0;
	g_hContadores.GetValue(chave, atual);
	g_hContadores.SetValue(chave, atual + quanto);
	g_bSujo = true;
}

/**
 * O evento manda "weapon_ak47" em alguns casos e "ak47" em outros, e o
 * HLstatsX usa a forma curta — normalizar aqui deixa o site cruzar as duas
 * fontes pelo mesmo código. Também barra caractere fora de [a-z0-9_], que
 * quebraria a chave achatada (o separador é "|").
 */
void Lendas_LimparArma(char[] arma, int maxlen)
{
	if (StrContains(arma, "weapon_") == 0)
		strcopy(arma, maxlen, arma[7]);

	int j = 0;
	for (int i = 0; arma[i] != '\0'; i++)
	{
		int c = arma[i];
		if (c >= 'A' && c <= 'Z')
			c += 32;
		if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_')
			arma[j++] = c;
	}
	arma[j] = '\0';
}

/* ---------------------------------------------------------------- *
 * Persistência
 * ---------------------------------------------------------------- */

void Lendas_Gravar()
{
	if (!g_bSujo || g_hContadores == null)
		return;

	char destino[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, destino, sizeof(destino), ARQUIVO);
	char temp[PLATFORM_MAX_PATH];
	Format(temp, sizeof(temp), "%s.tmp", destino);

	File f = OpenFile(temp, "w");
	if (f == null)
	{
		LogError("[PlayerStats] nao consegui escrever em %s", temp);
		return;
	}

	f.WriteLine("{\"generatedAt\":%d,\"since\":%d,\"players\":[", GetTime(), g_iDesde);

	// Um jogador por linha: percorre os nomes (um por jogador) e, pra cada
	// um, varre os contadores procurando as chaves dele.
	StringMapSnapshot nomes = g_hNomes.Snapshot();
	StringMapSnapshot chaves = g_hContadores.Snapshot();

	char id[ID_MAX], nick[NICK_MAX], nickEsc[NICK_MAX * 2];
	char chave[CHAVE_MAX], prefixo[CHAVE_MAX];
	int escritos = 0;

	for (int i = 0; i < nomes.Length; i++)
	{
		nomes.GetKey(i, id, sizeof(id));
		if (!g_hNomes.GetString(id, nick, sizeof(nick)))
			continue;

		Format(prefixo, sizeof(prefixo), "%s|", id);
		int tamPrefixo = strlen(prefixo);

		char campos[1024];
		campos[0] = '\0';
		int hs = 0, plant = 0, defuse = 0, totalKills = 0;
		int nArmas = 0;

		for (int k = 0; k < chaves.Length; k++)
		{
			chaves.GetKey(k, chave, sizeof(chave));
			if (strncmp(chave, prefixo, tamPrefixo) != 0)
				continue;

			int valor = 0;
			if (!g_hContadores.GetValue(chave, valor) || valor <= 0)
				continue;

			char campo[64];
			strcopy(campo, sizeof(campo), chave[tamPrefixo]);

			if (StrEqual(campo, "_hs")) { hs = valor; continue; }
			if (StrEqual(campo, "_plant")) { plant = valor; continue; }
			if (StrEqual(campo, "_defuse")) { defuse = valor; continue; }

			char parte[96];
			Format(parte, sizeof(parte), "%s\"%s\":%d", nArmas == 0 ? "" : ",", campo, valor);
			StrCat(campos, sizeof(campos), parte);
			totalKills += valor;
			nArmas++;
		}

		// Jogador que só conectou e não fez nada não polui o arquivo.
		if (nArmas == 0 && hs == 0 && plant == 0 && defuse == 0)
			continue;

		Lendas_JsonEscape(nick, nickEsc, sizeof(nickEsc));
		f.WriteLine("%s{\"id\":\"%s\",\"name\":\"%s\",\"kills\":%d,\"hs\":%d,\"plants\":%d,\"defuses\":%d,\"weapons\":{%s}}",
			escritos == 0 ? "" : ",", id, nickEsc, totalKills, hs, plant, defuse, campos);
		escritos++;
	}

	delete nomes;
	delete chaves;

	f.WriteLine("]}");
	delete f;

	DeleteFile(destino);
	if (!RenameFile(destino, temp))
	{
		LogError("[PlayerStats] falha ao renomear %s -> %s", temp, destino);
		return;
	}

	g_bSujo = false;
	LogMessage("[PlayerStats] %d jogador(es) gravados em addons/sourcemod/%s", escritos, ARQUIVO);
}

/**
 * Relê o arquivo pra continuar somando de onde parou — sem isso, cada
 * reinício do servidor zeraria os pódios. Parser mínimo: o formato é sempre
 * o que este mesmo plugin escreveu, uma linha por jogador.
 */
void Lendas_Carregar()
{
	char origem[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, origem, sizeof(origem), ARQUIVO);

	File f = OpenFile(origem, "r");
	if (f == null)
	{
		LogMessage("[PlayerStats] sem arquivo anterior — contagem comeca agora.");
		return;
	}

	char linha[2048];
	int lidos = 0;
	while (f.ReadLine(linha, sizeof(linha)))
	{
		// Preserva o início real da contagem, senão o site mostraria a data errada.
		int posSince = StrContains(linha, "\"since\":");
		if (posSince != -1)
		{
			int valor = StringToInt(linha[posSince + 8]);
			if (valor > 0)
				g_iDesde = valor;
		}

		int posId = StrContains(linha, "\"id\":\"");
		if (posId == -1)
			continue;

		char id[ID_MAX];
		int j = 0;
		for (int i = posId + 6; linha[i] != '\0' && linha[i] != '"' && j < ID_MAX - 1; i++)
			id[j++] = linha[i];
		id[j] = '\0';
		if (strlen(id) < 17)
			continue;

		int posNome = StrContains(linha, "\"name\":\"");
		if (posNome != -1)
		{
			char nick[NICK_MAX];
			j = 0;
			for (int i = posNome + 8; linha[i] != '\0' && j < NICK_MAX - 1; i++)
			{
				if (linha[i] == '\\' && linha[i + 1] != '\0') { nick[j++] = linha[++i]; continue; }
				if (linha[i] == '"') break;
				nick[j++] = linha[i];
			}
			nick[j] = '\0';
			if (nick[0] != '\0')
				g_hNomes.SetString(id, nick);
		}

		Lendas_LerInt(linha, "\"hs\":", id, "_hs");
		Lendas_LerInt(linha, "\"plants\":", id, "_plant");
		Lendas_LerInt(linha, "\"defuses\":", id, "_defuse");
		Lendas_LerArmas(linha, id);
		lidos++;
	}
	delete f;
	LogMessage("[PlayerStats] %d jogador(es) carregados; contagem desde %d.", lidos, g_iDesde);
}

void Lendas_LerInt(const char[] linha, const char[] rotulo, const char[] id, const char[] campo)
{
	int pos = StrContains(linha, rotulo);
	if (pos == -1)
		return;
	int valor = StringToInt(linha[pos + strlen(rotulo)]);
	if (valor > 0)
		Lendas_Somar(id, campo, valor);
}

/** Lê o objeto {"ak47":50,"awp":20} de volta pros contadores. */
void Lendas_LerArmas(const char[] linha, const char[] id)
{
	int pos = StrContains(linha, "\"weapons\":{");
	if (pos == -1)
		return;

	int i = pos + 11;
	while (linha[i] != '\0' && linha[i] != '}')
	{
		if (linha[i] != '"') { i++; continue; }

		char arma[64];
		int j = 0;
		for (i++; linha[i] != '\0' && linha[i] != '"' && j < 63; i++)
			arma[j++] = linha[i];
		arma[j] = '\0';

		while (linha[i] != '\0' && linha[i] != ':') i++;
		if (linha[i] == '\0') break;

		int valor = StringToInt(linha[i + 1]);
		if (arma[0] != '\0' && valor > 0)
			Lendas_Somar(id, arma, valor);

		while (linha[i] != '\0' && linha[i] != ',' && linha[i] != '}') i++;
		if (linha[i] == ',') i++;
	}
}

void Lendas_JsonEscape(const char[] entrada, char[] saida, int maxlen)
{
	int j = 0;
	for (int i = 0; entrada[i] != '\0' && j < maxlen - 7; i++)
	{
		int c = entrada[i];
		if (c == '"' || c == '\\') { saida[j++] = '\\'; saida[j++] = c; }
		else if (c >= 0 && c < 32) { /* controle: descarta */ }
		else saida[j++] = c;
	}
	saida[j] = '\0';
}
