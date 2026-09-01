/**
 * L.E.N.D.A.S. Steam Filter
 *
 * Bloqueia no join: conta com VAC/game ban previo, conta muito nova,
 * poucas horas de CS:S e perfil privado (opcional).
 *
 * Requer: SteamWorks extension
 *   https://github.com/KyleSanderson/SteamWorks
 *
 * Compilar com o compiler do SourceMod 1.12.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <SteamWorks>

#define PLUGIN_VERSION "1.2.0"
#define APPID_CSS      240
/** Onde mora a lista de contas que passam por cima de todas as checagens. */
#define ARQUIVO_WHITELIST "configs/lsf_whitelist.cfg"
#define STEAM64_BASE   76561197960265728

ConVar g_cvEnabled;
ConVar g_cvApiKey;
ConVar g_cvMinHours;
ConVar g_cvMinAccountDays;
ConVar g_cvBlockVac;
ConVar g_cvVacDaysGrace;
ConVar g_cvBlockPrivate;
ConVar g_cvBlockShared;
ConVar g_cvRequireOwned;
ConVar g_cvImmunityFlag;
ConVar g_cvKickMsg;

/**
 * SteamID64 -> liberado. Chave presente = passa direto.
 *
 * O arquivo ja existia em configs/ desde 2026-08-09, documentado, com
 * jogadores dentro — mas o codigo que o lia sumiu na copia do Servidor 02
 * sobre o 01 em 2026-08-29 (o .smx encolheu de 16607 para 13598 bytes). Ou
 * seja: a whitelist esteve SILENCIOSAMENTE desligada desde entao, e quem
 * estava nela continuou sendo barrado. Reimplementado seguindo o formato
 * que o proprio cabecalho do arquivo descreve.
 */
StringMap g_hWhitelist;

// Estado por cliente: quantas checagens ainda faltam responder.
int  g_iPending[MAXPLAYERS + 1];
bool g_bChecked[MAXPLAYERS + 1];

// Buffer de resposta HTTP. Os callbacks do SteamWorks sao processados
// um por vez, entao um buffer global compartilhado da conta.
#define RESPONSE_MAXLEN 16384
char g_sResponse[RESPONSE_MAXLEN];

// ---- Banco de dados ----
ConVar   g_cvDbConfig;
Database g_hDb = null;
bool     g_bDbLogged = false;   // ja avisou que o banco falhou?

// Dados coletados por cliente, gravados numa linha so no fim.
// -1 = nao coletado / ilegivel.
int  g_iHours[MAXPLAYERS + 1];
int  g_iAccountDays[MAXPLAYERS + 1];
int  g_iVisibility[MAXPLAYERS + 1];
int  g_iVacBans[MAXPLAYERS + 1];
int  g_iGameBans[MAXPLAYERS + 1];
int  g_iDaysSinceBan[MAXPLAYERS + 1];
char g_sLender[MAXPLAYERS + 1][32];
bool g_bRowWritten[MAXPLAYERS + 1];

// Momento (unix) em que o jogador foi aprovado e entrou de fato.
// Serve pra calcular quanto tempo ele ficou, na hora que sair.
// 0 = nunca entrou (ainda checando, ou foi barrado na porta).
int g_iJoinedAt[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name        = "L.E.N.D.A.S. Steam Filter",
    author      = "L.E.N.D.A.S.",
    description = "Filtra jogadores no join via Steam Web API",
    version     = PLUGIN_VERSION,
    url         = ""
};

