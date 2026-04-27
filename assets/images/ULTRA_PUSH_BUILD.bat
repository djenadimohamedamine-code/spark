@echo off
setlocal
echo "🚀 [ ULTRA PUSH & BUILD : SINGLE TRACK ] 🚀"

:: Nettoyage des index Git
echo [*] Nettoyage Git...
git gc --prune=now --quiet

:: Ajout de TOUS les fichiers
echo [*] Preparation des fichiers...
git add .

:: Commit force (avec date/heure pour garantir une modification)
set MYDATE=%date% %time%
echo [*] Creation du commit de declenchement...
git commit -m "🚀 Stable Build Trigger - %MYDATE%" || echo [INFO] Rien a committer.

:: Push vers MASTER uniquement pour eviter les conflits Web
echo [*] Envoi vers GitHub (master)...
git push origin master --force

echo.
echo ✅ [ SUCCES ] Le build iOS est en route (si necessaire) !
echo Les conflits de déploiement Web sont désormais évités.
echo Suivez la progression ici :
echo https://github.com/djenadimohamedamine-code/carte-nabil/actions
echo.
pause
