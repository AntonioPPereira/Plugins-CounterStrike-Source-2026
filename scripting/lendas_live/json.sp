/**
 * lendas_live / json.sp
 *
 * Nao existe encoder JSON nativo no SourceMod base — os eventos sao
 * montados na mao com Format/StrCat (mesmo estilo do lendas_steamfilter
 * pros seus JSON de request). So esta funcao de escape merece existir
 * separada: nickname de jogador e hostname do servidor sao texto livre, e
 * sem escapar aspas/barra invertida um nick normal ("Cara"Loko") quebraria
 * o JSON do LOTE inteiro, nao so daquele jogador.
 */

void Lendas_JsonEscape(const char[] input, char[] output, int maxlen)
{
	int outPos = 0;
	int len = strlen(input);

	for (int i = 0; i < len; i++)
	{
		// 3 bytes de sobra: o pior caso (escape de 2 chars) + o terminador nulo.
		if (outPos >= maxlen - 3)
			break;

		char c = input[i];

		if (c == '"' || c == '\\')
		{
			output[outPos++] = '\\';
			output[outPos++] = c;
		}
		else if (c == '\n')
		{
			output[outPos++] = '\\';
			output[outPos++] = 'n';
		}
		else if (c == '\r')
		{
			output[outPos++] = '\\';
			output[outPos++] = 'r';
		}
		else if (c == '\t')
		{
			output[outPos++] = '\\';
			output[outPos++] = 't';
		}
		else if (c < 0x20)
		{
			// Caractere de controle sem mapeamento — nunca aparece em nick de
			// verdade; vira espaco em vez de produzir um JSON invalido.
			output[outPos++] = ' ';
		}
		else
		{
			output[outPos++] = c;
		}
	}

	output[outPos] = '\0';
}
