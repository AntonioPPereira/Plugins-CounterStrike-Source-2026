#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.2.0"

/**
 * Fecha o atalho de "ir pro spec e voltar limpo".
 *
 * Dois abusos saem da MESMA jogada, e por isso ficam no mesmo plugin:
 *
 * 1. DOMINÂNCIA. O CS:S guarda quem domina quem em `m_bPlayerDominated` (e o
 *    espelho `m_bPlayerDominatingMe`), e limpa essas relações quando o
 *    jogador troca de time. Uma ida ao espectador apaga a dominância que
 *    alguém levou anos de rodada pra conquistar;
 * 2. DINHEIRO. Ao reentrar num time o jogador recebe o `mp_startmoney`. Para
 *    quem está quebrado isso é dinheiro de graça, toda vez que quiser.
 *
 * A correção é a mesma ideia nos dois casos: **a ida e volta não pode mudar
 * nada**. Guarda-se o estado no instante em que ele sai e devolve-se quando
 * ele volta. Não se bloqueia a troca de time — quem precisa sair de verdade
 * continua podendo, e quem só queria trapacear não ganha nada com isso.
 *
 * A foto é tirada no `jointeam`, ANTES da troca acontecer. No evento
 * `player_team` já é tarde: o jogo zerou o dinheiro e a dominância antes de
 * avisar.
 *
 * NADA é presumido sobre as netprops. Se `m_bPlayerDominated` não existir
 * neste jogo, o plugin diz isso no log e desliga só essa metade — o dinheiro
 * continua protegido. Ver `Lendas_Detectar`.
 */

public Plugin myinfo =
{
    name = "[LENDAS] Anti-abuso do Spec",
    author = "LENDAS Network",
    description = "Impede zerar dominância e ganhar dinheiro indo ao espectador e voltando.",
    version = PLUGIN_VERSION,
    url = "https://www.lendascss.com.br"
};

#define TIME_ESPECTADOR 1
#define TIME_TR         2
#define TIME_CT         3

ConVar g_CvarDinheiro;
ConVar g_CvarDominancia;
ConVar g_CvarDebug;
ConVar g_CvarZoar;
ConVar g_CvarSom;
ConVar g_CvarMulta;

ConVar g_CvarTolerancia;
ConVar g_CvarJanela;

/** Quantas vezes cada um tentou o truque neste mapa. Alimenta a zoação. */
int g_iTentativas[MAXPLAYERS + 1];

/** Instante em que saiu do time. Mede quanto tempo ficou fora. */
float g_fSaiuEm[MAXPLAYERS + 1];

/** Dinheiro no instante em que saiu de um time jogável. -1 = sem foto. */
int g_iDinheiro[MAXPLAYERS + 1];

/** Quem este jogador dominava, e quem o dominava, quando saiu. */
bool g_bDominava[MAXPLAYERS + 1][MAXPLAYERS + 1];
bool g_bDominado[MAXPLAYERS + 1][MAXPLAYERS + 1];

bool g_bTemFoto[MAXPLAYERS + 1];

/** -1 = ainda não olhamos; 0 = não existe neste jogo; 1 = existe. */
int g_iTemNetprops = -1;

