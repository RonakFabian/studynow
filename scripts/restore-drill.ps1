# Restore drill: back up -> add data AFTER the backup -> destroy everything incl. the DB volume
# -> restore from the encrypted off-site copy -> prove the app is healthy and measure RTO / RPO.
# Run from the repo root:  powershell -ExecutionPolicy Bypass -File scripts\restore-drill.ps1
$ErrorActionPreference = 'Continue'   # docker writes progress to stderr; we check exit codes explicitly
$env:COMPOSE_PROFILES = 'blue,green'   # so down/up see both colours
$bash = 'C:\Program Files\Git\bin\bash.exe'
$base = 'http://localhost'
function Now { [DateTime]::UtcNow }
function Step($m) { Write-Host ("[{0:HH:mm:ss}Z] {1}" -f (Now), $m) -ForegroundColor Cyan }
function Counts {
  'print("users=" + db.users.countDocuments({}) + " courses=" + db.courses.countDocuments({}))' |
    docker compose exec -T mongo sh -c 'mongosh --quiet -u $MONGO_APP_USER -p $MONGO_APP_PASSWORD --authenticationDatabase $MONGO_APP_DB $MONGO_APP_DB'
}
function Api($path, $method = 'GET', $body = $null, $token = $null) {
  $h = @{}; if ($token) { $h.Authorization = "Bearer $token" }
  if ($body) { Invoke-RestMethod "$base$path" -Method $method -Headers $h -ContentType 'application/json' -Body ($body | ConvertTo-Json) }
  else { Invoke-RestMethod "$base$path" -Method $method -Headers $h }
}
$pw = 'drill-password-1'

Step 'Check the stack is up (deploy first with scripts/deploy.sh <tag> if not)'
if (-not (Api '/api/health').db) { throw 'stack is not healthy - run scripts/deploy.sh first' }

Step 'Seed data BEFORE the backup (user drill-before + one course)'
$tag = Get-Random
$pre = Api '/api/auth/register' 'POST' @{ name = 'Drill Before'; email = "drill-before-$tag@example.com"; password = $pw }
Api '/api/courses' 'POST' @{ title = "Before backup $tag"; level = 'GCSE'; description = 'exists in the backup'; weeks = 3 } $pre.token | Out-Null
Write-Host "  DB now: $(Counts)"

Step 'Take an encrypted backup (this is the recovery point)'
docker compose run --rm --no-deps backup backup.sh
$backupTime = Now
$file = (Get-ChildItem offsite -Filter 'studyuk-*.age' | Sort-Object Name | Select-Object -Last 1)
Write-Host "  backup file: $($file.Name) ($($file.Length) bytes) - ciphertext, first bytes: $((Get-Content $file.FullName -TotalCount 1 -Encoding Byte)[0..6] -join ' ')"

Step 'Add data AFTER the backup (this is what an outage would lose)'
Start-Sleep -Seconds 20
$post = Api '/api/auth/register' 'POST' @{ name = 'Drill After'; email = "drill-after-$tag@example.com"; password = $pw }
Api '/api/courses' 'POST' @{ title = "After backup $tag"; level = 'GCSE'; description = 'NOT in the backup'; weeks = 3 } $post.token | Out-Null
$countsBefore = Counts
Write-Host "  DB before disaster: $countsBefore"

Step '*** DISASTER: destroying containers AND the MongoDB volume ***'
$disaster = Now
$sw = [Diagnostics.Stopwatch]::StartNew()
docker compose down -v --remove-orphans 2>&1 | Out-Null
Write-Host "  volumes left: $((docker volume ls -q | Select-String 'mongo_data') -join '')"

Step 'RECOVERY 1/4: start an empty MongoDB (auth + app user are created by the init script)'
docker compose up -d mongo | Out-Null

Step 'RECOVERY 2/4: restore from the newest encrypted off-site backup'
for ($i = 1; $i -le 30; $i++) {
  docker compose run --rm --no-deps restore 2>&1 | ForEach-Object { Write-Host "  $_" }
  if ($LASTEXITCODE -eq 0) { break }
  Write-Host "  mongo not ready yet (attempt $i), retrying..."; Start-Sleep -Seconds 3
}
if ($LASTEXITCODE -ne 0) { throw 'restore failed' }

Step 'RECOVERY 3/4: start the app (scripts/start.sh: live colour + gateway + backup)'
& $bash scripts/start.sh 2>&1 | ForEach-Object { Write-Host "  $_" }

Step 'RECOVERY 4/4: wait for /api/health'
do {
  Start-Sleep -Seconds 1
  $ok = try { (Invoke-RestMethod "$base/api/health").db } catch { $false }
} until ($ok -or $sw.Elapsed.TotalSeconds -gt 300)
$healthy = $sw.Elapsed.TotalSeconds
Step ("App healthy again after {0:N1}s" -f $healthy)

Step 'Verify the restored data through the app'
$countsAfter = Counts
Write-Host "  DB after restore:  $countsAfter"
$login = Api '/api/auth/login' 'POST' @{ email = "drill-before-$tag@example.com"; password = $pw }
$mine = (Api '/api/courses' 'GET' $null $login.token) | Where-Object { $_.mine }
Write-Host "  pre-backup user can log in, and sees its course: $($mine.title)"
try { Api '/api/auth/login' 'POST' @{ email = "drill-after-$tag@example.com"; password = $pw } | Out-Null; Write-Host '  UNEXPECTED: post-backup user exists' }
catch { Write-Host '  post-backup user is gone (expected - this is the data-loss window)' }

Write-Host ''
Write-Host '================ RESULT ================' -ForegroundColor Green
Write-Host ("RTO (disaster -> app healthy):      {0:N1} s" -f $healthy)
Write-Host ("RPO actually lost in this drill:    {0:N0} s  (last backup {1:HH:mm:ss}Z -> disaster {2:HH:mm:ss}Z)" -f ($disaster - $backupTime).TotalSeconds, $backupTime, $disaster)
Write-Host "Design RPO (worst case):            backup interval = 3600 s (hourly)"
Write-Host "Before disaster: $countsBefore"
Write-Host "After restore:   $countsAfter"
