#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <clientprefs>
#include <sdkhooks>

#define PLUGIN_VERSION "1.6.0"

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
 * O valor escolhido vai pros dois netprops de FOV, fica guardado num cookie
 * do clientprefs e é reposto a cada spawn e a cada troca de arma.
 *
 * O PROBLEMA DAS ARMAS INVISÍVEIS, e a aposta desta versão:
 *
 * Escrever `m_iFOV` é o único jeito de o mundo abrir de verdade — mexer só no
 * `m_iDefaultFOV` deixa a visão travada em 90 e apenas aproxima a arma da
 * cara, medido em jogo. Só que o CS:S trata `m_iFOV` diferente de zero como
 * "estou de luneta" e para de desenhar a arma.
 *
 * O `ShouldDraw()` do viewmodel no SDK aberto não tem condição nenhuma de
 * FOV, então quem esconde é código do CS:S que a Valve não publicou. Restam
 * duas possibilidades, e elas se distinguem por teste:
 *
 *   - o servidor marca `EF_NODRAW` no viewmodel  -> limpar a marca resolve;
 *   - o cliente decide sozinho não desenhar      -> não tem jeito, ponto.
 *
 * `Lendas_PosPensar` limpa a marca. Se a arma continuar sumida, é a segunda
 * possibilidade e este caminho está encerrado.
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
ConVar g_CvarPasso;

/** Bandeira do engine: viewmodel marcado assim não é desenhado. const.h. */
#define EF_NODRAW (1 << 5)

/**
 * FOV que ESTE plugin escreveu, por jogador. 0 = não mexemos nele.
 *
 * Serve pra distinguir o nosso FOV do zoom de verdade da AWP: quando o
 * `m_iFOV` do jogador é diferente deste valor, quem mexeu foi a arma, e aí
 * não se força arma nenhuma a aparecer — a luneta tem que continuar
 * escondendo o modelo, como sempre fez.
 */
int g_iEscolhido[MAXPLAYERS + 1];

/** Experimento de posição do viewmodel: frente, lado, altura. Ver sm_vmteste. */
float g_fDeslocamento[MAXPLAYERS + 1][3];
bool g_bDeslocando[MAXPLAYERS + 1];

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
    g_CvarPasso = CreateConVar("lendas_fov_passo", "5",
        "De quanto em quanto o menu oferece os valores.", _, true, 1.0, true, 50.0);

    g_hCookie = RegClientCookie("lendas_fov", "FOV escolhido pelo jogador", CookieAccess_Private);

    RegConsoleCmd("sm_fov", Comando_Fov, "Escolhe seu campo de visão. Sem valor, abre o menu.");
    RegConsoleCmd("sm_vmteste", Comando_VmTeste, "Experimento: sm_vmteste <frente> <lado> <altura>. Move a arma so pra voce.");
    RegConsoleCmd("sm_fovteste", Comando_FovTeste, "Diagnostico: sm_fovteste <m_iFOV> [m_iDefaultFOV]. Aplica so em voce.");
    HookEvent("player_spawn", Evento_Spawn);

    AutoExecConfig(true, "lendas_fov");

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
    g_iEscolhido[client] = 0;
    g_bDeslocando[client] = false;
    SDKHook(client, SDKHook_PostThinkPost, Lendas_MoverViewmodel);
    SDKHook(client, SDKHook_WeaponSwitchPost, Lendas_TrocaDeArma);
}

public void OnClientDisconnect(int client)
{
    g_iEscolhido[client] = 0;
}

/**
 * Trocar de arma zera o FOV escolhido.
 *
 * O jogo reseta a visão ao guardar a arma anterior — é o mesmo caminho que
 * tira o zoom da AWP quando se troca de arma com a mira aberta. Ele não sabe
 * distinguir "sair da mira" de "voltar pro FOV que o jogador escolheu", e
 * manda os dois de volta pro padrão.
 *
 * Reaplicar no spawn não bastava: a primeira troca de arma da rodada já
 * desfazia. Aqui a escolha é reposta a cada troca.
 *
 * Não precisa checar se está com mira: guardar a arma sempre fecha o zoom
 * antes, então neste ponto o jogador nunca está mirando.
 */
public void Lendas_TrocaDeArma(int client, int weapon)
{
    // O jogo escreve o FOV DEPOIS deste callback. Escrever agora seria
    // sobrescrito no mesmo frame, e o bug continuaria igual.
    RequestFrame(Lendas_ReaplicarNoFrame, GetClientUserId(client));
}