public void OnPluginStart()
{
    CreateConVar("lsf_version", PLUGIN_VERSION, "Versao do plugin",
        FCVAR_NOTIFY | FCVAR_DONTRECORD);

    g_cvEnabled = CreateConVar("lsf_enabled", "1",
        "Ativa o filtro.", _, true, 0.0, true, 1.0);

    g_cvApiKey = CreateConVar("lsf_apikey", "",
        "Steam Web API key. NAO deixa isso em cfg publico.",
        FCVAR_PROTECTED);

    g_cvMinHours = CreateConVar("lsf_min_hours", "20",
        "Minimo de horas em CS:S. 0 = nao checa.", _, true, 0.0);

    g_cvMinAccountDays = CreateConVar("lsf_min_account_days", "60",
        "Idade minima da conta Steam em dias. 0 = nao checa.", _, true, 0.0);

    g_cvBlockVac = CreateConVar("lsf_block_vac", "1",
        "Bloqueia conta com VAC ban ou game ban.", _, true, 0.0, true, 1.0);

    g_cvVacDaysGrace = CreateConVar("lsf_vac_days_grace", "0",
        "Libera se o ban for mais antigo que X dias. 0 = nunca libera.",
        _, true, 0.0);

    g_cvBlockPrivate = CreateConVar("lsf_block_private", "1",
        "Bloqueia perfil privado (sem perfil publico nao da pra ver horas).",
        _, true, 0.0, true, 1.0);

    g_cvBlockShared = CreateConVar("lsf_block_shared", "1",
        "Bloqueia conta jogando CS:S via Family Sharing (jogo emprestado).",
        _, true, 0.0, true, 1.0);

    g_cvRequireOwned = CreateConVar("lsf_require_owned", "1",
        "Bloqueia se nao der pra ler as horas (nao possui o jogo ou perfil fechado).",
        _, true, 0.0, true, 1.0);

    g_cvImmunityFlag = CreateConVar("lsf_immunity_flag", "b",
        "Flag de admin que passa direto pelo filtro. Vazio = ninguem passa.");

    g_cvKickMsg = CreateConVar("lsf_kick_msg",
        "Servidor L.E.N.D.A.S. - sua conta Steam nao atende aos requisitos",
        "Mensagem base do kick.");

    g_cvDbConfig = CreateConVar("lsf_db_config", "lsf",
        "Nome da entrada em databases.cfg. Vazio = nao grava no banco.");

    // Necessario pro FindTarget/ReplyToTargetError conseguirem imprimir
    // as mensagens de erro padrao ("No matching client", etc).
    LoadTranslations("common.phrases");

    AutoExecConfig(true, "lendas_steamfilter");

    ConnectDb();

    RegAdminCmd("sm_lsf_check", Cmd_Check, ADMFLAG_BAN,
        "sm_lsf_check <#userid|nome> - roda o filtro manualmente num jogador");
    RegAdminCmd("sm_lsf_reload", Cmd_Reload, ADMFLAG_BAN,
        "sm_lsf_reload - recarrega a whitelist sem esperar a troca de mapa");

    Lendas_CarregarWhitelist();
}

/**
 * Registra a saida no mesmo log diario onde ja moram "APROVADO" e
 * "Bloqueado", pro feed de atividade do site poder fechar o ciclo de cada
 * jogador (entrou -> saiu) em vez de so mostrar entradas.
 *
 * SO loga quem realmente ENTROU (g_iJoinedAt > 0). Quem foi barrado tambem
 * passa por aqui, porque RejectClient chama KickClient - e ai o feed
 * mostraria "Bloqueado" seguido de "Saiu" pro mesmo sujeito, contando duas
 * vezes uma coisa que aconteceu uma vez. Quem ainda estava sendo checado
 * quando caiu tambem nao conta: nunca chegou a jogar.
 *
 * O tempo de sessao vem de GetTime() (relogio unix), nao de GetGameTime(),
 * que zera a cada troca de mapa e daria "ficou 0 min" pra quem passou a
 * tarde inteira no servidor.
 */
/** A whitelist recarrega a cada mapa, como o cabecalho do arquivo promete. */
public void OnMapStart()
{
    Lendas_CarregarWhitelist();
}

