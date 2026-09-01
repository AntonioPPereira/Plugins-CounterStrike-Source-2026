/**
 * lendas_live / http.sp
 *
 * Unico ponto que fala HTTP com o backend. Usa a extensao SteamWorks —
 * ja instalada e comprovadamente funcionando neste servidor (e o que o
 * lendas_steamfilter usa pra falar com a Steam Web API) — em vez de trazer
 * uma extensao nova so pra isso.
 *
 * `SteamWorks_SendHTTPRequest` e assincrono: a chamada devolve na hora, a
 * resposta chega depois via callback. Isso e o que garante que um POST
 * lento (ou o backend fora do ar) nunca trava um tick do servidor.
 */

void Lendas_SendBatch(const char[] body)
{
	char url[256];
	g_cvApiUrl.GetString(url, sizeof(url));

	Handle req = SteamWorks_CreateHTTPRequest(k_EHTTPMethodPOST, url);
	if (req == null)
	{
		g_bFlushInFlight = false;
		Lendas_RegisterFailure("falha ao criar request HTTP");
		return;
	}

	char token[128];
	g_cvApiToken.GetString(token, sizeof(token));
	char authHeader[160];
	Format(authHeader, sizeof(authHeader), "Bearer %s", token);

	SteamWorks_SetHTTPRequestHeaderValue(req, "Authorization", authHeader);
	SteamWorks_SetHTTPRequestRawPostBody(req, "application/json", body, strlen(body));
	SteamWorks_SetHTTPRequestNetworkActivityTimeout(req, 10);
	SteamWorks_SetHTTPCallbacks(req, Lendas_OnBatchSent);

	if (g_cvDebug.BoolValue)
		LogMessage("[Lendas] Enviando lote (%d bytes, %d eventos)", strlen(body), g_iPendingFlushCount);

	if (!SteamWorks_SendHTTPRequest(req))
	{
		delete req;
		g_bFlushInFlight = false;
		Lendas_RegisterFailure("falha ao despachar request HTTP");
	}
}

public void Lendas_OnBatchSent(Handle hRequest, bool bFailure, bool bOk, EHTTPStatusCode code, any data)
{
	delete hRequest;
	g_bFlushInFlight = false;

	if (bFailure || !bOk)
	{
		Lendas_RegisterFailure("timeout ou falha de rede");
		return;
	}

	if (code == k_EHTTPStatusCode200OK || code == k_EHTTPStatusCode202Accepted)
	{
		Lendas_RegisterSuccess();
		Lendas_DequeueSent(g_iPendingFlushCount);
		g_iPendingFlushCount = 0;
		return;
	}

	if (code == k_EHTTPStatusCode401Unauthorized || code == k_EHTTPStatusCode403Forbidden)
	{
		// Token errado/backend nao configurado: nao descarta a fila — o
		// admin pode corrigir lendas_api_token a qualquer momento e os
		// eventos acumulados ainda serao uteis quando isso acontecer.
		Lendas_RegisterFailure("401/403 - confira lendas_api_token");
		return;
	}

	/**
	 * 4xx que NAO seja 401/403/429: o backend recusou o CONTEUDO deste lote.
	 * Reenviar os mesmos bytes nunca vai passar, entao o lote e descartado.
	 *
	 * Sem isso um unico evento invalido trava o feed pra sempre: em
	 * 2026-08-31 um 400 fez o plugin reenviar o mesmo lote por mais de 15
	 * tentativas seguidas, a fila encheu (429 avisos de "Fila cheia") e a
	 * partida ao vivo sumiu do site enquanto o servidor estava cheio.
	 *
	 * 429 continua sendo repetido de proposito: ali o conteudo esta certo,
	 * so chegou rapido demais. 5xx e timeout tambem — o problema e do outro
	 * lado e passa sozinho.
	 */
	int iCode = view_as<int>(code);
	char sCode[16];
	IntToString(iCode, sCode, sizeof(sCode));

	if (iCode >= 400 && iCode < 500 && iCode != 429)
	{
		LogError("[Lendas] Lote recusado (%d) - descartando %d evento(s); reenviar nao adiantaria.",
			iCode, g_iPendingFlushCount);
		Lendas_DequeueSent(g_iPendingFlushCount);
		g_iPendingFlushCount = 0;
	}

	Lendas_RegisterFailure(sCode);
}