public void Lendas_ReaplicarNoFrame(any userid)
{
    int client = GetClientOfUserId(userid);
    if (client > 0 && IsClientInGame(client) && IsPlayerAlive(client))
    {
        Lendas_AplicarGuardado(client);
    }
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

    // Sem argumento abre o menu; com número continua funcionando pra quem
    // já sabe o valor que quer e não quer navegar.
    if (args < 1)
    {
        Lendas_AbrirMenu(client);
        return Plugin_Handled;
    }

    char arg[8];
    GetCmdArg(1, arg, sizeof(arg));
    Lendas_Definir(client, StringToInt(arg), minimo, maximo);
    return Plugin_Handled;
}

/**
 * Experimento: dá pro SERVIDOR mover a arma na tela?
 *
 * É a pergunta que decide se o ajuste de posição estilo CS:GO
 * (`viewmodel_offset_x/y/z`) é possível aqui. Esses cvars não existem no
 * CS:S, e a posição do viewmodel é calculada no cliente a cada quadro — se
 * for só isso, escrever a origem pelo servidor não gruda e o cliente
 * desenha no lugar de sempre.
 *
 * Os eixos seguem a visão do jogador, não o mundo, que é como o CS:GO faz:
 * frente empurra a arma pra longe da mão, lado joga pra direita (positivo)
 * ou esquerda (negativo), altura sobe e desce.
 *
 * `sm_vmteste 0 0 0` desliga. Afeta só quem chama.
 */
public Action Comando_VmTeste(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return Plugin_Handled;
    }

    if (args < 3)
    {
        ReplyToCommand(client, "[LENDAS] uso: sm_vmteste <frente> <lado> <altura>   (ex: 8 0 0)");
        return Plugin_Handled;
    }

    char a[3][16];
    for (int i = 0; i < 3; i++)
    {
        GetCmdArg(i + 1, a[i], sizeof(a[]));
        g_fDeslocamento[client][i] = StringToFloat(a[i]);
    }

    g_bDeslocando[client] = (g_fDeslocamento[client][0] != 0.0
        || g_fDeslocamento[client][1] != 0.0 || g_fDeslocamento[client][2] != 0.0);

    Lendas_Diag(client, "deslocamento: frente=%.1f lado=%.1f altura=%.1f (%s)",
        g_fDeslocamento[client][0], g_fDeslocamento[client][1], g_fDeslocamento[client][2],
        g_bDeslocando[client] ? "ligado" : "desligado");
    return Plugin_Handled;
}

/** Empurra a origem do viewmodel a cada tick, nos eixos da visão. */
public void Lendas_MoverViewmodel(int client)
{
    if (!g_bDeslocando[client] || !IsPlayerAlive(client))
    {
        return;
    }

    float olhos[3], frente[3], lado[3], cima[3];
    GetClientEyeAngles(client, olhos);
    GetAngleVectors(olhos, frente, lado, cima);

    int total = GetEntPropArraySize(client, Prop_Send, "m_hViewModel");
    for (int i = 0; i < total; i++)
    {
        int vm = GetEntPropEnt(client, Prop_Send, "m_hViewModel", i);
        if (vm <= 0)
        {
            continue;
        }

        float pos[3];
        GetEntPropVector(vm, Prop_Send, "m_vecOrigin", pos);
        for (int e = 0; e < 3; e++)
        {
            pos[e] += frente[e] * g_fDeslocamento[client][0]
                    + lado[e]   * g_fDeslocamento[client][1]
                    + cima[e]   * g_fDeslocamento[client][2];
        }
        TeleportEntity(vm, pos, NULL_VECTOR, NULL_VECTOR);
    }
}

/**
 * Diagnóstico. Escreve o FOV SÓ em quem chamou e registra o que o jogo fez.
 *
 * O segundo argumento é o `m_iDefaultFOV`, que por muito tempo foi escrito
 * sempre igual ao `m_iFOV`. A compensação de viewmodel do Source só age
 * quando os dois DIFEREM, então poder separá-los é o que permite varrer as
 * combinações sem recompilar a cada tentativa.
 *
 * Sai no console de quem pediu e no log do servidor — o log é o que permite
 * ler o resultado de fora, sem pedir copia-e-cola.
 */
