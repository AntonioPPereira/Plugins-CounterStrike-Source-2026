<#
.SYNOPSIS
    Compila todos os plugins deste repositório.

.DESCRIPTION
    Chama o spcomp uma vez por arquivo em scripting/ e joga os .smx em build/.

    Compila TODOS antes de reclamar, e lista as falhas no fim. Parar no
    primeiro erro esconderia que os outros quatorze estão bem — e três destes
    plugins dependem do SteamWorks, que não vem com o SourceMod, então uma
    máquina sem ele deve conseguir compilar o resto mesmo assim.

.PARAMETER Compiler
    Caminho do spcomp64.exe (ou spcomp.exe) do SourceMod.
    A pasta include/ ao lado dele é passada ao compilador explicitamente, e não
    deduzida do diretório atual — chamar o spcomp de outro lugar sem isso faz
    ele não achar nem os includes que vêm na própria instalação.

.PARAMETER Include
    Pastas extras de include, para dependências que não vêm com o SourceMod.
    Aceita mais de uma. Veja o README: só o SteamWorks é necessário aqui.

.PARAMETER Out
    Pasta de saída. Padrão: build/

.EXAMPLE
    .\build.ps1 -Compiler "C:\sourcemod\addons\sourcemod\scripting\spcomp64.exe"

.EXAMPLE
    .\build.ps1 -Compiler "C:\sm\scripting\spcomp64.exe" -Include "C:\steamworks\include"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Compiler,

    [string[]]$Include = @(),

    [string]$Out = "build"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Compiler)) {
    Write-Error "Compilador não encontrado: $Compiler"
}

$raiz   = Split-Path -Parent $MyInvocation.MyCommand.Path
$fontes = Join-Path $raiz "scripting"
$saida  = Join-Path $raiz $Out

if (-not (Test-Path $saida)) {
    New-Item -ItemType Directory -Path $saida | Out-Null
}

# A include/ da própria instalação do SourceMod, ao lado do compilador.
$incArgs = @()
$incSM = Join-Path (Split-Path -Parent $Compiler) "include"
if (Test-Path $incSM) {
    $incArgs += "-i$incSM"
} else {
    Write-Warning "Não achei $incSM — o compilador vai depender do diretório atual."
}
foreach ($i in $Include) {
    if (-not (Test-Path $i)) { Write-Error "Pasta de include não existe: $i" }
    $incArgs += "-i$i"
}

# Só o nível de cima: subpastas como scripting/lendas_live/ são módulos
# incluídos por um .sp de cima, não plugins que compilam sozinhos.
$arquivos = Get-ChildItem -Path $fontes -Filter "*.sp" -File | Sort-Object Name

Write-Host "Compilando $($arquivos.Count) plugin(s)`n"

$falhas = @()
$ok = 0

foreach ($f in $arquivos) {
    $alvo = Join-Path $saida ($f.BaseName + ".smx")
    Write-Host ("  {0,-28} " -f $f.Name) -NoNewline

    $texto = & $Compiler $f.FullName "-o=$alvo" @incArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        $motivo = ($texto | Where-Object { $_ -match "error \d+" } | Select-Object -First 1)
        if (-not $motivo) { $motivo = "erro sem mensagem reconhecível" }
        # Mostra a partir de "error NNN:" — o caminho completo do arquivo antes
        # disso só empurra a mensagem util pra fora da tela.
        if ($motivo -match '(error \d+:.*)$') { $motivo = $Matches[1] }
        Write-Host "FALHOU" -ForegroundColor Red
        $falhas += [pscustomobject]@{ Arquivo = $f.Name; Motivo = $motivo.Trim() }
        continue
    }

    $kb = [math]::Round((Get-Item $alvo).Length / 1KB, 1)
    Write-Host ("ok  {0} KB" -f $kb) -ForegroundColor Green
    $ok++
}

Write-Host "`n$ok de $($arquivos.Count) compilado(s) em $saida"

if ($falhas.Count -gt 0) {
    Write-Host "`n$($falhas.Count) falhou(ram):" -ForegroundColor Red
    foreach ($x in $falhas) {
        Write-Host ("  {0,-28} {1}" -f $x.Arquivo, $x.Motivo)
    }
    if ($falhas.Motivo -match "SteamWorks") {
        Write-Host "`n  SteamWorks não vem com o SourceMod. Baixe o include e passe a pasta:" -ForegroundColor Yellow
        Write-Host "    .\build.ps1 -Compiler ... -Include C:\caminho\para\steamworks\include" -ForegroundColor Yellow
    }
    exit 1
}
