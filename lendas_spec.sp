#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.0.0"

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

    // O menu de times manda `jointeam <n>`; alguns clientes mandam `spectate`.
    AddCommandListener(Lendas_AntesDeTrocar, "jointeam");
    AddCommandListener(Lendas_AntesDeTrocar, "spectate");

    HookEvent("player_team", Evento_TrocaDeTime, EventHookMode_Post);

    AutoExecConfig(true, "lendas_spec");
}

public void OnMapStart()
{
    // Mapa novo, partida nova: nenhuma foto sobrevive. Devolver dominância
    // de um mapa anterior seria inventar história.
    for (int i = 1; i <= MaxClients; i++)
    {
        Lendas_Esquecer(i);
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

    if (g_CvarDebug.BoolValue)
    {
        LogMessage("devolvido a %N: dinheiro=%d dominancia=%s",
            client, g_iDinheiro[client], g_iTemNetprops == 1 ? "sim" : "indisponivel");
    }

    // A foto se gasta ao ser usada: uma segunda volta sem ter saído de novo
    // devolveria um estado velho.
    g_bTemFoto[client] = false;
}
