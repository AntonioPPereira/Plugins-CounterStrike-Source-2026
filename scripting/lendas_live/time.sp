/**
 * lendas_live / time.sp
 *
 * `FormatTime()` do SourceMod usa a hora LOCAL do sistema operacional do
 * servidor, que pode estar em qualquer fuso dependendo de onde a
 * hospedagem roda — não dá pra confiar nisso pra gerar um timestamp que o
 * backend valida como UTC estrito (`zod .datetime()`).
 *
 * `GetTime()` devolve epoch Unix (sempre UTC por definição). Esta funcao
 * converte epoch -> ano/mes/dia/hora/min/seg em UTC na mao, com o algoritmo
 * civil_from_days (Howard Hinnant, domínio público) — matemática pura,
 * independente de fuso ou biblioteca de data do SO.
 */

void Lendas_FormatIsoUtc(int unixTime, char[] buffer, int maxlen)
{
	int days = unixTime / 86400;
	int secondsOfDay = unixTime % 86400;
	if (secondsOfDay < 0)
	{
		secondsOfDay += 86400;
		days -= 1;
	}

	int hour = secondsOfDay / 3600;
	int minute = (secondsOfDay % 3600) / 60;
	int second = secondsOfDay % 60;

	int z = days + 719468;
	int era = (z >= 0 ? z : z - 146096) / 146097;
	int doe = z - era * 146097;                                   // [0, 146096]
	int yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
	int y = yoe + era * 400;
	int doy = doe - (365 * yoe + yoe / 4 - yoe / 100);            // [0, 365]
	int mp = (5 * doy + 2) / 153;                                  // [0, 11]
	int d = doy - (153 * mp + 2) / 5 + 1;                          // [1, 31]
	int m = mp + (mp < 10 ? 3 : -9);                               // [1, 12]
	y = y + (m <= 2 ? 1 : 0);

	Format(buffer, maxlen, "%04d-%02d-%02dT%02d:%02d:%02dZ", y, m, d, hour, minute, second);
}

void Lendas_NowIso(char[] buffer, int maxlen)
{
	Lendas_FormatIsoUtc(GetTime(), buffer, maxlen);
}
