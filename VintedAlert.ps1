# VintedAlert - surveille des recherches Vinted et envoie une notif sur le téléphone (via ntfy.sh)
# -UnTour : fait une seule vérification puis s'arrête (utilisé par GitHub Actions)
param([switch]$UnTour)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Dossier    = $PSScriptRoot
$ConfigPath = Join-Path $Dossier 'config.json'
$SeenPath   = Join-Path $Dossier 'deja_vus.json'
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
$SurGitHub = [bool]$env:GITHUB_ACTIONS
$MaxNotifsParTour = 10
if (-not $SurGitHub) { $Host.UI.RawUI.WindowTitle = 'VintedAlert' }

function Log($msg, $color = 'Gray') { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) -ForegroundColor $color }

function Load-Config {
    $cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($env:NTFY_TOPIC) {
        # Sur GitHub le canal est un "secret" : il n'apparaît pas dans les fichiers publics
        $cfg.ntfy_topic = $env:NTFY_TOPIC
    } elseif (-not $cfg.ntfy_topic) {
        if ($SurGitHub) { throw "Le secret NTFY_TOPIC n'est pas configuré sur GitHub" }
        # Premier lancement : on crée un nom de canal secret et on l'enregistre
        $cfg.ntfy_topic = 'vinted-' + -join ((48..57) + (97..122) | Get-Random -Count 12 | ForEach-Object { [char]$_ })
        ($cfg | ConvertTo-Json -Depth 5) | Out-File $ConfigPath -Encoding utf8
        Log "Nouveau canal de notification créé : $($cfg.ntfy_topic)" Yellow
    }
    return $cfg
}

function Load-Seen {
    $s = @{ ids = New-Object System.Collections.Generic.List[string]; set = @{}; init = @{} }
    if (Test-Path $SeenPath) {
        $d = Get-Content $SeenPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($id in @($d.ids)) { if ($id -and -not $s.set.ContainsKey("$id")) { $s.ids.Add("$id"); $s.set["$id"] = $true } }
        foreach ($u in @($d.init)) { if ($u) { $s.init[$u] = $true } }
    }
    return $s
}

function Save-Seen($s) {
    $ids = $s.ids; if ($ids.Count -gt 5000) { $ids = $ids.GetRange($ids.Count - 5000, 5000) }
    @{ ids = @($ids); init = @($s.init.Keys) } | ConvertTo-Json -Compress | Out-File $SeenPath -Encoding utf8
}

function Get-ItemsLeboncoin($url) {
    # Le site bloque les robots, mais l'API de l'appli mobile répond : on lui envoie le texte de la recherche
    $texte = [regex]::Match($url, '[?&]text=([^&]*)').Groups[1].Value
    if (-not $texte) { throw "l'URL Leboncoin doit contenir text=... (ex: https://www.leboncoin.fr/recherche?text=tamron)" }
    $texte = [Uri]::UnescapeDataString($texte.Replace('+', ' '))
    $req = @{ limit = 35; filters = @{ keywords = @{ text = $texte } }; sort_by = 'time'; sort_order = 'desc' } | ConvertTo-Json -Depth 5 -Compress
    $rep = Invoke-RestMethod 'https://api.leboncoin.fr/finder/search' -Method Post -TimeoutSec 30 `
        -Headers @{ api_key = 'ba0c2dad52b3ec' } -UserAgent 'LBC;Android;11;SM-G973F;phone;0;wifi;5.80.0' `
        -Body ([Text.Encoding]::UTF8.GetBytes($req)) -ContentType 'application/json; charset=utf-8'
    foreach ($a in @($rep.ads)) {
        $prix = if ($a.price) { [double]@($a.price)[0] } else { $null }
        [pscustomobject]@{
            Id    = "lbc-$($a.list_id)"
            Titre = $a.subject
            Desc  = "$($a.subject) - $prix € - $($a.location.city) (Leboncoin)"
            Prix  = $prix
            Url   = $a.url
            Image = @($a.images.urls)[0]
        }
    }
}

