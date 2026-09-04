#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION "1.0.0"
#define ARQUIVO "data/lendas_bans.json"

/**
 * lendas_bans
 *
 * Exporta os bans do SourceBans++ para um JSON dentro do proprio servidor,
 * que o backend do site le por SFTP.
 *
 * Por que assim e nao o backend falando direto com o MySQL: o usuario do
 * banco so aceita conexao vinda do proprio servidor de jogo, e o painel da
 * hospedagem nao expoe "Remote MySQL" pra liberar outros IPs. Este caminho
 * nao depende de liberacao nenhuma, nao expoe o banco na internet, e reusa
 * o mesmo transporte (SFTP) que o site ja usa pra demos e atividade.
 *
 * Tudo assincrono (SQL_TConnect/SQL_TQuery): nenhuma consulta bloqueia um
 * tick do servidor, mesmo se o MySQL estiver lento.
 *
 * NAO exporta IP cru: mascara os dois ultimos octetos aqui na origem, pra
 * que o endereco completo nunca saia do servidor de jogo.
 */
public Plugin myinfo =
{
	name = "[LENDAS] Bans Export",
	author = "LENDAS",
	description = "Exporta bans/mutes do SourceBans++ pra um JSON lido pelo site",
	version = PLUGIN_VERSION,
	url = "",
};

ConVar g_cvEnabled;
ConVar g_cvInterval;
ConVar g_cvLimit;

public void OnPluginStart()
{
	CreateConVar("lendas_bans_version", PLUGIN_VERSION, "Versao do plugin",
		FCVAR_NOTIFY | FCVAR_DONTRECORD);

	g_cvEnabled = CreateConVar("lendas_bans_enabled", "1",
		"1 = exporta os bans do SourceBans pro JSON que o site le.", _, true, 0.0, true, 1.0);

	g_cvInterval = CreateConVar("lendas_bans_interval", "300.0",
		"Segundos entre exportacoes. Ban novo demora ate esse tempo pra aparecer no site.",
		_, true, 30.0, true, 3600.0);

	g_cvLimit = CreateConVar("lendas_bans_limit", "1000",
		"Maximo de registros exportados (os mais recentes primeiro).",
		_, true, 50.0, true, 5000.0);

	AutoExecConfig(true, "lendas_bans");

	RegAdminCmd("sm_lendas_bans_export", Cmd_Exportar, ADMFLAG_ROOT,
		"Forca uma exportacao imediata dos bans pro JSON do site.");

	CreateTimer(10.0, Timer_Primeira);
	CreateTimer(g_cvInterval.FloatValue, Timer_Periodico, _, TIMER_REPEAT);
}

public Action Cmd_Exportar(int client, int args)
{
	Lendas_Exportar();
	ReplyToCommand(client, "[LENDAS] Exportacao de bans disparada — confira o log.");
	return Plugin_Handled;
}

public Action Timer_Primeira(Handle t)
{
	Lendas_Exportar();
	return Plugin_Stop;
}

public Action Timer_Periodico(Handle t)
{
	Lendas_Exportar();
	return Plugin_Continue;
}

void Lendas_Exportar()
{
	if (!g_cvEnabled.BoolValue)
		return;
	SQL_TConnect(OnConectado, "sourcebans");
}

public void OnConectado(Handle owner, Handle db, const char[] erro, any data)
{
	if (db == null)
	{
		LogError("[Bans] conexao com o banco falhou: %s", erro);
		return;
	}

	/**
	 * Sem isto, nick de admin ou de jogador com acento sai como byte solto
	 * (visto na pratica: "Kanga?eiroz"), o que quebra o JSON como UTF-8 do
	 * outro lado. Pedir utf8mb4 faz o proprio MySQL converter na saida.
	 */
	if (!SQL_SetCharset(db, "utf8mb4"))
		LogMessage("[Bans] aviso: SET NAMES utf8mb4 recusado, acentos podem sair errados.");

	/**
	 * Uma consulta so, unindo bans e mutes/gags. O LEFT JOIN garante que um
	 * ban feito pelo console (aid sem par em sb_admins) ou de um servidor
	 * removido ainda apareca — com o campo vazio, nunca sumindo da lista.
	 */
	char q[1400];
	Format(q, sizeof(q),
		"SELECT 'ban' AS k, b.bid, b.authid, b.name, b.created, b.ends, b.length, b.reason,"
		... " IFNULL(b.country,''), IFNULL(b.RemoveType,''), IFNULL(a.user,''),"
		... " IFNULL(CONCAT(s.ip,':',s.port),''), 0, IFNULL(b.ip,'')"
		... " FROM sb_bans b"
		... " LEFT JOIN sb_admins a ON a.aid = b.aid"
		... " LEFT JOIN sb_servers s ON s.sid = b.sid"
		... " UNION ALL"
		... " SELECT 'comm', c.bid, c.authid, c.name, c.created, c.ends, c.length, c.reason,"
		... " '', IFNULL(c.RemoveType,''), IFNULL(a.user,''),"
		... " IFNULL(CONCAT(s.ip,':',s.port),''), c.type, ''"
		... " FROM sb_comms c"
		... " LEFT JOIN sb_admins a ON a.aid = c.aid"
		... " LEFT JOIN sb_servers s ON s.sid = c.sid"
		... " ORDER BY created DESC LIMIT %d",
		g_cvLimit.IntValue);

	SQL_TQuery(db, OnConsulta, q);
}

