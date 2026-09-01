#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.3.0"
#define HITGROUP_HEAD 1

public Plugin myinfo =
{
    name = "[LENDAS] Headshot FX",
    author = "LENDAS / Codex",
    description = "Cria um efeito discreto de sangue no local de headshots.",
    version = PLUGIN_VERSION,
    url = ""
};

ConVar g_CvarEnabled;
ConVar g_CvarBodyAmount;
ConVar g_CvarHeadshotAmount;
ConVar g_CvarHeadshotSprayBursts;
ConVar g_CvarWindow;
ConVar g_CvarDebug;

float g_LastHeadPosition[MAXPLAYERS + 1][3];
float g_LastHeadHitTime[MAXPLAYERS + 1];
int g_LastHeadAttacker[MAXPLAYERS + 1];
ConVar g_CvarSprayDir;
ConVar g_CvarSpraySize;
ConVar g_CvarSpread;
ConVar g_CvarBodyBursts;
ConVar g_CvarDamageScale;

bool g_LoggedBloodEntityFailure;

/**
 * Altura do impacto por hitgroup, medida do pé do jogador.
 *
 * O plugin espirrava todo tiro de corpo a 42 unidades — altura de barriga.
 * Um tiro na perna soltava sangue no peito, e o efeito não conversava com
 * onde a bala entrou. Estes números são as alturas aproximadas de cada
 * parte num modelo de pé (72 de altura, olhos a ~64).
 */
int  g_iHitgroupZ[] = { 42, 62, 52, 42, 50, 50, 22, 22 };
int g_BloodSpriteModel;
int g_BloodDropModel;

public void OnPluginStart()
{
    CreateConVar("lendas_headshotfx_version", PLUGIN_VERSION, "Versão do [LENDAS] Headshot FX.", FCVAR_NOTIFY | FCVAR_DONTRECORD);
    g_CvarEnabled = CreateConVar("lendas_headshotfx_enabled", "1", "Ativa o efeito de sangue em headshots. 0 = desligado, 1 = ligado.", FCVAR_NONE, true, 0.0, true, 1.0);
    g_CvarBodyAmount = CreateConVar("lendas_headshotfx_body_amount", "8", "Intensidade do impacto de sangue em acertos não fatais. 0 = desliga esse impacto.", FCVAR_NONE, true, 0.0, true, 100.0);
    g_CvarHeadshotAmount = CreateConVar("lendas_headshotfx_headshot_amount", "60", "Intensidade da explosão de sangue no headshot fatal.", FCVAR_NONE, true, 1.0, true, 100.0);
    g_CvarHeadshotSprayBursts = CreateConVar("lendas_headshotfx_headshot_spray_bursts", "3", "Número de pulsos do jato de sangue em headshot fatal. 0 = desliga o jato.", FCVAR_NONE, true, 0.0, true, 6.0);
    g_CvarWindow = CreateConVar("lendas_headshotfx_hit_window", "0.50", "Janela máxima, em segundos, entre o dano na cabeça e a morte para confirmar a posição do efeito.", FCVAR_NONE, true, 0.05, true, 2.0);
    g_CvarDebug = CreateConVar("lendas_headshotfx_debug", "0", "Registra diagnósticos de headshot no console do servidor. 0 = desligado, 1 = ligado.", FCVAR_NONE, true, 0.0, true, 1.0);

    AutoExecConfig(true, "lendas_headshotfx", "sourcemod");

    HookEvent("player_hurt", Event_PlayerHurt, EventHookMode_Post);
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);

    g_CvarSprayDir = CreateConVar("lendas_headshotfx_spray_dir", "1",
        "Sangue voa na direção do tiro em vez de sempre pra cima.", _, true, 0.0, true, 1.0);
    g_CvarSpraySize = CreateConVar("lendas_headshotfx_spray_size", "14",
        "Tamanho do jato de sangue do headshot.");
    g_CvarSpread = CreateConVar("lendas_headshotfx_spread", "0.35",
        "Abertura do jato. 0 = feixe reto, 1 = espalha pra todo lado.");
    g_CvarBodyBursts = CreateConVar("lendas_headshotfx_body_bursts", "1",
        "Jatos de sangue num tiro no corpo. 0 = só o respingo.");
    g_CvarDamageScale = CreateConVar("lendas_headshotfx_damage_scale", "1",
        "Tiro que dói mais espirra mais sangue.", _, true, 0.0, true, 1.0);

    PrecacheBloodSprites();
}

