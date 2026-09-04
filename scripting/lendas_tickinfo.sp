#include <sourcemod>
#include <commandline>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.0.0"

/**
 * Diagnóstico de tickrate — lê de DENTRO do processo o que nenhum arquivo
 * conta de fora.
 *
 * O problema que motivou isto: o painel do host mostra `-tickrate 100`, o
 * addon `source-tickrate` está instalado, e mesmo assim o servidor roda a
 * 66.67. Medido pelo cabeçalho das demos: `playback_ticks / playback_time`
 * deu 0.01500s por tick em quatro mapas seguidos (100 tick daria 0.01000).
 *
 * De fora dá pra ver o arquivo de configuração e o binário do addon, mas
 * não dá pra ver as duas coisas que decidem a questão:
 *
 *   1. a linha de comando que o srcds REALMENTE recebeu — o `srcds_run` só
 *      repassa `$*`, e o painel pode estar pondo o parâmetro num lugar que
 *      não chega até aqui;
 *   2. o intervalo por tick em vigor agora.
 *
 * Com os dois no log, a conclusão é direta:
 *
 *   - sem `-tickrate` na linha  -> o painel não está passando o parâmetro;
 *   - `-tickrate 100` presente e intervalo 0.015 -> o parâmetro chega e o
 *     addon é que não está aplicando o hook.
 *
 * Plugin de leitura: não registra comando, não altera cvar, não toca em
 * nada do jogo. Serve o seu propósito e sai.
 */

public Plugin myinfo =
{
    name = "[LENDAS] Tick Info",
    author = "LENDAS Network",
    description = "Registra no log a linha de comando do srcds e o tickrate em vigor.",
    version = PLUGIN_VERSION,
    url = "https://www.lendascss.com.br"
};

public void OnPluginStart()
{
    Lendas_Relatar();
}

public void OnMapStart()
{
    Lendas_Relatar();
}

void Lendas_Relatar()
{
    float intervalo = GetTickInterval();
    float tickrate = (intervalo > 0.0) ? (1.0 / intervalo) : 0.0;

    LogMessage("=== tickrate ===");
    LogMessage("intervalo por tick em vigor: %.5f s  ->  %.2f tick", intervalo, tickrate);

    if (!FindCommandLineParam("-tickrate"))
    {
        LogMessage("-tickrate: AUSENTE da linha de comando do srcds.");
    }
    else
    {
        char pedido[32];
        GetCommandLineParam("-tickrate", pedido, sizeof(pedido), "(sem valor)");
        LogMessage("-tickrate: presente, valor \"%s\"", pedido);

        // A conclusão que interessa, escrita por extenso pra quem for ler o
        // log depois não precisar refazer a conta.
        if (tickrate > 0.0 && FloatAbs(tickrate - float(GetCommandLineParamInt("-tickrate", 0))) > 1.0)
        {
            LogMessage("CONCLUSAO: o parametro CHEGA no srcds mas NAO esta sendo aplicado.");
            LogMessage("           O addon source-tickrate e quem falhou, nao o painel.");
        }
        else
        {
            LogMessage("CONCLUSAO: tickrate aplicado corretamente.");
        }
    }

    // A linha inteira é o que revela um parâmetro escrito errado (aspas
    // sobrando, junto do anterior, depois de um `+` que o srcds trata como
    // comando de console).
    char linha[1024];
    if (GetCommandLine(linha, sizeof(linha)))
    {
        LogMessage("linha de comando: %s", linha);
    }
    else
    {
        LogMessage("linha de comando: nao foi possivel ler.");
    }

    LogMessage("=== fim tickrate ===");
}
