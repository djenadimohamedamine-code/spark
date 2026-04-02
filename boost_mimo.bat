@echo off
title --- MIMO SPARK PERF BOOST (i3/8GB Optimization) ---
echo.
echo    [ MIMO SPARK PERFORMANCE BOOSTER ]
echo    Optimisation de Windows pour coder sans lag...
echo.

:: 1. Force le plan de performances "Performances Elevées"
echo [+] Activation du plan Performance d'Alimentation...
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c >nul 2>&1

:: 2. Augmente la priorité de VS Code et Node (qui fait tourner l'IA)
echo [+] Priorité HAUTE pour VS Code & Node.exe...
powershell -Command "Get-Process Code | ForEach-Object { $_.PriorityClass = 'AboveNormal' }" >nul 2>&1
powershell -Command "Get-Process node | ForEach-Object { $_.PriorityClass = 'AboveNormal' }" >nul 2>&1

:: 3. Augmente la priorité de Dart et Flutter (Compilation)
echo [+] Priorité HAUTE pour Dart/Flutter...
powershell -Command "Get-Process dart | ForEach-Object { $_.PriorityClass = 'High' }" >nul 2>&1

:: 4. Nettoyage mémoire (Cache système)
echo [+] Purge des fichiers temporaires (Disk Cleanup)...
del /s /f /q %temp%\*.* >nul 2>&1

:: 5. Message final
echo.
echo --- OPTIMISATION TERMINEE ---
echo Garde cette fenetre ouverte ou relance-la si ca ralentit !
echo.
pause