public void OnMapStart()
{
    PrecacheBloodSprites();
}

public void OnClientDisconnect(int client)
{
    ClearHeadHit(client);
}

public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_CvarEnabled.BoolValue)
    {
        return;
    }

    int victim = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    if (!IsValidAliveClient(victim) || !IsValidClient(attacker) || attacker == victim)
    {
        return;
    }

    int hitgroup = event.GetInt("hitgroup");
    int remainingHealth = event.GetInt("health");

    if (hitgroup == HITGROUP_HEAD)
    {
        GetClientEyePosition(victim, g_LastHeadPosition[victim]);
        g_LastHeadHitTime[victim] = GetGameTime();
        g_LastHeadAttacker[victim] = attacker;

        // Se o jogador sobreviveu ao headshot, dá um retorno visual leve.
        // Se morreu, o player_death emitirá apenas o efeito forte abaixo.
        if (remainingHealth > 0 && g_CvarBodyAmount.IntValue > 0)
        {
            int qtd = Lendas_QuantidadePorDano(g_CvarBodyAmount.IntValue, event.GetInt("dmg_health"));
            CreateBloodEffect(g_LastHeadPosition[victim], qtd);
            Lendas_Jato(g_LastHeadPosition[victim], attacker, g_CvarBodyBursts.IntValue);
        }
    }
    else if (g_CvarBodyAmount.IntValue > 0)
    {
        float bodyPosition[3];
        GetClientAbsOrigin(victim, bodyPosition);
        bodyPosition[2] += Lendas_AlturaDoImpacto(victim, hitgroup);

        int qtd = Lendas_QuantidadePorDano(g_CvarBodyAmount.IntValue, event.GetInt("dmg_health"));
        CreateBloodEffect(bodyPosition, qtd);
        Lendas_Jato(bodyPosition, attacker, g_CvarBodyBursts.IntValue);
    }

    if (g_CvarDebug.BoolValue)
    {
        PrintToServer("[LENDAS Headshot FX] dano: atacante=%N vítima=%N hitgroup=%d vida=%d", attacker, victim, hitgroup, remainingHealth);
    }
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_CvarEnabled.BoolValue || !event.GetBool("headshot"))
    {
        return;
    }

    int victim = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    if (!IsValidClient(victim) || !IsValidClient(attacker) || attacker == victim)
    {
        return;
    }

    float elapsed = GetGameTime() - g_LastHeadHitTime[victim];
    bool hasMatchingHeadPosition = g_LastHeadAttacker[victim] == attacker
        && elapsed >= 0.0
        && elapsed <= g_CvarWindow.FloatValue;

    if (!hasMatchingHeadPosition)
    {
        if (g_CvarDebug.BoolValue)
        {
            PrintToServer("[LENDAS Headshot FX] headshot sem posição confirmada: atacante=%N vítima=%N intervalo=%.3f", attacker, victim, elapsed);
        }

        ClearHeadHit(victim);
        return;
    }

    CreateBloodEffect(g_LastHeadPosition[victim], g_CvarHeadshotAmount.IntValue);
    Lendas_Jato(g_LastHeadPosition[victim], attacker, g_CvarHeadshotSprayBursts.IntValue);

    if (g_CvarDebug.BoolValue)
    {
        PrintToServer("[LENDAS Headshot FX] efeito emitido: atacante=%N vítima=%N intervalo=%.3f", attacker, victim, elapsed);
    }

    ClearHeadHit(victim);
}

