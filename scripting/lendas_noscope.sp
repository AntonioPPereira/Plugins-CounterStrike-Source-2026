#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.2.0"
#define SCOPE_PROP "m_bIsScoped"

public Plugin myinfo =
{
    name = "[LENDAS] No Scope",
    author = "LENDAS / Codex",
    description = "Anuncia eliminações de AWP e Scout sem mira, com distância aproximada.",
    version = PLUGIN_VERSION,
    url = ""
};

ConVar g_CvarEnabled;
ConVar g_CvarMinDistance;
ConVar g_CvarShotWindow;
ConVar g_CvarDebug;

bool g_LastShotWasNoScope[MAXPLAYERS + 1];
float g_LastShotTime[MAXPLAYERS + 1];
char g_LastShotWeapon[MAXPLAYERS + 1][16];
bool g_LoggedMissingScopeProp;

public void OnPluginStart()
{
    CreateConVar("lendas_noscope_version", PLUGIN_VERSION, "Versão do [LENDAS] No Scope.", FCVAR_NOTIFY | FCVAR_DONTRECORD);
    g_CvarEnabled = CreateConVar("lendas_noscope_enabled", "1", "Ativa os anúncios de no-scope. 0 = desligado, 1 = ligado.", FCVAR_NONE, true, 0.0, true, 1.0);
    g_CvarMinDistance = CreateConVar("lendas_noscope_min_distance", "0.0", "Distância mínima, em metros, para anunciar um no-scope. 0 = qualquer distância.", FCVAR_NONE, true, 0.0);
    g_CvarShotWindow = CreateConVar("lendas_noscope_shot_window", "0.25", "Janela máxima, em segundos, entre o disparo e a morte para validar o no-scope.", FCVAR_NONE, true, 0.05, true, 1.0);
    g_CvarDebug = CreateConVar("lendas_noscope_debug", "0", "Registra o diagnóstico de tiros e mortes no console do servidor. 0 = desligado, 1 = ligado.", FCVAR_NONE, true, 0.0, true, 1.0);

    AutoExecConfig(true, "lendas_noscope", "sourcemod");

    HookEvent("weapon_fire", Event_WeaponFire, EventHookMode_Post);
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);

    for (int client = 1; client <= MaxClients; client++)
    {
        ClearLastShot(client);
    }
}

public void OnClientDisconnect(int client)
{
    ClearLastShot(client);
}

public void Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    int attacker = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidAliveClient(attacker))
    {
        return;
    }

    char weapon[16];
    event.GetString("weapon", weapon, sizeof(weapon));

    if (g_CvarDebug.BoolValue)
    {
        PrintToServer("[LENDAS No Scope] weapon_fire recebido: jogador=%N arma_bruta='%s'", attacker, weapon);
    }

    if (!IsSupportedSniper(weapon))
    {
        return;
    }

    g_LastShotTime[attacker] = GetGameTime();
    g_LastShotWasNoScope[attacker] = !IsClientScoped(attacker);
    strcopy(g_LastShotWeapon[attacker], sizeof(g_LastShotWeapon[]), weapon);

    if (g_CvarDebug.BoolValue)
    {
        PrintToServer("[LENDAS No Scope] weapon_fire: jogador=%N arma='%s' no_scope=%d", attacker, weapon, g_LastShotWasNoScope[attacker]);
    }
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_CvarEnabled.BoolValue)
    {
        return;
    }

    int victim = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    if (!IsValidClient(victim) || !IsValidClient(attacker) || attacker == victim)
    {
        return;
    }

    char weapon[16];
    event.GetString("weapon", weapon, sizeof(weapon));

    if (g_CvarDebug.BoolValue)
    {
        PrintToServer("[LENDAS No Scope] player_death recebido: atacante=%N vítima=%N arma_bruta='%s'", attacker, victim, weapon);
    }

    if (!IsSupportedSniper(weapon))
    {
        if (g_CvarDebug.BoolValue)
        {
            PrintToServer("[LENDAS No Scope] player_death ignorado: arma do evento='%s'", weapon);
        }
        return;
    }

    float elapsed = GetGameTime() - g_LastShotTime[attacker];
    bool lastShotWasNoScope = g_LastShotWasNoScope[attacker];
    char lastShotWeapon[16];
    strcopy(lastShotWeapon, sizeof(lastShotWeapon), g_LastShotWeapon[attacker]);
    bool isNoScope = g_LastShotWasNoScope[attacker]
        && StrEqual(g_LastShotWeapon[attacker], weapon, false)
        && elapsed >= 0.0
        && elapsed <= g_CvarShotWindow.FloatValue;

    ClearLastShot(attacker);

    if (!isNoScope)
    {
        if (g_CvarDebug.BoolValue)
        {
            PrintToServer("[LENDAS No Scope] player_death rejeitado: atacante=%N arma='%s' ultimo_tiro='%s' no_scope=%d intervalo=%.3f limite=%.3f", attacker, weapon, lastShotWeapon, lastShotWasNoScope, elapsed, g_CvarShotWindow.FloatValue);
        }
        return;
    }

    float attackerOrigin[3];
    float victimOrigin[3];
    GetClientAbsOrigin(attacker, attackerOrigin);
    GetClientAbsOrigin(victim, victimOrigin);

    // Uma unidade do mundo Source equivale aproximadamente a uma polegada.
    float distanceMeters = GetVectorDistance(attackerOrigin, victimOrigin) * 0.0254;

    if (distanceMeters < g_CvarMinDistance.FloatValue)
    {
        if (g_CvarDebug.BoolValue)
        {
            PrintToServer("[LENDAS No Scope] player_death rejeitado: distância=%.1f m, mínimo=%.1f m", distanceMeters, g_CvarMinDistance.FloatValue);
        }
        return;
    }

    if (g_CvarDebug.BoolValue)
    {
        PrintToServer("[LENDAS No Scope] ANÚNCIO: %N matou %N, arma='%s', distância=%.1f m", attacker, victim, weapon, distanceMeters);
    }

    char weaponName[8];
    if (StrEqual(weapon, "awp", false))
    {
        strcopy(weaponName, sizeof(weaponName), "AWP");
    }
    else
    {
        strcopy(weaponName, sizeof(weaponName), "Scout");
    }

    PrintToChatAll("\x04[LENDAS]\x01 ★ \x07FFCC00NO SCOPE!\x01 %N eliminou %N \x07FF6666SEM MIRA\x01 com %s — \x04%d metros\x01!", attacker, victim, weaponName, RoundToNearest(distanceMeters));
}

