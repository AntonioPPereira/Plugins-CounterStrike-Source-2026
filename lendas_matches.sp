/**
 * L.E.N.D.A.S. Matches
 *
 * Guarda cada partida ENCERRADA num JSON que o painel le por SFTP: mapa,
 * horarios, placar final, o resultado de cada round e o scoreboard (o Tab)
 * de todo mundo que jogou.
 *
 * POR QUE UM PLUGIN SEPARADO do lendas_live, se os dois escutam os mesmos
 * eventos: o lendas_live TRANSMITE (manda tudo pro backend por HTTP e o
 * backend so guarda em memoria — o Render hiberna e perde). Este aqui
 * PERSISTE no disco do proprio servidor de jogo. Separado, da pra carregar
 * e descarregar sem encostar no feed ao vivo, que ja funciona.
 *
 * O historico comeca no dia em que este plugin sobe. Partida antiga nao tem
 * como ser reconstruida: o HLstatsX nao guarda partida, e demo sem parser
 * nao da scoreboard. O painel precisa dizer isso, nao fingir que a lista
 * esta completa.
 *
 * O `id` e o mesmo formato do nome da demo (AAAAMMDD-HHMM-mapa), de
 * proposito: e assim que o backend casa a gravacao com a partida, sem
 * precisar de nenhum campo a mais dos dois lados.
 *
 * Compilar com o compiler do SourceMod 1.12 (mesma toolchain dos outros
 * plugins lendas_*).
 */

#pragma semicolon 1
#pragma newdecls required
#pragma dynamic 32768

#include <sourcemod>
#include <cstrike>

#define PLUGIN_VERSION "1.6.0"
#define ARQUIVO        "data/lendas_matches.json"

/** Quantas partidas o arquivo guarda. Mais que isso, a mais velha sai. */
#define MAX_PARTIDAS   100
#define MAX_ROUNDS     60
#define MAX_JOGADORES  64

#define NICK_MAX       64
/** Uma partida inteira cabe numa linha; ver Lendas_CopiarAnteriores. */
#define LINHA_MAX      8192
#define ID_MAX         24

enum struct Round
{
	int  numero;
	char vencedor[4];   // "CT" ou "T"
	char motivo[16];    // bomb | defuse | elimination | time | hostage
	int  ctScore;
	int  tScore;
}

enum struct Jogador
{
	char steamId64[ID_MAX];
	char nick[NICK_MAX];
	char time[4];       // CT | T | SPEC
	int  kills;
	int  deaths;
}

char   g_sMapa[64];
int    g_iInicio;                       // GetTime() no comeco do mapa
Round  g_aRounds[MAX_ROUNDS];
int    g_iNumRounds;

/**
 * Scoreboard acumulado do mapa inteiro, indexado por SteamID64.
 *
 * Nao da pra so ler os jogadores conectados no fim: quem saiu antes do
 * ultimo round sumiria do Tab, e ele jogou. Entao cada jogador e copiado
 * pra ca sempre que sai, e os conectados sao mesclados no fechamento.
 */
Jogador g_aJogadores[MAX_JOGADORES];
int     g_iNumJogadores;

/**
 * A partida em andamento comecou ANTES deste plugin carregar?
 *
 * Carregar no meio de um mapa (sm plugins load) nao dispara OnMapStart,
 * entao nao sabemos o mapa, nem a hora de inicio, nem os rounds ja jogados,
 * nem quem ja saiu. Gravar assim produziria uma partida pela metade
 * parecendo inteira — e um id quebrado (mapa vazio, data de 1970) que
 * ficaria no arquivo pra sempre. Esta partida e descartada; a proxima, que
 * comeca com o plugin ja de pe, e gravada normalmente.
 */
bool g_bParcial;

/**
 * Placar dos times no INICIO do mapa. Quase sempre 0, mas nao sempre: com
 * restart do mix o contador do servidor vem acumulado, e sem esta linha de
 * base a partida herdaria o placar da anterior.
 */
int g_iCtInicial;
int g_iTInicial;

/** Soma do placar no ultimo round visto — cair significa restart. */
int g_iUltimoTotal;