public void OnClientDisconnect(int client)
{
    if (g_iJoinedAt[client] > 0)
    {
        int minutos = (GetTime() - g_iJoinedAt[client]) / 60;
        LogMessage("SAIU: %L ficou %d min.", client, minutos);
    }

    ResetClient(client);
}

void ResetClient(int client)
{
    g_iPending[client]      = 0;
    g_bChecked[client]      = false;
    g_bRowWritten[client]   = false;
    g_iJoinedAt[client]     = 0;
    g_iHours[client]        = -1;
    g_iAccountDays[client]  = -1;
    g_iVisibility[client]   = -1;
    g_iVacBans[client]      = -1;
    g_iGameBans[client]     = -1;
    g_iDaysSinceBan[client] = -1;
    g_sLender[client][0]    = '\0';
}

/* ---------- banco ---------- */

void ConnectDb()
{
    char sConfig[64];
    g_cvDbConfig.GetString(sConfig, sizeof(sConfig));

    if (sConfig[0] == '\0')
        return;

    if (!SQL_CheckConfig(sConfig))
    {
        LogError("Entrada \"%s\" nao existe em databases.cfg - nao vou gravar no banco.", sConfig);
        return;
    }

    Database.Connect(OnDbConnect, sConfig);
}

public void OnDbConnect(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("Falha ao conectar no banco: %s", error);
        return;
    }

    g_hDb = db;
    g_hDb.SetCharset("utf8mb4");
    LogMessage("Conectado ao banco - log de checagens ativo.");
}

/**
 * Grava a linha final da checagem. Chamado uma vez por cliente:
 * ou no bloqueio, ou quando todas as checagens passam, ou em erro de API.
 */
void WriteRow(int client, const char[] verdict, const char[] reason)
{
    if (g_bRowWritten[client])
        return;

    g_bRowWritten[client] = true;

    if (g_hDb == null)
    {
        if (!g_bDbLogged)
        {
            LogError("Banco indisponivel - checagens nao estao sendo gravadas.");
            g_bDbLogged = true;
        }
        return;
    }

    char sSteam64[32], sSteamId[32], sNick[64], sIp[46];
    GetClientAuthId(client, AuthId_SteamID64, sSteam64, sizeof(sSteam64));
    GetClientAuthId(client, AuthId_Steam2, sSteamId, sizeof(sSteamId));
    GetClientName(client, sNick, sizeof(sNick));
    GetClientIP(client, sIp, sizeof(sIp));

    char sNickEsc[129], sReasonEsc[257], sLenderEsc[65];
    g_hDb.Escape(sNick, sNickEsc, sizeof(sNickEsc));
    g_hDb.Escape(reason, sReasonEsc, sizeof(sReasonEsc));
    g_hDb.Escape(g_sLender[client], sLenderEsc, sizeof(sLenderEsc));

    // Cada valor num buffer proprio. Nao use uma funcao que retorna array
    // varias vezes dentro do mesmo Format: em SourcePawn as chamadas podem
    // compartilhar buffer temporario e sobrescrever uma a outra.
    char sHours[16], sDays[16], sVis[16], sVac[16], sGame[16], sSinceBan[16];
    NullOrInt(g_iHours[client],        sHours,    sizeof(sHours));
    NullOrInt(g_iAccountDays[client],  sDays,     sizeof(sDays));
    NullOrInt(g_iVisibility[client],   sVis,      sizeof(sVis));
    NullOrInt(g_iVacBans[client],      sVac,      sizeof(sVac));
    NullOrInt(g_iGameBans[client],     sGame,     sizeof(sGame));
    NullOrInt(g_iDaysSinceBan[client], sSinceBan, sizeof(sSinceBan));

    // Strings: NULL sem aspas, ou o valor entre aspas.
    char sReasonSql[300], sLenderSql[70];
    if (reason[0] == '\0')
        strcopy(sReasonSql, sizeof(sReasonSql), "NULL");
    else
        FormatEx(sReasonSql, sizeof(sReasonSql), "'%s'", sReasonEsc);

    if (sLenderEsc[0] == '\0')
        strcopy(sLenderSql, sizeof(sLenderSql), "NULL");
    else
        FormatEx(sLenderSql, sizeof(sLenderSql), "'%s'", sLenderEsc);

    char sQuery[1024];
    Format(sQuery, sizeof(sQuery),
        "INSERT INTO lsf_checks \
         (steam64, steam_id, nick, ip, verdict, reason, hours_css, \
          account_days, visibility, vac_bans, game_bans, days_since_ban, \
          lender_steam64) \
         VALUES ('%s', '%s', '%s', '%s', '%s', %s, %s, %s, %s, %s, %s, %s, %s)",
        sSteam64, sSteamId, sNickEsc, sIp, verdict, sReasonSql,
        sHours, sDays, sVis, sVac, sGame, sSinceBan, sLenderSql);

    g_hDb.Query(OnInsertDone, sQuery, 0, DBPrio_Low);
}

