# Vibecoder School local installer for Windows 10/11 PowerShell.

[CmdletBinding()]
param(
    [string]$ServerHost = $env:VIBECODER_SERVER_HOST,
    [int]$SshPort = $(if ($env:VIBECODER_SSH_PORT) { [int]$env:VIBECODER_SSH_PORT } else { 22 })
)

$SshPortWasBound = $PSBoundParameters.ContainsKey('SshPort')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$InstallerVersion = '2026.09.18.1'
$DefaultBaseUrl = 'https://raw.githubusercontent.com/swan4er/claude-code-remote/main'
$BaseUrl = if ($env:VIBECODER_BASE_URL) { $env:VIBECODER_BASE_URL.TrimEnd('/') } else { $DefaultBaseUrl }
$SshAlias = 'vibecoder'
$SshDir = Join-Path $HOME '.ssh'
$KeyPath = Join-Path $SshDir 'vibecoder_vps_ed25519'
$PublicKeyPath = "$KeyPath.pub"
$SshConfigPath = Join-Path $SshDir 'config'
$TempBootstrap = $null

function Write-Info([string]$Message) {
    Write-Host "`n$Message" -ForegroundColor Yellow
}

function Write-Ok([string]$Message) {
    Write-Host "✓ $Message" -ForegroundColor Green
}

function Stop-Install([string]$Message) {
    throw $Message
}

function Assert-LastExitCode([string]$Action) {
    if ($LASTEXITCODE -ne 0) {
        Stop-Install "$Action завершилось с кодом $LASTEXITCODE."
    }
}

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Stop-Install "Не найдена команда '$Name'. Установите компонент OpenSSH Client в Windows и повторите запуск."
    }
}

function Invoke-Download([string]$Uri, [string]$OutFile) {
    $attempt = 0
    while ($attempt -lt 3) {
        $attempt++
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile -TimeoutSec 60
            return
        }
        catch {
            if ($attempt -ge 3) { throw }
            Start-Sleep -Seconds 2
        }
    }
}

function Get-UserInput {
    Write-Host "`nVibecoder School — автоматическая настройка VPS"
    Write-Host 'Поддерживаются Ubuntu Server 24.04 и 26.04 LTS.'

    if ([string]::IsNullOrWhiteSpace($script:ServerHost)) {
        $script:ServerHost = (Read-Host 'IP-адрес VPS').Trim()
    }
    if (-not $env:VIBECODER_SSH_PORT -and -not $script:SshPortWasBound) {
        $enteredPort = (Read-Host 'SSH-порт [22]').Trim()
        if ($enteredPort) {
            if ($enteredPort -notmatch '^\d+$') { Stop-Install 'SSH-порт должен быть числом.' }
            $script:SshPort = [int]$enteredPort
        }
    }

    if ($script:ServerHost -notmatch '^[A-Za-z0-9.-]+$') {
        Stop-Install 'Введите IPv4-адрес или домен сервера без http://, пробелов и дополнительных символов.'
    }
    if ($script:SshPort -lt 1 -or $script:SshPort -gt 65535) {
        Stop-Install 'SSH-порт должен быть числом от 1 до 65535.'
    }
}

function New-VibecoderKey {
    New-Item -ItemType Directory -Force -Path $SshDir | Out-Null

    if ((Test-Path $KeyPath) -and -not (Test-Path $PublicKeyPath)) {
        Stop-Install "Найден приватный ключ без публичной части: $KeyPath. Не перезаписываю его автоматически."
    }
    if (-not (Test-Path $KeyPath)) {
        Write-Info 'Создаю отдельный SSH-ключ для Vibecoder School...'
        & ssh-keygen.exe -q -t ed25519 -a 64 -N '""' -C 'vibecoder-school' -f $KeyPath
        Assert-LastExitCode 'Создание SSH-ключа'
        Write-Ok "SSH-ключ создан: $KeyPath"
    }
    else {
        Write-Ok "Использую существующий ключ: $KeyPath"
    }
}