function Get-Items($url) {
    if ($url -match 'leboncoin\.fr') { return Get-ItemsLeboncoin $url }
    # Force le tri "plus récents d'abord"
    if ($url -notmatch 'order=') { $url += $(if ($url -match '\?') { '&' } else { '?' }) + 'order=newest_first' }
    $html = (Invoke-WebRequest $url -UserAgent $UA -UseBasicParsing -TimeoutSec 30).Content

    $images = @{}
    foreach ($m in [regex]::Matches($html, '<img[^>]*?src="([^"]+)"[^>]*?data-testid="product-item-id-(\d+)--image--img"')) {
        $images[$m.Groups[2].Value] = $m.Groups[1].Value
    }
    $items = [ordered]@{}
    foreach ($m in [regex]::Matches($html, 'href="(/items/(\d+)-[^"?]*)[^"]*"[^>]*?data-testid="product-item-id-\d+--overlay-link"[^>]*?title="([^"]*)"')) {
        $id = $m.Groups[2].Value
        if ($items.Contains($id)) { continue }
        $desc = [System.Net.WebUtility]::HtmlDecode($m.Groups[3].Value)
        $prix = $null
        $pm = [regex]::Match($desc, '(\d[\d  ]*(?:[.,]\d{1,2})?)\s*€')
        if ($pm.Success) { $prix = [double](($pm.Groups[1].Value -replace '[\s  ]', '') -replace ',', '.') }
        $items[$id] = [pscustomobject]@{
            Id    = $id
            Titre = ($desc -split ', Marque:')[0]
            Desc  = $desc
            Prix  = $prix
            Url   = 'https://www.vinted.fr' + $m.Groups[1].Value
            Image = $images[$id]
        }
    }
    if ($items.Count -eq 0) { throw "aucune annonce trouvée sur la page (Vinted bloque ou a changé son site ?)" }
    return $items.Values
}

function Send-Notif($topic, $nomRecherche, $item) {
    $body = @{
        topic    = $topic
        title    = "[$nomRecherche] $($item.Titre)"
        message  = $item.Desc
        click    = $item.Url
        tags     = @('shopping')
        priority = 4
    }
    if ($item.Image) { $body.attach = $item.Image }
    $json = $body | ConvertTo-Json -Compress
    Invoke-RestMethod 'https://ntfy.sh/' -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8' | Out-Null
}

# --- Démarrage ---
$cfg = Load-Config
$seen = Load-Seen

Write-Host ''
Write-Host '  ===== VintedAlert =====' -ForegroundColor Cyan
if (-not $SurGitHub) {
    Write-Host "  Sur ton tel : installe l'appli 'ntfy' et abonne-toi au canal :" -ForegroundColor Cyan
    Write-Host "      $($cfg.ntfy_topic)" -ForegroundColor Green
    Write-Host '  (Ctrl+C ou ferme la fenêtre pour arrêter)' -ForegroundColor DarkGray
}
Write-Host ''

while ($true) {
    $cfg = Load-Config   # relu à chaque tour : tu peux modifier config.json sans relancer
    foreach ($r in $cfg.recherches) {
        try {
            $items = @(Get-Items $r.url)
            $nouveaux = @($items | Where-Object { -not $seen.set.ContainsKey($_.Id) })
            [array]::Reverse($nouveaux)   # du plus ancien au plus récent
            foreach ($it in $nouveaux) { $seen.set[$it.Id] = $true; $seen.ids.Add($it.Id) }

            if (-not $seen.init.ContainsKey($r.url)) {
                # Nouvelle recherche : on ne notifie pas tout ce qui existe déjà
                $seen.init[$r.url] = $true
                Log "$($r.nom) : $($items.Count) annonces actuelles mémorisées, j'attends les nouvelles..." DarkCyan
                continue
            }
            $envoyes = 0
            foreach ($it in $nouveaux) {
                if ($r.prix_max -and $it.Prix -and $it.Prix -gt $r.prix_max) { continue }
                $interdit = $r.mots_interdits | Where-Object { $_ -and $it.Desc -match [regex]::Escape($_) }
                if ($interdit) { continue }
                # Tous les mots requis doivent être dans le titre (la recherche Vinted est floue)
                $manquant = $r.mots_requis | Where-Object { $_ -and $it.Titre -notmatch [regex]::Escape($_) }
                if ($manquant) { continue }
                if ($envoyes -ge $MaxNotifsParTour) { continue }
                $envoyes++
                Log "NOUVEAU [$($r.nom)] $($it.Prix) € - $($it.Titre)" Green
                Log "   $($it.Url)" DarkGray
                try { Send-Notif $cfg.ntfy_topic $r.nom $it } catch { Log "Notif non envoyée : $($_.Exception.Message)" Red }
                if (-not $SurGitHub) { [console]::Beep(1000, 200) }
            }
            if ($nouveaux.Count -eq 0) { Log "$($r.nom) : rien de neuf" }
        } catch {
            Log "$($r.nom) : erreur ($($_.Exception.Message)), je réessaie au prochain tour" Red
        }
        Start-Sleep -Seconds (Get-Random -Minimum 2 -Maximum 5)
    }
    Save-Seen $seen
    if ($UnTour) { break }
    $attente = [int]$cfg.intervalle_secondes; if ($attente -lt 30) { $attente = 30 }
    Start-Sleep -Seconds ($attente + (Get-Random -Minimum 0 -Maximum 15))
}
