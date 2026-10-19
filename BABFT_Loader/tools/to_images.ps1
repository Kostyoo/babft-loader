# Картинки для загрузчика BABFT: перетащи файлы на «kartinki_syuda.bat».
# PNG, JPG, BMP копируются как есть; остальное (WEBP, GIF, TIFF, ICO, HEIC — что умеет Windows) переводится в PNG.
# Имя — латиницей («кот.png» -> «kot.png»): у Xeno одно русское имя в workspace ломает список файлов (19.10).
# Файл с таким именем уже есть — новому добавится (2), (3)…, чтобы загрузчик заметил его и открыл сам.
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Paths)
$dst = Join-Path (Split-Path $PSScriptRoot -Parent) 'images'
New-Item -ItemType Directory -Force -Path $dst | Out-Null
try { Add-Type -AssemblyName PresentationCore } catch {}
$lat = @('a','b','v','g','d','e','e','zh','z','i','y','k','l','m','n','o','p','r','s','t','u','f','h','ts','ch','sh','sch','','y','','e','yu','ya')
$abc = 'абвгдеёжзийклмнопрстуфхцчшщъыьэюя'
$map = New-Object 'System.Collections.Generic.Dictionary[string,string]'   # с учётом регистра (а не @{})
for ($i = 0; $i -lt $abc.Length; $i++) {
    $l = $lat[$i]
    $map[[string]$abc[$i]] = $l
    $map[([string]$abc[$i]).ToUpper()] = $(if ($l.Length -gt 0) { $l.Substring(0, 1).ToUpper() + $l.Substring(1) } else { '' })
}
function Ascii-Name([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $c = [string]$ch
        if ($map.ContainsKey($c)) { [void]$sb.Append($map[$c]) }
        elseif ([int]$ch -lt 128 -and $c -match '[A-Za-z0-9 ._()\-]') { [void]$sb.Append($c) }
        else { [void]$sb.Append('_') }
    }
    $r = $sb.ToString().Trim()
    if ($r -eq '' -or $r -match '^[_ .]+$') { $r = 'image_' + (Get-Date -Format 'MMdd_HHmmss') }
    return $r
}
function Free-Name([string]$base, [string]$ext) {
    $p = Join-Path $dst ($base + $ext); $k = 2
    while (Test-Path -LiteralPath $p) { $p = Join-Path $dst ("{0} ({1}){2}" -f $base, $k, $ext); $k++ }
    return $p
}
function Kind([string]$path) {
    $b = New-Object byte[] 12
    $fs = [IO.File]::OpenRead($path)
    try { $n = $fs.Read($b, 0, 12) } finally { $fs.Close() }
    if ($n -ge 8 -and $b[0] -eq 0x89 -and $b[1] -eq 0x50 -and $b[2] -eq 0x4E -and $b[3] -eq 0x47) { return '.png' }
    if ($n -ge 3 -and $b[0] -eq 0xFF -and $b[1] -eq 0xD8 -and $b[2] -eq 0xFF) { return '.jpg' }
    if ($n -ge 2 -and $b[0] -eq 0x42 -and $b[1] -eq 0x4D) { return '.bmp' }
    return $null
}
if (-not $Paths -or $Paths.Count -eq 0) {
    Write-Host "Перетащи картинку (или несколько) на этот файл мышкой."
    Start-Sleep -Seconds 4; exit
}
foreach ($p in $Paths) {
    try {
        $base = Ascii-Name ([IO.Path]::GetFileNameWithoutExtension($p))
        $k = Kind $p
        if ($k) {
            $out = Free-Name $base $k
            Copy-Item -LiteralPath $p -Destination $out
            Write-Host ("готово: " + [IO.Path]::GetFileName($out))
        } else {
            $fs = [IO.File]::OpenRead($p)
            try {
                $dec = [Windows.Media.Imaging.BitmapDecoder]::Create($fs, [Windows.Media.Imaging.BitmapCreateOptions]::None,
                    [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
                $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
                $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($dec.Frames[0]))
                $out = Free-Name $base '.png'
                $os = [IO.File]::Create($out)
                try { $enc.Save($os) } finally { $os.Close() }
                Write-Host ("готово: " + [IO.Path]::GetFileName($out) + " (переведено в PNG)")
            } finally { $fs.Close() }
        }
    } catch {
        Write-Host ("не вышло: " + $p + " — " + $_.Exception.Message)
    }
}
Write-Host ""
Write-Host ("Картинки в папке " + $dst)
Write-Host "Загрузчик (вкладка «Картинка») откроет новую сам."
Start-Sleep -Seconds 3