public Action Comando_FovTeste(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
    {
        return Plugin_Handled;
    }

    if (args >= 1)
    {
        char arg[8];
        GetCmdArg(1, arg, sizeof(arg));
        int fov = StringToInt(arg);

        int padrao = fov;
        if (args >= 2)
        {
            char arg2[8];
            GetCmdArg(2, arg2, sizeof(arg2));
            padrao = StringToInt(arg2);
        }

        SetEntProp(client, Prop_Send, "m_iDefaultFOV", padrao);
        SetEntProp(client, Prop_Send, "m_iFOV", fov);
        g_iEscolhido[client] = fov;
        Lendas_Diag(client, "escrevi m_iFOV=%d e m_iDefaultFOV=%d", fov, padrao);
    }

    Lendas_Diag(client, "===== estado do FOV =====");
    Lendas_Diag(client, "m_iFOV .......... %d", GetEntProp(client, Prop_Send, "m_iFOV"));
    Lendas_Diag(client, "m_iDefaultFOV ... %d", GetEntProp(client, Prop_Send, "m_iDefaultFOV"));

    // Netprops de zoom que PODEM não existir. Perguntar antes de ler é o que
    // evita repetir o erro do m_bIsScoped no lendas_noscope.
    char talvez[3][20] = { "m_hZoomOwner", "m_bResumeZoom", "m_iLastZoom" };
    for (int i = 0; i < sizeof(talvez); i++)
    {
        if (HasEntProp(client, Prop_Send, talvez[i]))
        {
            Lendas_Diag(client, "%s = %d", talvez[i], GetEntProp(client, Prop_Send, talvez[i]));
        }
    }

    // TODOS os slots, não só o zero: o lendas_skins põe a skin num viewmodel
    // separado e esconde o de baixo. Olhar só o slot 0 conta meia história.
    int total = GetEntPropArraySize(client, Prop_Send, "m_hViewModel");
    Lendas_Diag(client, "slots de viewmodel: %d", total);
    for (int i = 0; i < total; i++)
    {
        int vm = GetEntPropEnt(client, Prop_Send, "m_hViewModel", i);
        if (vm <= 0)
        {
            continue;
        }
        int efeitos = GetEntProp(vm, Prop_Send, "m_fEffects");
        char modelo[128];
        GetEntPropString(vm, Prop_Data, "m_ModelName", modelo, sizeof(modelo));
        Lendas_Diag(client, "  slot %d: ent=%d m_fEffects=%d EF_NODRAW=%s modelo=%s",
            i, vm, efeitos, (efeitos & EF_NODRAW) ? "SIM" : "nao", modelo);
    }
    Lendas_Diag(client, "=========================");
    return Plugin_Handled;
}

/** Sai no console de quem pediu E no log do servidor, pra eu ler de fora. */
void Lendas_Diag(int client, const char[] formato, any ...)
{
    char linha[256];
    VFormat(linha, sizeof(linha), formato, 3);
    PrintToConsole(client, "%s", linha);
    LogMessage("[fovteste] %s", linha);
}

/** Aplica uma escolha, venha ela do menu ou do comando digitado. */
void Lendas_Definir(int client, int desejado, int minimo, int maximo)
{
    if (desejado == 0)
    {
        // Volta pro que o cliente tem no `fov_desired` dele, que é o valor
        // que ele veria sem este plugin.
        SetClientCookie(client, g_hCookie, "");
        QueryClientConVar(client, "fov_desired", Lendas_FovConsultado);
        PrintToChat(client, "\x04[LENDAS]\x01 Seu FOV voltou ao padrão.");
        return;
    }

    if (desejado < minimo || desejado > maximo)
    {
        PrintToChat(client, "\x04[LENDAS]\x01 O FOV precisa ficar entre \x04%d\x01 e \x04%d\x01. O padrão do jogo é %d.",
            minimo, maximo, FOV_PADRAO);
        return;
    }

    char cookie[8];
    IntToString(desejado, cookie, sizeof(cookie));
    SetClientCookie(client, g_hCookie, cookie);
    Lendas_Escrever(client, desejado);

    PrintToChat(client, "\x04[LENDAS]\x01 FOV ajustado para \x04%d\x01. Fica guardado para as próximas vezes.", desejado);
}

/**
 * O menu é montado a cada abertura, a partir das cvars de faixa e passo.
 *
 * Nada de lista fixa: se alguém apertar o limite no cfg, o menu deixa de
 * oferecer o que o plugin recusaria em seguida. Uma lista escrita à mão
 * ficaria mentindo na primeira vez que a faixa mudasse.
 */