public Plugin myinfo =
{
	name        = "L.E.N.D.A.S. Matches",
	author      = "L.E.N.D.A.S.",
	description = "Persiste placar, rounds e scoreboard de cada partida encerrada",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	CreateConVar("lendas_matches_version", PLUGIN_VERSION, "Versao do plugin",
		FCVAR_NOTIFY | FCVAR_DONTRECORD);

	HookEvent("round_end", Evento_RoundEnd);
	// Quem sai leva o placar dele junto; sem isso o Tab perderia essa pessoa.
	HookEvent("player_disconnect", Evento_PlayerDisconnect, EventHookMode_Pre);

	// Carga tardia: ha um mapa rodando que este plugin nao viu comecar.
	g_bParcial = true;
	LogMessage("[Matches] carregado no meio de um mapa — esta partida nao sera gravada; a proxima sim.");
}

public void OnMapStart()
{
	GetCurrentMap(g_sMapa, sizeof(g_sMapa));
	g_iInicio        = GetTime();
	g_iNumRounds     = 0;
	g_iNumJogadores  = 0;
	// Vimos este mapa comecar: daqui pra frente o registro e completo.
	g_bParcial       = false;
	g_iCtInicial     = CS_GetTeamScore(CS_TEAM_CT);
	g_iTInicial      = CS_GetTeamScore(CS_TEAM_T);
	g_iUltimoTotal   = g_iCtInicial + g_iTInicial;
}

public void OnMapEnd()
{
	Lendas_FecharPartida();
}

/* ---------------------------------------------------------------- *
 * Coleta
 * ---------------------------------------------------------------- */

public void Evento_RoundEnd(Event evento, const char[] nome, bool naoBroadcast)
{
	if (g_iNumRounds >= MAX_ROUNDS)
		return;

	int vencedor = evento.GetInt("winner");
	// Round anulado (empate tecnico, troca de lado) nao entra: nao houve
	// vitoria de ninguem, e registrar como round mentiria no historico.
	if (vencedor != CS_TEAM_CT && vencedor != CS_TEAM_T)
		return;

	int ct = CS_GetTeamScore(CS_TEAM_CT);
	int t  = CS_GetTeamScore(CS_TEAM_T);

	/**
	 * RESTART detectado: o placar do servidor DIMINUIU.
	 *
	 * Num mix isso acontece o tempo todo — knife round, mp_restartgame,
	 * reinicio pedido pelos times. O servidor joga o placar fora, mas o
	 * contador de rodadas daqui continuava somando, e o resultado era um
	 * registro que se contradizia: placar 1x14 com 26 rodadas desenhadas,
	 * a maioria vencida pelo lado que aparecia com 1 ponto.
	 *
	 * As rodadas de antes do restart nao valem mais nada pro servidor, entao
	 * tambem nao valem aqui. Zerar as duas coisas juntas mantem placar e
	 * linha do tempo contando a MESMA partida.
	 */
	if (ct + t < g_iUltimoTotal)
	{
		g_iNumRounds = 0;
		g_iCtInicial = 0;
		g_iTInicial  = 0;
	}
	g_iUltimoTotal = ct + t;

	g_aRounds[g_iNumRounds].numero  = g_iNumRounds + 1;
	g_aRounds[g_iNumRounds].ctScore = ct;
	g_aRounds[g_iNumRounds].tScore  = t;
	strcopy(g_aRounds[g_iNumRounds].vencedor, 4, vencedor == CS_TEAM_CT ? "CT" : "T");

	Lendas_MotivoDoRound(evento.GetInt("reason"), g_aRounds[g_iNumRounds].motivo, 16);
	g_iNumRounds++;
}

/**
 * Traduz o `reason` do evento pro mesmo vocabulario que o painel ja usa
 * (`RoundEndReason` em painel/src/data/types.ts). Motivo desconhecido vira
 * "elimination", que e o desfecho mais comum — e nunca uma string crua que
 * o frontend nao saberia desenhar.
 */