/**
 * Escreve o inteiro em out, ou "NULL" se for negativo (= nao coletado).
 */
void NullOrInt(int value, char[] out, int maxlen)
{
    if (value < 0)
        strcopy(out, maxlen, "NULL");
    else
        IntToString(value, out, maxlen);
}

public void OnInsertDone(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
        LogError("Falha ao gravar checagem: %s", error);
}

public void OnClientPostAdminCheck(int client)
{
    ResetClient(client);

    if (!g_cvEnabled.BoolValue || IsFakeClient(client))
        return;

    if (HasImmunity(client))
        return;

    /**
     * Whitelist ANTES das checagens, nao depois: o ponto dela e nao gastar
     * chamada a Steam com quem ja esta liberado, e nao so ignorar o
     * veredito no fim.
     */
    if (EstaNaWhitelist(client))
    {
        g_bChecked[client] = true;
        LogMessage("APROVADO: %L esta na whitelist.", client);
        WriteRow(client, "aprovado", "whitelist");
        return;
    }

    RunChecks(client);
}

public Action Cmd_Reload(int client, int args)
{
    int n = Lendas_CarregarWhitelist();
    ReplyToCommand(client, "[LSF] Whitelist recarregada: %d conta(s).", n);
    return Plugin_Handled;
}

bool EstaNaWhitelist(int client)
{
    if (g_hWhitelist == null)
        return false;

    char sSteam64[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, sSteam64, sizeof(sSteam64)))
        return false;

    bool liberado;
    return g_hWhitelist.GetValue(sSteam64, liberado);
}

/**
 * Le o arquivo inteiro do zero. Devolve quantas contas entraram.
 *
 * Formato, exatamente como o cabecalho do arquivo descreve: um SteamID64
 * por linha, motivo opcional depois de um espaco, linhas com // ou ;
 * ignoradas. Linha que nao seja 17 digitos comecando com 765 e descartada
 * COM AVISO no log — uma whitelist que engole erro em silencio deixa o
 * admin achando que liberou alguem que continua barrado.
 */
int Lendas_CarregarWhitelist()
{
    delete g_hWhitelist;
    g_hWhitelist = new StringMap();

    char caminho[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, caminho, sizeof(caminho), ARQUIVO_WHITELIST);

    File f = OpenFile(caminho, "r");
    if (f == null)
    {
        LogMessage("Whitelist: %s nao existe — ninguem liberado.", ARQUIVO_WHITELIST);
        return 0;
    }

    int n = 0, linhaN = 0;
    char linha[256];

    while (!f.EndOfFile() && f.ReadLine(linha, sizeof(linha)))
    {
        linhaN++;
        TrimString(linha);

        if (linha[0] == '\0' || linha[0] == ';')
            continue;
        if (linha[0] == '/' && linha[1] == '/')
            continue;

        // O motivo vem depois do primeiro espaco e nao faz parte do ID.
        int espaco = FindCharInString(linha, ' ');
        char sId[32];
        if (espaco == -1)
            strcopy(sId, sizeof(sId), linha);
        else
            strcopy(sId, espaco + 1, linha);

        if (!Lendas_PareceSteam64(sId))
        {
            LogError("Whitelist: linha %d ignorada, nao parece SteamID64: \"%s\"", linhaN, sId);
            continue;
        }

        g_hWhitelist.SetValue(sId, true);
        n++;
    }

    delete f;
    LogMessage("Whitelist: %d conta(s) liberada(s).", n);
    return n;
}