function Get-PublicKeyBase64 {
    $publicKey = (Get-Content -LiteralPath $PublicKeyPath -Raw).Trim()
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($publicKey))
}

function Add-RootKey([string]$PublicKeyBase64) {
    Write-Info 'Подключаюсь к серверу как root.'
    Write-Host 'Сейчас сервер может один раз попросить пароль root.'
    Write-Host 'Во время ввода пароля символы и звёздочки не отображаются — это нормально.'
    Write-Host ''

    $remoteCommand = "umask 077; mkdir -p /root/.ssh; touch /root/.ssh/authorized_keys; chmod 700 /root/.ssh; chmod 600 /root/.ssh/authorized_keys; KEY=`$(printf '%s' '$PublicKeyBase64' | base64 -d); grep -qxF -- `"`$KEY`" /root/.ssh/authorized_keys || printf '%s\n' `"`$KEY`" >> /root/.ssh/authorized_keys"
    & ssh.exe `
        -p $SshPort `
        -i $KeyPath `
        -o 'IdentitiesOnly=no' `
        -o 'ConnectTimeout=15' `
        -o 'ServerAliveInterval=30' `
        -o 'StrictHostKeyChecking=accept-new' `
        "root@$ServerHost" $remoteCommand
    Assert-LastExitCode 'Добавление SSH-ключа на сервер'
    Write-Ok 'Выделенный ключ добавлен на сервер'
}

function Test-ExistingVibeLogin {
    & ssh.exe `
        -p $SshPort `
        -i $KeyPath `
        -o 'IdentitiesOnly=yes' `
        -o 'BatchMode=yes' `
        -o 'ConnectTimeout=8' `
        -o 'StrictHostKeyChecking=accept-new' `
        "vibe@$ServerHost" 'exit 0' *> $null
    return ($LASTEXITCODE -eq 0)
}

