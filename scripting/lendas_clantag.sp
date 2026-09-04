/**
 * L.E.N.D.A.S. Clan Tag
 *
 * Devolve ao jogador a tag do grupo Steam que ele escolheu.
 *
 * POR QUE ISTO EXISTE: depois que o CS:S mudou de branch de engine, a tag
 * parou de aparecer sozinha no placar. E bug conhecido do jogo — ha issue
 * aberta no repositorio da Valve (Source-1-Games #2853) e nenhuma correcao.
 * Servidores que "arrumaram" nao consertaram o bug: eles fazem o trabalho
 * no lugar do jogo, que e exatamente o que este plugin faz.
 *
 * COMO: o cliente continua enviando `cl_clanid` (o ID do grupo que ele
 * selecionou) — isso o servidor consegue ler. Dai:
 *
 *   1. gid64 = 103582791429521408 + cl_clanid
 *   2. GET /gid/<gid64>/memberslistxml/?xml=1  -> <groupURL>
 *   3. GET /groups/<groupURL>                  -> grouppage_header_abbrev
 *   4. CS_SetClientClanTag(client, abreviacao)
 *
 * Os dois passos foram escolhidos assim porque nenhum deles redireciona
 * (verificado): pedir /gid/<id> direto devolve 302, e seguir redirect no
 * SteamWorks e trabalho extra sem ganho.
 *
 * NAO BRIGA COM O MIX: so escreve quando a tag atual esta VAZIA. Durante um
 * mix o abnermix poe "Team A"/"Team B", e este plugin fica quieto. Quando o
 * mix termina e limpa as tags, o round seguinte devolve a tag pessoal.
 *
 * Requer: extensao SteamWorks (a mesma que o lendas_steamfilter ja usa).
 * Compilar com o compiler do SourceMod 1.12.
 */

#pragma semicolon 1
#pragma newdecls required
/**
 * O buffer da pagina (~74 KB) e GLOBAL, entao mora na secao de dados e nao
 * na pilha — nao e ele que exige isto aqui. 32768 cells (128 KB) e folga
 * para as funcoes locais; a primeira versao pedia 1 MB sem precisar.
 */
#pragma dynamic 32768

#include <sourcemod>
#include <cstrike>
#include <SteamWorks>

#define PLUGIN_VERSION  "1.2.0"

#define TAG_MAX         32
#define URL_MAX         256
#define RESPOSTA_MAX    98304

ConVar g_cvEnabled;
ConVar g_cvDebug;

/** Buffer de resposta HTTP. Os callbacks do SteamWorks vem um por vez. */
char g_sResposta[RESPOSTA_MAX];

/** cl_clanid que ja resolvemos pra cada cliente, pra nao repetir consulta. */
char g_sClanIdAtual[MAXPLAYERS + 1][32];
/** A tag resolvida de cada cliente. Vazia = sem grupo ou nao resolvida. */
char g_sTag[MAXPLAYERS + 1][TAG_MAX];

/**
 * grupo -> tag, compartilhado entre todos os clientes.
 *
 * Numa rede onde metade do servidor usa o mesmo grupo, isto transforma
 * dezenas de consultas em uma. Nunca expira: a abreviacao de um grupo
 * praticamente nao muda, e um `sm plugins reload` limpa se mudar.
 */
StringMap g_hCache;

public Plugin myinfo =
{
    name        = "L.E.N.D.A.S. Clan Tag",
    author      = "L.E.N.D.A.S.",
    description = "Devolve a tag do grupo Steam do jogador, que o jogo parou de mostrar",
    version     = PLUGIN_VERSION,
    url         = ""
};