/** 17 digitos comecando com 765 — o mesmo criterio que o arquivo promete. */
bool Lendas_PareceSteam64(const char[] valor)
{
    if (strlen(valor) != 17)
        return false;
    if (valor[0] != '7' || valor[1] != '6' || valor[2] != '5')
        return false;

    for (int i = 0; i < 17; i++)
        if (!IsCharNumeric(valor[i]))
            return false;

    return true;
}

public Action Cmd_Check(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[LSF] Uso: sm_lsf_check <#userid|nome>");
        return Plugin_Handled;
    }

    char sArg[65];
    GetCmdArg(1, sArg, sizeof(sArg));

    int target = FindTarget(client, sArg, true, false);
    if (target == -1)
        return Plugin_Handled;

    ReplyToCommand(client, "[LSF] Checando %N...", target);
    RunChecks(target);

    return Plugin_Handled;
}

bool HasImmunity(int client)
{
    char sFlags[8];
    g_cvImmunityFlag.GetString(sFlags, sizeof(sFlags));

    if (sFlags[0] == '\0')
        return false;

    AdminFlag flag;
    if (!FindFlagByChar(sFlags[0], flag))
        return false;

    return CheckCommandAccess(client, "lsf_immunity", FlagToBit(flag), true);
}

void RunChecks(int client)
{
    char sKey[64];
    g_cvApiKey.GetString(sKey, sizeof(sKey));

    if (sKey[0] == '\0')
    {
        LogError("lsf_apikey nao configurada - filtro inativo.");
        return;
    }

    char sSteam64[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, sSteam64, sizeof(sSteam64)))
    {
        // Ainda nao autenticou. Tenta de novo em breve.
        CreateTimer(2.0, Timer_Retry, GetClientUserId(client));
        return;
    }

    char sUrl[512];

    // 1) Bans (VAC / game ban)
    if (g_cvBlockVac.BoolValue)
    {
        FormatEx(sUrl, sizeof(sUrl),
            "https://api.steampowered.com/ISteamUser/GetPlayerBans/v1/?key=%s&steamids=%s",
            sKey, sSteam64);
        if (SendRequest(client, sUrl, OnBansReceived))
            g_iPending[client]++;
    }

    // 2) Perfil (idade da conta / visibilidade)
    if (g_cvMinAccountDays.IntValue > 0 || g_cvBlockPrivate.BoolValue)
    {
        FormatEx(sUrl, sizeof(sUrl),
            "https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/?key=%s&steamids=%s",
            sKey, sSteam64);
        if (SendRequest(client, sUrl, OnSummaryReceived))
            g_iPending[client]++;
    }

    // 3) Family Sharing - o jogo e emprestado?
    if (g_cvBlockShared.BoolValue)
    {
        FormatEx(sUrl, sizeof(sUrl),
            "https://api.steampowered.com/IPlayerService/IsPlayingSharedGame/v1/?key=%s&steamid=%s&appid_playing=%d",
            sKey, sSteam64, APPID_CSS);
        if (SendRequest(client, sUrl, OnSharedReceived))
            g_iPending[client]++;
    }

    // 4) Horas de CS:S
    if (g_cvMinHours.IntValue > 0)
    {
        FormatEx(sUrl, sizeof(sUrl),
            "https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/?key=%s&steamid=%s&appids_filter[0]=%d",
            sKey, sSteam64, APPID_CSS);
        if (SendRequest(client, sUrl, OnGamesReceived))
            g_iPending[client]++;
    }
}

