# ============================================================
#  音乐台桥接服务  music-bridge.ps1
#  作用：让网页(index.html)读取并控制系统里正在播放的音乐软件
#        （QQ音乐 / 网易云音乐 …），没有在播时负责拉起 QQ 音乐。
#  原理：Windows 媒体会话 SMTC（Windows.Media.Control）
#  接口：http://127.0.0.1:8787/
#        GET /state          当前播放状态（JSON）
#        GET /action?name=   toggle|play|pause|next|prev
#        GET /seek?p=秒       跳转进度
#        GET /open            打开 QQ 音乐
#        GET /ping            健康检查
#        GET /quit            关闭服务
# ============================================================
param([int]$Port = 8787)

$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

Add-Type -AssemblyName System.Runtime.WindowsRuntime

# ---- WinRT 异步调用辅助 ----
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and `
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]

function Await($op, $rt){
    $m = $asTaskGeneric.MakeGenericMethod($rt)
    $t = $m.Invoke($null, @($op))
    $t.Wait(-1) | Out-Null
    $t.Result
}

$script:MgrType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager,Windows.Media.Control,ContentType=WindowsRuntime]
$script:Mgr = $null

$script:AppNames = @{
    'QQMusic.exe'   = 'QQ音乐'
    'cloudmusic.exe'= '网易云音乐'
    'Spotify.exe'   = 'Spotify'
    'foobar2000.exe'= 'foobar2000'
    'KuGou.exe'     = '酷狗音乐'
    'KWMusic.exe'   = '酷我音乐'
    'AIMP.exe'      = 'AIMP'
}

function Get-Mgr {
    if (-not $script:Mgr) {
        $script:Mgr = Await ($script:MgrType::RequestAsync()) $script:MgrType
    }
    return $script:Mgr
}

# 只挑音乐类应用的会话；优先正在播放的那一个
function Get-Session {
    $mgr = Get-Mgr
    if (-not $mgr) { return $null }
    $all = @($mgr.GetSessions())
    if ($all.Count -eq 0) { $script:Mgr = $null; return $null }

    $music = @($all | Where-Object { $script:AppNames.ContainsKey($_.SourceAppUserModelId) })
    if ($music.Count -eq 0) { return $null }

    $playing = @($music | Where-Object { $_.GetPlaybackInfo().PlaybackStatus.ToString() -eq 'Playing' })
    if ($playing.Count -gt 0) { return $playing[0] }
    return $music[0]
}

function Build-State {
    $st = [ordered]@{
        ok = $true; connected = $false; app = ''; appName = ''
        title = ''; artist = ''; album = ''
        playing = $false; position = 0; duration = 0
        canNext = $false; canPrev = $false
    }
    $s = Get-Session
    if (-not $s) { return $st }

    try {
        $pi = $s.GetPlaybackInfo()
        $st.connected = $true
        $st.app = [string]$s.SourceAppUserModelId
        if ($script:AppNames.ContainsKey($st.app)) { $st.appName = $script:AppNames[$st.app] }
        else { $st.appName = $st.app }
        $st.playing = ($pi.PlaybackStatus.ToString() -eq 'Playing')
        $st.canNext  = [bool]$pi.Controls.IsNextEnabled
        $st.canPrev  = [bool]$pi.Controls.IsPreviousEnabled

        $props = Await ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
        if ($props) {
            if ($props.Title)   { $st.title  = [string]$props.Title }
            if ($props.Artist)  { $st.artist = [string]$props.Artist }
            if ($props.AlbumTitle) { $st.album = [string]$props.AlbumTitle }
        }
        $tl = $s.GetTimelineProperties()
        if ($tl) {
            $st.position = [math]::Round($tl.Position.TotalSeconds, 1)
            $st.duration = [math]::Round($tl.EndTime.TotalSeconds, 1)
        }
    } catch {
        $st.connected = $false
    }
    return $st
}

function Invoke-Action([string]$name) {
    $s = Get-Session
    if (-not $s) { return $false }
    try {
        switch ($name) {
            'toggle' { $null = Await ($s.TryTogglePlayPauseAsync()) ([bool]) }
            'play'   { $null = Await ($s.TryPlayAsync()) ([bool]) }
            'pause'  { $null = Await ($s.TryPauseAsync()) ([bool]) }
            'next'   { $null = Await ($s.TrySkipNextAsync()) ([bool]) }
            'prev'   { $null = Await ($s.TrySkipPreviousAsync()) ([bool]) }
            default  { return $false }
        }
        return $true
    } catch { return $false }
}

function Invoke-Seek([double]$seconds) {
    $s = Get-Session
    if (-not $s) { return $false }
    try {
        $ticks = [long]($seconds * 10000000)
        $null = Await ($s.TryChangePlaybackPositionAsync($ticks)) ([bool])
        return $true
    } catch { return $false }
}

# 没在播时拉起 QQ 音乐
function Open-QQMusic {
    $candidates = @()
    foreach ($hive in @('HKLM:', 'HKCU:')) {
        foreach ($k in @(
            "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\QQMusic.exe",
            "$hive\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\QQMusic.exe"
        )) {
            $v = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).'(default)'
            if ($v) { $candidates += $v }
        }
    }
    $candidates += 'D:\Program Files (x86)\Tencent\QQMusic\QQMusic.exe'
    $candidates += 'C:\Program Files (x86)\Tencent\QQMusic\QQMusic.exe'
    $candidates += 'C:\Program Files\Tencent\QQMusic\QQMusic.exe'

    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            try { Start-Process -FilePath $p | Out-Null; return $p } catch {}
        }
    }
    try { Start-Process 'qqmusic://' | Out-Null; return 'qqmusic://' } catch {}
    return ''
}

# ---------------- 极简 HTTP 服务（TcpListener，免管理员） ----------------
function Send-Response($stream, [string]$status, [string]$ctype, [byte[]]$body) {
    $head = "HTTP/1.1 $status`r`n" +
            "Content-Type: $ctype`r`n" +
            "Content-Length: $($body.Length)`r`n" +
            "Access-Control-Allow-Origin: *`r`n" +
            "Access-Control-Allow-Headers: *`r`n" +
            "Access-Control-Allow-Methods: GET, POST, OPTIONS`r`n" +
            "Access-Control-Allow-Private-Network: true`r`n" +
            "Cache-Control: no-store`r`n" +
            "Connection: close`r`n`r`n"
    $hb = [Text.Encoding]::ASCII.GetBytes($head)
    $stream.Write($hb, 0, $hb.Length)
    if ($body.Length -gt 0) { $stream.Write($body, 0, $body.Length) }
    $stream.Flush()
}

function Send-Json($stream, $obj) {
    $json = ($obj | ConvertTo-Json -Compress -Depth 5)
    if (-not $json) { $json = '{}' }
    Send-Response $stream '200 OK' 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
try {
    $listener.Start()
} catch {
    Write-Host ""
    # 先看看是不是自己已经在跑了
    $alive = $false
    try {
        $req = [Net.WebRequest]::Create("http://127.0.0.1:$Port/ping")
        $req.Timeout = 1500
        $resp = $req.GetResponse()
        $sr = New-Object IO.StreamReader($resp.GetResponseStream())
        $txt = $sr.ReadToEnd()
        $sr.Close(); $resp.Close()
        if ($txt -match 'music-bridge') { $alive = $true }
    } catch {}

    if ($alive) {
        Write-Host "  音乐台桥接已经在运行了（端口 $Port），不用重复启动。" -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        exit 0
    }

    Write-Host "  端口 $Port 被别的程序占用了，音乐台桥接没有启动。" -ForegroundColor Red
    Write-Host "  可以改脚本开头的 -Port 参数换个端口（网页里的 BRIDGE 地址也要一起改）。"
    Write-Host ""
    Start-Sleep -Seconds 8
    exit 1
}

Write-Host ""
Write-Host "  ♪ 音乐台桥接已启动" -ForegroundColor Green
Write-Host "    http://127.0.0.1:$Port"
Write-Host "    网页里的音乐台会自动连上；关掉这个窗口即停止。"
Write-Host ""

$script:Cache = $null
$script:CacheAt = [datetime]::MinValue

while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
        $stream = $client.GetStream()
        $client.ReceiveTimeout = 4000

        $buf = New-Object byte[] 8192
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { $client.Close(); continue }

        $text = [Text.Encoding]::ASCII.GetString($buf, 0, $n)
        $requestLine = ($text -split "`r`n")[0]
        $parts = $requestLine -split ' '
        $path = '/'
        if ($parts.Count -ge 2) { $path = $parts[1] }

        $pathOnly = ($path -split '\?')[0]
        $query = ''
        if ($path -match '\?(.*)$') { $query = $matches[1] }

        # 500ms 内重复请求直接给缓存，避免每次都等 WinRT
        if ($pathOnly -eq '/state' -and $script:Cache -and ((Get-Date) - $script:CacheAt).TotalMilliseconds -lt 500) {
            Send-Json $stream $script:Cache
        }
        elseif ($pathOnly -eq '/ping') {
            Send-Json $stream ([ordered]@{ ok = $true; service = 'music-bridge'; port = $Port })
        }
        elseif ($pathOnly -eq '/state') {
            $script:Cache = Build-State
            $script:CacheAt = Get-Date
            Send-Json $stream $script:Cache
        }
        elseif ($pathOnly -eq '/action') {
            $name = ''
            if ($query -match 'name=([a-z]+)') { $name = $matches[1] }
            $done = Invoke-Action $name
            Start-Sleep -Milliseconds 300   # 等播放状态真正切换后再读
            $state = Build-State
            $script:Cache = $state
            $script:CacheAt = Get-Date
            $state['ok'] = $done
            Send-Json $stream $state
        }
        elseif ($pathOnly -eq '/seek') {
            $sec = 0.0
            if ($query -match 'p=([0-9\.]+)') { $sec = [double]$matches[1] }
            $done = Invoke-Seek $sec
            Start-Sleep -Milliseconds 300
            $state = Build-State
            $script:Cache = $state
            $script:CacheAt = Get-Date
            $state['ok'] = $done
            Send-Json $stream $state
        }
        elseif ($pathOnly -eq '/open') {
            $opened = Open-QQMusic
            $script:Cache = $null
            Send-Json $stream ([ordered]@{ ok = [bool]$opened; opened = $opened })
        }
        elseif ($pathOnly -eq '/quit') {
            Send-Json $stream ([ordered]@{ ok = $true })
            break
        }
        else {
            Send-Response $stream '404 Not Found' 'text/plain; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes('not found'))
        }
    } catch {
        # 单个请求出错不影响服务
    } finally {
        try { $client.Close() } catch {}
    }
}

$listener.Stop()
Write-Host "  音乐台桥接已停止。"