public void OnPluginStart()
{
    CreateConVar("lendas_clantag_version", PLUGIN_VERSION, "Versao do plugin",
        FCVAR_NOTIFY | FCVAR_DONTRECORD);

    g_cvEnabled = CreateConVar("lendas_clantag_enabled", "1",
        "Devolve a tag do grupo Steam do jogador.", _, true, 0.0, true, 1.0);
    g_cvDebug = CreateConVar("lendas_clantag_debug", "0",
        "Registra no log o que o servidor enxerga de cada jogador (cl_clanid e tag atual).",
        _, true, 0.0, true, 1.0);

    AutoExecConfig(true, "lendas_clantag");

    // Devolve a tag pessoal depois que algo a limpou — o fim de um mix, por
    // exemplo. So repoe quando esta vazia; ver Lendas_Aplicar.
    HookEvent("round_start", Evento_RoundStart, EventHookMode_PostNoCopy);

    g_hCache = new StringMap();

    // Carga tardia: quem ja esta no servidor tambem merece a tag.
    for (int i = 1; i <= MaxClients; i++)
        if (IsClientInGame(i) && !IsFakeClient(i))
            Lendas_Resolver(i);
}

public void OnClientPutInServer(int client)
{
    g_sClanIdAtual[client][0] = '\0';
    g_sTag[client][0]         = '\0';
    Lendas_Resolver(client);
}

/**
 * Disparado quando o cliente muda qualquer convar replicada — inclusive
 * `cl_clanid`. E assim que a troca de grupo pelo menu do jogo chega aqui,
 * sem precisar de temporizador.
 */
public void OnClientSettingsChanged(int client)
{
    Lendas_Resolver(client);
}

public void OnClientDisconnect(int client)
{
    g_sClanIdAtual[client][0] = '\0';
    g_sTag[client][0]         = '\0';
}

public void Evento_RoundStart(Event evento, const char[] nome, bool naoBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
        if (IsClientInGame(i) && !IsFakeClient(i) && g_sTag[i][0] != '\0')
            Lendas_Aplicar(i);
}

/* ---------------------------------------------------------------- *
 * Resolucao
 * ---------------------------------------------------------------- */

void Lendas_Resolver(int client)
{
    if (!g_cvEnabled.BoolValue || !IsClientInGame(client) || IsFakeClient(client))
        return;

    char sClanId[32];
    if (!GetClientInfo(client, "cl_clanid", sClanId, sizeof(sClanId)))
        sClanId[0] = '\0';

    /**
     * O log de debug so sai quando algo MUDA.
     *
     * `OnClientSettingsChanged` dispara a cada convar replicada que o
     * cliente mexe — som, video, o que for — entao logar aqui sem condicao
     * enchia o arquivo: 32 linhas identicas em um minuto, para um jogador
     * so, na primeira vez que isto rodou de verdade. Ruido que esconde o
     * que interessa e ainda custa I/O num servidor cheio.
     */
    bool mudou = !StrEqual(sClanId, g_sClanIdAtual[client]);
    if (g_cvDebug.BoolValue && mudou)
    {
        char sAtual[TAG_MAX];
        CS_GetClientClanTag(client, sAtual, sizeof(sAtual));
        LogMessage("[ClanTag] %L -> cl_clanid=\"%s\" tag_no_servidor=\"%s\"",
            client, sClanId, sAtual);
    }

    // Sem grupo selecionado: nada a fazer, e nada a apagar — quem limpou a
    // tag pode ter sido outro plugin, e nao cabe a este desfazer.
    if (sClanId[0] == '\0' || StringToInt(sClanId) <= 0)
    {
        g_sClanIdAtual[client][0] = '\0';
        g_sTag[client][0]         = '\0';
        return;
    }

    // Mesmo grupo de antes: ja temos a tag, so reaplicar.
    if (StrEqual(sClanId, g_sClanIdAtual[client]))
    {
        if (g_sTag[client][0] != '\0')
            Lendas_Aplicar(client);
        return;
    }

    strcopy(g_sClanIdAtual[client], 32, sClanId);
    g_sTag[client][0] = '\0';

    // Outro jogador do mesmo grupo ja resolveu: sai de graca.
    char sCache[TAG_MAX];
    if (g_hCache.GetString(sClanId, sCache, sizeof(sCache)))
    {
        strcopy(g_sTag[client], TAG_MAX, sCache);
        Lendas_Aplicar(client);
        return;
    }

    char sGid[32];
    Lendas_GidDeGrupo(sClanId, sGid, sizeof(sGid));

    char sUrl[URL_MAX];
    FormatEx(sUrl, sizeof(sUrl), "https://steamcommunity.com/gid/%s/memberslistxml/?xml=1", sGid);
    Lendas_Pedir(client, sUrl, OnGrupoRecebido);
}

