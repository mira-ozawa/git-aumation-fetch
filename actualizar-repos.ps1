<#
.SYNOPSIS
  Actualiza los remotes de todos tus repos locales segun donde viven HOY en GitHub
  (cambios de org/usuario y de nombre) y hace git fetch de cada uno.
  Un error en un repo nunca detiene el script. Al final muestra y guarda todo lo que fallo.

.USO
  # 1) Modo prueba (no cambia remotes, pero si hace fetch):
  powershell -ExecutionPolicy Bypass -File .\actualizar-repos.ps1

  # 2) Aplicar cambios de remotes + fetch:
  powershell -ExecutionPolicy Bypass -File .\actualizar-repos.ps1 -Apply

  # Solo actualizar remotes, sin fetch:
  powershell -ExecutionPolicy Bypass -File .\actualizar-repos.ps1 -Apply -NoFetch

  # Otras carpetas raiz:
  powershell -ExecutionPolicy Bypass -File .\actualizar-repos.ps1 -Roots "C:\code","D:\work"

.REQUISITOS
  git y (opcional pero recomendado) GitHub CLI "gh" con sesion iniciada: gh auth login
#>

[CmdletBinding()]
param(
    [switch]$Apply,                 # sin esto = solo prueba (no modifica remotes)
    [switch]$NoFetch,               # no hacer git fetch
    [switch]$IncluirMalware,        # incluir la carpeta 16.malware
    [switch]$Silent,                # modo automatico: no deja carpetas de reporte si no hubo cambios
    [string[]]$Roots,               # carpetas raiz; si se omite usa Documents\<N>.* (carpetas numeradas)
    [int]$FetchTimeoutSeg = 60      # segundos sin trafico antes de abortar un fetch
)

$ErrorActionPreference = 'Continue'   # nunca detener todo por un error
$ProgressPreference    = 'SilentlyContinue'

# Evita que dos ejecuciones corran a la vez (importante en la tarea programada)
$mutex = New-Object System.Threading.Mutex($false, 'Local\ActualizarRemotesGit')
if (-not $mutex.WaitOne(0)) { Write-Host 'Ya hay otra ejecucion en curso. Saliendo.'; exit 0 }

# Evita que git se quede esperando usuario/clave o confirmacion SSH
$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE     = 'Never'
$env:GIT_SSH_COMMAND     = 'ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new'

# ---------------------------------------------------------------
#  Preparacion
# ---------------------------------------------------------------
$inicio  = Get-Date
$stamp   = $inicio.ToString('yyyyMMdd-HHmmss')
$outDir  = Join-Path $env:USERPROFILE "Documents\reportes-repos\$stamp"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$logFile = Join-Path $outDir 'log.txt'

function Log([string]$msg, [string]$color = 'Gray') {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Write-Host $line -ForegroundColor $color
    try { Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 } catch {}
}

# Comprobar git
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: git no esta instalado o no esta en el PATH." -ForegroundColor Red
    exit 2
}

# Comprobar gh
$ghOk = $false
if (Get-Command gh -ErrorAction SilentlyContinue) {
    & gh auth status *> $null
    if ($LASTEXITCODE -eq 0) { $ghOk = $true }
}
if (-not $ghOk) {
    Log "AVISO: 'gh' no esta instalado o no hay sesion (gh auth login). Se omite la deteccion de cambios de org; solo se hara fetch." 'Yellow'
}

# Evita el error 'dubious ownership' (una sola vez, sin duplicar)
try {
    $ya = & git config --global --get-all safe.directory 2>$null
    if ($ya -notcontains '*') { & git config --global --add safe.directory '*' 2>$null }
} catch {}

# Carpetas raiz
if (-not $Roots -or $Roots.Count -eq 0) {
    $docs  = Join-Path $env:USERPROFILE 'Documents'
    $Roots = @(Get-ChildItem -LiteralPath $docs -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+\.' -and ($IncluirMalware -or $_.Name -ne '16.malware') } |
        Select-Object -ExpandProperty FullName)
}
$Roots = @($Roots | Where-Object { Test-Path -LiteralPath $_ })
if ($Roots.Count -eq 0) {
    Write-Host "ERROR: no hay carpetas raiz validas donde buscar." -ForegroundColor Red
    exit 2
}

$skip = @('.git','node_modules','$Recycle.Bin','Windows','System Volume Information',
          '.venv','venv','vendor','__pycache__','.next')