void Lendas_MotivoDoRound(int reason, char[] saida, int maxlen)
{
	switch (reason)
	{
		case CSRoundEnd_TargetBombed:        strcopy(saida, maxlen, "bomb");
		case CSRoundEnd_BombDefused:         strcopy(saida, maxlen, "defuse");
		case CSRoundEnd_CTWin:               strcopy(saida, maxlen, "elimination");
		case CSRoundEnd_TerroristWin:        strcopy(saida, maxlen, "elimination");
		case CSRoundEnd_TargetSaved:         strcopy(saida, maxlen, "time");
		case CSRoundEnd_HostagesRescued:     strcopy(saida, maxlen, "hostage");
		case CSRoundEnd_HostagesNotRescued:  strcopy(saida, maxlen, "time");
		case CSRoundEnd_GameStart:           strcopy(saida, maxlen, "time");
		default:                             strcopy(saida, maxlen, "elimination");
	}
}

public void Evento_PlayerDisconnect(Event evento, const char[] nome, bool naoBroadcast)
{
	int client = GetClientOfUserId(evento.GetInt("userid"));
	if (client > 0)
		Lendas_GuardarJogador(client);
}

/** Copia o estado atual do jogador pro acumulado, criando ou atualizando. */
void Lendas_GuardarJogador(int client)
{
	if (!IsClientInGame(client) || IsFakeClient(client))
		return;

	char id[ID_MAX];
	if (!GetClientAuthId(client, AuthId_SteamID64, id, sizeof(id)))
		return;

	int pos = -1;
	for (int i = 0; i < g_iNumJogadores; i++)
	{
		if (StrEqual(g_aJogadores[i].steamId64, id))
		{
			pos = i;
			break;
		}
	}
	if (pos == -1)
	{
		if (g_iNumJogadores >= MAX_JOGADORES)
			return;
		pos = g_iNumJogadores++;
		strcopy(g_aJogadores[pos].steamId64, ID_MAX, id);
	}

	GetClientName(client, g_aJogadores[pos].nick, NICK_MAX);
	Lendas_NomeDoTime(GetClientTeam(client), g_aJogadores[pos].time, 4);
	/**
	 * So abates e mortes: e o que o Tab do CS:S de fato tem. Assistencias e
	 * MVP sao netprops do CS:GO (`m_iAssists`, `m_iMVPs`) e nao existem
	 * nesta engine — exportar as duas daria uma coluna de zeros, que e dado
	 * inventado com outro nome.
	 */
	g_aJogadores[pos].kills  = GetClientFrags(client);
	g_aJogadores[pos].deaths = GetClientDeaths(client);
}

void Lendas_NomeDoTime(int team, char[] saida, int maxlen)
{
	if (team == CS_TEAM_CT)      strcopy(saida, maxlen, "CT");
	else if (team == CS_TEAM_T)  strcopy(saida, maxlen, "T");
	else                         strcopy(saida, maxlen, "SPEC");
}

/* ---------------------------------------------------------------- *
 * Fechamento e persistencia
 * ---------------------------------------------------------------- */

