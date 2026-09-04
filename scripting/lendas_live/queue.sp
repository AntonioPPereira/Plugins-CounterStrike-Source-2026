/**
 * lendas_live / queue.sp
 *
 * Fila em memoria + backoff. Nada aqui bloqueia o loop do jogo: enfileirar
 * e so um PushString num ArrayList, e o envio de verdade (SteamWorks HTTP)
 * ja e assincrono por natureza (callback, nunca espera a resposta).
 *
 * Cheio demais -> descarta o mais ANTIGO (nunca o mais novo: o estado atual
 * importa mais que um evento de 30s atras que o backend nunca vai ver a
 * tempo de ser relevante).
 *
 * Backend fora do ar -> os eventos ficam na fila (nao sao descartados so
 * por falhar uma vez) e o flush entra em backoff exponencial (1,2,4,8,16,
 * ate 30s), pra nao martelar um backend que ja esta fora do ar. O jogo
 * continua rodando normalmente o tempo todo — nada disso trava um tick.
 */

// 16KB cobre com folga um player_snapshot de 32 jogadores mesmo no pior caso
// (nickname todo composto de aspas/barras, que dobra de tamanho ao escapar).
#define LENDAS_EVENT_JSON_MAXLEN 16384
// Reduzido de 65536: o corpo nunca precisa caber mais que um punhado de
// eventos pequenos + um player_snapshot grande por vez (o loop já para e
// deixa o resto pro próximo flush, nunca trunca um evento no meio) — um
// teto menor reduz a memória de pico que o flush precisa de uma vez.
#define LENDAS_BODY_MAXLEN 24576
#define LENDAS_MAX_BATCH_EVENTS 100
#define LENDAS_MAX_BACKOFF_SECONDS 30

ArrayList g_hQueue;
bool g_bFlushInFlight;
int g_iPendingFlushCount;
int g_iConsecutiveFailures;
int g_iBackoffUntil;

void Lendas_QueueInit()
{
	if (g_hQueue == null)
		g_hQueue = new ArrayList(ByteCountToCells(LENDAS_EVENT_JSON_MAXLEN));
}

/** Enfileira um evento ja serializado (um objeto JSON completo, sem a chave "kind" faltando). */
void Lendas_Enqueue(const char[] jsonEvent)
{
	Lendas_QueueInit();
	g_hQueue.PushString(jsonEvent);

	int max = g_cvQueueMaxEvents.IntValue;
	int overflow = g_hQueue.Length - max;
	if (overflow > 0)
	{
		for (int i = 0; i < overflow; i++)
			g_hQueue.Erase(0);
		LogError("[Lendas] Fila cheia (max %d) - descartando %d evento(s) mais antigo(s).", max, overflow);
	}
}

bool Lendas_InBackoff()
{
	return g_iBackoffUntil > 0 && GetTime() < g_iBackoffUntil;
}

static int Lendas_BackoffSeconds(int failures)
{
	int delay = 1;
	for (int i = 1; i < failures && delay < LENDAS_MAX_BACKOFF_SECONDS; i++)
		delay *= 2;
	return delay > LENDAS_MAX_BACKOFF_SECONDS ? LENDAS_MAX_BACKOFF_SECONDS : delay;
}

void Lendas_RegisterFailure(const char[] reason)
{
	g_iConsecutiveFailures++;
	int delay = Lendas_BackoffSeconds(g_iConsecutiveFailures);
	g_iBackoffUntil = GetTime() + delay;

	if (g_iConsecutiveFailures == 1)
		LogMessage("[Lendas] Backend unavailable (%s) - proxima tentativa em %ds", reason, delay);
	else if (g_cvDebug.BoolValue)
		LogMessage("[Lendas] Ainda indisponivel (falha %d) - proxima tentativa em %ds", g_iConsecutiveFailures, delay);
}

void Lendas_RegisterSuccess()
{
	if (g_iConsecutiveFailures > 0)
		LogMessage("[Lendas] Backend connected");
	g_iConsecutiveFailures = 0;
	g_iBackoffUntil = 0;
}

/** Remove do inicio da fila os eventos que acabaram de ser confirmados pelo backend. */
void Lendas_DequeueSent(int count)
{
	if (g_hQueue == null)
		return;
	for (int i = 0; i < count && g_hQueue.Length > 0; i++)
		g_hQueue.Erase(0);
}

/**
 * Monta o proximo lote e manda pro backend. Nunca bloqueia: so serializa
 * string em memoria e entrega pro modulo HTTP, que e assincrono.
 */
void Lendas_FlushQueue()
{
	if (!Lendas_IsEnabled())
		return;
	if (g_hQueue == null || g_hQueue.Length == 0)
		return;
	if (Lendas_InBackoff())
		return;
	if (g_bFlushInFlight)
		return; // ja existe um POST em voo - espera a resposta antes de empilhar outro

	char serverId[64];
	Lendas_GetServerId(serverId, sizeof(serverId));
	char escapedServerId[128];
	Lendas_JsonEscape(serverId, escapedServerId, sizeof(escapedServerId));

	char[] body = new char[LENDAS_BODY_MAXLEN];
	Format(body, LENDAS_BODY_MAXLEN, "{\"serverId\":\"%s\",\"events\":[", escapedServerId);

	int total = g_hQueue.Length;
	if (total > LENDAS_MAX_BATCH_EVENTS)
		total = LENDAS_MAX_BATCH_EVENTS;

	char eventJson[LENDAS_EVENT_JSON_MAXLEN];
	int included = 0;
	int bodyLen = strlen(body);

	for (int i = 0; i < total; i++)
	{
		g_hQueue.GetString(i, eventJson, sizeof(eventJson));
		int needed = strlen(eventJson) + 2; // + separador "," e folga

		// Nunca trunca um evento no meio: se nao cabe mais, para aqui e deixa
		// o resto na fila pro proximo flush — corromper o JSON custaria o
		// lote inteiro (o zod rejeita tudo, nao so o campo que estourou).
		if (bodyLen + needed > LENDAS_BODY_MAXLEN - 8)
			break;

		if (included > 0)
		{
			StrCat(body, LENDAS_BODY_MAXLEN, ",");
			bodyLen++;
		}
		StrCat(body, LENDAS_BODY_MAXLEN, eventJson);
		bodyLen += strlen(eventJson);
		included++;
	}

	StrCat(body, LENDAS_BODY_MAXLEN, "]}");

	if (included == 0)
		return; // um unico evento maior que o buffer inteiro — nunca deveria acontecer, mas nao trava o flush

	g_iPendingFlushCount = included;
	g_bFlushInFlight = true;
	Lendas_SendBatch(body);
}