function Get-Bootstrap {
    $script:TempBootstrap = Join-Path ([IO.Path]::GetTempPath()) ("vibecoder-bootstrap-{0}.sh" -f [Guid]::NewGuid().ToString('N'))
    Write-Info 'Загружаю серверный установщик...'
    Invoke-Download "$BaseUrl/bootstrap.sh?v=$InstallerVersion" $script:TempBootstrap

    $fileInfo = Get-Item -LiteralPath $script:TempBootstrap
    if ($fileInfo.Length -eq 0) { Stop-Install 'Серверный установщик загрузился пустым файлом.' }
    $firstLine = Get-Content -LiteralPath $script:TempBootstrap -TotalCount 1
    if ($firstLine -ne '#!/usr/bin/env bash') { Stop-Install 'По адресу bootstrap.sh получен неожиданный файл.' }
    $expectedVersionLine = "readonly INSTALLER_VERSION=`"$InstallerVersion`""
    if (-not (Select-String -LiteralPath $script:TempBootstrap -SimpleMatch $expectedVersionLine -Quiet)) {
        Stop-Install 'Версии локального и серверного установщиков не совпадают. Очистите кэш сайта/CDN и повторите запуск.'
    }
    Write-Ok 'Серверный установщик загружен'
}

function Send-Bootstrap {
    Write-Info 'Передаю установщик на VPS...'
    if ($script:ConnectionUser -eq 'root') {
        & ssh.exe -p $SshPort -i $KeyPath -o 'IdentitiesOnly=yes' "root@$ServerHost" 'install -d -m 700 /root/.cache/vibecoder'
        Assert-LastExitCode 'Создание служебной папки на VPS'

        & scp.exe -q -P $SshPort -i $KeyPath -o 'IdentitiesOnly=yes' $TempBootstrap "root@${ServerHost}:/root/.cache/vibecoder/bootstrap.sh"
        Assert-LastExitCode 'Передача bootstrap.sh на VPS'

        & ssh.exe -p $SshPort -i $KeyPath -o 'IdentitiesOnly=yes' "root@$ServerHost" 'chmod 700 /root/.cache/vibecoder/bootstrap.sh'
        Assert-LastExitCode 'Подготовка bootstrap.sh на VPS'
    }
    else {
        & scp.exe -q -P $SshPort -i $KeyPath -o 'IdentitiesOnly=yes' $TempBootstrap "vibe@${ServerHost}:/tmp/vibecoder-bootstrap.sh"
        Assert-LastExitCode 'Передача bootstrap.sh на VPS'

        & ssh.exe -p $SshPort -i $KeyPath -o 'IdentitiesOnly=yes' "vibe@$ServerHost" 'sudo -n install -d -m 700 /root/.cache/vibecoder && sudo -n install -m 700 /tmp/vibecoder-bootstrap.sh /root/.cache/vibecoder/bootstrap.sh && rm -f /tmp/vibecoder-bootstrap.sh'
        Assert-LastExitCode 'Подготовка bootstrap.sh через vibe'
    }
    Write-Ok 'Установщик передан'
}

function Invoke-BootstrapPhase([string]$Phase, [string]$PublicKeyBase64) {
    $remoteCommand = "env VIBE_PUBLIC_KEY_B64='$PublicKeyBase64' VIBECODER_SSH_PORT='$SshPort' /root/.cache/vibecoder/bootstrap.sh '$Phase'"
    if ($script:ConnectionUser -eq 'vibe') {
        $remoteCommand = "sudo -n $remoteCommand"
    }
    & ssh.exe `
        -p $SshPort `
        -i $KeyPath `
        -o 'IdentitiesOnly=yes' `
        -o 'ServerAliveInterval=30' `
        -o 'ServerAliveCountMax=20' `
        "$($script:ConnectionUser)@$ServerHost" $remoteCommand
    Assert-LastExitCode "Серверный этап $Phase"
}

function Test-VibeLogin {
    Write-Info 'Проверяю реальный вход с этого компьютера под пользователем vibe...'
    $result = & ssh.exe `
        -p $SshPort `
        -i $KeyPath `
        -o 'IdentitiesOnly=yes' `
        -o 'BatchMode=yes' `
        -o 'ConnectTimeout=15' `
        "vibe@$ServerHost" 'printf VIBE_LOGIN_OK'
    if ($LASTEXITCODE -ne 0 -or (($result -join '').Trim() -ne 'VIBE_LOGIN_OK')) {
        Stop-Install 'Вход под vibe не прошёл. Root-доступ и вход по паролю пока НЕ отключены; исправьте причину и перезапустите установщик.'
    }
    Write-Ok 'Вход под vibe по ключу работает'
}

function Write-SshConfig {
    $beginMarker = '# >>> Vibecoder School managed host >>>'
    $endMarker = '# <<< Vibecoder School managed host <<<'
    $existing = if (Test-Path $SshConfigPath) { Get-Content -LiteralPath $SshConfigPath -Raw } else { '' }
    $pattern = '(?ms)^' + [regex]::Escape($beginMarker) + '\r?\n.*?^' + [regex]::Escape($endMarker) + '\r?\n?'
    $cleaned = [regex]::Replace($existing, $pattern, '').TrimEnd()
    $identityPath = $KeyPath.Replace('\', '/')
    $managedBlock = @"
$beginMarker
Host $SshAlias
    HostName $ServerHost
    User vibe
    Port $SshPort
    IdentityFile "$identityPath"
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 6
$endMarker
"@
    $newContent = if ($cleaned) { "$cleaned`r`n`r`n$managedBlock`r`n" } else { "$managedBlock`r`n" }
    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($SshConfigPath, $newContent, $utf8NoBom)

    & ssh.exe -G $SshAlias *> $null
    Assert-LastExitCode 'Проверка SSH config'
    Write-Ok "В SSH добавлено подключение '$SshAlias'"
}

function Test-LocalPort([int]$Port) {
    $listener = $null
    try {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $listener) { $listener.Stop() }
    }
}

function Get-LocalPort {
    foreach ($port in 6080..6099) {
        if (Test-LocalPort $port) { return $port }
    }
    Stop-Install 'Локальные порты 6080–6099 заняты. Закройте старые SSH-туннели и повторите запуск.'
}

function Start-NoVncTunnel {
    $localPort = Get-LocalPort
    $url = "http://127.0.0.1:$localPort/vnc.html?autoconnect=1&resize=remote"
    Write-Info 'Открываю защищённый туннель к рабочему столу VPS...'

    $arguments = @(
        '-N',
        '-o', 'ExitOnForwardFailure=yes',
        '-L', "${localPort}:127.0.0.1:6080",
        $SshAlias
    )
    $process = Start-Process -FilePath 'ssh.exe' -ArgumentList $arguments -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 2
    if ($process.HasExited) {
        Stop-Install "SSH-туннель завершился сразу после запуска с кодом $($process.ExitCode)."
    }

    $ready = $false
    foreach ($attempt in 1..20) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$localPort/vnc.html" -TimeoutSec 3 | Out-Null
            $ready = $true
            break
        }
        catch {
            Start-Sleep -Seconds 1
        }
    }
    if (-not $ready) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        Stop-Install "SSH-туннель запущен, но страница noVNC не отвечает. Выполните: ssh vibecoder 'sudo systemctl status vibecoder-novnc --no-pager'"
    }

    $state = [ordered]@{
        process_id = $process.Id
        local_port = $localPort
        server = $ServerHost
        created_at = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json
    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $SshDir 'vibecoder_tunnel.json'), $state, $utf8NoBom)

    Write-Ok "Удалённый рабочий стол доступен через локальный порт $localPort"
    Start-Process $url
    Write-Host "`nОткрылся рабочий стол VPS. Внутри него работает Firefox с IP вашего сервера."
    Write-Host 'Не переносите ссылку авторизации в другую вкладку локального браузера.'
    Write-Host "Если браузер не открылся автоматически: $url"
}