public Action Timer_Retry(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client > 0 && IsClientInGame(client) && !g_bChecked[client])
        RunChecks(client);

    return Plugin_Stop;
}

bool SendRequest(int client, const char[] url, SteamWorksHTTPRequestCompleted cb)
{
    Handle hReq = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, url);
    if (hReq == null)
    {
        LogError("Falha ao criar request HTTP.");
        return false;
    }

    SteamWorks_SetHTTPRequestNetworkActivityTimeout(hReq, 10);
    SteamWorks_SetHTTPCallbacks(hReq, cb);
    SteamWorks_SetHTTPRequestContextValue(hReq, GetClientUserId(client));

    if (!SteamWorks_SendHTTPRequest(hReq))
    {
        delete hReq;
        return false;
    }

    return true;
}

/**
 * Le o corpo da resposta pro buffer global g_sResponse.
 * SourcePawn nao permite retornar array dinamico de uma funcao, por isso
 * o buffer e global em vez de alocado aqui.
 */
bool ReadBody(Handle hReq, bool bFailure, bool bOk, EHTTPStatusCode code)
{
    g_sResponse[0] = '\0';

    if (bFailure || !bOk || code != k_EHTTPStatusCode200OK)
        return false;

    int len;
    if (!SteamWorks_GetHTTPResponseBodySize(hReq, len) || len <= 1)
        return false;

    if (len > RESPONSE_MAXLEN - 1)
        len = RESPONSE_MAXLEN - 1;

    if (!SteamWorks_GetHTTPResponseBodyData(hReq, g_sResponse, len))
    {
        g_sResponse[0] = '\0';
        return false;
    }

    g_sResponse[len] = '\0';
    return true;
}

/**
 * Extrai um valor numerico de um JSON simples, tipo "campo":123
 * Nao e um parser de verdade - da conta dos payloads da Steam API.
 * Devolve -1 se nao achar.
 */
int JsonInt(const char[] json, const char[] field)
{
    char sNeedle[64];
    FormatEx(sNeedle, sizeof(sNeedle), "\"%s\":", field);

    int pos = StrContains(json, sNeedle);
    if (pos == -1)
        return -1;

    pos += strlen(sNeedle);

    // pula espaco
    while (json[pos] == ' ')
        pos++;

    char sNum[24];
    int i = 0;
    while (i < sizeof(sNum) - 1 && IsCharNumeric(json[pos]))
        sNum[i++] = json[pos++];

    if (i == 0)
        return -1;

    sNum[i] = '\0';
    return StringToInt(sNum);
}

/**
 * Extrai um valor string de um JSON simples: "campo":"valor"
 */
bool ExtractJsonString(const char[] json, const char[] field,
                       char[] out, int maxlen)
{
    out[0] = '\0';

    char sNeedle[64];
    FormatEx(sNeedle, sizeof(sNeedle), "\"%s\":", field);

    int pos = StrContains(json, sNeedle);
    if (pos == -1)
        return false;

    pos += strlen(sNeedle);

    while (json[pos] == ' ')
        pos++;

    if (json[pos] != '"')
        return false;
    pos++;

    int i = 0;
    while (i < maxlen - 1 && json[pos] != '"' && json[pos] != '\0')
        out[i++] = json[pos++];

    out[i] = '\0';
    return (i > 0);
}

bool JsonBoolTrue(const char[] json, const char[] field)
{
    char sNeedle[64];
    FormatEx(sNeedle, sizeof(sNeedle), "\"%s\":", field);

    int pos = StrContains(json, sNeedle);
    if (pos == -1)
        return false;

    pos += strlen(sNeedle);
    while (json[pos] == ' ')
        pos++;

    return (json[pos] == 't');
}

