#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <clientprefs>

#define PLUGIN_VERSION "1.1.0"

/**
 * Posição da arma na tela, escolhida por jogador.
 *
 * Substitui o `lendas_fov`, que prometia campo de visão e não entregava. A
 * investigação inteira está registrada; o resumo do que importa aqui:
 *
 * - FOV de verdade NÃO é possível por plugin no CS:S. Escrever `m_iFOV` abre
 *   o mundo e apaga a arma, e o motivo é o cliente, não o servidor — medido:
 *   com a arma sumida, `m_hZoomOwner` era -1 e o `EF_NODRAW` do viewmodel
 *   estava desligado. Por isso só programa externo faz isso, e por isso o
 *   VAC bane;
 * - `viewmodel_fov` não funciona no CS:S, é resto morto do Half-Life 2;
 * - o que SOBROU e funciona é o `m_iDefaultFOV`. Com o `m_iFOV` em zero, ele
 *   não mexe na visão do mundo, mas desloca a câmera do viewmodel:
 *
 *       fovViewmodel = viewmodel_fov - (m_iDefaultFOV - 90)
 *
 *   Câmera mais fechada = arma ocupando mais tela. Ou seja, valor MAIOR
 *   aproxima a arma. É o contrário do CS:GO, e é exatamente por isso que o
 *   menu mostra o efeito e nunca o número.
 */

public Plugin myinfo =
{
    name = "[LENDAS] Posição da Arma",
    author = "LENDAS Network",
    description = "Deixa cada jogador escolher o quão perto a arma aparece na tela.",
    version = PLUGIN_VERSION,
    url = "https://www.lendascss.com.br"
};

/** O padrão do CS:S. Referência dos rótulos e valor de segurança. */
#define POSICAO_NORMAL 90

/**
 * O quanto se PODE descer, no limite.
 *
 * Abaixo do normal a arma se afasta — mas num teste com 70 ela sumiu de vez,
 * e eu não sei onde exatamente está a fronteira. Por isso o chão de verdade
 * é a cvar `lendas_viewmodel_min`, que sai de fábrica em 90 (nenhum degrau
 * de afastar) e só desce até aqui. Assim dá pra procurar o limite em jogo,
 * um valor por vez, sem recompilar e sem arriscar deixar o servidor inteiro
 * com arma invisível.
 */
#define POSICAO_PISO 70

ConVar g_CvarEnabled;
ConVar g_CvarMax;
ConVar g_CvarMin;

Handle g_hCookie;

public void OnPluginStart()
{
    CreateConVar("lendas_viewmodel_version", PLUGIN_VERSION, "Versão do [LENDAS] Posição da Arma.",
        FCVAR_NOTIFY | FCVAR_DONTRECORD);

    g_CvarEnabled = CreateConVar("lendas_viewmodel_enabled", "1",
        "Liga o comando !arma. 0 = desligado, 1 = ligado.", _, true, 0.0, true, 1.0);
    g_CvarMax = CreateConVar("lendas_viewmodel_max", "110",
        "O quanto a arma pode chegar perto. 90 = sem ajuste nenhum.", _, true, 90.0, true, 130.0);
    g_CvarMin = CreateConVar("lendas_viewmodel_min", "90",
        "O quanto a arma pode se afastar. 90 = nenhum degrau de afastar. CUIDADO: valores baixos podem deixar a arma invisível.",
        _, true, float(POSICAO_PISO), true, 90.0);

    g_hCookie = RegClientCookie("lendas_viewmodel", "Posição da arma escolhida", CookieAccess_Private);

    RegConsoleCmd("sm_arma", Comando_Arma, "Escolhe o quão perto sua arma aparece. Sem valor, abre o menu.");
    RegConsoleCmd("sm_viewmodel", Comando_Arma, "O mesmo que !arma.");
    HookEvent("player_spawn", Evento_Spawn);

    AutoExecConfig(true, "lendas_viewmodel");

    // Recarga no meio do mapa: quem já está jogando não passa pelo
    // OnClientPutInServer de novo e ficaria sem o hook até morrer.
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client))
        {
            OnClientPutInServer(client);
        }
    }
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_WeaponSwitchPost, Lendas_TrocaDeArma);
}

/**
 * Trocar de arma desfaz a escolha.
 *
 * Guardar a arma anterior devolve a visão ao padrão — é o mesmo caminho que
 * fecha o zoom da AWP. O jogo não distingue "sair da mira" de "voltar pro
 * que o jogador escolheu", então a escolha é reposta a cada troca.
 */
public void Lendas_TrocaDeArma(int client, int weapon)
{
    // O jogo escreve DEPOIS deste callback; escrever agora seria sobrescrito
    // no mesmo frame e o ajuste não duraria nada.
    RequestFrame(Lendas_ReporNoFrame, GetClientUserId(client));
}

public void Lendas_ReporNoFrame(any userid)
{
    int client = GetClientOfUserId(userid);
    if (client > 0 && IsClientInGame(client) && IsPlayerAlive(client))
    {
        Lendas_AplicarGuardado(client);
    }
}

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

public Action Comando_Arma(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return Plugin_Handled;
    }

    if (!g_CvarEnabled.BoolValue)
    {
        ReplyToCommand(client, "\x04[LENDAS]\x01 O ajuste de arma está desligado neste servidor.");
        return Plugin_Handled;
    }

    if (!AreClientCookiesCached(client))
    {
        ReplyToCommand(client, "\x04[LENDAS]\x01 Suas preferências ainda estão carregando. Tente de novo em alguns segundos.");
        return Plugin_Handled;
    }

    if (args < 1)
    {
        Lendas_AbrirMenu(client);
        return Plugin_Handled;
    }

    char arg[8];
    GetCmdArg(1, arg, sizeof(arg));
    Lendas_Definir(client, StringToInt(arg));
    return Plugin_Handled;
}