try {
    if ($env:OS -ne 'Windows_NT') {
        Stop-Install 'install.ps1 предназначен для Windows. На macOS и Linux используйте install.sh.'
    }
    Require-Command 'ssh.exe'
    Require-Command 'scp.exe'
    Require-Command 'ssh-keygen.exe'
    Get-UserInput
    New-VibecoderKey

    $publicKeyBase64 = Get-PublicKeyBase64
    if (Test-ExistingVibeLogin) {
        $script:ConnectionUser = 'vibe'
        Write-Ok 'Сервер уже принимает ключ пользователя vibe; продолжаю безопасный повторный запуск'
    }
    else {
        $script:ConnectionUser = 'root'
        Add-RootKey $publicKeyBase64
    }
    Get-Bootstrap
    Send-Bootstrap

    Write-Info 'Готовлю Ubuntu, пользователя vibe, Claude Code и удалённый рабочий стол. Это может занять 10–20 минут...'
    Invoke-BootstrapPhase 'prepare' $publicKeyBase64

    Test-VibeLogin
    Write-Info 'Безопасный вход под vibe подтверждён. Теперь отключаю root-login и вход по паролю...'
    Invoke-BootstrapPhase 'harden' $publicKeyBase64
    Test-VibeLogin

    Write-SshConfig
    Write-Ok "Сервер полностью настроен (версия установщика $InstallerVersion)"
    Write-Host "`nВ VS Code выберите: Remote-SSH → Connect to Host → $SshAlias"
    Start-NoVncTunnel
}
catch {
    Write-Host "`nОшибка: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Исправьте указанную причину и запустите установщик ещё раз. Уже выполненные безопасные шаги повторно не сломаются.' -ForegroundColor Yellow
    exit 1
}
finally {
    if ($TempBootstrap -and (Test-Path -LiteralPath $TempBootstrap)) {
        Remove-Item -LiteralPath $TempBootstrap -Force -ErrorAction SilentlyContinue
    }
}