# ---------------------------------------------------------------
#  Buscar repos (incluye repos anidados dentro de otros repos)
# ---------------------------------------------------------------
function Find-Repos([string]$root) {
    $found = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Stack
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $dir = [string]$stack.Pop()
        try {
            if (Test-Path -LiteralPath (Join-Path $dir '.git')) { $found.Add($dir) }
            $subs = [IO.Directory]::GetDirectories($dir)
        } catch { continue }
        foreach ($s in $subs) {
            $leaf = [IO.Path]::GetFileName($s)
            if ($skip -contains $leaf) { continue }
            $stack.Push($s)
        }
    }
    return $found
}

Log "Modo: $(if ($Apply) {'APLICAR CAMBIOS'} else {'PRUEBA (no modifica remotes)'}) | Fetch: $(if ($NoFetch) {'NO'} else {'SI'}) | gh: $(if ($ghOk) {'SI'} else {'NO'})" 'Cyan'
Log "Buscando repos en $($Roots.Count) carpeta(s)..." 'Cyan'

$repos = New-Object System.Collections.Generic.List[string]
foreach ($root in $Roots) {
    try {
        $r = Find-Repos $root
        foreach ($x in $r) { $repos.Add($x) }
        Log ("  {0}  ->  {1} repos" -f $root, $r.Count)
    } catch {
        Log "  ERROR recorriendo ${root}: $($_.Exception.Message)" 'Red'
    }
}
$repos = @($repos | Select-Object -Unique)
Log "Total de repos encontrados: $($repos.Count)" 'Cyan'

# ---------------------------------------------------------------
#  Funciones auxiliares
# ---------------------------------------------------------------
$cache = @{}   # org/repo (minusculas) -> @{ Full=...; Estado=... }

function Resolve-GitHub([string]$org, [string]$name) {
    $key = "$org/$name".ToLower()
    if ($cache.ContainsKey($key)) { return $cache[$key] }

    $res = @{ Full = $null; Estado = 'SIN GH'; Detalle = '' }
    if ($ghOk) {
        try {
            $out  = & gh api "repos/$org/$name" --jq .full_name 2>&1
            $code = $LASTEXITCODE
            $txt  = ($out | ForEach-Object { $_.ToString() }) -join ' '
            if ($code -eq 0 -and $txt) {
                $res = @{ Full = $txt.Trim(); Estado = 'OK'; Detalle = '' }
            } elseif ($txt -match '404|Not Found') {
                $res = @{ Full = $null; Estado = 'NO ENCONTRADO'; Detalle = 'GitHub responde 404 (borrado, sin acceso o SSO sin autorizar)' }
            } elseif ($txt -match '403|rate limit|SAML|SSO') {
                $res = @{ Full = $null; Estado = 'ERROR API'; Detalle = $txt }
            } else {
                $res = @{ Full = $null; Estado = 'ERROR API'; Detalle = $txt }
            }
        } catch {
            $res = @{ Full = $null; Estado = 'ERROR API'; Detalle = $_.Exception.Message }
        }
    }
    $cache[$key] = $res
    return $res
}

function Invoke-Fetch([string]$repo, [string]$remote) {
    $job = $null
    try {
        $job = Start-Job -ScriptBlock {
            param($r, $rm)
            $o = & git -C $r fetch $rm --prune 2>&1
            [PSCustomObject]@{
                Code = $LASTEXITCODE
                Out  = (($o | ForEach-Object { $_.ToString() }) -join ' ')
            }
        } -ArgumentList $repo, $remote

        if (Wait-Job -Job $job -Timeout $FetchTimeoutSeg) {
            $res = Receive-Job -Job $job
            Remove-Job -Job $job -Force
            $txt = ([string]$res.Out).Trim()
            if ($txt.Length -gt 400) { $txt = $txt.Substring(0,400) + '...' }
            return @{ Ok = ($res.Code -eq 0); Detalle = $txt }
        } else {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            return @{ Ok = $false; Detalle = "Timeout: el fetch tardo mas de $FetchTimeoutSeg s y se cancelo" }
        }
    } catch {
        if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
        return @{ Ok = $false; Detalle = $_.Exception.Message }
    }
}

# ---------------------------------------------------------------
#  Proceso principal (un error en un repo NO detiene el resto)
# ---------------------------------------------------------------
$report = New-Object System.Collections.Generic.List[object]
$i = 0

