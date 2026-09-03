#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <clientprefs>

#define PLUGIN_VERSION "1.0.0"

/**
 * FOV escolhido pelo jogador, guardado entre sessões.
 *
 * Equivalente ao "[ANY] Unrestricted FOV" do Dr. McKay, reescrito em vez de
 * instalado. Três motivos concretos, não preferência:
 *
 * 1. O fonte publicado dele depende de `easy_commands.inc`, que NÃO está no
 *    repositório — não dá pra compilar o que está publicado;
 * 2. ele carrega um auto-atualizador que baixa e troca o próprio .smx a
 *    partir de um host de terceiro. Num servidor de produção isso é código
 *    entrando sem ninguém olhar;
 * 3. metade dele é Team Fortress 2 (`TF2_OnConditionAdded`, `TFCond_Zoomed`),
 *    inútil aqui.
 *
 * O que ele faz e este também faz: `m_iFOV` e `m_iDefaultFOV` recebem o valor
 * escolhido, guardado num cookie do clientprefs e reaplicado a cada spawn.
 *
 * CONVERSA COM O lendas_noscope: aquele plugin decide se o tiro saiu com mira
 * comparando o `m_iFOV` do momento com o FOV padrão do jogador. Por isso os
 * DOIS valores são escritos aqui, sempre juntos e sempre iguais — o zoom real
 * da AWP e da scout desce abaixo do padrão e continua sendo detectado. Escrever
 * só o `m_iFOV` faria todo mundo com FOV abaixo de 90 parecer permanentemente
 * com mira. Ver `IsClientScoped` no lendas_noscope 1.2.0.
 */

public Plugin myinfo =
{
    name = "[LENDAS] FOV",
    author = "LENDAS Network",
    description = "Permite ao jogador escolher o próprio campo de visão.",
    version = PLUGIN_VERSION,
    url = "https://www.lendascss.com.br"
};

ConVar g_CvarEnabled;
ConVar g_CvarMin;
ConVar g_CvarMax;

Handle g_hCookie;

/** FOV padrão do CS:S. Serve de referência nas mensagens e no reset. */
#define FOV_PADRAO 90

public void OnPluginStart()
{
    CreateConVar("lendas_fov_version", PLUGIN_VERSION, "Versão do [LENDAS] FOV.",
        FCVAR_NOTIFY | FCVAR_DONTRECORD);

    g_CvarEnabled = CreateConVar("lendas_fov_enabled", "1",
        "Liga o comando !fov. 0 = desligado, 1 = ligado.", _, true, 0.0, true, 1.0);
    g_CvarMin = CreateConVar("lendas_fov_min", "90",
        "Menor FOV que o jogador pode escolher.", _, true, 20.0, true, 180.0);
    g_CvarMax = CreateConVar("lendas_fov_max", "110",
        "Maior FOV que o jogador pode escolher.", _, true, 20.0, true, 180.0);

    g_hCookie = RegClientCookie("lendas_fov", "FOV escolhido pelo jogador", CookieAccess_Private);

    RegConsoleCmd("sm_fov", Comando_Fov, "Escolhe seu campo de visão. Sem valor, mostra o atual.");
    HookEvent("player_spawn", Evento_Spawn);

    AutoExecConfig(true, "lendas_fov");
}

/** Cookie chegou depois do jogador já estar em jogo: aplica na hora. */
public void OnClientCookiesCached(int client)
{
    if (IsClientInGame(client) && IsPlayerAlive(client))
    {
        Lendas_AplicarGuardado(client);
    }
}

public void Evento_Spawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0 && IsClientInGame(client))
    {
        Lendas_AplicarGuardado(client);
    }
}