public void OnPluginStart()
{
    CreateConVar("lendas_spec_version", PLUGIN_VERSION, "Versão do [LENDAS] Anti-abuso do Spec.",
        FCVAR_NOTIFY | FCVAR_DONTRECORD);

    g_CvarDinheiro = CreateConVar("lendas_spec_dinheiro", "1",
        "Devolve o dinheiro que o jogador tinha ao voltar do espectador.", _, true, 0.0, true, 1.0);
    g_CvarDominancia = CreateConVar("lendas_spec_dominancia", "1",
        "Devolve as relações de dominância ao voltar do espectador.", _, true, 0.0, true, 1.0);
    g_CvarDebug = CreateConVar("lendas_spec_debug", "0",
        "Registra no log cada foto e cada devolução.", _, true, 0.0, true, 1.0);
    g_CvarZoar = CreateConVar("lendas_spec_zoar", "1",
        "Anuncia no chat quem tentou fugir da dominância indo pro espectador.", _, true, 0.0, true, 1.0);
    g_CvarSom = CreateConVar("lendas_spec_som", "quake/standard/humiliation.mp3",
        "Som tocado na zoação. Vazio = sem som.");
    g_CvarMulta = CreateConVar("lendas_spec_multa", "1500",
        "Multa em dólares. Só a partir da tentativa seguinte à tolerância. 0 = sem multa.",
        _, true, 0.0, true, 16000.0);
    g_CvarTolerancia = CreateConVar("lendas_spec_tolerancia", "1",
        "Quantas idas ao espectador são perdoadas antes de multar. A primeira pode ser motivo de verdade.",
        _, true, 0.0, true, 10.0);
    g_CvarJanela = CreateConVar("lendas_spec_janela", "180",
        "Segundos no espectador para ainda contar como fuga. Quem fica mais que isso saiu por motivo real e não é cobrado.",
        _, true, 5.0, true, 3600.0);

    // O menu de times manda `jointeam <n>`; alguns clientes mandam `spectate`.
    AddCommandListener(Lendas_AntesDeTrocar, "jointeam");
    AddCommandListener(Lendas_AntesDeTrocar, "spectate");

    HookEvent("player_team", Evento_TrocaDeTime, EventHookMode_Post);

    AutoExecConfig(true, "lendas_spec");
}

public void OnMapStart()
{
    // O som da zoação precisa estar precacheado e na lista de download. O
    // quakesounds já faz isso pros sons dele, mas repetir não custa e cobre
    // o caso de alguém trocar o som por outro na cvar.
    char som[PLATFORM_MAX_PATH];
    g_CvarSom.GetString(som, sizeof(som));
    if (som[0] != EOS)
    {
        char caminho[PLATFORM_MAX_PATH];
        Format(caminho, sizeof(caminho), "sound/%s", som);
        if (FileExists(caminho, true))
        {
            PrecacheSound(som, true);
            AddFileToDownloadsTable(caminho);
        }
        else
        {
            LogError("Som da zoação não existe: %s. A zoação sai sem som.", caminho);
        }
    }

    // Mapa novo, partida nova: nenhuma foto sobrevive. Devolver dominância
    // de um mapa anterior seria inventar história.
    for (int i = 1; i <= MaxClients; i++)
    {
        Lendas_Esquecer(i);
        g_iTentativas[i] = 0;
    }
}

public void OnClientDisconnect(int client)
{
    Lendas_Esquecer(client);

    // Quem saiu do servidor não domina mais ninguém, e ninguém mais o domina.
    // Manter isso na foto dos OUTROS faria a dominância reaparecer no slot
    // reaproveitado por um jogador diferente.
    for (int i = 1; i <= MaxClients; i++)
    {
        g_bDominava[i][client] = false;
        g_bDominado[i][client] = false;
    }
}

void Lendas_Esquecer(int client)
{
    g_iDinheiro[client] = -1;
    g_fSaiuEm[client] = 0.0;
    g_bTemFoto[client] = false;
    for (int i = 0; i <= MaxClients; i++)
    {
        g_bDominava[client][i] = false;
        g_bDominado[client][i] = false;
    }
}

/**
 * As netprops de dominância existem neste jogo?
 *
 * Perguntado uma vez só, com um cliente válido em mãos — `HasEntProp` precisa
 * de uma entidade de verdade. O resultado vai pro log nos dois casos, porque
 * "o plugin não fez nada e não disse por quê" é o pior resultado possível.
 */
void Lendas_Detectar(int client)
{
    if (g_iTemNetprops != -1)
    {
        return;
    }

    bool tem = HasEntProp(client, Prop_Send, "m_bPlayerDominated")
            && HasEntProp(client, Prop_Send, "m_bPlayerDominatingMe");

    g_iTemNetprops = tem ? 1 : 0;

    if (tem)
    {
        LogMessage("Dominância disponível (m_bPlayerDominated + m_bPlayerDominatingMe). Proteção ligada.");
    }
    else
    {
        LogError("Netprops de dominância não existem neste jogo. Só o dinheiro será protegido.");
    }
}