void Lendas_FecharPartida()
{
	// Partida que ja estava em andamento quando o plugin subiu: ver g_bParcial.
	if (g_bParcial)
	{
		LogMessage("[Matches] mapa encerrado, mas comecou antes do plugin — nao gravado.");
		return;
	}

	// Mapa que ninguem jogou nao vira partida: warmup vazio, troca rapida,
	// servidor reiniciando. Sem round nao ha placar pra contar.
	if (g_iNumRounds == 0)
		return;

	// Quem ainda esta no servidor entra agora, com o numero final.
	for (int client = 1; client <= MaxClients; client++)
		if (IsClientInGame(client))
			Lendas_GuardarJogador(client);

	if (g_iNumJogadores == 0)
		return;

	/**
	 * O placar da partida e a DIFERENCA desde o comeco do mapa, nao o valor
	 * cru de `CS_GetTeamScore`.
	 *
	 * Motivo: o contador de time do servidor nem sempre zera na troca de
	 * mapa — com restart do mix, ou quando o plugin entra e o mapa recomeca,
	 * ele vem acumulado. Em 2026-08-31 isso gravou "14x12 com 2 rounds",
	 * numeros que nao existem juntos.
	 *
	 * Uma tentativa anterior usou a invariante "soma dos placares == rounds
	 * contados" pra detectar isso, e estava ERRADA: num servidor de mix o
	 * knife round e os restarts fazem a conta nao fechar mesmo em partida
	 * legitima — ela rejeitou as tres partidas reais que existiam. Medir a
	 * diferenca resolve sem depender de nenhuma suposicao sobre o formato
	 * do jogo.
	 */
	int ctFinal = CS_GetTeamScore(CS_TEAM_CT) - g_iCtInicial;
	int tFinal  = CS_GetTeamScore(CS_TEAM_T) - g_iTInicial;
	if (ctFinal < 0) ctFinal = 0;
	if (tFinal < 0)  tFinal = 0;

	char destino[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, destino, sizeof(destino), ARQUIVO);
	char temp[PLATFORM_MAX_PATH];
	Format(temp, sizeof(temp), "%s.tmp", destino);

	File f = OpenFile(temp, "w");
	if (f == null)
	{
		LogError("[Matches] nao consegui escrever em %s", temp);
		return;
	}

	f.WriteLine("{\"version\":1,\"generatedAt\":%d,\"matches\":[", GetTime());
	Lendas_EscreverPartidaAtual(f, ctFinal, tFinal);

	/**
	 * As antigas sao COPIADAS DIRETO do arquivo velho pro novo, uma linha
	 * por vez, sem passar por um array intermediario.
	 *
	 * A 1.2.0 carregava tudo num `char[100][2048]` e isso quebrou de duas
	 * formas: uma partida com 33 rounds passa de 2800 caracteres, entao o
	 * ReadLine cortava a linha no meio de uma string JSON (o resto virava
	 * uma "linha" nova e o arquivo saia invalido — "Bad control character
	 * in string literal"); e 100 x 2048 sao 200 KB parados so pra copiar
	 * texto de um arquivo pro outro.
	 *
	 * Em fluxo, o unico limite e o buffer de UMA linha, e ele pode ser
	 * generoso sem custar nada.
	 */
	int copiadas = Lendas_CopiarAnteriores(destino, f);
	f.WriteLine("]}");
	delete f;

	DeleteFile(destino);
	if (!RenameFile(destino, temp))
	{
		LogError("[Matches] falha ao renomear %s -> %s", temp, destino);
		return;
	}

	LogMessage("[Matches] partida gravada: %s, %d rounds, %d jogadores (+%d no historico).",
		g_sMapa, g_iNumRounds, g_iNumJogadores, copiadas);
}

/**
 * Escreve a partida em UMA LINHA SO.
 *
 * Isto nao e estetica: `Lendas_LerPartidasAnteriores` recupera o historico
 * lendo o arquivo linha a linha, uma partida por linha. A versao 1.1.0
 * escrevia cada round e cada jogador na sua propria linha, entao na SEGUNDA
 * gravacao o leitor tratou cada uma dessas ~40 linhas como se fosse uma
 * partida e devolveu todas com virgula na frente — o arquivo virou JSON
 * invalido (`"rounds":[ ,{...}` e `,],"players":[`) e o backend nao
 * conseguia ler nada.
 *
 * `WriteString(..., false)` escreve sem quebra de linha; o `WriteLine("")`
 * no fim e o unico que termina a linha.
 */
