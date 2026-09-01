#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>

#pragma semicolon 1
#pragma newdecls required

// ============================================================================
// DEFINES & PATHS
// ============================================================================
#define PLUGIN_VERSION "2.2.0"

#define PREFIX " \x04[LENDAS]\x01"

// ============================================================================
// MODELOS & SONS
// ============================================================================
#define VIEW_MODEL  "models/lendas_css/v_eq_fraggrenade.mdl"
#define WORLD_MODEL "models/lendas_css/w_eq_fraggrenade_thrown.mdl"

#define SOUND_DRAW     "weapons/by_daimon/draw2.wav"
#define SOUND_EXPLODE  "weapons/by_daimon/he/explode3.wav"
#define SOUND_FIRE     "ambient/fire/fire_big_loop1.wav"

// Lista completa de arquivos
static const char g_sDownloadFiles[][] =
{
"models/lendas_css/v_eq_fraggrenade.mdl",
"models/lendas_css/v_eq_fraggrenade.dx80.vtx",
"models/lendas_css/v_eq_fraggrenade.dx90.vtx",
"models/lendas_css/v_eq_fraggrenade.sw.vtx",
"models/lendas_css/v_eq_fraggrenade.vvd",
"models/lendas_css/w_eq_fraggrenade_thrown.mdl",
"models/lendas_css/w_eq_fraggrenade_thrown.dx80.vtx",
"models/lendas_css/w_eq_fraggrenade_thrown.dx90.vtx",
"models/lendas_css/w_eq_fraggrenade_thrown.sw.vtx",
"models/lendas_css/w_eq_fraggrenade_thrown.vvd",
"models/lendas_css/w_eq_fraggrenade_thrown.phy",
"materials/models/weapons/v_models/equip_molotov/bottle.vtf",
"materials/models/weapons/v_models/equip_molotov/bottle_nr.vtf",
"materials/models/weapons/v_models/equip_molotov/hand_lightwarp.vtf",
"materials/models/weapons/v_models/equip_molotov/v_eq_molotov_bottle.vmt",
"materials/models/weapons/v_models/equip_molotov/v_eq_molotov_lighter_flame.vmt",
"materials/models/weapons/v_models/equip_molotov/v_eq_molotov_rag.vmt",
"materials/models/weapons/v_models/equip_molotov/w_eq_molotov_bottle.vmt",
"materials/models/weapons/v_models/equip_molotov/w_eq_molotov_rag.vmt",
"materials/models/weapons/v_models/arms/bare_arm_133.vmt",
"materials/models/weapons/v_models/arms/bare_arm_133.vtf",
"materials/models/weapons/v_models/arms/bare_arm_133_normal.vtf",
"materials/models/weapons/v_models/arms/bare_arm_exponent.vtf",
"materials/models/weapons/v_models/arms/bare_arm_light.vtf",
"materials/models/weapons/v_models/arms/glove_fullfinger.vmt",
"materials/models/weapons/v_models/arms/glove_fullfinger.vtf",
"materials/models/weapons/v_models/arms/glove_fullfinger_exp.vtf",
"materials/models/weapons/v_models/arms/glove_fullfinger_normal.vtf",
"materials/models/weapons/v_models/arms/hand_lightwarp.vtf",
"materials/models/weapons/v_models/arms/professional_exp.vtf",
"materials/models/weapons/v_models/arms/professional_normal.vtf",
"materials/models/weapons/v_models/arms/professional_watch.vmt",
"materials/models/weapons/v_models/arms/professional_watch.vtf",
"materials/models/weapons/v_models/arms/professional_watch_exponent.vtf",
"materials/models/weapons/v_models/arms/professional_watch_gold.vmt",
"materials/models/weapons/v_models/arms/professional_watch_gold.vtf",
"materials/models/weapons/v_models/arms/professional_watch_normal.vtf",
"sound/weapons/by_daimon/draw2.wav",
"sound/weapons/by_daimon/he/explode3.wav"
};

// ============================================================================
// VARIÁVEIS GLOBAIS
// ============================================================================
int g_iViewModelIndex = 0;
int g_iWorldModelIndex = 0;

bool g_bHasMolotov[MAXPLAYERS + 1];
bool g_bBoughtThisRound[MAXPLAYERS + 1];
int g_iClientViewModelProp[MAXPLAYERS + 1];

bool g_bIsMolotovProj[2048];

ConVar sm_molotov_price;
ConVar sm_molotov_smoke;
ConVar sm_molotov_smoke_radius;
ConVar sm_molotov_smoke_time;
ConVar sm_molotov_smoke_consume;
ConVar sm_molotov_smoke_fade;
ConVar sm_molotov_smoke_fade_time;