void FinishCheck(int client)
{
    if (g_iPending[client] > 0)
        g_iPending[client]--;

    if (g_iPending[client] == 0)
    {
        g_bChecked[client] = true;
        g_iJoinedAt[client] = GetTime();
        LogMessage("APROVADO: %L passou em todas as checagens.", client);
        WriteRow(client, "aprovado", "");
    }
}

void RejectClient(int client, const char[] reason)
{
    WriteRow(client, "bloqueado", reason);

    char sMsg[192];
    g_cvKickMsg.GetString(sMsg, sizeof(sMsg));

    LogMessage("Bloqueado %L - %s", client, reason);
    PrintToConsole(client, "[LSF] Motivo: %s", reason);

    KickClient(client, "%s (%s)", sMsg, reason);
}

/* ---------- callbacks ---------- */

public void OnBansReceived(Handle hReq, bool bFailure, bool bOk,
                           EHTTPStatusCode code, any userid)
{
    int client = GetClientOfUserId(userid);
    bool bGotBody = ReadBody(hReq, bFailure, bOk, code);
    delete hReq;

    if (client <= 0 || !IsClientInGame(client))
        return;

    if (!bGotBody)
    {
        LogError("GetPlayerBans falhou para %L - liberando por seguranca.", client);
        LogMessage("ERRO API: GetPlayerBans falhou para %L - LIBERADO sem checar.", client);
        WriteRow(client, "erro_api", "GetPlayerBans falhou");
        FinishCheck(client);
        return;
    }

    int vacBans  = JsonInt(g_sResponse, "NumberOfVACBans");
    int gameBans = JsonInt(g_sResponse, "NumberOfGameBans");
    int daysSince = JsonInt(g_sResponse, "DaysSinceLastBan");
    bool bVac = JsonBoolTrue(g_sResponse, "VACBanned");

    bool bHasBan = (bVac || vacBans > 0 || gameBans > 0);

    if (bHasBan)
    {
        int grace = g_cvVacDaysGrace.IntValue;
        if (grace > 0 && daysSince > grace)
        {
            LogMessage("%L tem ban antigo (%d dias) - liberado pela grace.",
                client, daysSince);
        }
        else
        {
            RejectClient(client, "conta com VAC/game ban");
            return;
        }
    }

    g_iVacBans[client]      = vacBans      < 0 ? 0 : vacBans;
    g_iGameBans[client]     = gameBans     < 0 ? 0 : gameBans;
    g_iDaysSinceBan[client] = daysSince    < 0 ? 0 : daysSince;

    LogMessage("[bans] %L -> VAC:%d gamebans:%d dias_desde_ban:%d",
        client, vacBans, gameBans, daysSince);

    FinishCheck(client);
}

public void OnSummaryReceived(Handle hReq, bool bFailure, bool bOk,
                              EHTTPStatusCode code, any userid)
{
    int client = GetClientOfUserId(userid);
    bool bGotBody = ReadBody(hReq, bFailure, bOk, code);
    delete hReq;

    if (client <= 0 || !IsClientInGame(client))
        return;

    if (!bGotBody)
    {
        LogError("GetPlayerSummaries falhou para %L - liberando.", client);
        LogMessage("ERRO API: GetPlayerSummaries falhou para %L - LIBERADO sem checar.", client);
        WriteRow(client, "erro_api", "GetPlayerSummaries falhou");
        FinishCheck(client);
        return;
    }

    // communityvisibilitystate: 3 = publico, 1 = privado/amigos
    int vis = JsonInt(g_sResponse, "communityvisibilitystate");
    g_iVisibility[client] = vis;

    if (g_cvBlockPrivate.BoolValue && vis != -1 && vis != 3)
    {
        RejectClient(client, "perfil Steam privado");
        return;
    }

    int minDays = g_cvMinAccountDays.IntValue;
    if (minDays > 0)
    {
        int created = JsonInt(g_sResponse, "timecreated");
        if (created > 0)
        {
            int ageDays = (GetTime() - created) / 86400;
            if (ageDays < minDays)
            {
                char sReason[96];
                FormatEx(sReason, sizeof(sReason),
                    "conta com %d dias (minimo %d)", ageDays, minDays);
                RejectClient(client, sReason);
                return;
            }

            g_iAccountDays[client] = ageDays;
            g_iVisibility[client]   = vis;

            LogMessage("[perfil] %L -> conta com %d dias, visibilidade:%d",
                client, ageDays, vis);
        }
    }

    FinishCheck(client);
}