void Lendas_EscreverPartidaAtual(File f, int ct, int t)
{

	char id[64];
	Lendas_MontarId(id, sizeof(id));

	char mapaEsc[128];
	Lendas_JsonEscape(g_sMapa, mapaEsc, sizeof(mapaEsc));

	char parte[512];
	Format(parte, sizeof(parte),
		"{\"id\":\"%s\",\"map\":\"%s\",\"startedAt\":%d,\"endedAt\":%d,\"ctScore\":%d,\"tScore\":%d,\"rounds\":[",
		id, mapaEsc, g_iInicio, GetTime(), ct, t);
	f.WriteString(parte, false);

	for (int i = 0; i < g_iNumRounds; i++)
	{
		Format(parte, sizeof(parte), "%s{\"n\":%d,\"winner\":\"%s\",\"reason\":\"%s\",\"ct\":%d,\"t\":%d}",
			i == 0 ? "" : ",",
			g_aRounds[i].numero, g_aRounds[i].vencedor, g_aRounds[i].motivo,
			g_aRounds[i].ctScore, g_aRounds[i].tScore);
		f.WriteString(parte, false);
	}

	f.WriteString("],\"players\":[", false);

	char nickEsc[NICK_MAX * 2];
	for (int i = 0; i < g_iNumJogadores; i++)
	{
		Lendas_JsonEscape(g_aJogadores[i].nick, nickEsc, sizeof(nickEsc));
		Format(parte, sizeof(parte),
			"%s{\"steamId64\":\"%s\",\"name\":\"%s\",\"team\":\"%s\",\"kills\":%d,\"deaths\":%d}",
			i == 0 ? "" : ",",
			g_aJogadores[i].steamId64, nickEsc, g_aJogadores[i].time,
			g_aJogadores[i].kills, g_aJogadores[i].deaths);
		f.WriteString(parte, false);
	}

	// O unico que quebra a linha: daqui pra frente e outra partida.
	f.WriteLine("]}");
}

/**
 * MESMO formato do nome da demo (AAAAMMDD-HHMM-mapa), porque e por ele que
 * o backend casa gravacao com partida. Muda aqui, quebra o vinculo la.
 */
void Lendas_MontarId(char[] saida, int maxlen)
{
	char data[32];
	FormatTime(data, sizeof(data), "%Y%m%d-%H%M", g_iInicio);

	char mapaLimpo[64];
	Lendas_Sanitizar(g_sMapa, mapaLimpo, sizeof(mapaLimpo));
	Format(saida, maxlen, "%s-%s", data, mapaLimpo);
}

/** O backend so aceita [A-Za-z0-9_] no nome do mapa (ver lib/demoId.ts). */
void Lendas_Sanitizar(const char[] entrada, char[] saida, int maxlen)
{
	int j = 0;
	for (int i = 0; entrada[i] != '\0' && j < maxlen - 1; i++)
	{
		int c = entrada[i];
		bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
			|| (c >= '0' && c <= '9') || c == '_';
		if (ok)
			saida[j++] = c;
	}
	saida[j] = '\0';
}

/**
 * Copia as partidas ja gravadas do arquivo antigo pro novo, em fluxo.
 *
 * Parsing deliberadamente burro, e agora ele CASA com o escritor: a 1.2.0
 * em diante grava exatamente uma partida por linha, entao basta repassar as
 * linhas entre `"matches":[` e o `]}` final, tirando a virgula da frente.
 * Um parser de JSON de verdade em SourcePawn custaria muito mais do que o
 * problema pede.
 *
 * Devolve quantas foram copiadas.
 */
int Lendas_CopiarAnteriores(const char[] caminho, File saida)
{
	File origem = OpenFile(caminho, "r");
	if (origem == null)
		return 0;

	int copiadas = 0;
	// Folgado de proposito: uma partida de 33 rounds com 10 jogadores passa
	// de 3 KB, e cortar a linha aqui e o que corrompeu o arquivo na 1.2.0.
	char linha[LINHA_MAX];
	bool dentro = false;

	while (!origem.EndOfFile() && origem.ReadLine(linha, sizeof(linha)))
	{
		TrimString(linha);
		if (!dentro)
		{
			if (StrContains(linha, "\"matches\":[") != -1)
				dentro = true;
			continue;
		}
		if (StrEqual(linha, "]}") || strlen(linha) < 2)
			continue;
		if (copiadas >= MAX_PARTIDAS - 1)
			break;

		int inicio = linha[0] == ',' ? 1 : 0;
		saida.WriteLine(",%s", linha[inicio]);
		copiadas++;
	}

	delete origem;
	return copiadas;
}

void Lendas_JsonEscape(const char[] entrada, char[] saida, int maxlen)
{
	int j = 0;
	for (int i = 0; entrada[i] != '\0' && j < maxlen - 2; i++)
	{
		int c = entrada[i];
		if (c == '"' || c == '\\')
		{
			saida[j++] = '\\';
			saida[j++] = c;
		}
		else if (c >= 32)
		{
			saida[j++] = c;
		}
	}
	saida[j] = '\0';
}