/**
 * Molotovs acesas agora.
 *
 * Precisa existir por causa do DANO: o fogo visual são entidades `env_fire`
 * que dá pra achar e apagar, mas o dano vem de um timer separado que não
 * conhece essas entidades. Apagar só as chamas deixaria o jogador queimando
 * dentro da fumaça, sem ver de quê — pior que não apagar nada.
 */
#define MAX_MOLOTOVS 32
enum struct Molotov
{
    bool  ativa;
    float pos[3];
}
Molotov g_aMolotovs[MAX_MOLOTOVS];

/**
 * Fumaças ainda de pé.
 *
 * Guardadas porque o CS:GO apaga nos DOIS sentidos: fumaça jogada em cima
 * do fogo, e fogo jogado dentro da fumaça. O segundo caso só funciona se a
 * gente lembrar onde a fumaça caiu.
 */
#define MAX_FUMACAS 32
enum struct Fumaca
{
    bool  ativa;
    float pos[3];
    int   fim;
}
Fumaca g_aFumacas[MAX_FUMACAS];
ConVar sm_molotov_duration;
ConVar sm_molotov_damage;
ConVar sm_molotov_radius;

// ============================================================================
// INITIALIZATION
// ============================================================================
public void OnPluginStart()
{
    RegConsoleCmd("sm_mol", Cmd_BuyMolotov, "Compra uma molotov");
    RegConsoleCmd("sm_molotov", Cmd_BuyMolotov, "Compra uma molotov");

    sm_molotov_smoke = CreateConVar("sm_molotov_smoke", "1",
        "Fumaça apaga a molotov, como no CS:GO/CS2.", _, true, 0.0, true, 1.0);
    sm_molotov_smoke_radius = CreateConVar("sm_molotov_smoke_radius", "170.0",
        "Raio em que a fumaça apaga o fogo.");
    sm_molotov_smoke_consume = CreateConVar("sm_molotov_smoke_consume", "1",
        "A fumaça se desfaz junto com o fogo que ela apagou, como no CS2.", _, true, 0.0, true, 1.0);
    sm_molotov_smoke_fade = CreateConVar("sm_molotov_smoke_fade", "1.5",
        "Segundos entre apagar o fogo e a fumaça começar a se desfazer. 0 = na hora.");
    sm_molotov_smoke_fade_time = CreateConVar("sm_molotov_smoke_fade_time", "2.5",
        "Quanto tempo a fumaça leva se dissipando. 0 = some de uma vez.");

    sm_molotov_smoke_time = CreateConVar("sm_molotov_smoke_time", "18",
        "Por quantos segundos a fumaça continua apagando fogo novo jogado nela.");

    sm_molotov_price = CreateConVar("sm_molotov_price", "800", "Preço da Molotov");
    sm_molotov_duration = CreateConVar("sm_molotov_duration", "10.0", "Duração do fogo");
    sm_molotov_damage = CreateConVar("sm_molotov_damage", "20.0", "Dano do fogo por segundo");
    sm_molotov_radius = CreateConVar("sm_molotov_radius", "180.0", "Raio do fogo");

    HookEvent("hegrenade_detonate", Event_SmokeDetonate, EventHookMode_Pre);
    HookEvent("smokegrenade_detonate", Event_FumacaDetonate);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("player_spawn", Event_PlayerSpawn);
    HookEvent("round_start", Event_RoundStart);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
            OnClientPutInServer(i);
    }
}

public void OnMapStart()
{
    g_iViewModelIndex  = PrecacheModel(VIEW_MODEL, true);
    g_iWorldModelIndex = PrecacheModel(WORLD_MODEL, true);

    PrecacheSound(SOUND_DRAW, true);
    PrecacheSound(SOUND_EXPLODE, true);
    PrecacheSound(SOUND_FIRE, true);

    PrecacheModel("sprites/fire.vmt", true);

    for (int i = 0; i < sizeof(g_sDownloadFiles); i++)
    {
        AddFileToDownloadsTable(g_sDownloadFiles[i]);
    }
}

public void OnClientPutInServer(int client)
{
    g_bHasMolotov[client] = false;
    g_bBoughtThisRound[client] = false;
    g_iClientViewModelProp[client] = -1;
    SDKHook(client, SDKHook_WeaponSwitchPost, OnWeaponSwitchPost);
    SDKHook(client, SDKHook_PostThinkPost, OnPostThinkPost);
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    if (inflictor > 0 && IsValidEntity(inflictor))
    {
        char cls[64];
        GetEdictClassname(inflictor, cls, sizeof(cls));
        if (StrEqual(cls, "hegrenade_projectile") && g_bIsMolotovProj[inflictor])
        {
            damage = 0.0;
            return Plugin_Handled; // Cancela totalmente o dano da explosão!
        }
    }
    return Plugin_Continue;
}

