import re

# Lecture du fichier
with open('CP_FXConstellation.lua', 'r', encoding='utf-8') as f:
    content = f.read()

# Remplacement des appels aux fonctions granulaires
replacements = [
    # Remplace initializeGranularGrid() par GranularEngine.InitializeGrid(state)
    (r'\binitializeGranularGrid\(\)', 'GranularEngine.InitializeGrid(state)'),
    
    # Remplace randomizeGranularGrid() par GranularEngine.RandomizeGrid(state)
    (r'\brandomizeGranularGrid\(\)', 'GranularEngine.RandomizeGrid(state)'),
    
    # Remplace applyGranularGesture(x, y) par GranularEngine.ApplyGesture(x, y, state)
    (r'\bapplyGranularGesture\(([\w_]+),\s*([\w_]+)\)', r'GranularEngine.ApplyGesture(\1, \2, state)'),
]

# Applique les remplacements
for pattern, replacement in replacements:
    content = re.sub(pattern, replacement, content)

# Sauvegarde
with open('CP_FXConstellation.lua', 'w', encoding='utf-8') as f:
    f.write(content)

print("Refactoring completed!")
print("Replaced:")
print("- initializeGranularGrid() -> GranularEngine.InitializeGrid(state)")
print("- randomizeGranularGrid() -> GranularEngine.RandomizeGrid(state)")
print("- applyGranularGesture(x, y) -> GranularEngine.ApplyGesture(x, y, state)")