bool IsSupportedSniper(const char[] weapon)
{
    return StrEqual(weapon, "awp", false) || StrEqual(weapon, "scout", false);
}

bool IsClientScoped(int client)
{
    int fov = -1;
    bool hasFov = HasEntProp(client, Prop_Send, "m_iFOV");
    if (hasFov)
    {
        fov = GetEntProp(client, Prop_Send, "m_iFOV");
    }

    bool hasScopedFlag = HasEntProp(client, Prop_Send, SCOPE_PROP);
    if (!hasScopedFlag)
    {
        if (!g_LoggedMissingScopeProp)
        {
            LogError("Não foi possível localizar a netprop %s. O plugin tentará usar m_iFOV como alternativa.", SCOPE_PROP);
            g_LoggedMissingScopeProp = true;
        }

        if (g_CvarDebug.BoolValue)
        {
            PrintToServer("[LENDAS No Scope] estado no disparo: m_bIsScoped=indisponível m_iFOV=%d disponivel=%d", fov, hasFov);
        }

        // No CS:S vanilla o FOV normal é 90 e o zoom reduz esse valor.
        // Sem a netprop, só classificamos como scope quando o FOV confirma zoom.
        //
        // A comparação é contra o FOV PADRÃO DO PRÓPRIO JOGADOR, não contra
        // 90 fixo. Sem plugin de FOV os dois são a mesma coisa e o resultado
        // não muda. Com um, o 90 fixo passa a mentir: quem escolhe 75 fica
        // permanentemente dentro da faixa lida como "com mira", e nenhuma
        // morte dele volta a contar como no-scope. O zoom real da AWP e da
        // scout sempre desce ABAIXO do padrão, seja ele qual for.
        int padrao = 90;
        if (HasEntProp(client, Prop_Send, "m_iDefaultFOV"))
        {
            int lido = GetEntProp(client, Prop_Send, "m_iDefaultFOV");
            if (lido > 0)
            {
                padrao = lido;
            }
        }

        return hasFov && fov > 0 && fov < padrao;
    }

    bool scopedFlag = GetEntProp(client, Prop_Send, SCOPE_PROP) != 0;

    if (g_CvarDebug.BoolValue)
    {
        PrintToServer("[LENDAS No Scope] estado no disparo: m_bIsScoped=%d m_iFOV=%d disponivel=%d", scopedFlag, fov, hasFov);
    }

    return scopedFlag;
}

bool IsValidClient(int client)
{
    return client >= 1 && client <= MaxClients && IsClientInGame(client);
}

bool IsValidAliveClient(int client)
{
    return IsValidClient(client) && IsPlayerAlive(client);
}

void ClearLastShot(int client)
{
    g_LastShotWasNoScope[client] = false;
    g_LastShotTime[client] = 0.0;
    g_LastShotWeapon[client][0] = '\0';
}