public void OnClientDisconnect(int client)
{
    RemoveCustomViewModel(client);
    g_bHasMolotov[client] = false;
}

// ============================================================================
// COMPRA
// ============================================================================
public Action Cmd_BuyMolotov(int client, int args)
{
    if (!client || !IsClientInGame(client) || !IsPlayerAlive(client))
        return Plugin_Handled;

    if (g_bBoughtThisRound[client])
    {
        PrintToChat(client, "\x04[LENDAS]\x01 Você já comprou uma Molotov neste round!");
        return Plugin_Handled;
    }

    if (g_bHasMolotov[client])
    {
        PrintToChat(client, "\x04[LENDAS]\x01 Você já possui uma Molotov nas mãos!");
        return Plugin_Handled;
    }

    int price = sm_molotov_price.IntValue;
    int money = GetEntProp(client, Prop_Send, "m_iAccount");

    if (money < price)
    {
        PrintToChat(client, "\x04[LENDAS]\x01 Dinheiro insuficiente (Custo: \x04$%d\x01).", price);
        return Plugin_Handled;
    }

    int heEnt = GetPlayerWeaponSlot(client, CS_SLOT_GRENADE);
    if (heEnt != -1)
    {
        char cls[64];
        GetEdictClassname(heEnt, cls, sizeof(cls));
        if (StrEqual(cls, "weapon_hegrenade"))
        {
            RemovePlayerItem(client, heEnt);
            AcceptEntityInput(heEnt, "Kill");
        }
    }

    SetEntProp(client, Prop_Send, "m_iAccount", money - price);
    g_bHasMolotov[client] = true;
    g_bBoughtThisRound[client] = true;
    GivePlayerItem(client, "weapon_hegrenade");

    PrintToChat(client, "\x04[LENDAS]\x01 Molotov Especial comprada por \x04$%d\x01!", price);
    return Plugin_Handled;
}

// ============================================================================
// LIFECYCLE EVENTOS
// ============================================================================
public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    // Round novo, mapa limpo: nada do round anterior continua valendo.
    for (int i = 0; i < MAX_MOLOTOVS; i++)
        g_aMolotovs[i].ativa = false;
    for (int i = 0; i < MAX_FUMACAS; i++)
        g_aFumacas[i].ativa = false;

    for (int i = 1; i <= MaxClients; i++)
    {
        g_bBoughtThisRound[i] = false;
    }
    return Plugin_Continue;
}

public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client)
    {
        g_bHasMolotov[client] = false;
        RemoveCustomViewModel(client);
    }
    return Plugin_Continue;
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client)
    {
        g_bHasMolotov[client] = false;
        RemoveCustomViewModel(client);
    }
    return Plugin_Continue;
}

public Action CS_OnCSWeaponDrop(int client, int weaponIndex)
{
    if (g_bHasMolotov[client])
    {
        char cls[64];
        GetEdictClassname(weaponIndex, cls, sizeof(cls));
        if (StrEqual(cls, "weapon_hegrenade"))
        {
            g_bHasMolotov[client] = false;
            SetEntityModel(weaponIndex, WORLD_MODEL);
            RemoveCustomViewModel(client);
        }
    }
    return Plugin_Continue;
}