/**
 * ID de grupo de 64 bits a partir do `cl_clanid` (que e a parte de 32 bits).
 *
 * Feito com string porque SourcePawn nao tem inteiro de 64 bits: a soma e
 * decimal, digito a digito, com o "vai um". A logica foi conferida fora do
 * jogo contra aritmetica de precisao arbitraria, em tres casos:
 * 1 -> ...409, 4272308 -> ...793716 e 5151157 -> 103582791434672565.
 *
 * Nao trata "vai um" que estoure o ultimo digito: a base tem 18 digitos e
 * o maior cl_clanid possivel tem 10, entao a soma nunca chega a 19.
 */
void Lendas_GidDeGrupo(const char[] sClanId, char[] saida, int maxlen)
{
    char sBase[32];
    strcopy(sBase, sizeof(sBase), "103582791429521408");

    int nBase = strlen(sBase);
    int nSoma = strlen(sClanId);

    char sRes[32];
    int carry = 0;
    int j = nBase;
    sRes[j] = '\0';

    for (int i = 0; i < nBase; i++)
    {
        int posBase = nBase - 1 - i;
        int posSoma = nSoma - 1 - i;

        int d = (sBase[posBase] - '0') + carry;
        if (posSoma >= 0)
            d += (sClanId[posSoma] - '0');

        carry = d / 10;
        sRes[--j] = view_as<char>('0' + (d % 10));
    }

    strcopy(saida, maxlen, sRes[j]);
}

bool Lendas_Pedir(int client, const char[] url, SteamWorksHTTPRequestCompleted cb)
{
    Handle hReq = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, url);
    if (hReq == null)
    {
        LogError("[ClanTag] falha ao criar request pra %s", url);
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

/** Le o corpo da resposta pro buffer global. Falso = resposta inutil. */
bool Lendas_LerCorpo(Handle hReq, bool bFalhou, bool bOk, EHTTPStatusCode code)
{
    g_sResposta[0] = '\0';

    if (bFalhou || !bOk || code != k_EHTTPStatusCode200OK)
        return false;

    int len;
    if (!SteamWorks_GetHTTPResponseBodySize(hReq, len) || len <= 1)
        return false;

    if (len > RESPOSTA_MAX - 1)
        len = RESPOSTA_MAX - 1;

    if (!SteamWorks_GetHTTPResponseBodyData(hReq, g_sResposta, len))
    {
        g_sResposta[0] = '\0';
        return false;
    }

    g_sResposta[len] = '\0';
    return true;
}

/* ---------------------------------------------------------------- *
 * Callbacks
 * ---------------------------------------------------------------- */

public void OnGrupoRecebido(Handle hReq, bool bFalhou, bool bOk, EHTTPStatusCode code, any userid)
{
    bool temCorpo = Lendas_LerCorpo(hReq, bFalhou, bOk, code);
    delete hReq;

    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client) || !temCorpo)
        return;

    // <groupURL><![CDATA[steamuniverse]]></groupURL>
    char sVanity[128];
    if (!Lendas_EntreMarcas(g_sResposta, "<groupURL><![CDATA[", "]]>", sVanity, sizeof(sVanity)))
        return;

    char sUrl[URL_MAX];
    FormatEx(sUrl, sizeof(sUrl), "https://steamcommunity.com/groups/%s", sVanity);
    Lendas_Pedir(client, sUrl, OnPaginaRecebida);
}