public Action Comando_Fov(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return Plugin_Handled;
    }

    if (!g_CvarEnabled.BoolValue)
    {
        ReplyToCommand(client, "\x04[LENDAS]\x01 O comando de FOV está desligado neste servidor.");
        return Plugin_Handled;
    }

    // Sem o cookie carregado não dá pra guardar a escolha, e guardar é metade
    // da graça: o jogador não quer redigitar isso toda vez que entra.
    if (!AreClientCookiesCached(client))
    {
        ReplyToCommand(client, "\x04[LENDAS]\x01 Suas preferências ainda estão carregando. Tente de novo em alguns segundos.");
        return Plugin_Handled;
    }

    int minimo = g_CvarMin.IntValue;
    int maximo = g_CvarMax.IntValue;

    if (args < 1)
    {
        ReplyToCommand(client, "\x04[LENDAS]\x01 Seu FOV agora é \x04%d\x01. Use \x04!fov <%d-%d>\x01 para mudar, ou \x04!fov 0\x01 para voltar ao seu padrão.",
            Lendas_FovAtual(client), minimo, maximo);
        return Plugin_Handled;
    }

    char arg[8];
    GetCmdArg(1, arg, sizeof(arg));
    int desejado = StringToInt(arg);

    if (desejado == 0)
    {
        // Volta pro que o cliente tem no `fov_desired` dele, que é o valor
        // que ele veria sem este plugin.
        SetClientCookie(client, g_hCookie, "");
        QueryClientConVar(client, "fov_desired", Lendas_FovConsultado);
        ReplyToCommand(client, "\x04[LENDAS]\x01 Seu FOV voltou ao padrão.");
        return Plugin_Handled;
    }

    if (desejado < minimo || desejado > maximo)
    {
        ReplyToCommand(client, "\x04[LENDAS]\x01 O FOV precisa ficar entre \x04%d\x01 e \x04%d\x01. O padrão do jogo é %d.",
            minimo, maximo, FOV_PADRAO);
        return Plugin_Handled;
    }

    char cookie[8];
    IntToString(desejado, cookie, sizeof(cookie));
    SetClientCookie(client, g_hCookie, cookie);
    Lendas_Escrever(client, desejado);

    ReplyToCommand(client, "\x04[LENDAS]\x01 FOV ajustado para \x04%d\x01. Fica guardado para as próximas vezes.", desejado);
    return Plugin_Handled;
}

public void Lendas_FovConsultado(QueryCookie cookie, int client, ConVarQueryResult result,
    const char[] cvarName, const char[] cvarValue)
{
    if (result != ConVarQuery_Okay || !IsClientInGame(client))
    {
        return;
    }

    int valor = StringToInt(cvarValue);
    Lendas_Escrever(client, valor > 0 ? valor : FOV_PADRAO);
}

void Lendas_AplicarGuardado(int client)
{
    if (!g_CvarEnabled.BoolValue || !AreClientCookiesCached(client))
    {
        return;
    }

    char cookie[8];
    GetClientCookie(client, g_hCookie, cookie, sizeof(cookie));
    if (cookie[0] == '\0')
    {
        return;
    }

    int fov = StringToInt(cookie);

    // A faixa é reconferida a cada spawn de propósito: se o servidor apertar
    // o limite depois, quem já tinha um valor fora dele volta ao padrão em
    // vez de ficar com um privilégio herdado.
    if (fov < g_CvarMin.IntValue || fov > g_CvarMax.IntValue)
    {
        return;
    }

    Lendas_Escrever(client, fov);
}

/**
 * Os dois netprops, sempre juntos.
 *
 * `m_iFOV` é o que se vê agora; `m_iDefaultFOV` é para onde o jogo volta ao
 * sair da mira. Escrever só o primeiro faria o FOV sumir no primeiro zoom.
 */
void Lendas_Escrever(int client, int fov)
{
    SetEntProp(client, Prop_Send, "m_iFOV", fov);
    SetEntProp(client, Prop_Send, "m_iDefaultFOV", fov);
}

int Lendas_FovAtual(int client)
{
    if (HasEntProp(client, Prop_Send, "m_iDefaultFOV"))
    {
        int valor = GetEntProp(client, Prop_Send, "m_iDefaultFOV");
        if (valor > 0)
        {
            return valor;
        }
    }
    return FOV_PADRAO;
}