// ============================================================================
// VIEWMODEL TRUQUE DEFINITIVO (ARQUITETURA SM-WEAPONMODELS - EF_NODRAW + VM2)
// ============================================================================
public void OnWeaponSwitchPost(int client, int weapon)
{
    RemoveCustomViewModel(client);

    if (weapon <= 0 || !IsValidEntity(weapon))
        return;

    char cls[64];
    GetEdictClassname(weapon, cls, sizeof(cls));

    if (StrEqual(cls, "weapon_hegrenade") && g_bHasMolotov[client])
    {
        // Define o modelo mundial para que outros jogadores vejam a garrafa em 3ª pessoa
        SetEntProp(weapon, Prop_Send, "m_iWorldModelIndex", g_iWorldModelIndex);

        int vm1 = GetEntPropEnt(client, Prop_Send, "m_hViewModel");
        if (vm1 > 0 && IsValidEntity(vm1))
        {
            // Aplica EF_NODRAW (32) no ViewModel primário (o client continua prevendo ele invisível)
            int flags = GetEntProp(vm1, Prop_Send, "m_fEffects");
            SetEntProp(vm1, Prop_Send, "m_fEffects", flags | 32);

            // Cria um ViewModel Secundário que o Client NÃO vai prever!
            int vm2 = CreateEntityByName("predicted_viewmodel");
            if (vm2 != -1)
            {
                SetEntPropEnt(vm2, Prop_Send, "m_hOwner", client);
                SetEntPropEnt(vm2, Prop_Send, "m_hWeapon", weapon); // CRÍTICO: Sem isso, fica invisível
                SetEntProp(vm2, Prop_Send, "m_nViewModelIndex", 1);
                DispatchKeyValue(vm2, "model", VIEW_MODEL);
                DispatchSpawn(vm2);

                // CRÍTICO: Avisar o jogador que este é o braço secundário dele, senão ele nasce no chão/parede!
                SetEntPropEnt(client, Prop_Send, "m_hViewModel", vm2, 1);

                // Força o modelo customizado no VM2
                SetEntityModel(vm2, VIEW_MODEL);
                
                // Salva a referência para copiar as animações no PostThink
                g_iClientViewModelProp[client] = EntIndexToEntRef(vm2);
                
                EmitSoundToClient(client, SOUND_DRAW);
            }
        }
    }
}

public void OnPostThinkPost(int client)
{
    if (!IsPlayerAlive(client))
        return;

    int vm2_ref = g_iClientViewModelProp[client];
    if (vm2_ref != -1)
    {
        int vm2 = EntRefToEntIndex(vm2_ref);
        if (vm2 > 0 && IsValidEntity(vm2))
        {
            int vm1 = GetEntPropEnt(client, Prop_Send, "m_hViewModel");
            if (vm1 > 0 && IsValidEntity(vm1))
            {
                // Garante que o VM primário continua invisível (Client prediction tenta remover o NODRAW)
                int flags = GetEntProp(vm1, Prop_Send, "m_fEffects");
                if (!(flags & 32))
                {
                    SetEntProp(vm1, Prop_Send, "m_fEffects", flags | 32);
                }

                // Copia a animação (Sequence) do VM1 para o VM2 sem forçar o Cycle
                // Se forçarmos o Cycle, a animação vai engasgar (stutter) porque o client-side prediction interpola o Cycle localmente!
                int seq = GetEntProp(vm1, Prop_Send, "m_nSequence");
                int parity = GetEntProp(vm1, Prop_Send, "m_nAnimationParity");
                float playback = GetEntPropFloat(vm1, Prop_Send, "m_flPlaybackRate");

                SetEntProp(vm2, Prop_Send, "m_nSequence", seq);
                SetEntProp(vm2, Prop_Send, "m_nAnimationParity", parity);
                SetEntPropFloat(vm2, Prop_Send, "m_flPlaybackRate", playback);
            }
        }
    }
}

void RemoveCustomViewModel(int client)
{
    int vm2_ref = g_iClientViewModelProp[client];
    if (vm2_ref != -1)
    {
        int vm2 = EntRefToEntIndex(vm2_ref);
        if (vm2 > 0 && IsValidEntity(vm2))
        {
            AcceptEntityInput(vm2, "Kill");
        }
    }
    g_iClientViewModelProp[client] = -1;

    if (IsClientInGame(client))
    {
        // Limpa o ponteiro do braço secundário no jogador
        SetEntPropEnt(client, Prop_Send, "m_hViewModel", -1, 1);

        int vm1 = GetEntPropEnt(client, Prop_Send, "m_hViewModel");
        if (vm1 > 0 && IsValidEntity(vm1))
        {
            // Remove o EF_NODRAW
            int flags = GetEntProp(vm1, Prop_Send, "m_fEffects");
            SetEntProp(vm1, Prop_Send, "m_fEffects", flags & ~32);
        }
    }
}

// ============================================================================
// LANÇAMENTO & FÍSICA
// ============================================================================
public void OnEntityCreated(int entity, const char[] classname)
{
    if (StrEqual(classname, "hegrenade_projectile"))
    {
        SDKHook(entity, SDKHook_SpawnPost, OnSmokeProjectileSpawnPost);
    }
}

public void OnSmokeProjectileSpawnPost(int entity)
{
    int thrower = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
    if (thrower > 0 && thrower <= MaxClients)
    {
        if (g_bHasMolotov[thrower])
        {
            g_bHasMolotov[thrower] = false;
            g_bIsMolotovProj[entity] = true;
            SetEntityModel(entity, WORLD_MODEL);
            RemoveCustomViewModel(thrower); 
        }
        else
        {
            g_bIsMolotovProj[entity] = false;
        }
    }
}