public void OnConsulta(Handle owner, Handle rs, const char[] erro, any data)
{
	if (rs == null)
	{
		LogError("[Bans] consulta falhou: %s", erro);
		return;
	}

	char destino[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, destino, sizeof(destino), ARQUIVO);

	/**
	 * Escreve num temporario e so no fim renomeia pro nome definitivo: se o
	 * backend ler exatamente durante a exportacao, ele pega o arquivo antigo
	 * inteiro em vez de um JSON cortado no meio.
	 */
	char temp[PLATFORM_MAX_PATH];
	Format(temp, sizeof(temp), "%s.tmp", destino);

	File f = OpenFile(temp, "w");
	if (f == null)
	{
		LogError("[Bans] nao consegui escrever em %s", temp);
		return;
	}

	f.WriteLine("{\"generatedAt\":%d,\"items\":[", GetTime());

	int n = 0;
	char kind[8], authid[64], nome[128], razao[512], pais[8], removeType[8];
	char admin[64], servidor[80], ip[64];
	char nomeEsc[300], razaoEsc[1100], adminEsc[150];

	while (SQL_FetchRow(rs))
	{
		SQL_FetchString(rs, 0, kind, sizeof(kind));
		int bid = SQL_FetchInt(rs, 1);
		SQL_FetchString(rs, 2, authid, sizeof(authid));
		SQL_FetchString(rs, 3, nome, sizeof(nome));
		int criado = SQL_FetchInt(rs, 4);
		int termina = SQL_FetchInt(rs, 5);
		int duracao = SQL_FetchInt(rs, 6);
		SQL_FetchString(rs, 7, razao, sizeof(razao));
		SQL_FetchString(rs, 8, pais, sizeof(pais));
		SQL_FetchString(rs, 9, removeType, sizeof(removeType));
		SQL_FetchString(rs, 10, admin, sizeof(admin));
		SQL_FetchString(rs, 11, servidor, sizeof(servidor));
		int commType = SQL_FetchInt(rs, 12);
		SQL_FetchString(rs, 13, ip, sizeof(ip));

		char ipMasc[64];
		Lendas_MascararIp(ip, ipMasc, sizeof(ipMasc));

		Lendas_JsonEscape(nome, nomeEsc, sizeof(nomeEsc));
		Lendas_JsonEscape(razao, razaoEsc, sizeof(razaoEsc));
		Lendas_JsonEscape(admin, adminEsc, sizeof(adminEsc));

		f.WriteLine("%s{\"kind\":\"%s\",\"bid\":%d,\"authid\":\"%s\",\"name\":\"%s\",\"created\":%d,\"ends\":%d,\"length\":%d,\"reason\":\"%s\",\"country\":\"%s\",\"removeType\":\"%s\",\"admin\":\"%s\",\"server\":\"%s\",\"commType\":%d,\"ipMasked\":\"%s\"}",
			n == 0 ? "" : ",", kind, bid, authid, nomeEsc, criado, termina, duracao,
			razaoEsc, pais, removeType, adminEsc, servidor, commType, ipMasc);
		n++;
	}

	f.WriteLine("]}");
	delete f;

	DeleteFile(destino);
	if (!RenameFile(destino, temp))
		LogError("[Bans] falha ao renomear %s -> %s", temp, destino);

	LogMessage("[Bans] %d registro(s) exportados para addons/sourcemod/%s", n, ARQUIVO);
}

/** "189.45.12.200" -> "189.45.x.x": o endereco completo nunca sai daqui. */
void Lendas_MascararIp(const char[] ip, char[] saida, int maxlen)
{
	saida[0] = '\0';
	if (ip[0] == '\0')
		return;

	char partes[4][8];
	int n = ExplodeString(ip, ".", partes, sizeof(partes), sizeof(partes[]));
	if (n < 4)
		return;

	Format(saida, maxlen, "%s.%s.x.x", partes[0], partes[1]);
}

/** Escapa o minimo que um JSON valido exige: aspas, barra e controles. */
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
		else if (c == '\n' || c == '\r' || c == '\t')
		{
			saida[j++] = ' ';
		}
		else if (c >= 0 && c < 32)
		{
			// caractere de controle: descarta, nao vale quebrar o JSON por ele
		}
		else
		{
			saida[j++] = c;
		}
	}
	saida[j] = '\0';
}