void PrecacheBloodSprites()
{
    // Sprite nativo do CS:S; não requer FastDL nem whitelist adicional.
    g_BloodSpriteModel = PrecacheDecal("sprites/blood.vmt");
    g_BloodDropModel = g_BloodSpriteModel;
}

/**
 * Jato de sangue saindo do ponto atingido.
 *
 * Duas mudanças em relação ao anterior, que jogava tudo reto pra cima:
 *
 * 1. A direção é a do TIRO — do atirador para a vítima. Sangue que sobe
 *    igual em todo headshot lê como fonte; sangue que sai pelo outro lado
 *    da cabeça lê como bala atravessando.
 * 2. Cada jato sai com um desvio aleatório dentro de um cone, então os
 *    três não saem empilhados na mesma linha.
 *
 * Sem atirador válido (queda, dano de mundo), volta pro jato pra cima — é
 * o que sobra quando não existe direção de tiro.
 */
void Lendas_Jato(const float position[3], int attacker, int bursts)
{
    if (bursts <= 0 || g_BloodSpriteModel <= 0 || g_BloodDropModel <= 0)
    {
        return;
    }

    float direcao[3] = {0.0, 0.0, 1.0};
    if (g_CvarSprayDir.BoolValue)
    {
        Lendas_DirecaoDoTiro(attacker, position, direcao);
    }

    DataPack data = new DataPack();
    data.WriteFloat(position[0]);
    data.WriteFloat(position[1]);
    data.WriteFloat(position[2]);
    data.WriteFloat(direcao[0]);
    data.WriteFloat(direcao[1]);
    data.WriteFloat(direcao[2]);
    data.WriteCell(bursts);

    CreateTimer(0.04, Timer_HeadshotSpray, data, TIMER_REPEAT | TIMER_DATA_HNDL_CLOSE | TIMER_FLAG_NO_MAPCHANGE);
}

/**
 * Do olho do atirador até o ponto atingido, normalizado.
 *
 * O alvo é a posição de impacto JÁ GUARDADA, não o olho da vítima lido na
 * hora: no `player_death` a vítima já morreu e a posição dela não vale mais
 * nada. A posição guardada é de quando a bala entrou, que é justamente de
 * onde o sangue tem que sair.
 */
bool Lendas_DirecaoDoTiro(int attacker, const float alvo[3], float saida[3])
{
    if (!IsValidClient(attacker))
    {
        return false;
    }

    float de[3];
    GetClientEyePosition(attacker, de);
    SubtractVectors(alvo, de, saida);

    if (GetVectorLength(saida) < 1.0)
    {
        return false;
    }

    NormalizeVector(saida, saida);
    return true;
}

/**
 * Mais dano, mais sangue — até o dobro.
 *
 * Uma facada e um tiro de AWP soltavam exatamente a mesma coisa. Escalar
 * pelo dano é o que dá peso diferente a tiros diferentes, que era metade
 * do pedido de "melhorar a sensação de tiro no corpo".
 */
int Lendas_QuantidadePorDano(int base, int dano)
{
    if (!g_CvarDamageScale.BoolValue || dano <= 0)
    {
        return base;
    }

    // 25 de dano = quantidade base; 50 ou mais = o dobro.
    float fator = 0.6 + (float(dano) / 35.0);
    if (fator > 2.0)
    {
        fator = 2.0;
    }

    int qtd = RoundToNearest(float(base) * fator);
    return qtd < 1 ? 1 : qtd;
}

/** Altura do impacto conforme a parte atingida. Ver g_iHitgroupZ. */
float Lendas_AlturaDoImpacto(int victim, int hitgroup)
{
    int z = (hitgroup >= 0 && hitgroup < sizeof(g_iHitgroupZ)) ? g_iHitgroupZ[hitgroup] : 42;

    // Agachado, o corpo inteiro desce: sem isto o sangue sai flutuando
    // acima da cabeça de quem levou o tiro agachado.
    if (IsValidClient(victim) && (GetEntityFlags(victim) & FL_DUCKING))
    {
        return float(z) * 0.55;
    }

    return float(z);
}