public void OnEntityDestroyed(int entity)
{
    if (entity > 0 && entity < 2048)
    {
        g_bIsMolotovProj[entity] = false;
    }
}

// ============================================================================
// EXPLOSÃO & FOGO
// ============================================================================
public Action Event_SmokeDetonate(Event event, const char[] name, bool dontBroadcast)
{
    float pos[3];
    pos[0] = event.GetFloat("x");
    pos[1] = event.GetFloat("y");
    pos[2] = event.GetFloat("z");

    int client = GetClientOfUserId(event.GetInt("userid"));
    bool isMolotov = false;

    int maxEnts = GetMaxEntities();
    for (int i = MaxClients + 1; i < maxEnts; i++)
    {
        if (IsValidEntity(i) && g_bIsMolotovProj[i])
        {
            char cls[64];
            GetEdictClassname(i, cls, sizeof(cls));
            if (StrEqual(cls, "hegrenade_projectile"))
            {
                float ePos[3];
                GetEntPropVector(i, Prop_Send, "m_vecOrigin", ePos);
                if (GetVectorDistance(pos, ePos) < 50.0)
                {
                    isMolotov = true;
                    // Limpa a entidade projétil para não bugar outras lógicas
                    AcceptEntityInput(i, "Kill");
                    break;
                }
            }
        }
    }

    if (isMolotov)
    {
        // Mata a fumaça nativa
        for (int i = MaxClients + 1; i < maxEnts; i++)
        {
            if (IsValidEntity(i))
            {
                char cls[64];
                GetEdictClassname(i, cls, sizeof(cls));
                if (StrEqual(cls, "env_particlesmokegrenade"))
                {
                    float ePos[3];
                    GetEntPropVector(i, Prop_Send, "m_vecOrigin", ePos);
                    if (GetVectorDistance(pos, ePos) < 50.0)
                    {
                        AcceptEntityInput(i, "Kill");
                    }
                }
            }
        }

        /**
         * Caiu dentro de uma fumaça que já estava lá? Não pega fogo.
         *
         * É o comportamento do CS:GO, e evita o caso estranho de a molotov
         * queimar por meio segundo antes de o código de apagar rodar.
         */
        if (sm_molotov_smoke.BoolValue && Lendas_DentroDeFumaca(pos))
        {
            EmitSoundToAll(SOUND_EXPLODE, SOUND_FROM_WORLD, SNDCHAN_AUTO, SNDLEVEL_NORMAL, SND_NOFLAGS, 0.6, SNDPITCH_NORMAL, -1, pos);

            // Gastou a fumaça pra abafar o fogo — vale nos dois sentidos.
            if (sm_molotov_smoke_consume.BoolValue)
                Lendas_ConsumirFumaca(pos);

            return Plugin_Handled;
        }

        int iMolotov = Lendas_RegistrarMolotov(pos);

        EmitSoundToAll(SOUND_EXPLODE, SOUND_FROM_WORLD, SNDCHAN_AUTO, SNDLEVEL_NORMAL, SND_NOFLAGS, 1.0, SNDPITCH_NORMAL, -1, pos);

        // Criar 5 pontos de fogo para simular spread MAIS LARGO (Centro, +X, -X, +Y, -Y)
        float offsets[5][3] = {
            {0.0, 0.0, 0.0},
            {80.0, 0.0, 0.0},
            {-80.0, 0.0, 0.0},
            {0.0, 80.0, 0.0},
            {0.0, -80.0, 0.0}
        };

        for (int i = 0; i < 5; i++)
        {
            int fire = CreateEntityByName("env_fire");
            if (fire != -1)
            {
                DispatchKeyValue(fire, "health", "10");
                DispatchKeyValue(fire, "firesize", "100"); // Tamanho balanceado para não ficar muito alto
                DispatchKeyValue(fire, "fireattack", "0");
                DispatchKeyValue(fire, "damagescale", "0");
                DispatchKeyValue(fire, "StartDisabled", "0");
                DispatchKeyValue(fire, "spawnflags", "14");
                
                float fPos[3];
                fPos[0] = pos[0] + offsets[i][0];
                fPos[1] = pos[1] + offsets[i][1];
                fPos[2] = pos[2] + offsets[i][2];

                TeleportEntity(fire, fPos, NULL_VECTOR, NULL_VECTOR);
                DispatchSpawn(fire);
                AcceptEntityInput(fire, "StartFire");
                
                // Emite o som APENAS na primeira entidade (centro) para podermos parar depois
                if (i == 0)
                {
                    EmitSoundToAll(SOUND_FIRE, fire, SNDCHAN_AUTO, SNDLEVEL_NORMAL, SND_NOFLAGS, 1.0, SNDPITCH_NORMAL, -1, fPos);
                }

                char fireStr[32];
                Format(fireStr, sizeof(fireStr), "OnUser1 !self:Extinguish::%f:1", sm_molotov_duration.FloatValue);
                SetVariantString(fireStr);
                AcceptEntityInput(fire, "AddOutput");
                AcceptEntityInput(fire, "FireUser1");
                
                CreateTimer(sm_molotov_duration.FloatValue + 1.0, Timer_KillFire, EntIndexToEntRef(fire), TIMER_FLAG_NO_MAPCHANGE);
            }
        }

        DataPack dp;
        // Timer roda 4 vezes por segundo (0.25) para o dano ser IMEDIATO ao inves de demorar 1 segundo inteiro
        CreateDataTimer(0.25, Timer_FireDamage, dp, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
        dp.WriteFloat(pos[0]);
        dp.WriteFloat(pos[1]);
        dp.WriteFloat(pos[2]);
        dp.WriteCell(client);
        dp.WriteCell(GetTime());
        dp.WriteCell(iMolotov);

        return Plugin_Handled;
    }
    return Plugin_Continue;
}

/* ---------------------------------------------------------------- *
 * Fumaça apaga fogo
 * ---------------------------------------------------------------- */

public void Event_FumacaDetonate(Event event, const char[] name, bool dontBroadcast)
{
    if (!sm_molotov_smoke.BoolValue)
        return;

    float pos[3];
    pos[0] = event.GetFloat("x");
    pos[1] = event.GetFloat("y");
    pos[2] = event.GetFloat("z");

    Lendas_RegistrarFumaca(pos);
    Lendas_ApagarFogoPerto(pos);
}

int Lendas_RegistrarMolotov(const float pos[3])
{
    for (int i = 0; i < MAX_MOLOTOVS; i++)
    {
        if (g_aMolotovs[i].ativa)
            continue;

        g_aMolotovs[i].ativa = true;
        g_aMolotovs[i].pos = pos;
        return i;
    }
    // Sem espaço: -1 desliga o controle desta molotov, que segue funcionando
    // como antes. Perder o "apagar" é melhor que perder a molotov inteira.
    return -1;
}

void Lendas_LiberarMolotov(int i)
{
    if (i >= 0 && i < MAX_MOLOTOVS)
        g_aMolotovs[i].ativa = false;
}

void Lendas_RegistrarFumaca(const float pos[3])
{
    int agora = GetTime();
    int livre = -1;

    for (int i = 0; i < MAX_FUMACAS; i++)
    {
        // Reaproveita a vaga de uma fumaça que já se dissipou.
        if (g_aFumacas[i].ativa && g_aFumacas[i].fim <= agora)
            g_aFumacas[i].ativa = false;
        if (!g_aFumacas[i].ativa && livre == -1)
            livre = i;
    }

    if (livre == -1)
        return;

    g_aFumacas[livre].ativa = true;
    g_aFumacas[livre].pos = pos;
    g_aFumacas[livre].fim = agora + sm_molotov_smoke_time.IntValue;
}

bool Lendas_DentroDeFumaca(const float pos[3])
{
    int agora = GetTime();
    float raio = sm_molotov_smoke_radius.FloatValue;

    for (int i = 0; i < MAX_FUMACAS; i++)
    {
        if (!g_aFumacas[i].ativa)
            continue;
        if (g_aFumacas[i].fim <= agora)
        {
            g_aFumacas[i].ativa = false;
            continue;
        }
        if (GetVectorDistance(g_aFumacas[i].pos, pos) <= raio)
            return true;
    }
    return false;
}

/**
 * Apaga as chamas e o dano de toda molotov dentro do raio.
 *
 * As duas coisas juntas de propósito: as `env_fire` são o que se vê, o
 * registro é o que machuca. Mexer só num dos dois deixa o jogo mentindo
 * numa das duas direções.
 */
void Lendas_ApagarFogoPerto(const float pos[3])
{
    float raio = sm_molotov_smoke_radius.FloatValue;
    int apagadas = 0;

    // 1) o dano
    for (int i = 0; i < MAX_MOLOTOVS; i++)
    {
        if (!g_aMolotovs[i].ativa)
            continue;
        if (GetVectorDistance(g_aMolotovs[i].pos, pos) > raio)
            continue;

        g_aMolotovs[i].ativa = false;
        apagadas++;
    }

    // 2) as chamas. O raio é mais folgado porque os pontos de fogo ficam
    // espalhados até 80 unidades do centro da molotov (ver os offsets).
    float raioChamas = raio + 80.0;
    char cls[32];

    for (int ent = MaxClients + 1; ent < GetMaxEntities(); ent++)
    {
        if (!IsValidEntity(ent))
            continue;
        if (!GetEntityClassname(ent, cls, sizeof(cls)) || !StrEqual(cls, "env_fire"))
            continue;

        /**
         * Lê a posição com HasEntProp antes: uma entidade sem a netprop faz
         * o GetEntPropVector lançar erro, e isso rodaria a cada fumaça
         * jogada, enchendo o log de erro por causa de um enfeite.
         */
        float fogoPos[3];
        if (HasEntProp(ent, Prop_Send, "m_vecOrigin"))
            GetEntPropVector(ent, Prop_Send, "m_vecOrigin", fogoPos);
        else if (HasEntProp(ent, Prop_Data, "m_vecAbsOrigin"))
            GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", fogoPos);
        else
            continue;

        if (GetVectorDistance(fogoPos, pos) > raioChamas)
            continue;

        /**
         * O som ANTES do Kill.
         *
         * O `SOUND_FIRE` é um loop preso à entidade do centro. Matar a
         * entidade não interrompe o loop no cliente — ele continua tocando
         * num fogo que não existe mais. O `Timer_KillFire` já fazia isso
         * certo; a primeira versão de apagar por fumaça esqueceu, e o
         * resultado foi som de fogo em fumaça vazia.
         */
        StopSound(ent, SNDCHAN_AUTO, SOUND_FIRE);
        AcceptEntityInput(ent, "Extinguish");
        AcceptEntityInput(ent, "Kill");
    }

    if (apagadas > 0)
    {
        EmitSoundToAll(SOUND_EXPLODE, SOUND_FROM_WORLD, SNDCHAN_AUTO, SNDLEVEL_NORMAL, SND_NOFLAGS, 0.5, SNDPITCH_NORMAL, -1, pos);

        /**
         * A fumaça se gasta ao apagar o fogo, como no CS2 — os dois somem
         * juntos em vez de sobrar uma fumaça inteira sobre o chão limpo.
         *
         * Com um respiro antes: sumir no mesmo instante lê como bug de
         * renderização. Um segundo e meio depois lê como a fumaça tendo
         * feito o trabalho e se acabado nele.
         */
        if (sm_molotov_smoke_consume.BoolValue)
        {
            float espera = sm_molotov_smoke_fade.FloatValue;
            if (espera <= 0.0)
            {
                Lendas_ConsumirFumaca(pos);
            }
            else
            {
                DataPack dp;
                CreateDataTimer(espera, Timer_ConsumirFumaca, dp, TIMER_FLAG_NO_MAPCHANGE);
                dp.WriteFloat(pos[0]);
                dp.WriteFloat(pos[1]);
                dp.WriteFloat(pos[2]);
            }
        }
    }
}

public Action Timer_ConsumirFumaca(Handle timer, DataPack dp)
{
    dp.Reset();
    float pos[3];
    pos[0] = dp.ReadFloat();
    pos[1] = dp.ReadFloat();
    pos[2] = dp.ReadFloat();

    Lendas_ConsumirFumaca(pos);
    return Plugin_Stop;
}

/**
 * Desfaz a fumaça que acabou de apagar um fogo.
 *
 * Some do mundo (a entidade de partícula) E do registro: se ficasse no
 * registro, continuaria impedindo molotov nova de pegar num lugar onde já
 * não há fumaça nenhuma — bloqueio invisível, que é o pior tipo.
 */
void Lendas_ConsumirFumaca(const float pos[3])
{
    float raio = sm_molotov_smoke_radius.FloatValue;

    for (int i = 0; i < MAX_FUMACAS; i++)
    {
        if (!g_aFumacas[i].ativa)
            continue;
        if (GetVectorDistance(g_aFumacas[i].pos, pos) <= raio)
            g_aFumacas[i].ativa = false;
    }

    char cls[64];
    for (int ent = MaxClients + 1; ent < GetMaxEntities(); ent++)
    {
        if (!IsValidEntity(ent))
            continue;
        if (!GetEdictClassname(ent, cls, sizeof(cls)))
            continue;
        if (!StrEqual(cls, "env_particlesmokegrenade"))
            continue;

        float ePos[3];
        if (!HasEntProp(ent, Prop_Send, "m_vecOrigin"))
            continue;
        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", ePos);

        if (GetVectorDistance(ePos, pos) <= raio)
            Lendas_DissiparFumaca(ent);
    }
}

/**
 * Faz a fumaça se DESFAZER em vez de sumir de um quadro pro outro.
 *
 * A `env_particlesmokegrenade` tem dois campos de fade que o cliente usa
 * pra ir apagando a nuvem: `m_FadeStartTime` e `m_FadeEndTime`. Eles são
 * contados em segundos DESDE O SPAWN da entidade, não em tempo de jogo —
 * é por isso que o cálculo desconta o `m_flSpawnTime` antes de somar.
 * (Confirmado no código do SDK: `SetRelativeFadeTime` faz exatamente essa
 * conta.)
 *
 * Botar o início no instante atual e o fim alguns segundos depois é o que
 * transforma o "sumiu" em "está acabando".
 *
 * Sem os campos, cai no `Kill` de antes: perder o efeito é aceitável,
 * deixar a fumaça eterna não.
 */
void Lendas_DissiparFumaca(int ent)
{
    float duracao = sm_molotov_smoke_fade_time.FloatValue;

    bool temCampos = HasEntProp(ent, Prop_Send, "m_flSpawnTime")
        && HasEntProp(ent, Prop_Send, "m_FadeStartTime")
        && HasEntProp(ent, Prop_Send, "m_FadeEndTime");

    if (duracao <= 0.0 || !temCampos)
    {
        AcceptEntityInput(ent, "Kill");
        return;
    }

    float desdeSpawn = GetGameTime() - GetEntPropFloat(ent, Prop_Send, "m_flSpawnTime");
    if (desdeSpawn < 0.0)
        desdeSpawn = 0.0;

    SetEntPropFloat(ent, Prop_Send, "m_FadeStartTime", desdeSpawn);
    SetEntPropFloat(ent, Prop_Send, "m_FadeEndTime", desdeSpawn + duracao);

    // Some do mundo depois de terminar de sumir da tela: uma nuvem
    // invisivel parada no mapa nao atrapalha ninguem, mas tambem nao
    // precisa ficar.
    CreateTimer(duracao + 0.5, Timer_MatarFumaca, EntIndexToEntRef(ent), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_MatarFumaca(Handle timer, int ref)
{
    int ent = EntRefToEntIndex(ref);
    if (ent > 0 && IsValidEntity(ent))
        AcceptEntityInput(ent, "Kill");
    return Plugin_Stop;
}

public Action Timer_KillFire(Handle timer, int ref)
{
    int ent = EntRefToEntIndex(ref);
    if (ent > 0 && IsValidEntity(ent))
    {
        // Para o som de loop amarrado a esta entidade antes de deleta-la
        StopSound(ent, SNDCHAN_AUTO, SOUND_FIRE);
        AcceptEntityInput(ent, "Kill");
    }
    return Plugin_Handled;
}

public Action Timer_FireDamage(Handle timer, DataPack dp)
{
    dp.Reset();
    float pos[3];
    pos[0] = dp.ReadFloat();
    pos[1] = dp.ReadFloat();
    pos[2] = dp.ReadFloat();
    int attacker = dp.ReadCell();
    int startTime = dp.ReadCell();
    int iMolotov = dp.ReadCell();

    if (GetTime() - startTime > sm_molotov_duration.IntValue)
    {
        Lendas_LiberarMolotov(iMolotov);
        return Plugin_Stop;
    }

    // Apagada pela fumaça: para o dano JUNTO com as chamas. Sem isto o
    // jogador continuaria queimando dentro da fumaça sem ver fogo nenhum.
    if (iMolotov >= 0 && !g_aMolotovs[iMolotov].ativa)
    {
        return Plugin_Stop;
    }

    float radius = sm_molotov_radius.FloatValue;
    float damage = sm_molotov_damage.FloatValue / 4.0; // Divide por 4 pois roda a cada 0.25s

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && IsPlayerAlive(i))
        {
            float targetPos[3];
            GetClientEyePosition(i, targetPos);
            
            if (GetVectorDistance(pos, targetPos) <= radius)
            {
                SDKHooks_TakeDamage(i, 0, attacker, damage, DMG_BURN | DMG_PREVENT_PHYSICS_FORCE, -1, NULL_VECTOR, pos);
                
                // Aplicar Shake (Tremor) na tela de quem ta queimando
                Handle msg = StartMessageOne("Shake", i);
                if (msg != null)
                {
                    BfWriteByte(msg, 0); // command
                    BfWriteFloat(msg, 3.0); // amplitude
                    BfWriteFloat(msg, 10.0); // frequency
                    BfWriteFloat(msg, 0.5);  // duration
                    EndMessage();
                }
            }
        }
    }

    return Plugin_Continue;
}