foreach ($repo in $repos) {
    $i++
    Write-Host ("[{0}/{1}] {2}" -f $i, $repos.Count, $repo) -ForegroundColor DarkGray

    try {
        $remotes = @(& git -C $repo remote 2>$null | Where-Object { $_ })

        if ($remotes.Count -eq 0) {
            $report.Add([PSCustomObject]@{ Repo=$repo; Remote=''; UrlAntes=''; UrlNueva=''; Remoto='SIN REMOTE'; Fetch='OMITIDO'; Detalle='Repo solo local' })
            continue
        }

        foreach ($r in $remotes) {
            $row = [PSCustomObject]@{ Repo=$repo; Remote=$r; UrlAntes=''; UrlNueva=''; Remoto=''; Fetch='OMITIDO'; Detalle='' }

            try {
                $url = (& git -C $repo remote get-url $r 2>$null | Select-Object -First 1)
                $row.UrlAntes = [string]$url

                if (-not $url) {
                    $row.Remoto  = 'ERROR'
                    $row.Detalle = 'No se pudo leer la URL del remote'
                    $report.Add($row); continue
                }

                $urlActual = [string]$url

                # Acepta https://github.com/..., git@github.com:..., alias SSH tipo git@github-trabajo:...
                $m = [regex]::Match($urlActual, '^(?<pre>.*?github[^:/]*[:/])(?<org>[^/]+)/(?<name>[^/]+?)(?<suf>\.git)?/?$')

                if (-not $m.Success) {
                    $row.Remoto = 'NO GITHUB'
                } elseif (-not $ghOk) {
                    $row.Remoto = 'SIN GH'
                } else {
                    $org  = $m.Groups['org'].Value
                    $name = $m.Groups['name'].Value
                    $info = Resolve-GitHub $org $name

                    if ($info.Estado -ne 'OK') {
                        $row.Remoto  = $info.Estado
                        $row.Detalle = $info.Detalle
                    } elseif ($info.Full.ToLower() -eq "$org/$name".ToLower()) {
                        $row.Remoto = 'AL DIA'
                    } else {
                        $nueva = $m.Groups['pre'].Value + $info.Full + $m.Groups['suf'].Value
                        $row.UrlNueva = $nueva
                        if ($Apply) {
                            $null = & git -C $repo remote set-url $r $nueva 2>&1
                            $setCode = $LASTEXITCODE
                            $check = [string](& git -C $repo remote get-url $r 2>$null | Select-Object -First 1)
                            if ($setCode -eq 0 -and $check.Trim() -eq $nueva) {
                                $row.Remoto = 'ACTUALIZADO'
                                $urlActual  = $nueva
                                Log "[OK] $repo ($r)  ->  $nueva" 'Green'
                            } else {
                                $row.Remoto  = 'ERROR'
                                $row.Detalle = 'set-url no se aplico correctamente'
                                Log "[ERROR] $repo ($r): set-url fallo" 'Red'
                            }
                        } else {
                            $row.Remoto = 'POR ACTUALIZAR'
                            Log "[PRUEBA] $repo ($r)`n      $urlActual`n      -> $nueva" 'Yellow'
                        }
                    }
                }

                # Fetch
                if (-not $NoFetch) {
                    $f = Invoke-Fetch $repo $r
                    if ($f.Ok) {
                        $row.Fetch = 'OK'
                    } else {
                        $row.Fetch = 'FALLO'
                        if ($row.Detalle) { $row.Detalle += ' | ' }
                        $row.Detalle += "fetch: $($f.Detalle)"
                        Log "[FETCH FALLO] $repo ($r): $($f.Detalle)" 'Red'
                    }
                }
            } catch {
                $row.Remoto  = 'ERROR'
                $row.Detalle = $_.Exception.Message
                Log "[ERROR] $repo ($r): $($_.Exception.Message)" 'Red'
            }

            $report.Add($row)
        }
    } catch {
        $report.Add([PSCustomObject]@{ Repo=$repo; Remote=''; UrlAntes=''; UrlNueva=''; Remoto='ERROR'; Fetch='OMITIDO'; Detalle=$_.Exception.Message })
        Log "[ERROR] ${repo}: $($_.Exception.Message)" 'Red'
    }
}