/** Aplica uma escolha, venha ela do menu ou do comando digitado. */
void Lendas_Definir(int client, int valor)
{
    int teto = Lendas_Teto();

    // Fora da faixa cai no normal, nunca num valor que o servidor recusaria.
    if (valor < Lendas_Chao() || valor > teto)
    {
        valor = POSICAO_NORMAL;
    }

    char cookie[8];
    IntToString(valor, cookie, sizeof(cookie));
    SetClientCookie(client, g_hCookie, cookie);
    Lendas_Escrever(client, valor);

    char rotulo[32];
    Lendas_Rotulo(valor, teto, rotulo, sizeof(rotulo));
    PrintToChat(client, "\x04[LENDAS]\x01 Arma: \x04%s\x01. Fica guardado para as próximas vezes.", rotulo);
}

/**
 * O rótulo que o jogador lê.
 *
 * Descreve o EFEITO, nunca o número. O valor por baixo é um FOV em que maior
 * aproxima — mostrar isso só confundiria quem conhece o CS:GO, onde a escala
 * corre para o outro lado.
 *
 * Os degraus são calculados sobre a faixa, não fixos: mexer no teto pela
 * cvar não deixa os rótulos mentindo.
 */
void Lendas_Rotulo(int valor, int teto, char[] saida, int tamanho)
{
    if (valor == POSICAO_NORMAL)
    {
        strcopy(saida, tamanho, "normal (padrão do jogo)");
        return;
    }

    if (valor < POSICAO_NORMAL)
    {
        int faixaLonge = POSICAO_NORMAL - Lendas_Chao();
        int passoLonge = (faixaLonge > 0) ? (((POSICAO_NORMAL - valor) * 3 - 1) / faixaLonge) : 0;

        switch (passoLonge)
        {
            case 0:  strcopy(saida, tamanho, "um pouco mais longe");
            case 1:  strcopy(saida, tamanho, "mais longe");
            default: strcopy(saida, tamanho, "bem longe");
        }
        return;
    }

    int faixa = teto - POSICAO_NORMAL;
    int degrau = (faixa > 0) ? (((valor - POSICAO_NORMAL) * 4 - 1) / faixa) : 0;

    switch (degrau)
    {
        case 0:  strcopy(saida, tamanho, "um pouco mais perto");
        case 1:  strcopy(saida, tamanho, "mais perto");
        case 2:  strcopy(saida, tamanho, "bem perto");
        default: strcopy(saida, tamanho, "colada");
    }
}

int Lendas_Teto()
{
    int teto = g_CvarMax.IntValue;
    return (teto < POSICAO_NORMAL) ? POSICAO_NORMAL : teto;
}

int Lendas_Chao()
{
    int chao = g_CvarMin.IntValue;
    if (chao > POSICAO_NORMAL) chao = POSICAO_NORMAL;
    if (chao < POSICAO_PISO) chao = POSICAO_PISO;
    return chao;
}

void Lendas_AbrirMenu(int client)
{
    int teto = Lendas_Teto();
    int atual = Lendas_Atual(client);

    Menu menu = new Menu(Lendas_MenuEscolha);
    menu.SetTitle("Posição da arma\nEscolha e veja na hora");

    char info[8], rotulo[32], item[64];
    for (int valor = Lendas_Chao(); valor <= teto; valor += 5)
    {
        IntToString(valor, info, sizeof(info));
        Lendas_Rotulo(valor, teto, rotulo, sizeof(rotulo));
        Format(item, sizeof(item), "%s%s", rotulo, valor == atual ? "  <-- o seu" : "");
        menu.AddItem(info, item);
    }

    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int Lendas_MenuEscolha(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }

    if (action != MenuAction_Select || !IsClientInGame(client))
    {
        return 0;
    }

    char info[8];
    menu.GetItem(item, info, sizeof(info));
    Lendas_Definir(client, StringToInt(info));

    // Reabre pra comparar dois degraus sem redigitar. O menu do CS:S fica na
    // lateral e não tapa a arma, que é justamente o que se quer olhar.
    Lendas_AbrirMenu(client);
    return 0;
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

    int valor = StringToInt(cookie);

    // Reconferido a cada spawn: se o servidor apertar o teto depois, quem
    // tinha um valor fora dele volta ao normal em vez de herdar privilégio.
    if (valor < Lendas_Chao() || valor > Lendas_Teto())
    {
        valor = POSICAO_NORMAL;
    }

    Lendas_Escrever(client, valor);
}

/**
 * `m_iDefaultFOV` recebe o valor; `m_iFOV` fica em ZERO, sempre.
 *
 * Zero significa "sem zoom, use o padrão". Escrever o `m_iFOV` é o que abre
 * o mundo E apaga a arma, e está provado que não há como ter um sem o outro
 * — então este plugin simplesmente não encosta nele.
 *
 * O zero é escrito, não presumido: quem testou as versões antigas do
 * lendas_fov pode ter um valor preso ali, e sem esta linha continuaria sem
 * ver a arma.
 */
void Lendas_Escrever(int client, int valor)
{
    SetEntProp(client, Prop_Send, "m_iDefaultFOV", valor);
    SetEntProp(client, Prop_Send, "m_iFOV", 0);
}

int Lendas_Atual(int client)
{
    if (HasEntProp(client, Prop_Send, "m_iDefaultFOV"))
    {
        int valor = GetEntProp(client, Prop_Send, "m_iDefaultFOV");
        if (valor > 0)
        {
            return valor;
        }
    }
    return POSICAO_NORMAL;
}
