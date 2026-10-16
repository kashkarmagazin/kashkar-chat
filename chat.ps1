# Kompyuter o'chiq bo'lganda Telegram botga kelgan xabarlarga bulutda (GitHub Actions) Claude orqali javob beradi.
# Kompyuterdagi bot.ps1 xabarni bir zumda oladi; agar xabar 60 soniyadan beri olinmagan bo'lsa — kompyuter o'chiq, javobni shu skript beradi.
$ErrorActionPreference = "Stop"
$tg = $env:TG_TOKEN; $owner = $env:TG_CHAT
$api = "https://api.telegram.org/bot$tg"
$state = Join-Path $PSScriptRoot "state"; New-Item -ItemType Directory -Force $state | Out-Null
$histFile = Join-Path $state "history.enc"
$tmp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }

function Tg($method, $body) {
  $json = $body | ConvertTo-Json -Depth 5
  Invoke-RestMethod -Method Post "$api/$method" -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType "application/json; charset=utf-8" -TimeoutSec 90
}
function Say($text) {
  for ($i = 0; $i -lt $text.Length; $i += 3900) { Tg sendMessage @{ chat_id = $owner; text = $text.Substring($i, [Math]::Min(3900, $text.Length - $i)); disable_web_page_preview = $true } | Out-Null }
}
function Load-History {
  if (-not (Test-Path $histFile)) { return @() }
  $plain = & openssl enc -d -aes-256-cbc -pbkdf2 -a -A -pass env:HIST_KEY -in $histFile 2>$null
  if (-not $plain) { return @() }
  ($plain -join "`n") | ConvertFrom-Json
}
function Save-History($h) {
  $h = @($h | Select-Object -Last 40)
  $p = Join-Path $tmp "hist.json"
  [IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $h -Depth 4 -Compress), (New-Object Text.UTF8Encoding($false)))
  & openssl enc -aes-256-cbc -pbkdf2 -a -A -salt -pass env:HIST_KEY -in $p -out $histFile
  Remove-Item $p
}
# Umumiy tarixga yozish (kompyuter ham shu faylga yozadi): eng yangi holatni olib, qo'shib, push; to'qnashuvda qaytadan
function Append-History($entries) {
  for ($try = 0; $try -lt 5; $try++) {
    & git -C $PSScriptRoot fetch -q origin main; & git -C $PSScriptRoot reset -q --hard origin/main
    Save-History (@(Load-History) + $entries)
    & git -C $PSScriptRoot add state/history.enc
    & git -C $PSScriptRoot -c user.name=kashkar-bot -c user.email=kashkar-bot@users.noreply.github.com commit -qm "suhbat (bulut)"
    & git -C $PSScriptRoot push -q origin HEAD:main 2>$null
    if ($LASTEXITCODE -eq 0) { return }
    Start-Sleep 3
  }
}

# 1) Ko'rib chiqish (tasdiqlamasdan): kompyuter olmagan eski xabarlar bormi?
$ups = @((Invoke-RestMethod "$api/getUpdates?timeout=0&allowed_updates=%5B%22message%22%5D" -TimeoutSec 30).result)
if (-not $ups) { "bo'sh"; return }
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
if (($ups | ForEach-Object { $_.message.date } | Measure-Object -Minimum).Minimum -gt $now - 60) { "kompyuter ishlayapti (yangi xabarlar bor, kutamiz)"; return }
# 2) Tasdiqlash — endi bu xabarlar bizniki
$null = Invoke-RestMethod "$api/getUpdates?timeout=0&offset=$(($ups[-1].update_id) + 1)" -TimeoutSec 30
$msgs = @($ups | Where-Object { $_.message -and "$($_.message.chat.id)" -eq $owner } | ForEach-Object { $_.message })
if (-not $msgs) { "begona xabarlar o'tkazib yuborildi"; return }