public void OnSharedReceived(Handle hReq, bool bFailure, bool bOk,
                             EHTTPStatusCode code, any userid)
{
    int client = GetClientOfUserId(userid);
    bool bGotBody = ReadBody(hReq, bFailure, bOk, code);
    delete hReq;

    if (client <= 0 || !IsClientInGame(client))
        return;

    if (!bGotBody)
    {
        LogError("IsPlayingSharedGame falhou para %L - liberando.", client);
        LogMessage("ERRO API: IsPlayingSharedGame falhou para %L - LIBERADO sem checar.", client);
        WriteRow(client, "erro_api", "IsPlayingSharedGame falhou");
        FinishCheck(client);
        return;
    }

    // lender_steamid vem como string. "0" = nao e emprestado.
    // Qualquer outro valor = SteamID64 de quem emprestou.
    char sLender[32];
    if (ExtractJsonString(g_sResponse, "lender_steamid", sLender, sizeof(sLender))
        && strlen(sLender) > 1)
    {
        char sReason[128];
        FormatEx(sReason, sizeof(sReason),
            "Family Sharing (jogo emprestado de %s)", sLender);
        strcopy(g_sLender[client], 32, sLender);
        LogMessage("[shared] %L -> emprestado de %s", client, sLender);
        RejectClient(client, sReason);
        return;
    }

    LogMessage("[shared] %L -> jogo proprio, nao emprestado", client);
    FinishCheck(client);
}

public void OnGamesReceived(Handle hReq, bool bFailure, bool bOk,
                            EHTTPStatusCode code, any userid)
{
    int client = GetClientOfUserId(userid);
    bool bGotBody = ReadBody(hReq, bFailure, bOk, code);
    delete hReq;

    if (client <= 0 || !IsClientInGame(client))
        return;

    if (!bGotBody)
    {
        LogError("GetOwnedGames falhou para %L - liberando.", client);
        LogMessage("ERRO API: GetOwnedGames falhou para %L - LIBERADO sem checar.", client);
        WriteRow(client, "erro_api", "GetOwnedGames falhou");
        FinishCheck(client);
        return;
    }

    // Perfil privado devolve {"response":{}} - sem game_count.
    int minutes = JsonInt(g_sResponse, "playtime_forever");

    if (minutes == -1)
    {
        // Nao veio playtime: ou o perfil esconde os jogos, ou a conta nao
        // possui CS:S (Family Sharing). Nos dois casos nao da pra validar
        // horas, entao o comportamento e controlado por lsf_require_owned.
        LogMessage("[horas] %L -> horas NAO visiveis (nao possui o jogo ou perfil fechado)",
            client);

        if (g_cvRequireOwned.BoolValue)
            RejectClient(client, "horas de CS:S nao verificaveis");
        else
            FinishCheck(client);
        return;
    }

    int hours = minutes / 60;
    int minHours = g_cvMinHours.IntValue;

    if (hours < minHours)
    {
        char sReason[96];
        FormatEx(sReason, sizeof(sReason),
            "%dh de CS:S (minimo %dh)", hours, minHours);
        RejectClient(client, sReason);
        return;
    }

    g_iHours[client] = hours;

    LogMessage("[horas] %L -> %dh de CS:S (minimo %dh)",
        client, hours, minHours);

    FinishCheck(client);
}
