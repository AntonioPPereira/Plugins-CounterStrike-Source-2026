/**
 * lendas_live / config.sp
 *
 * Convars do plugin. Nada de credencial com valor real aqui — o arquivo
 * gerado em cfg/sourcemod/lendas_live.cfg é que recebe o token de verdade,
 * e mesmo esse fica fora do controle de versão (mesmo padrão do
 * lendas_steamfilter: lsf_apikey nunca no .cfg publicado).
 */

ConVar g_cvEnabled;
ConVar g_cvApiUrl;
ConVar g_cvApiToken;
ConVar g_cvServerId;
ConVar g_cvDebug;
ConVar g_cvSnapshotInterval;
ConVar g_cvFlushInterval;
ConVar g_cvQueueMaxEvents;

void Lendas_CreateConVars()
{
	CreateConVar("lendas_live_version", PLUGIN_VERSION, "Versao do plugin",
		FCVAR_NOTIFY | FCVAR_DONTRECORD);

	g_cvEnabled = CreateConVar("lendas_enabled", "1",
		"Ativa o envio de dados ao vivo pro LENDAS.", _, true, 0.0, true, 1.0);

	g_cvApiUrl = CreateConVar("lendas_api_url", "",
		"URL completa do endpoint de ingestao, ex: https://SEU-BACKEND/api/live/events. Vazio = plugin fica mudo.");

	g_cvApiToken = CreateConVar("lendas_api_token", "",
		"Token compartilhado com o backend (Authorization: Bearer). NAO deixe isso em cfg publico.",
		FCVAR_PROTECTED);

	g_cvServerId = CreateConVar("lendas_server_id", "",
		"Identificador deste servidor no LENDAS. Use o MESMO nome da pasta SFTP (ex: 104.234.65.244_27800) pra bater com /api/servers. Vazio = so a porta, com aviso no log.");

	g_cvDebug = CreateConVar("lendas_debug", "0",
		"1 = loga cada envio/recebimento com detalhe extra (nunca token/segredo).", _, true, 0.0, true, 1.0);

	g_cvSnapshotInterval = CreateConVar("lendas_snapshot_interval", "2.0",
		"Segundos entre snapshots periodicos de servidor+jogadores.", _, true, 0.5, true, 10.0);

	g_cvFlushInterval = CreateConVar("lendas_flush_interval", "1.0",
		"Segundos entre tentativas de esvaziar a fila de eventos pro backend.", _, true, 0.25, true, 5.0);

	g_cvQueueMaxEvents = CreateConVar("lendas_queue_max_events", "300",
		"Tamanho maximo da fila em memoria. Acima disso, descarta os eventos mais antigos.", _, true, 50.0, true, 2000.0);

	AutoExecConfig(true, "lendas_live");
}

bool Lendas_IsEnabled()
{
	if (!g_cvEnabled.BoolValue)
		return false;

	char url[256];
	g_cvApiUrl.GetString(url, sizeof(url));
	return url[0] != '\0';
}

/**
 * `hostip` reflete o bind interno do processo, nao necessariamente o IP
 * publico do servidor (comum em hospedagem com NAT) — nao da pra confiar
 * nele pra montar um ID que precise bater com a pasta SFTP. Por isso o
 * identificador certo e configurado a mao (`lendas_server_id`), uma vez por
 * servidor; sem ele, cai so na porta (com aviso), nunca inventa um IP.
 */
void Lendas_GetServerId(char[] buffer, int maxlen)
{
	g_cvServerId.GetString(buffer, maxlen);
	if (buffer[0] != '\0')
		return;

	int port = FindConVar("hostport").IntValue;
	Format(buffer, maxlen, "sem-id_%d", port);

	static bool s_warned;
	if (!s_warned)
	{
		LogError("lendas_server_id nao configurado - usando \"%s\". Configure em cfg/sourcemod/lendas_live.cfg com o mesmo nome da pasta SFTP deste servidor.", buffer);
		s_warned = true;
	}
}