public void OnPaginaRecebida(Handle hReq, bool bFalhou, bool bOk, EHTTPStatusCode code, any userid)
{
    bool temCorpo = Lendas_LerCorpo(hReq, bFalhou, bOk, code);
    delete hReq;

    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client) || !temCorpo)
        return;

    /**
     * <span class="grouppage_header_abbrev" ...>TAG</span>
     *
     * O atributo `style` aparece numa ocorrencia e nao na outra, entao o
     * corte e pelo `>` que fecha a tag de abertura, nao por uma string fixa.
     */
    int pos = StrContains(g_sResposta, "grouppage_header_abbrev");
    if (pos == -1)
        return;

    int fim = -1;
    for (int i = pos; g_sResposta[i] != '\0'; i++)
    {
        if (g_sResposta[i] == '>')
        {
            fim = i + 1;
            break;
        }
    }
    if (fim == -1)
        return;

    char sTag[TAG_MAX];
    if (!Lendas_AteMarca(g_sResposta[fim], "</span>", sTag, sizeof(sTag)))
        return;

    /**
     * A pagina e HTML: o que for `&`, `<`, `>` ou aspas chega como entidade,
     * senao quebraria a marcacao. Sem desfazer isso, uma tag "A&B" viraria
     * literalmente "A&amp;B" no placar.
     *
     * Acento e simbolo NAO precisam disso — a pagina e UTF-8 e a Steam manda
     * crus (verificado: um grupo com caracteres de 3 bytes e outro com
     * "[VALVᴱ]" chegam inteiros).
     */
    Lendas_DesescaparHtml(sTag, sizeof(sTag));

    TrimString(sTag);
    if (sTag[0] == '\0')
        return;

    strcopy(g_sTag[client], TAG_MAX, sTag);
    g_hCache.SetString(g_sClanIdAtual[client], sTag);

    if (g_cvDebug.BoolValue)
        LogMessage("[ClanTag] %L -> grupo %s = \"%s\"", client, g_sClanIdAtual[client], sTag);

    Lendas_Aplicar(client);
}

/**
 * Escreve a tag SOMENTE se a atual estiver vazia.
 *
 * E o que mantem a paz com o abnermix: durante um mix ele poe "Team A"/
 * "Team B", e sobrescrever isso estragaria a partida. Quando o mix acaba e
 * limpa as tags, o round seguinte encontra vazio e devolve a pessoal.
 */
void Lendas_Aplicar(int client)
{
    if (!g_cvEnabled.BoolValue || g_sTag[client][0] == '\0')
        return;
    if (!IsClientInGame(client) || IsFakeClient(client))
        return;

    char sAtual[TAG_MAX];
    CS_GetClientClanTag(client, sAtual, sizeof(sAtual));
    if (sAtual[0] != '\0')
        return;

    CS_SetClientClanTag(client, g_sTag[client]);
}

/* ---------------------------------------------------------------- *
 * Texto
 * ---------------------------------------------------------------- */

/** Trecho entre duas marcas. Falso = qualquer uma das duas nao apareceu. */
bool Lendas_EntreMarcas(const char[] texto, const char[] inicio, const char[] fim,
                        char[] saida, int maxlen)
{
    int a = StrContains(texto, inicio);
    if (a == -1)
        return false;

    a += strlen(inicio);
    return Lendas_AteMarca(texto[a], fim, saida, maxlen);
}

/**
 * Desfaz as entidades HTML que a Steam usa. Entidade desconhecida fica como
 * esta: melhor um "&hearts;" visivel que um caractere inventado.
 */
void Lendas_DesescaparHtml(char[] texto, int maxlen)
{
    ReplaceString(texto, maxlen, "&lt;", "<");
    ReplaceString(texto, maxlen, "&gt;", ">");
    ReplaceString(texto, maxlen, "&quot;", "\"");
    ReplaceString(texto, maxlen, "&#39;", "'");
    ReplaceString(texto, maxlen, "&apos;", "'");
    ReplaceString(texto, maxlen, "&nbsp;", " ");
    // `&amp;` por ULTIMO: se viesse antes, "&amp;lt;" viraria "<" em vez do
    // texto "&lt;" que o grupo realmente tem no nome.
    ReplaceString(texto, maxlen, "&amp;", "&");
}

/** Do comeco do texto ate a marca. */
bool Lendas_AteMarca(const char[] texto, const char[] fim, char[] saida, int maxlen)
{
    int b = StrContains(texto, fim);
    if (b <= 0)
        return false;

    if (b > maxlen - 1)
    {
        b = maxlen - 1;
        /**
         * Corte seguro em UTF-8: bytes 0x80-0xBF sao CONTINUACAO de um
         * caractere. Cortar em cima de um deles deixa meio caractere, que o
         * jogo desenha como lixo. Recua ate o inicio do caractere.
         */
        while (b > 0 && (texto[b] & 0xC0) == 0x80)
            b--;
    }

    strcopy(saida, b + 1, texto);
    return true;
}
