# Script PowerShell pour ajouter automatiquement des headers ReaPack à tous vos scripts
# Sauvegardez ce fichier comme "add_headers.ps1" dans votre dossier CP_Scripts

$baseHeader = @"
--[[
@description CP - {SCRIPT_NAME}
@author Cedric Pamallo
@version 1.0
@changelog Version initiale
--]]

"@

# Fonction pour traiter un fichier
function Add-Header {
    param($FilePath)
    
    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $content = Get-Content $FilePath -Raw
    
    # Vérifier si le header existe déjà
    if ($content -match '@version') {
        Write-Host "Header déjà présent dans: $fileName" -ForegroundColor Yellow
        return
    }
    
    # Remplacer le placeholder par le nom du script
    $header = $baseHeader -replace '\{SCRIPT_NAME\}', $fileName
    
    # Ajouter le header au début du fichier
    $newContent = $header + $content
    
    # Sauvegarder le fichier
    Set-Content $FilePath $newContent -Encoding UTF8
    Write-Host "Header ajouté à: $fileName" -ForegroundColor Green
}

# Traiter tous les fichiers .lua dans Scripts/ et ses sous-dossiers
$scriptFiles = Get-ChildItem -Path "Scripts" -Filter "*.lua" -Recurse

if ($scriptFiles.Count -eq 0) {
    Write-Host "Aucun fichier .lua trouvé dans le dossier Scripts/" -ForegroundColor Red
    Write-Host "Vérifiez que vos scripts sont dans Scripts/Various/ ou Scripts/MIDI Editor/" -ForegroundColor Yellow
} else {
    Write-Host "Traitement de $($scriptFiles.Count) fichiers..." -ForegroundColor Cyan
    foreach ($file in $scriptFiles) {
        Add-Header $file.FullName
    }
    Write-Host "Terminé ! Vous pouvez maintenant faire git push pour régénérer l'index." -ForegroundColor Green
}

# Afficher la structure attendue
Write-Host "`nStructure attendue:" -ForegroundColor Cyan
Write-Host "CP_Scripts/" -ForegroundColor White
Write-Host "├── Scripts/" -ForegroundColor White  
Write-Host "│   ├── Various/" -ForegroundColor White
Write-Host "│   │   ├── script1.lua" -ForegroundColor White
Write-Host "│   │   └── script2.lua" -ForegroundColor White
Write-Host "│   └── MIDI Editor/" -ForegroundColor White
Write-Host "│       └── script3.lua" -ForegroundColor White
Write-Host "└── index.xml" -ForegroundColor White