void Lendas_AbrirMenu(int client)
{
    int minimo = g_CvarMin.IntValue;
    int maximo = g_CvarMax.IntValue;
    int passo = g_CvarPasso.IntValue;
    int atual = Lendas_FovAtual(client);

    Menu menu = new Menu(Lendas_MenuEscolha);
    menu.SetTitle("Campo de visão\nO padrão do CS:S é %d", FOV_PADRAO);

    char info[8], rotulo[48];
    bool atualNaLista = false;

    for (int fov = minimo; fov <= maximo; fov += passo)
    {
        IntToString(fov, info, sizeof(info));
        if (fov == atual)
        {
            atualNaLista = true;
            Format(rotulo, sizeof(rotulo), "%d  (o seu agora)", fov);
        }
        else
        {
            Format(rotulo, sizeof(rotulo), "%d", fov);
        }
        menu.AddItem(info, rotulo);
    }

    // O passo pode não fechar redondo no topo (de 90 a 110 de 7 em 7 pararia
    // em 104). O limite superior é o valor que mais interessa a quem abre o
    // menu, então ele entra de qualquer jeito.
    if ((maximo - minimo) % passo != 0)
    {
        IntToString(maximo, info, sizeof(info));
        Format(rotulo, sizeof(rotulo), "%d%s", maximo, maximo == atual ? "  (o seu agora)" : "");
        menu.AddItem(info, rotulo);
        if (maximo == atual)
        {
            atualNaLista = true;
        }
    }

    // Quem digitou !fov 97 tem um valor que não cai na lista. Sem esta linha
    // o menu não mostraria o FOV dele em lugar nenhum.
    if (!atualNaLista)
    {
        Format(rotulo, sizeof(rotulo), "%d  (o seu agora)", atual);
        menu.AddItem("atual", rotulo, ITEMDRAW_DISABLED);
    }

    menu.AddItem("0", "Voltar ao padrão");
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
    Lendas_Definir(client, StringToInt(info), g_CvarMin.IntValue, g_CvarMax.IntValue);

    // Reabre pra quem quiser comparar dois valores sem redigitar o comando.
    // O menu do CS:S fica na lateral e não tapa a visão do resultado.
    Lendas_AbrirMenu(client);
    return 0;
}

public void Lendas_FovConsultado(QueryCookie cookie, int client, ConVarQueryResult result,
    const char[] cvarName, const char[] cvarValue)
{
    if (result != ConVarQuery_Okay || !IsClientInGame(client))
    {
        return;
    }

    int valor = StringToInt(cvarValue);
    Lendas_Limpar(client, valor > 0 ? valor : FOV_PADRAO);
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
 * Só o `m_iDefaultFOV`. O `m_iFOV` fica em ZERO, de propósito.
 *
 * `m_iFOV` diferente de zero não quer dizer "este é o meu FOV" — quer dizer
 * "estou com zoom", e é nesse estado que o CS:S esconde o modelo da arma,
 * exatamente como acontece ao olhar pela luneta da AWP. Escrever os dois
 * (o que o plugin do Dr. McKay faz) deixa todo mundo de mãos vazias.
 *
 * Zero significa "sem zoom, use o padrão", e o jogo calcula a visão como
 * `m_iFOV == 0 ? m_iDefaultFOV : m_iFOV`. Então mexer só no padrão dá o FOV
 * escolhido com a arma à vista.
 *
 * De quebra, o `lendas_noscope` volta a acertar sozinho: fora da mira o
 * `m_iFOV` é 0 e não passa no teste dele; com a mira aberta o jogo escreve
 * 40 ou 15, abaixo de qualquer padrão, e o tiro conta como com mira.
 *
 * O zero é ESCRITO, não só presumido: quem usou a versão anterior ficou com
 * um valor preso aí, e sem esta linha continuaria sem ver a arma.
 */
void Lendas_Escrever(int client, int fov)
{
    SetEntProp(client, Prop_Send, "m_iDefaultFOV", fov);

    // m_iFOV em ZERO no caminho normal: escrever esse netprop abre o mundo
    // mas apaga a arma, e a investigação disso vive no sm_fovteste, que
    // afeta só quem chama. Ninguém joga com arma invisível por engano.
    SetEntProp(client, Prop_Send, "m_iFOV", 0);
    g_iEscolhido[client] = 0;
}

/** Devolve o jogador ao estado natural: sem FOV nosso, sem forçar desenho. */
void Lendas_Limpar(int client, int padrao)
{
    SetEntProp(client, Prop_Send, "m_iDefaultFOV", padrao);
    SetEntProp(client, Prop_Send, "m_iFOV", 0);
    g_iEscolhido[client] = 0;
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