# ---------------------------------------------------------------
#  Reportes
# ---------------------------------------------------------------
$csvTodo   = Join-Path $outDir 'reporte-completo.csv'
$csvFallos = Join-Path $outDir 'fallos.csv'
$csvRevert = Join-Path $outDir 'revertir.csv'

$report | Export-Csv -LiteralPath $csvTodo -NoTypeInformation -Encoding UTF8

$estadosMalos = 'NO ENCONTRADO','ERROR API','ERROR'
$fallos = @($report | Where-Object { $_.Fetch -eq 'FALLO' -or $estadosMalos -contains $_.Remoto })
$fallos | Export-Csv -LiteralPath $csvFallos -NoTypeInformation -Encoding UTF8

# Respaldo para revertir cambios aplicados
$aplicados = @($report | Where-Object { $_.Remoto -eq 'ACTUALIZADO' })
if ($aplicados.Count) {
    $aplicados | Select-Object Repo, Remote, UrlAntes, UrlNueva | Export-Csv -LiteralPath $csvRevert -NoTypeInformation -Encoding UTF8
}

$dur = (Get-Date) - $inicio
Write-Host ""
Write-Host "================ RESUMEN ================" -ForegroundColor Cyan
Write-Host ("Repos revisados : {0}" -f $repos.Count)
Write-Host ("Remotes revisados: {0}" -f $report.Count)
Write-Host ("Duracion         : {0:mm\:ss}" -f $dur)
Write-Host ""
Write-Host "Estado del remote:" -ForegroundColor Yellow
$report | Group-Object Remoto | Sort-Object Name | ForEach-Object { "  {0,-16} {1}" -f $_.Name, $_.Count }
if (-not $NoFetch) {
    Write-Host ""
    Write-Host "Resultado del fetch:" -ForegroundColor Yellow
    $report | Group-Object Fetch | Sort-Object Name | ForEach-Object { "  {0,-16} {1}" -f $_.Name, $_.Count }
}

if ($fallos.Count -gt 0) {
    Write-Host ""
    Write-Host "!!! HAY $($fallos.Count) FALLO(S) !!!" -ForegroundColor Red
    foreach ($f in $fallos) {
        Write-Host ("  - {0} ({1})" -f $f.Repo, $f.Remote) -ForegroundColor Red
        Write-Host ("      remoto: {0} | fetch: {1}" -f $f.Remoto, $f.Fetch) -ForegroundColor DarkRed
        if ($f.Detalle) { Write-Host ("      {0}" -f $f.Detalle) -ForegroundColor DarkRed }
    }
} else {
    Write-Host ""
    Write-Host "Sin fallos." -ForegroundColor Green
}

$porAplicar = @($report | Where-Object { $_.Remoto -eq 'POR ACTUALIZAR' })
if ($porAplicar.Count -gt 0) {
    Write-Host ""
    Write-Host "$($porAplicar.Count) remote(s) siguen con el nombre viejo. Ejecuta de nuevo con -Apply para corregirlos." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Archivos guardados en: $outDir" -ForegroundColor Cyan
Write-Host "  reporte-completo.csv  (todos los repos y su estado)"
Write-Host "  fallos.csv            (solo lo que fallo)"
if ($aplicados.Count) { Write-Host "  revertir.csv          (para deshacer los cambios aplicados)" }
Write-Host "  log.txt"

if ($Silent) {
    $baseRep = Join-Path $env:USERPROFILE 'Documents\reportes-repos'
    $fFallos = Join-Path $baseRep 'ultimo-fallos.csv'
    if ($fallos.Count -gt 0) {
        $fallos | Export-Csv -LiteralPath $fFallos -NoTypeInformation -Encoding UTF8
    } elseif (Test-Path -LiteralPath $fFallos) {
        Remove-Item -LiteralPath $fFallos -Force -ErrorAction SilentlyContinue
    }
    foreach ($a in $aplicados) {
        Add-Content -LiteralPath (Join-Path $baseRep 'cambios-automaticos.log') -Encoding UTF8 -Value (
            "{0} | {1} ({2}) | {3} -> {4}" -f (Get-Date -Format 's'), $a.Repo, $a.Remote, $a.UrlAntes, $a.UrlNueva)
    }
    Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue
}

try { $mutex.ReleaseMutex() } catch {}
if ($fallos.Count -gt 0) { exit 1 } else { exit 0 }