# 3) Xabarlarni matnga aylantirish
$parts = @(); $files = @()
foreach ($m in $msgs) {
  $text = "" + $(if ($m.text) { $m.text } else { $m.caption })
  if ($text -match '^/(start|yangi)') { continue }
  if ($m.reply_to_message) { $parts += "[Bu xabarga javob: $($m.reply_to_message.text)]" }
  $fid = $null; $kind = $null
  if ($m.voice) { $fid = $m.voice.file_id; $kind = "voice" } elseif ($m.audio) { $fid = $m.audio.file_id; $kind = "voice" }
  elseif ($m.photo) { $fid = ($m.photo | Select-Object -Last 1).file_id; $kind = "photo" }
  elseif ($m.video -or $m.document -or $m.video_note -or $m.animation) { $kind = "file" }
  if ($fid) {
    $f = (Tg getFile @{ file_id = $fid }).result
    $dest = Join-Path $tmp ([IO.Path]::GetFileName($f.file_path))
    Invoke-WebRequest "https://api.telegram.org/file/bot$tg/$($f.file_path)" -OutFile $dest
    if ($kind -eq "voice") {
      & pip install -q faster-whisper 2>$null | Out-Null
      $heard = & python3 -c "import sys;from faster_whisper import WhisperModel as W;m=W('large-v3-turbo',device='cpu',compute_type='int8');s,_=m.transcribe(sys.argv[1],language='uz',vad_filter=True);print(' '.join(x.text.strip() for x in s))" $dest 2>$null
      $parts += "[Ovozli xabar, avtomatik matnga o'girildi, xato bo'lishi mumkin]: $heard"
    } else { $parts += "[Rasm yubordi: $dest — Read vositasi bilan ko'r]"; $files += $dest }
  }
  if ($kind -eq "file") { $parts += "[Video/fayl yubordi. Bulutdan uni kompyuterga saqlab bo'lmaydi — Yusufga kompyuter yoqilganda qayta yuborishini ayt]" }
  if ($text) { $parts += $text }
}
if (-not $parts) { "buyruqlar o'tkazib yuborildi"; return }
$userText = $parts -join "`n"

# 4) Claude
Tg sendChatAction @{ chat_id = $owner; action = "typing" } | Out-Null
$hist = @(Load-History)
$histText = ($hist | ForEach-Object { $w = if ($_.src -eq "kompyuter") { "💻" } else { "☁️" }; "[$($_.t) $w] $($_.who): $($_.text)" }) -join "`n"
$oshNow = [DateTime]::UtcNow.AddHours(6).ToString("dd.MM.yyyy HH:mm")
$sys = @"
Sen Kashkar magazini (Osh, Qirg'iziston, kiyim-kechak/tovarlar do'koni, Instagram: kashkar_magazin, WhatsApp 0550 175 667) egasi Yusufning shaxsiy yordamchisisan. U Telegram botga telefondan yozyapti.
Hozir uning kompyuteri O'CHIQ, sen bulutda (GitHub Actions) ishlayapsan: kompyuterdagi fayllar, videolar va montaj vositalari yo'q. Kompyuter kerak bo'ladigan ishni (montaj, post joylash) "kompyuter yoqilganda bajaraman" deb rejaga yoz.
Instagram statistikasi kerak bo'lsa: curl "https://graph.instagram.com/v21.0/me?fields=username,followers_count,media_count&access_token=`$IG_TOKEN" (media: /me/media?fields=caption,timestamp,like_count,comments_count,permalink,media_product_type). Tokenni hech qachon chiqarma.
Kunlik reja: kuniga 2 ta reels. Javobni o'zbek tilida (lotin), qisqa va aniq yoz; markdown jadval, ** va # ishlatma. Hozir Osh vaqti: $oshNow.
"@
$prompt = "Oldingi suhbat (eski -> yangi):`n$histText`n`n--- Yangi xabar ---`n$userText"
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { & npm install -g --silent @anthropic-ai/claude-code 2>$null | Out-Null }
$in = Join-Path $tmp "in.txt"; [IO.File]::WriteAllText($in, $prompt, (New-Object Text.UTF8Encoding($false)))
$sysF = Join-Path $tmp "sys.txt"; [IO.File]::WriteAllText($sysF, $sys, (New-Object Text.UTF8Encoding($false)))
$job = Start-Job { param($in, $sysF) Get-Content $in -Raw | claude -p --output-format json --model opus --permission-mode bypassPermissions --append-system-prompt-file $sysF 2>&1 | Out-String } -ArgumentList $in, $sysF
while ($job.State -eq "Running") { try { Tg sendChatAction @{ chat_id = $owner; action = "typing" } | Out-Null } catch {}; Wait-Job $job -Timeout 5 | Out-Null }
$raw = Receive-Job $job
try { $ans = ($raw | ConvertFrom-Json).result } catch { $ans = $null }
if (-not $ans) { $ans = "Bulutda xatolik bo'ldi, javob bera olmadim. Kompyuter yoqilganda qayta yozing."; "claude javobi o'qilmadi" }
Say ("☁️ " + $ans)

Append-History @(
  [pscustomobject]@{ id = [guid]::NewGuid().ToString(); src = "bulut"; t = $oshNow; who = "Yusuf"; text = $userText },
  [pscustomobject]@{ id = [guid]::NewGuid().ToString(); src = "bulut"; t = $oshNow; who = "Yordamchi"; text = $ans })
"javob yuborildi"