/**
 * Roda ANTES do jogo processar a troca de time — é a única janela em que o
 * dinheiro e a dominância ainda são os de verdade.
 */
public Action Lendas_AntesDeTrocar(int client, const char[] comando, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return Plugin_Continue;
    }

    Lendas_Detectar(client);

    int time = GetClientTeam(client);
    if (time != TIME_TR && time != TIME_CT)
    {
        return Plugin_Continue;
    }

    // Sair de um time jogável: guarda tudo. Vale mesmo que ele esteja
    // trocando de TR pra CT — se a troca não for pro espectador, a devolução
    // simplesmente não acontece.
    g_iDinheiro[client] = GetEntProp(client, Prop_Send, "m_iAccount");
    g_fSaiuEm[client] = GetGameTime();
    g_bTemFoto[client] = true;

    if (g_iTemNetprops == 1)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            g_bDominava[client][i] = GetEntProp(client, Prop_Send, "m_bPlayerDominated", 1, i) != 0;
            g_bDominado[client][i] = GetEntProp(client, Prop_Send, "m_bPlayerDominatingMe", 1, i) != 0;
        }
    }

    if (g_CvarDebug.BoolValue)
    {
        LogMessage("foto de %N: dinheiro=%d", client, g_iDinheiro[client]);
    }

    return Plugin_Continue;
}

public void Evento_TrocaDeTime(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    // Quem está saindo do servidor não volta pra time nenhum.
    if (event.GetBool("disconnect"))
    {
        Lendas_Esquecer(client);
        return;
    }

    int novo = event.GetInt("team");
    int velho = event.GetInt("oldteam");

    // Só interessa a VOLTA: do espectador para um time jogável.
    if (velho != TIME_ESPECTADOR || (novo != TIME_TR && novo != TIME_CT))
    {
        return;
    }

    if (!g_bTemFoto[client])
    {
        return;
    }

    // O jogo ainda vai mexer no jogador depois deste evento. Devolver agora
    // seria sobrescrito; por isso a devolução espera o próximo quadro.
    RequestFrame(Lendas_DevolverNoFrame, GetClientUserId(client));
}

public void Lendas_DevolverNoFrame(any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client) || !g_bTemFoto[client])
    {
        return;
    }

    if (g_CvarDinheiro.BoolValue && g_iDinheiro[client] >= 0)
    {
        SetEntProp(client, Prop_Send, "m_iAccount", g_iDinheiro[client]);
    }

    if (g_CvarDominancia.BoolValue && g_iTemNetprops == 1)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsClientInGame(i))
            {
                continue;
            }

            SetEntProp(client, Prop_Send, "m_bPlayerDominated", g_bDominava[client][i] ? 1 : 0, 1, i);
            SetEntProp(client, Prop_Send, "m_bPlayerDominatingMe", g_bDominado[client][i] ? 1 : 0, 1, i);

            // O espelho no OUTRO jogador também foi limpo pelo jogo. Sem
            // isto, um lado veria a dominância e o outro não.
            SetEntProp(i, Prop_Send, "m_bPlayerDominatingMe", g_bDominava[client][i] ? 1 : 0, 1, client);
            SetEntProp(i, Prop_Send, "m_bPlayerDominated", g_bDominado[client][i] ? 1 : 0, 1, client);
        }
    }

    Lendas_Zoar(client);

    if (g_CvarDebug.BoolValue)
    {
        LogMessage("devolvido a %N: dinheiro=%d dominancia=%s",
            client, g_iDinheiro[client], g_iTemNetprops == 1 ? "sim" : "indisponivel");
    }

    // A foto se gasta ao ser usada: uma segunda volta sem ter saído de novo
    // devolveria um estado velho.
    g_bTemFoto[client] = false;
}