public Action Timer_HeadshotSpray(Handle timer, DataPack data)
{
    data.Reset();

    float position[3], direction[3];
    position[0] = data.ReadFloat();
    position[1] = data.ReadFloat();
    position[2] = data.ReadFloat();
    direction[0] = data.ReadFloat();
    direction[1] = data.ReadFloat();
    direction[2] = data.ReadFloat();
    int burstsRemaining = data.ReadCell();

    // Cada jato desvia um pouco: tres saidas identicas empilhadas leem como
    // um borrao so, nao como sangue espirrando.
    float espalhado[3];
    Lendas_Espalhar(direction, espalhado);

    int color[4] = {255, 0, 0, 255};
    TE_SetupBloodSprite(position, espalhado, color, g_CvarSpraySize.IntValue,
        g_BloodSpriteModel, g_BloodDropModel);
    TE_SendToAll();

    burstsRemaining--;
    if (burstsRemaining <= 0)
    {
        return Plugin_Stop;
    }

    // O ponto anda um pouco na direcao do tiro a cada jato: o rastro
    // acompanha a bala em vez de ficar preso onde ela entrou.
    data.Reset();
    data.WriteFloat(position[0] + direction[0] * 3.0);
    data.WriteFloat(position[1] + direction[1] * 3.0);
    data.WriteFloat(position[2] + direction[2] * 3.0 + 1.0);
    data.WriteFloat(direction[0]);
    data.WriteFloat(direction[1]);
    data.WriteFloat(direction[2]);
    data.WriteCell(burstsRemaining);
    return Plugin_Continue;
}

/** Desvia a direção dentro de um cone. Ver lendas_headshotfx_spread. */
void Lendas_Espalhar(const float direcao[3], float saida[3])
{
    float abertura = g_CvarSpread.FloatValue;

    saida[0] = direcao[0] + GetRandomFloat(-abertura, abertura);
    saida[1] = direcao[1] + GetRandomFloat(-abertura, abertura);
    saida[2] = direcao[2] + GetRandomFloat(-abertura, abertura);

    if (GetVectorLength(saida) < 0.01)
    {
        saida = direcao;
        return;
    }

    NormalizeVector(saida, saida);
}

void CreateBloodEffect(const float position[3], int amountValue)
{
    int blood = CreateEntityByName("env_blood");
    if (blood == -1)
    {
        if (!g_LoggedBloodEntityFailure)
        {
            LogError("Não foi possível criar a entidade env_blood. O efeito foi ignorado.");
            g_LoggedBloodEntityFailure = true;
        }

        return;
    }

    char amount[8];
    IntToString(amountValue, amount, sizeof(amount));

    DispatchKeyValue(blood, "color", "0");
    DispatchKeyValue(blood, "amount", amount);
    // Não usar a flag 2 (Blood Stream): no CS:S ela pode renderizar magenta/roxo
    // por falta de textura compatível. Mantemos direção aleatória + decal de sangue.
    DispatchKeyValue(blood, "spawnflags", "9");
    TeleportEntity(blood, position, NULL_VECTOR, NULL_VECTOR);
    DispatchSpawn(blood);
    AcceptEntityInput(blood, "EmitBlood");

    CreateTimer(0.10, Timer_RemoveBloodEntity, EntIndexToEntRef(blood), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_RemoveBloodEntity(Handle timer, any entityRef)
{
    int entity = EntRefToEntIndex(entityRef);
    if (entity != INVALID_ENT_REFERENCE)
    {
        RemoveEntity(entity);
    }

    return Plugin_Stop;
}

bool IsValidClient(int client)
{
    return client >= 1 && client <= MaxClients && IsClientInGame(client);
}

bool IsValidAliveClient(int client)
{
    return IsValidClient(client) && IsPlayerAlive(client);
}

void ClearHeadHit(int client)
{
    g_LastHeadHitTime[client] = 0.0;
    g_LastHeadAttacker[client] = 0;
}