/**
 * A parte que dói: humilhação pública.
 *
 * Só dispara em quem ESTAVA sendo dominado na hora em que foi pro
 * espectador. Quem foi por motivo legítimo — travou, telefone tocou, tanto
 * faz — não passa vergonha nenhuma. Sem essa checagem o plugin acusaria
 * inocente, que é pior do que não acusar ninguém.
 *
 * A multa é opcional e vem desligada. Num mix, tirar dinheiro de alguém
 * castiga o time inteiro pelo erro de um; a vergonha, não.
 */
void Lendas_Zoar(int client)
{
    if (!g_CvarZoar.BoolValue || g_iTemNetprops != 1)
    {
        return;
    }

    // Quem o dominava? Se ninguém, não houve fuga nenhuma.
    int dominadores = 0;
    int primeiro = -1;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_bDominado[client][i] && IsClientInGame(i))
        {
            dominadores++;
            if (primeiro == -1)
            {
                primeiro = i;
            }
        }
    }

    if (dominadores == 0)
    {
        return;
    }

    /**
     * FREIO 1: quanto tempo ficou fora.
     *
     * Quem foge de dominância volta correndo — é o sentido da jogada. Quem
     * saiu por motivo de verdade fica fora bem mais tempo, ou nem volta.
     * Passou da janela, o estado é devolvido do mesmo jeito (isso é justo
     * com ele E com quem o domina), mas ninguém é acusado de nada.
     */
    float fora = GetGameTime() - g_fSaiuEm[client];
    if (fora > g_CvarJanela.FloatValue)
    {
        if (g_CvarDebug.BoolValue)
        {
            LogMessage("%N ficou %.0fs no spec: fora da janela, sem cobrança.", client, fora);
        }
        return;
    }

    g_iTentativas[client]++;
    int vezes = g_iTentativas[client];

    /**
     * FREIO 2: a primeira vez é de graça.
     *
     * Ninguém apanha por uma ocorrência isolada. Uma vez é acidente, motivo
     * real, ou curiosidade; repetir no mesmo mapa é padrão. Como o plugin já
     * devolve tudo, o espertinho não ganha nada esperando a segunda — só a
     * conta.
     */
    if (vezes <= g_CvarTolerancia.IntValue)
    {
        PrintToChat(client, "\x04[LENDAS]\x01 Você voltou como saiu: dinheiro e dominância intactos. Se repetir, tem multa.");
        if (g_CvarDebug.BoolValue)
        {
            LogMessage("%N: tentativa %d dentro da tolerancia, so aviso.", client, vezes);
        }
        return;
    }

    char extra[64];
    if (vezes > 1)
    {
        Format(extra, sizeof(extra), " Já é a \x04%dª vez\x01.", vezes);
    }
    else
    {
        extra = "";
    }

    if (dominadores == 1)
    {
        PrintToChatAll("\x04[LENDAS]\x01 \x03%N\x01 correu pro espectador pra fugir da dominância de \x03%N\x01. Voltou do mesmo jeito.%s",
            client, primeiro, extra);
    }
    else
    {
        PrintToChatAll("\x04[LENDAS]\x01 \x03%N\x01 correu pro espectador pra fugir de \x03%d\x01 dominâncias. Voltou com todas.%s",
            client, dominadores, extra);
    }

    // Quem domina merece saber, e é essa mensagem que arranca o "kkkk" no mic.
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_bDominado[client][i] && IsClientInGame(i))
        {
            PrintToChat(i, "\x04[LENDAS]\x01 \x03%N\x01 tentou fugir da SUA dominância. Continua sendo seu.", client);
        }
    }

    PrintCenterText(client, "Não colou.");

    char som[PLATFORM_MAX_PATH];
    g_CvarSom.GetString(som, sizeof(som));
    if (som[0] != EOS)
    {
        EmitSoundToAll(som);
    }

    int multa = g_CvarMulta.IntValue;
    if (multa > 0)
    {
        int agora = GetEntProp(client, Prop_Send, "m_iAccount");
        int novo = agora - multa;
        SetEntProp(client, Prop_Send, "m_iAccount", novo < 0 ? 0 : novo);
        PrintToChat(client, "\x04[LENDAS]\x01 Multa de \x03$%d\x01 pela tentativa.", multa);
    }
}
